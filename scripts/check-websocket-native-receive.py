#!/usr/bin/env python3
"""Qualify native WebSocket assembly with paced local frame writes (opt-in)."""

from __future__ import annotations

import argparse
import hashlib
import itertools
import json
import os
import shlex
import shutil
import subprocess
import sys
import zipfile
from itertools import pairwise
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
    for control in ["none", "ping", "pong"]:
        result.append(
            (
                f"read-control-{control}",
                "burst",
                [
                    "--wire-chunk-bytes=65536",
                    "--capacity=524288",
                    "--body-bytes=4095",
                    "--credit=4095",
                    "--fragment-bytes=127",
                    f"--fragment-control={control}",
                    "--message-type=alternating",
                    "--empty-fragments=true",
                ],
            )
        )
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
    for kind, control, tail in itertools.product(
        ["text", "binary", "unicode"], ["none", "ping", "pong"], ["empty", "oversize"]
    ):
        result.append(
            (
                f"boundary-large-{kind}-{control}-{tail}",
                "limit",
                [
                    "--capacity=131071",
                    "--wire-chunk-bytes=8191",
                    "--wire-delay-ms=1",
                    f"--message-type={kind}",
                    f"--fragment-control={control}",
                    "--control-bytes=125",
                    f"--oversize={'true' if tail == 'oversize' else 'false'}",
                ],
            )
        )
    for control, tail_bytes in itertools.product(["none", "ping", "pong"], [1, 2, 3]):
        result.append(
            (
                f"boundary-unicode-{control}-{tail_bytes}",
                "limit",
                [
                    "--capacity=131071",
                    "--wire-chunk-bytes=8191",
                    "--wire-delay-ms=1",
                    "--message-type=unicode",
                    f"--fragment-control={control}",
                    "--control-bytes=125",
                    f"--tail-bytes={tail_bytes}",
                ],
            )
        )
    for chunk, reason, origin, full in itertools.product(
        [1, 3, 65536], ["max-ascii", "max-mixed"], ["server", "client"], ["false", "true"]
    ):
        result.append(
            (
                f"boundary-close-{chunk}-{reason}-{origin}-{full}",
                "close",
                [
                    "--capacity=127",
                    f"--wire-chunk-bytes={chunk}",
                    "--wire-delay-ms=1",
                    f"--reason={reason}",
                    f"--origin={origin}",
                    f"--full-fragment={full}",
                ],
            )
        )
    for reason, origin in itertools.product(["max-ascii", "max-mixed"], ["server", "client"]):
        result.append(
            (
                f"boundary-large-close-{reason}-{origin}",
                "close",
                [
                    "--capacity=131071",
                    "--wire-chunk-bytes=8191",
                    "--wire-delay-ms=1",
                    f"--reason={reason}",
                    f"--origin={origin}",
                    "--full-fragment=true",
                ],
            )
        )
    return result


def reproduction_files() -> dict[str, bytes]:
    sources = ["ws_test_server.gd", *(fixture[0] for fixture in FIXTURES.values())]
    files = {f"tests/smoke/{name}": (ROOT / "tests/smoke" / name).read_bytes() for name in sources}
    files["project.godot"] = (
        b'config_version=5\n[application]\nconfig/name="WebSocket reproductions"\n'
        b'[rendering]\nrenderer/rendering_method="gl_compatibility"\n'
    )
    commands = {
        "control-bytes": "run_websocket_receive_boundary.gd -- --fragment-bytes=127 --fragment-control=ping --capacity=524288",
        "control-baseline": "run_websocket_receive_boundary.gd -- --fragment-bytes=127 --fragment-control=none --capacity=524288",
        "reuse": "run_websocket_fragment_reuse.gd",
        "reuse-baseline": "run_websocket_fragment_reuse.gd -- --replacement=handshake",
        "full-buffer": "run_websocket_fragment_limit.gd",
        "close-unicode": "run_websocket_close_reason.gd -- --wire-chunk-bytes=3 --wire-delay-ms=10 --reason=two --origin=server",
        "close-baseline": "run_websocket_close_reason.gd -- --reason=two --origin=server",
    }
    lines = [
        "WebSocket engine reproductions (Godot 4.3+)",
        "",
        "Extract this archive. Run commands from the extracted directory.",
        "Only Godot is required. No addon, extension, service or Python is needed.",
        "The fixtures bind a raw TCP server to 127.0.0.1 on a free port.",
        "First import with: godot --headless --editor --path . --quit",
        "Each command exits 0 on success and 1 on an observed failure.",
        "Expected: passed=true, exact packet bytes/types and close metadata.",
        "Official native 4.4.1/4.7.2 fail the four defect cases below.",
        "The three baseline controls pass. 4.3 passes control-bytes and reuse.",
        "Paced writes are local scheduling controls; TCP may coalesce them.",
        "These results do not qualify Web exports or remote networks.",
        "",
    ]
    for name, command in commands.items():
        lines.extend([name, "godot --headless --path . --script tests/smoke/" + command, ""])
    files["README.txt"] = ("\n".join(lines) + "\n").encode()
    files["SHA256SUMS"] = (
        "".join(
            f"{hashlib.sha256(body).hexdigest()}  {name}\n" for name, body in sorted(files.items())
        )
    ).encode()
    return files


def export_reproduction(destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(destination, "x", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, body in sorted(reproduction_files().items()):
            info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, body)


def repro_commands(files: dict[str, bytes], project: Path) -> list[tuple[str, list[str]]]:
    commands: list[tuple[str, list[str]]] = []
    name = ""
    for line in files["README.txt"].decode().splitlines():
        if line.startswith("godot ") and name:
            arguments = shlex.split(line)[1:]
            arguments[arguments.index("--path") + 1] = str(project)
            commands.append((name, arguments))
            name = ""
        elif line.strip():
            name = line.strip()
    if not commands:
        raise ValueError("README lists no reproduction commands")
    return commands


def run_repro(
    binary: Path, importer: Path, runner: Path | None, runner_args: list[str], output: Path
) -> dict[str, object]:
    output.mkdir(parents=True)
    project = output.resolve() / "project"
    project.mkdir()
    files = reproduction_files()
    for name, body in files.items():
        target = project / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(body)
    for line in files["SHA256SUMS"].decode().splitlines():
        expected, name = line.split("  ", 1)
        if digest(project / name) != expected:
            raise ValueError(f"reproduction file mismatch: {name}")
    prefix = [str(runner), *runner_args] if runner else []
    imported = run(
        [str(importer), "--headless", "--editor", "--path", str(project), "--quit"],
        output / "import.log",
        90,
    )
    results = []
    for name, arguments in repro_commands(files, project):
        log = output / f"{name}.log"
        report = run([*prefix, str(binary), *arguments], log, 90)
        text = log.read_text(errors="replace")
        records = [
            json.loads(line.split(" ", 1)[1]) for line in text.splitlines() if "_RESULT " in line
        ]
        report.update(
            name=name,
            records=records,
            passed=report["returncode"] == 0
            and not report["engine_errors"]
            and len(records) == 1
            and records[0].get("passed") is True,
        )
        results.append(report)
        print(f"{name}: {'PASS' if report['passed'] else 'FAIL'}", flush=True)
    summary: dict[str, object] = {
        "binary": str(binary),
        "binary_sha256": digest(binary),
        "importer": str(importer),
        "importer_sha256": digest(importer),
        "runner": str(runner) if runner else None,
        "runner_args": runner_args,
        "import": imported,
        "commands": results,
    }
    (output / "standalone-report.json").write_text(json.dumps(summary, indent=2) + "\n")
    return summary


def run(
    command: list[str], log: Path, timeout: int, env: dict[str, str] | None = None
) -> dict[str, object]:
    timed_out = False
    with log.open("w") as stream:
        try:
            completed = subprocess.run(  # noqa: S603 - Explicit local engine path and fixed fixture options.
                command,
                stdout=stream,
                stderr=subprocess.STDOUT,
                timeout=timeout,
                check=False,
                env=env,
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


def delivery_summary(text: str) -> dict[str, object]:
    packets: list[dict[str, object]] = []
    intervals: list[int] = []
    for line in text.splitlines():
        if line.startswith("WEBSOCKET_RECEIVE_PACKET "):
            try:
                packets.append(json.loads(line[len("WEBSOCKET_RECEIVE_PACKET ") :]))
            except ValueError:
                packets.append({})
        elif line.startswith("WEBSOCKET_RECEIVE_POLL "):
            try:
                poll = json.loads(line[len("WEBSOCKET_RECEIVE_POLL ") :])
            except ValueError:
                continue
            interval = poll.get("interval_us")
            if isinstance(interval, int):
                intervals.append(interval)
    largest: dict[str, object] | None = None
    largest_us = 0
    for previous, current in pairwise(packets):
        before, after = previous.get("delivered_us"), current.get("delivered_us")
        if isinstance(before, int) and isinstance(after, int) and after - before > largest_us:
            largest_us = after - before
            largest = {"after": previous.get("sequence"), "us": largest_us}
    return {
        "packets": len(packets),
        "polls": len(intervals),
        "largest_delivery_gap": largest,
        "largest_poll_interval_us": max(intervals, default=None),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", type=Path, help="Native engine or template to test")
    parser.add_argument("--importer", type=Path, help="Godot editor for fixture import")
    parser.add_argument("--runner", type=Path, help="Optional emulator for the tested engine")
    parser.add_argument(
        "--runner-arg",
        action="append",
        default=[],
        help="Emulator argument (repeatable; use = for flags)",
    )
    parser.add_argument("--output", type=Path, help="New directory; every attempt is kept")
    parser.add_argument(
        "--recv-cap-bytes",
        type=int,
        help="Linux native only: cap each libc recv call (1..65536); requires cc",
    )
    parser.add_argument(
        "--suite", choices=["all", "assembly", "close", "boundaries"], default="all"
    )
    parser.add_argument(
        "--export-repro", type=Path, help="Write a standalone reproduction ZIP and exit"
    )
    parser.add_argument(
        "--run-repro",
        action="store_true",
        help="Run the standalone reproduction commands against --godot into --output",
    )
    parser.add_argument("--case", action="append", help="Run named cases only (repeatable)")
    args = parser.parse_args()
    if args.export_repro and args.run_repro:
        parser.error("--export-repro and --run-repro are mutually exclusive")
    if args.export_repro:
        if (
            args.godot
            or args.importer
            or args.output
            or args.case
            or args.runner
            or args.runner_arg
            or args.recv_cap_bytes is not None
            or args.suite != "all"
        ):
            parser.error("--export-repro cannot be combined with runtime options")
        if args.export_repro.exists():
            parser.error("reproduction archive already exists")
        export_reproduction(args.export_repro.resolve())
        print(
            json.dumps(
                {"archive": str(args.export_repro.resolve()), "sha256": digest(args.export_repro)}
            )
        )
        return 0
    if not args.godot or not args.importer or not args.output:
        parser.error("--godot, --importer and --output are required for runtime checks")
    if args.runner_arg and not args.runner:
        parser.error("--runner-arg requires --runner")
    if args.recv_cap_bytes is not None:
        if not 1 <= args.recv_cap_bytes <= 65536:
            parser.error("--recv-cap-bytes must be 1..65536")
        if sys.platform != "linux" or args.runner:
            parser.error("--recv-cap-bytes requires native Linux without an emulator")
        if not shutil.which("cc"):
            parser.error("--recv-cap-bytes requires cc on PATH")
        if any(character.isspace() or character == ":" for character in str(args.output.resolve())):
            parser.error("--recv-cap-bytes needs an output path without whitespace or colons")
    if args.run_repro and (args.recv_cap_bytes is not None or args.case or args.suite != "all"):
        parser.error("--run-repro cannot select cases, suites or receive caps")
    runner = args.runner.resolve() if args.runner else None
    if runner and not runner.is_file():
        parser.error("runner must be an executable file")
    if args.run_repro:
        if args.output.exists():
            parser.error("output already exists; use a new directory to retain each attempt")
        binary, importer = args.godot.resolve(), args.importer.resolve()
        if not binary.is_file() or not importer.is_file():
            parser.error("godot and importer must be executable files")
        try:
            summary = run_repro(binary, importer, runner, args.runner_arg, args.output)
        except ValueError as error:
            print(f"run-repro failed: {error}", file=sys.stderr)
            return 1
        print(json.dumps({"report": str(args.output / "standalone-report.json")}))
        imported = summary["import"]
        if not isinstance(imported, dict):
            return 1
        return 0 if imported["returncode"] == 0 else 1
    prefix = [str(runner), *args.runner_arg] if runner else []
    selected = [
        case
        for case in cases()
        if (args.case is None or case[0] in args.case)
        and (
            args.suite == "all"
            or args.suite
            == (
                "boundaries"
                if case[0].startswith("boundary-")
                else "close"
                if case[1] == "close"
                else "assembly"
            )
        )
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
        "runner": str(runner) if runner else None,
        "runner_sha256": digest(runner) if runner else None,
        "runner_args": args.runner_arg,
    }
    (args.output / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    library = args.output.resolve() / "recv-cap.so"
    if args.recv_cap_bytes is not None:
        source = ROOT / "scripts/websocket-recv-cap.c"
        shutil.copy2(source, args.output / source.name)
        compiled = run(
            [
                str(shutil.which("cc")),
                "-shared",
                "-fPIC",
                "-O2",
                "-Wall",
                "-Wextra",
                "-Werror",
                str(args.output.resolve() / source.name),
                "-o",
                str(library),
                "-ldl",
                "-pthread",
            ],
            args.output / "recv-cap-build.log",
            60,
        )
        provenance["recv_cap"] = {
            "cap_bytes": args.recv_cap_bytes,
            "source_sha256": digest(source),
            "compile": compiled,
            "library_sha256": digest(library) if library.is_file() else None,
        }
        (args.output / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
        if compiled["returncode"] != 0:
            print("recv cap compilation failed; see recv-cap-build.log", file=sys.stderr)
            return 1
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
            environment = None
            receive_report = args.output.resolve() / f"{name}-recv.json"
            if args.recv_cap_bytes is not None:
                environment = {
                    **os.environ,
                    "LD_PRELOAD": str(library)
                    + (":" + os.environ["LD_PRELOAD"] if os.environ.get("LD_PRELOAD") else ""),
                    "SF_RECV_CAP_BYTES": str(args.recv_cap_bytes),
                    "SF_RECV_CAP_REPORT": str(receive_report),
                }
            report = run(
                [
                    *prefix,
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
                env=environment,
            )
            if environment is not None:
                report["receive_environment"] = {
                    key: environment[key]
                    for key in ("LD_PRELOAD", "SF_RECV_CAP_BYTES", "SF_RECV_CAP_REPORT")
                }
            text = log.read_text(errors="replace")
            records = [
                json.loads(line[len(marker) :])
                for line in text.splitlines()
                if line.startswith(marker)
            ]
            result = records[0] if len(records) == 1 else {}
            wire = result.get("wire", {})
            paced = (
                wire.get("writes", 0) >= (1 if kind == "close" else 2) and wire.get("error") == 0
            )
            if name.startswith("byte-"):
                paced = paced and wire.get("split_headers", 0) > 0
            observed = True
            if args.recv_cap_bytes is not None:
                try:
                    receive = json.loads(receive_report.read_text())
                except (OSError, ValueError):
                    receive = {}
                observed = (
                    receive.get("cap_bytes") == args.recv_cap_bytes
                    and receive.get("limited_reads", 0) > 0
                    and 0 < receive.get("largest_read", 0) <= args.recv_cap_bytes
                )
                report["recv_cap"] = receive
            report.update(
                case=name,
                result=result,
                passed=report["returncode"] == 0
                and not report["engine_errors"]
                and len(records) == 1
                and result.get("passed") is True
                and paced
                and observed,
            )
            delivery = delivery_summary(text)
            if kind == "burst":
                report["delivery"] = delivery
            reports.append(report)
            (args.output / f"{name}.json").write_text(json.dumps(report, indent=2) + "\n")
            print(f"{name}: {'PASS' if report['passed'] else 'FAIL'}", flush=True)
    passed = len(reports) == len(selected) and all(report["passed"] for report in reports)
    summary = {"passed": passed, "import": imported, "cases": reports}
    (args.output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
