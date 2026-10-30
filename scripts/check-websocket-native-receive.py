#!/usr/bin/env python3
"""Qualify native WebSocket assembly with paced local frame writes (opt-in)."""

from __future__ import annotations

import argparse
import hashlib
import itertools
import json
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = {
    "limit": ("run_websocket_fragment_limit.gd", "FRAGMENT_LIMIT_RESULT "),
    "reuse": ("run_websocket_fragment_reuse.gd", "REDIAL_RESULT "),
    "burst": ("run_websocket_receive_boundary.gd", "WEBSOCKET_RECEIVE_RESULT "),
    "close": ("run_websocket_close_reason.gd", "CLOSE_REASON_RESULT "),
}


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def cases() -> list[tuple[str, str, list[str]]]:
    result = []
    for profile, capacity, chunk, fragment in [("byte", 31, 1, 9), ("chunk", 4095, 127, 127)]:
        wire = [f"--wire-chunk-bytes={chunk}", "--wire-delay-ms=1"]
        for kind, control, oversize in itertools.product(
            ["text", "binary"], ["none", "ping", "pong"], ["false", "true"]
        ):
            result.append(
                (
                    f"{profile}-limit-{kind}-{control}-{oversize}",
                    "limit",
                    [
                        *wire,
                        f"--capacity={capacity}",
                        f"--message-type={kind}",
                        f"--fragment-control={control}",
                        f"--oversize={oversize}",
                    ],
                )
            )
        for old, fresh, replacement in itertools.product(
            ["text", "binary"], ["text", "binary"], ["closing", "aborted", "handshake"]
        ):
            pending = ["--pending-wire-before-replace=true"] if replacement != "handshake" else []
            result.append(
                (
                    f"{profile}-reuse-{old}-{fresh}-{replacement}",
                    "reuse",
                    [
                        *wire,
                        *pending,
                        f"--partial-type={old}",
                        f"--fresh-type={fresh}",
                        f"--replacement={replacement}",
                        "--queued-before-partial=true",
                    ],
                )
            )
        for control in ["none", "ping", "pong"]:
            result.append(
                (
                    f"{profile}-burst-alternating-{control}",
                    "burst",
                    [
                        *wire,
                        f"--body-bytes={capacity}",
                        f"--capacity={capacity}",
                        f"--credit={capacity}",
                        f"--fragment-bytes={fragment}",
                        f"--fragment-control={control}",
                        "--message-type=alternating",
                        "--empty-fragments=true",
                        "--max-queued-packets=2",
                    ],
                )
            )
    for chunk, reason, origin in itertools.product(
        [1, 2, 3, 5, 65536],
        ["empty", "ascii", "two", "three", "four", "mixed"],
        ["server", "client"],
    ):
        result.append(
            (
                f"close-{chunk}-{reason}-{origin}",
                "close",
                [
                    f"--wire-chunk-bytes={chunk}",
                    "--wire-delay-ms=10",
                    f"--reason={reason}",
                    f"--origin={origin}",
                ],
            )
        )
    for reason, origin in itertools.product(
        ["empty", "ascii", "two", "three", "four", "mixed"], ["server", "client"]
    ):
        result.append(
            (
                f"close-full-{reason}-{origin}",
                "close",
                [
                    "--wire-chunk-bytes=3",
                    "--wire-delay-ms=10",
                    f"--reason={reason}",
                    f"--origin={origin}",
                    "--full-fragment=true",
                ],
            )
        )
    return result


def run(command: list[str], log: Path, timeout: int) -> dict[str, object]:
    timed_out = False
    with log.open("w") as stream:
        try:
            completed = subprocess.run(  # noqa: S603 - Explicit local engine path and fixed fixture options.
                command, stdout=stream, stderr=subprocess.STDOUT, timeout=timeout, check=False
            )
            returncode = completed.returncode
        except subprocess.TimeoutExpired:
            timed_out = True
            returncode = None
    output = log.read_text(errors="replace")
    return {
        "command": command,
        "returncode": returncode,
        "timed_out": timed_out,
        "engine_errors": "ERROR:" in output,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--godot", type=Path, required=True, help="Native engine or template to test"
    )
    parser.add_argument(
        "--importer", type=Path, required=True, help="Godot editor for fixture import"
    )
    parser.add_argument(
        "--output", type=Path, required=True, help="New directory; every attempt is kept"
    )
    parser.add_argument("--suite", choices=["all", "assembly", "close"], default="all")
    parser.add_argument("--case", action="append", help="Run named cases only (repeatable)")
    args = parser.parse_args()
    selected = [
        case
        for case in cases()
        if (args.case is None or case[0] in args.case)
        and (args.suite == "all" or (case[1] == "close") == (args.suite == "close"))
    ]
    if not selected or (args.case and set(args.case) - {case[0] for case in selected}):
        parser.error("unknown or empty case selection")
    if args.output.exists():
        parser.error("output already exists; use a new directory to retain each attempt")
    binary, importer = args.godot.resolve(), args.importer.resolve()
    if not binary.is_file() or not importer.is_file():
        parser.error("godot and importer must be executable files")
    args.output.mkdir(parents=True)
    project = args.output.resolve() / "project"
    target = project / "tests/smoke"
    target.mkdir(parents=True)
    sources = ["ws_test_server.gd", *(fixture[0] for fixture in FIXTURES.values())]
    for name in sources:
        shutil.copy2(ROOT / "tests/smoke" / name, target / name)
    settings = (ROOT / "project.godot").read_text().split("[debug]\n", 1)[1].split("\n[", 1)[0]
    (project / "project.godot").write_text("config_version=5\n[debug]\n" + settings)
    provenance = {
        "binary": str(binary),
        "binary_sha256": digest(binary),
        "importer": str(importer),
        "importer_sha256": digest(importer),
        "fixtures_sha256": {name: digest(target / name) for name in sources},
        "project_sha256": digest(project / "project.godot"),
    }
    (args.output / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    imported = run(
        [str(importer), "--headless", "--editor", "--path", str(project), "--quit"],
        args.output / "import.log",
        60,
    )
    reports = []
    if imported["returncode"] == 0 and not imported["engine_errors"]:
        for name, kind, options in selected:
            script, marker = FIXTURES[kind]
            log = args.output / f"{name}.log"
            report = run(
                [
                    str(binary),
                    "--headless",
                    "--path",
                    str(project),
                    "--script",
                    f"tests/smoke/{script}",
                    "--",
                    *options,
                ],
                log,
                90,
            )
            records = [
                json.loads(line[len(marker) :])
                for line in log.read_text(errors="replace").splitlines()
                if line.startswith(marker)
            ]
            result = records[0] if len(records) == 1 else {}
            wire = result.get("wire", {})
            paced = (
                wire.get("writes", 0) >= (1 if kind == "close" else 2) and wire.get("error") == 0
            )
            if name.startswith("byte-"):
                paced = paced and wire.get("split_headers", 0) > 0
            report.update(
                case=name,
                result=result,
                passed=report["returncode"] == 0
                and not report["engine_errors"]
                and len(records) == 1
                and result.get("passed") is True
                and paced,
            )
            reports.append(report)
            (args.output / f"{name}.json").write_text(json.dumps(report, indent=2) + "\n")
            print(f"{name}: {'PASS' if report['passed'] else 'FAIL'}", flush=True)
    passed = len(reports) == len(selected) and all(report["passed"] for report in reports)
    summary = {"passed": passed, "import": imported, "cases": reports}
    (args.output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
