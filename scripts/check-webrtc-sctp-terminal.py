#!/usr/bin/env python3
"""Run actual pinned native SCTP callbacks under controlled disconnect ordering."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shlex
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REVISION = "6b1e2e620f1e37f0eafeee702eaea0043cb305fd"
FILES = (
    "src/impl/sctptransport.cpp",
    "src/impl/sctptransport.hpp",
    "src/impl/transport.cpp",
    "src/impl/transport.hpp",
    "include/rtc/utils.hpp",
)
CASES = frozenset(
    {
        "connecting_failure",
        "connected_loss",
        "repeated_notification",
        "lower_before_notification",
        "lower_before_classification",
        "lower_after_selection",
        "late_comm_up",
        "failed_notification",
        "failed_lower",
        "duplicate_lower",
        "disconnected_notification",
        "delayed_connected_callback",
        "reentrant_disconnect",
        "null_state_callback",
        "null_state_callback_failure",
        "close_connecting",
        "close_during_comm_up",
    }
)
BASELINE_FAILURES = frozenset(
    {
        "lower_before_notification",
        "lower_before_classification",
        "lower_after_selection",
        "late_comm_up",
        "delayed_connected_callback",
        "close_during_comm_up",
    }
)
BASELINE_PASSES = frozenset(
    {"connecting_failure", "connected_loss", "failed_lower", "close_connecting"}
)


def run(command: list[str], log: Path, cwd: Path | None = None) -> str:
    with log.open("a") as stream:
        stream.write(shlex.join(command) + "\n")
        stream.flush()
        environment = os.environ.copy()
        environment["SF_NATIVE_LIFECYCLE"] = "0"
        try:
            result = subprocess.run(  # noqa: S603
                command,
                cwd=cwd,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=120,
                check=False,
                env=environment,
            )
        except subprocess.TimeoutExpired as exc:
            captured = exc.stdout or ""
            stream.write(
                captured.decode(errors="replace") if isinstance(captured, bytes) else captured
            )
            stream.write("\nCommand timed out after 120 seconds\n")
            raise RuntimeError(f"Command timed out; see {log}") from exc
        stream.write(result.stdout + f"\nExit code: {result.returncode}\n")
    if result.returncode:
        raise RuntimeError(f"Command exited {result.returncode}; see {log}")
    return result.stdout


def control_results(raw: str) -> list[dict[str, object]]:
    rows: list[dict[str, object]] = []
    names: set[str] = set()
    for line_number, line in enumerate(raw.splitlines(), start=1):
        try:
            value: object = json.loads(line)
        except json.JSONDecodeError as exc:
            raise RuntimeError(
                f"Invalid JSON on control output line {line_number}: {line[:160]!r}"
            ) from exc
        if not isinstance(value, dict):
            raise RuntimeError("Invalid control record")
        name = value.get("case")
        if not isinstance(name, str) or name in names or type(value.get("passed")) is not bool:
            raise RuntimeError("Missing, duplicate or invalid control case")
        if any(
            type(value.get(key)) is not int
            for key in ("state", "state_callbacks", "eof_callbacks", "errors")
        ):
            raise RuntimeError("Invalid control counters")
        names.add(name)
        rows.append(value)
    if names != CASES:
        raise RuntimeError(
            f"Control cases differ: missing={sorted(CASES - names)}, extra={sorted(names - CASES)}"
        )
    return rows


def instrument(root: Path, repaired: bool) -> None:
    impl = root / "src/impl"
    header = impl / "sctptransport.hpp"
    header.write_text(
        header.read_text().replace(
            "private:\n", "private:\n\tfriend struct SctpTerminalControl;\n", 1
        )
    )
    source = impl / "sctptransport.cpp"
    text = source.read_text().replace(
        "using namespace std::chrono_literals;",
        "extern void sf_terminal_hook(int);\n\nusing namespace std::chrono_literals;",
    )
    if repaired:
        text = text.replace(
            "\t\tconst auto previous = state();",
            "\t\tconst auto previous = state();\n\t\tsf_terminal_hook(1);",
        ).replace("\t\t\tdisconnect(&sac);", "\t\t\tsf_terminal_hook(0);\n\t\t\tdisconnect(&sac);")
    else:
        text = text.replace(
            "\t\t\tif (state() == State::Connected) {",
            "\t\t\tsf_terminal_hook(0);\n\t\t\tconst auto previous = state();\n"
            "\t\t\tsf_terminal_hook(1);\n\t\t\tif (previous == State::Connected) {",
        )
    close_transition = (
        "\t\tchangeState(State::Failed);"
        if not repaired
        else "\t\tchangeStateIf(State::Connecting, State::Failed);"
    )
    if close_transition not in text:
        close_transition = "\t\tif (!changeStateIf(State::Connecting, State::Failed))"
    text = text.replace(close_transition, "\t\tsf_terminal_hook(4);\n" + close_transition, 1)
    source.write_text(text)
    transport = impl / "transport.cpp"
    text = transport.read_text().replace(
        '#include "transport.hpp"', '#include "transport.hpp"\nextern void sf_terminal_hook(int);'
    )
    if repaired:
        text = text.replace(
            "changed = mState.compare_exchange_strong(expected, desired);",
            "changed = mState.compare_exchange_strong(expected, desired);\n\t\t\tif (changed && desired == State::Connected) sf_terminal_hook(2);",
        )
        text = text.replace(
            "bool Transport::changeStateIf(State expected, State desired) {",
            "bool Transport::changeStateIf(State expected, State desired) {\n\tsf_terminal_hook(3);",
        )
    else:
        text = text.replace(
            "if (mState.exchange(state) != state)\n\t\t\tmStateChangeCallback(state);",
            "if (mState.exchange(state) != state) {\n\t\t\tif (state == State::Connected) sf_terminal_hook(2);\n\t\t\tmStateChangeCallback(state);\n\t\t}",
        )
        # The old path finishes EOF delivery; the repaired path blocks before locking.
        text = text.replace(
            "\n}\n\nvoid Transport::incoming",
            "\n\tsf_terminal_hook(3);\n}\n\nvoid Transport::incoming",
        )
    transport.write_text(text)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--source", required=True, type=Path, help="Built trace-patched webrtc-native clone"
    )
    parser.add_argument("--output", required=True, type=Path, help="New evidence directory")
    args = parser.parse_args()
    source = args.source.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    control_source = output / "control.cpp"
    repair_patch = output / "repair.patch"
    shutil.copy2(ROOT / "tests/smoke/webrtc_sctp_terminal_control.cpp", control_source)
    shutil.copy2(ROOT / "tests/smoke/webrtc_sctp_terminal.patch", repair_patch)
    log = output / "commands.log"
    library = source / "thirdparty/libdatachannel"
    revision = run(["git", "rev-parse", "HEAD"], log, library).strip()
    if revision != REVISION:
        raise RuntimeError(f"Expected libdatachannel {REVISION}, got {revision}")
    builds = list(
        (source / "bin/thirdparty/libdatachannel").glob(
            "*/*/CMakeFiles/datachannel-static.dir/flags.make"
        )
    )
    if len(builds) != 1:
        raise RuntimeError("Expected one built libdatachannel target")
    build = builds[0].parents[2]
    flags = ["g++"]
    for line in builds[0].read_text().splitlines():
        if line.startswith(("CXX_DEFINES =", "CXX_INCLUDES =", "CXX_FLAGS =")):
            flags.extend(shlex.split(line.split("=", 1)[1]))
    libraries = [
        build / "libdatachannel-static.a",
        build / "deps/libjuice/libjuice-static.a",
        build / "deps/libsrtp/libsrtp2.a",
        build / "deps/usrsctp/usrsctplib/libusrsctp.a",
    ]
    libraries.extend((source / "bin/thirdparty/mbedtls").glob("*/*/install/lib/*.a"))
    results: dict[str, object] = {
        "revision": revision,
        "source_sha256": {
            name: hashlib.sha256((library / name).read_bytes()).hexdigest() for name in FILES
        },
        "patch_sha256": hashlib.sha256(repair_patch.read_bytes()).hexdigest(),
        "control_sha256": hashlib.sha256(control_source.read_bytes()).hexdigest(),
        "library_sha256": {
            str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in libraries
        },
    }
    for variant in ("baseline", "repaired"):
        work = output / variant
        native = work / "thirdparty/libdatachannel"
        shutil.copytree(library / "include", native / "include")
        shutil.copytree(library / "src", native / "src")
        for name in FILES:
            target = native / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(library / name, target)
        if variant == "repaired":
            run(
                [
                    "git",
                    "apply",
                    "--unsafe-paths",
                    "--directory",
                    str(work),
                    str(repair_patch),
                ],
                log,
            )
        instrument(native, variant == "repaired")
        prefix = [
            flags[0],
            "-I" + str(native / "include"),
            "-I" + str(native / "include/rtc"),
            "-I" + str(native / "src/impl"),
            "-I" + str(library / "src/impl"),
            *flags[1:],
        ]
        objects = []
        for path in (
            native / "src/impl/sctptransport.cpp",
            native / "src/impl/transport.cpp",
            control_source,
        ):
            obj = work / (path.stem + ".o")
            run([*prefix, "-c", str(path), "-o", str(obj)], log)
            objects.append(str(obj))
        executable = work / "control"
        run(
            [
                "g++",
                "-pthread",
                *objects,
                "-Wl,--start-group",
                *map(str, libraries),
                "-Wl,--end-group",
                "-ldl",
                "-o",
                str(executable),
            ],
            log,
        )
        raw = run([str(executable)], log)
        results[variant + "_binary_sha256"] = hashlib.sha256(executable.read_bytes()).hexdigest()
        (work / "results.jsonl").write_text(raw)
        rows = control_results(raw)
        results[variant] = rows
    (output / "assessment.json").write_text(json.dumps(results, indent=2) + "\n")
    baseline = results["baseline"]
    repaired = results["repaired"]
    if not isinstance(baseline, list) or not isinstance(repaired, list):
        raise RuntimeError("Missing control results")
    baseline_passed = {row["case"] for row in baseline if row["passed"]}
    if baseline_passed & BASELINE_FAILURES or not baseline_passed >= BASELINE_PASSES:
        raise RuntimeError("Baseline failed to reproduce the required races or positive controls")
    if not all(row["passed"] for row in repaired):
        raise RuntimeError("Repair failed a terminal control")
    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
