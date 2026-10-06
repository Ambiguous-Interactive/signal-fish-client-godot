#!/usr/bin/env python3
"""Run Godot suites in isolated project copies."""

from __future__ import annotations

import hashlib
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile
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

# Issue #317 groundwork: the real GodotSteam GDExtension needs Godot 4.4+
# (GDE 4.16+ dropped the 4.1-4.3 libraries, and no 4.3-compatible build ships
# linux arm64), so the lane pins the CI matrix's 4.4.1 engine instead of the
# PATH godot. Checksums pin the downloads; the GDE zip carries linux64 and
# linuxarm64 libraries.
STEAM_ENGINE_VERSION = "4.4.1-stable"
STEAM_ENGINE_BASE_URL = "https://github.com/godotengine/godot/releases/download/4.4.1-stable"
STEAM_ENGINE_ARCHIVES = {
    "x86_64": (
        "x86_64",
        f"{STEAM_ENGINE_BASE_URL}/Godot_v4.4.1-stable_linux.x86_64.zip",
        "d6e382fb531019f85630c1f485a561a0d20c4a2344b6c3847735cfee7da812aa",
    ),
    "aarch64": (
        "arm64",
        f"{STEAM_ENGINE_BASE_URL}/Godot_v4.4.1-stable_linux.arm64.zip",
        "07e170b208f91a5bd663fae40f2731fdba1ee3380e4fea90a0d0131e0d3522df",
    ),
}
STEAM_GDE_ARCHIVE = (
    "https://codeberg.org/godotsteam/godotsteam/releases/download/v4.21-gde/"
    "godotsteam-4.21-gdextension-plugin-4.4.zip",
    "288c41f9f9cf974d9da0566c54be8a14b849777aae88571f874b7390c3fb98bf",
)
STEAM_GROUNDWORK = "tests/smoke/run_steam_groundwork.gd"


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


def godot_command(script: str, project: Path, engine: Path | None = None) -> list[str]:
    binary = str(engine) if engine is not None else GODOT
    command = [binary, "--headless", "--path", str(project)]
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


def install_steam_gde(project: Path, gde_root: Path) -> None:
    # Replace, never merge: an untracked local GodotSteam checkout must not
    # leak other-version files into the pinned install.
    shutil.rmtree(project / "addons" / "godotsteam", ignore_errors=True)
    shutil.copytree(gde_root / "addons" / "godotsteam", project / "addons" / "godotsteam")


def run_steam_worker(script: str, archive: Path, engine: Path, gde_root: Path) -> Result:
    try:
        with tempfile.TemporaryDirectory(
            prefix="signal-fish-steam-ext.",
            dir=os.environ.get("RUNNER_TEMP") or tempfile.gettempdir(),
        ) as parent:
            project = copy_project(Path(parent), archive, None)
            install_steam_gde(project, gde_root)
            # The .gdextension only registers after an import scan, so a
            # successful pass is what makes the singleton appear at all.
            import_status, import_output = capture(
                [str(engine), "--headless", "--path", str(project), "--import"]
            )
            if import_status != 0:
                return import_status, f"steam-ext import pass failed:\n{import_output}"
            return capture(godot_command(script, project, engine))
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


def steam_cache() -> Path:
    override = os.environ.get("SF_STEAM_EXT_CACHE")
    if override:
        return Path(override)
    runner_temp = os.environ.get("RUNNER_TEMP")
    if runner_temp:
        return Path(runner_temp) / "signal-fish-steam-ext"
    return Path(tempfile.gettempdir()) / "signal-fish-steam-ext"


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def fetch_pinned(url: str, checksum: str, target: Path) -> Path:
    if target.is_file() and file_sha256(target) == checksum:
        return target
    target.parent.mkdir(parents=True, exist_ok=True)
    print(f"steam-ext: downloading {url}")
    # Pid-stamped: two lane invocations sharing a cache must not interleave
    # writes into one temp file.
    partial = target.with_name(f"{target.name}.{os.getpid()}.part")
    with (
        urllib.request.urlopen(url, timeout=60) as response,  # noqa: S310 - pinned constant
        partial.open("wb") as sink,
    ):
        shutil.copyfileobj(response, sink)
    if file_sha256(partial) != checksum:
        partial.unlink()
        raise RuntimeError(f"{target.name} does not match the pinned sha256")
    os.replace(partial, target)
    return target


def unzip(archive: Path, target: Path) -> None:
    # Extract beside the target and swap, so an interrupted run can never
    # leave a half-extracted dir that a later run would reuse. Pid-stamped
    # for the same reason as the download temp file.
    staging = target.with_name(f"{target.name}.{os.getpid()}.partial")
    shutil.rmtree(staging, ignore_errors=True)
    staging.mkdir(parents=True)
    with zipfile.ZipFile(archive) as bundle:
        bundle.extractall(staging)
    shutil.rmtree(target, ignore_errors=True)
    staging.rename(target)


def steam_engine(toolchain: Path) -> Path:
    machine = platform.machine()
    if machine not in STEAM_ENGINE_ARCHIVES:
        raise RuntimeError(f"no pinned GodotSteam engine for {machine}")
    flavor, url, checksum = STEAM_ENGINE_ARCHIVES[machine]
    archive = fetch_pinned(url, checksum, toolchain / "downloads" / url.rsplit("/", 1)[-1])
    # The extract dirs carry the verified checksum so a corrected pin can
    # never run stale bytes (cache-stamp rule).
    engine_dir = toolchain / f"engine-{STEAM_ENGINE_VERSION}-{machine}-{checksum[:12]}"
    binary = engine_dir / f"Godot_v{STEAM_ENGINE_VERSION}_linux.{flavor}"
    if not binary.is_file():
        unzip(archive, engine_dir)
    if not binary.is_file():
        raise RuntimeError(f"engine archive has no {binary.name}")
    mode = binary.stat().st_mode | 0o111
    binary.chmod(mode)
    return binary


def steam_gde(toolchain: Path) -> Path:
    url, checksum = STEAM_GDE_ARCHIVE
    archive = fetch_pinned(url, checksum, toolchain / "downloads" / url.rsplit("/", 1)[-1])
    # Checksum-stamped like the engine dirs: a corrected pin never runs
    # stale bytes (cache-stamp rule).
    gde_root = toolchain / f"godotsteam-gde-{checksum[:12]}"
    marker = gde_root / "addons" / "godotsteam" / "godotsteam.gdextension"
    if not marker.is_file():
        unzip(archive, gde_root)
    if not marker.is_file():
        raise RuntimeError("the GDExtension archive layout changed")
    return gde_root


def steam_ext() -> int:
    if not sys.platform.startswith("linux"):
        print(
            "steam-ext: only linux is pinned today; extend STEAM_ENGINE_ARCHIVES for more",
            file=sys.stderr,
        )
        return 2
    toolchain = steam_cache()
    try:
        engine = steam_engine(toolchain)
        gde_root = steam_gde(toolchain)
    except (OSError, RuntimeError) as exc:
        print(f"steam-ext toolchain failed: {exc}", file=sys.stderr)
        return 1
    stages: list[tuple[str, str]] = [("groundwork", STEAM_GROUNDWORK), *SUITES.items()]
    with tempfile.TemporaryDirectory(
        prefix="signal-fish-steam-ext-prep.",
        dir=os.environ.get("RUNNER_TEMP") or tempfile.gettempdir(),
    ) as prep_name:
        archive = Path(prep_name) / "proj.tar"
        status, output = make_archive(archive)
        if status != 0:
            print(output, end="", file=sys.stderr)
            return status
        with ThreadPoolExecutor(max_workers=min(4, len(stages))) as pool:
            futures = [
                (name, pool.submit(run_steam_worker, script, archive, engine, gde_root))
                for name, script in stages
            ]
            results = [(name, future.result()) for name, future in futures]
    failed = 0
    for name, (stage_status, stage_output) in results:
        print(f"=== steam-ext: {name} ===")
        failed |= int(report(stage_output, stage_status) != 0)
    return failed


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
        print("usage: run-runtime-godot.py [godot [suites...]|smoke|steam-ext]", file=sys.stderr)
        return 2
    if sys.argv[1] == "godot":
        return run_suites(sys.argv[2:])
    if sys.argv[1] == "smoke" and len(sys.argv) == 2:
        status, output = run_worker("tests/smoke/run_websocket_smoke.gd", None, None)
        return report(output, status)
    if sys.argv[1] == "steam-ext" and len(sys.argv) == 2:
        return steam_ext()
    print("usage: run-runtime-godot.py [godot [suites...]|smoke|steam-ext]", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
