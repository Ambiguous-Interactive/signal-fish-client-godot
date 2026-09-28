#!/usr/bin/env python3
"""Run Godot suites in isolated project copies."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from collections.abc import Sequence
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GIT = shutil.which("git") or "git"
TAR = shutil.which("tar") or "tar"
CP = shutil.which("cp") or "cp"
GODOT = shutil.which("godot") or "godot"
SUITES = {
    "protocol": "tests/protocol/run_protocol_tests.gd",
    "transport": "tests/transport/run_transport_tests.gd",
    "client": "tests/client/run_client_tests.gd",
    "binary": "tests/client/run_binary_tests.gd",
    "reconnect": "tests/client/run_reconnect_tests.gd",
    "demo_boot": "@demo",
    "p2p_boot": "@p2p",
}
Result = tuple[int, str]


def capture(command: Sequence[str], data: bytes | None = None) -> Result:
    try:
        result = subprocess.run(  # noqa: S603
            command,
            input=data,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            cwd=ROOT,
        )
    except OSError as exc:
        return 1, f"{command[0]}: {exc}\n"
    return result.returncode, result.stdout.decode(errors="replace")


def in_git_worktree() -> bool:
    return capture([GIT, "rev-parse", "--is-inside-work-tree"])[0] == 0


def git_manifest() -> bytes:
    result = subprocess.run(  # noqa: S603
        [GIT, "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        check=False,
        capture_output=True,
        cwd=ROOT,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.decode(errors="replace") or "git ls-files failed")
    manifest = bytearray()
    root = os.fsencode(ROOT)
    for path in result.stdout.split(b"\0"):
        candidate = os.path.join(root, path)
        if path and (os.path.isfile(candidate) or os.path.islink(candidate)):
            manifest.extend(path)
            manifest.append(0)
    return bytes(manifest)


def make_archive(archive: Path) -> Result:
    if not in_git_worktree():
        return 1, "not in a git worktree\n"
    try:
        manifest = git_manifest()
    except RuntimeError as exc:
        return 1, f"{exc}\n"
    return capture([TAR, "--null", "--files-from=-", "--create", f"--file={archive}"], manifest)


def warm_snapshot(prep: Path) -> Result:
    if os.environ.get("SF_COLD") == "1" or not (ROOT / ".godot").is_dir():
        return 0, ""
    return capture([CP, "-a", ".godot", str(prep / ".godot")])


def copy_project(parent: Path, archive: Path | None, snapshot: Path | None) -> Path:
    project = parent / "project"
    project.mkdir()
    if archive is not None:
        status, output = capture([TAR, "--extract", f"--file={archive}", f"--directory={project}"])
    elif in_git_worktree():
        local_archive = parent / "project.tar"
        status, output = make_archive(local_archive)
        if status == 0:
            status, output = capture(
                [TAR, "--extract", f"--file={local_archive}", f"--directory={project}"]
            )
    else:
        local_archive = parent / "project.tar"
        status, output = capture(
            [
                TAR,
                "--exclude=./.git",
                "--exclude=./.godot",
                "--exclude=./.import",
                "--exclude=./.venv-ci",
                "--exclude=./logs_*.zip",
                "--create",
                f"--file={local_archive}",
                ".",
            ]
        )
        if status == 0:
            status, output = capture(
                [TAR, "--extract", f"--file={local_archive}", f"--directory={project}"]
            )
    if status != 0:
        raise RuntimeError(output or "project copy failed")
    if snapshot is not None:
        status, output = capture([CP, "-a", str(snapshot / ".godot"), str(project / ".godot")])
        if status != 0:
            raise RuntimeError(output or "warm cache copy failed")
    return project


def godot_command(script: str, project: Path) -> list[str]:
    command = [GODOT, "--headless", "--path", str(project)]
    if script == "@demo":
        return [*command, "--quit-after", "3"]
    if script == "@p2p":
        return [*command, "res://demo/p2p.tscn", "--quit-after", "3"]
    return [*command, "--script", script]


def run_worker(script: str, archive: Path | None, snapshot: Path | None) -> Result:
    try:
        with tempfile.TemporaryDirectory(
            prefix="signal-fish-godot-cold.",
            dir=os.environ.get("RUNNER_TEMP") or tempfile.gettempdir(),
        ) as parent:
            project = copy_project(Path(parent), archive, snapshot)
            return capture(godot_command(script, project))
    except (OSError, RuntimeError) as exc:
        return 1, f"godot project setup failed: {exc}\n"


def report(output: str, status: int) -> int:
    if "SCRIPT ERROR" in output:
        print(
            "::error::SCRIPT ERROR in godot output (issue #104): "
            "the aborted test skipped its remaining assertions",
            file=sys.stderr,
        )
        status = 1
    if status != 0 or os.environ.get("SF_VERBOSE") == "1":
        print(output, end="")
    else:
        print("passed (set SF_VERBOSE=1 for full Godot output)")
        diagnostics = [
            line for line in output.splitlines() if line.startswith(("ERROR:", "WARNING:"))
        ]
        for line in diagnostics[:10]:
            print(line)
        if len(diagnostics) > 10:
            print(f"... {len(diagnostics) - 10} more diagnostics")
    return status


def run_suites(names: Sequence[str]) -> int:
    selected = list(names) if names else list(SUITES)
    for name in selected:
        if name not in SUITES:
            print(f"unknown suite: {name} (suites: {' '.join(SUITES)})", file=sys.stderr)
            return 2
    if len(selected) == 1 and os.environ.get("SF_COLD") != "1":
        name = selected[0]
        print(f"=== {name} (warm; SF_COLD=1 for the CI-identical cold copy) ===")
        status, output = capture(godot_command(SUITES[name], ROOT))
        return report(output, status)

    with tempfile.TemporaryDirectory(
        prefix="signal-fish-godot-prep.", dir=os.environ.get("TMPDIR") or tempfile.gettempdir()
    ) as prep_name:
        prep = Path(prep_name)
        archive = prep / "proj.tar"
        with ThreadPoolExecutor(max_workers=2) as pool:
            archive_future = pool.submit(make_archive, archive)
            snapshot_future = pool.submit(warm_snapshot, prep)
            archive_status, archive_output = archive_future.result()
            snapshot_status, snapshot_output = snapshot_future.result()
        if archive_status != 0 or snapshot_status != 0:
            print("::warning::godot prep step failed; using per-worker copies", file=sys.stderr)
            print(archive_output + snapshot_output, end="", file=sys.stderr)
        selected_archive = archive if archive_status == 0 and archive.is_file() else None
        selected_snapshot = prep if snapshot_status == 0 and (prep / ".godot").is_dir() else None
        with ThreadPoolExecutor(max_workers=len(selected)) as pool:
            futures = [
                pool.submit(run_worker, SUITES[name], selected_archive, selected_snapshot)
                for name in selected
            ]
            results = [future.result() for future in futures]
    failed = 0
    for name, (status, output) in zip(selected, results, strict=True):
        print(f"=== {name} ===")
        failed |= int(report(output, status) != 0)
    return failed


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: run-runtime-godot.py [godot [suites...]|smoke]", file=sys.stderr)
        return 2
    if sys.argv[1] == "godot":
        return run_suites(sys.argv[2:])
    if sys.argv[1] == "smoke" and len(sys.argv) == 2:
        status, output = run_worker("tests/smoke/run_websocket_smoke.gd", None, None)
        return report(output, status)
    print("usage: run-runtime-godot.py [godot [suites...]|smoke]", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
