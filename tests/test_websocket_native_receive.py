"""Exercise emulator qualification without a cross-compiled engine."""

import hashlib
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import Mock, patch

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/check-websocket-native-receive.py"
SPEC = importlib.util.spec_from_file_location("native_receive", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Could not load {SCRIPT}")
drill = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(drill)

ACTIVE_SCRIPT = SCRIPT.with_name("check-active-shutdown.py")
ACTIVE_SPEC = importlib.util.spec_from_file_location("active_shutdown", ACTIVE_SCRIPT)
if ACTIVE_SPEC is None or ACTIVE_SPEC.loader is None:
    raise RuntimeError(f"Could not load {ACTIVE_SCRIPT}")
active = importlib.util.module_from_spec(ACTIVE_SPEC)
with patch.object(sys, "path", [str(SCRIPT.parent), *sys.path]):
    ACTIVE_SPEC.loader.exec_module(active)


class EmulatorTests(unittest.TestCase):
    def test_emulator_runs_target_and_preserves_binary_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "target with spaces.py"
            target.write_text(
                "import json, sys\n"
                "assert '--headless' in sys.argv\n"
                "print('CLOSE_REASON_RESULT ' + json.dumps({'passed': True, "
                "'wire': {'writes': 1, 'error': 0}}))\n"
            )
            importer = root / "importer"
            importer.write_text("#!/bin/sh\nexit 0\n")
            importer.chmod(0o755)
            output = root / "results"
            command = [
                str(SCRIPT),
                "--godot",
                str(target),
                "--importer",
                str(importer),
                "--output",
                str(output),
                "--runner",
                sys.executable,
                "--runner-arg=-I",
                "--case",
                "close-1-empty-server",
            ]
            with patch.object(sys, "argv", command), redirect_stdout(io.StringIO()):
                self.assertEqual(drill.main(), 0)
            provenance = json.loads((output / "provenance.json").read_text())
            self.assertEqual(provenance["binary"], str(target.resolve()))
            self.assertEqual(
                provenance["binary_sha256"], hashlib.sha256(target.read_bytes()).hexdigest()
            )
            self.assertEqual(
                provenance["runner_sha256"],
                hashlib.sha256(Path(sys.executable).resolve().read_bytes()).hexdigest(),
            )
            summary = json.loads((output / "summary.json").read_text())
            self.assertEqual(summary["import"]["command"][0], str(importer))
            self.assertEqual(
                summary["cases"][0]["command"][:3],
                [str(Path(sys.executable).resolve()), "-I", str(target)],
            )

    def test_emulator_options_fail_before_creating_results(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "results"
            required = [
                "--godot",
                sys.executable,
                "--importer",
                sys.executable,
                "--output",
                str(output),
            ]
            for options in (
                [*required, "--runner-arg=-L"],
                [*required, "--runner", str(root / "missing")],
                ["--export-repro", str(root / "repro.zip"), "--runner", sys.executable],
            ):
                with (
                    self.subTest(options=options),
                    patch.object(sys, "argv", [str(SCRIPT), *options]),
                    redirect_stderr(io.StringIO()),
                    self.assertRaises(SystemExit) as raised,
                ):
                    drill.main()
                self.assertEqual(raised.exception.code, 2)
                self.assertFalse(output.exists())
                self.assertFalse((root / "repro.zip").exists())


@unittest.skipUnless(sys.platform == "linux" and shutil.which("cc"), "Linux cc required")
class ReceiveCapTests(unittest.TestCase):
    def test_invalid_cap_options_leave_no_results(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for extra, output in (
                (["--recv-cap-bytes=0"], root / "zero"),
                (["--recv-cap-bytes=65537"], root / "large"),
                (["--recv-cap-bytes=1", "--runner", sys.executable], root / "emulator"),
                (["--recv-cap-bytes=1"], root / "has spaces"),
            ):
                with (
                    self.subTest(extra=extra, output=output),
                    patch.object(
                        sys,
                        "argv",
                        [
                            str(SCRIPT),
                            "--godot",
                            sys.executable,
                            "--importer",
                            sys.executable,
                            "--output",
                            str(output),
                            *extra,
                        ],
                    ),
                    redirect_stderr(io.StringIO()),
                    self.assertRaises(SystemExit) as raised,
                ):
                    drill.main()
                self.assertEqual(raised.exception.code, 2)
                self.assertFalse(output.exists())

    def test_real_reads_are_capped_and_bytes_preserved(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            library = root / "cap.so"
            subprocess.run(  # noqa: S603 - Local fixture compiler and source.
                [
                    str(shutil.which("cc")),
                    "-shared",
                    "-fPIC",
                    "-Wall",
                    "-Wextra",
                    "-Werror",
                    str(SCRIPT.with_name("websocket-recv-cap.c")),
                    "-o",
                    str(library),
                    "-ldl",
                    "-pthread",
                ],
                check=True,
            )
            for cap in (1, 3, 127):
                report = root / f"{cap}.json"
                child = subprocess.run(  # noqa: S603 - Fixed socket fixture.
                    [
                        sys.executable,
                        "-c",
                        "import socket\n"
                        "a,b=socket.socketpair()\n"
                        "body=bytes(range(256))*4\n"
                        "a.sendall(body)\n"
                        "received=b''\n"
                        "while len(received)<len(body):\n"
                        f" part=b.recv(4096); assert 0<len(part)<={cap}\n"
                        " received+=part\n"
                        "assert received==body\n",
                    ],
                    env={
                        **os.environ,
                        "LD_PRELOAD": str(library),
                        "SF_RECV_CAP_BYTES": str(cap),
                        "SF_RECV_CAP_REPORT": str(report),
                    },
                    capture_output=True,
                    text=True,
                    timeout=10,
                    check=False,
                )
                self.assertEqual(child.returncode, 0, child.stderr)
                record = json.loads(report.read_text())
                self.assertEqual(record["bytes"], 1024)
                self.assertEqual(record["largest_read"], cap)
                self.assertGreater(record["limited_reads"], 0)

    def test_unobserved_cap_cannot_pass_a_green_fixture(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "target"
            target.write_text(
                "#!/bin/sh\n"
                'echo \'CLOSE_REASON_RESULT {"passed":true,'
                '"wire":{"writes":1,"error":0}}\'\n'
            )
            target.chmod(0o755)
            output = root / "results"
            with (
                patch.object(
                    sys,
                    "argv",
                    [
                        str(SCRIPT),
                        "--godot",
                        str(target),
                        "--importer",
                        str(target),
                        "--output",
                        str(output),
                        "--case",
                        "close-1-empty-server",
                        "--recv-cap-bytes=1",
                    ],
                ),
                redirect_stdout(io.StringIO()),
            ):
                self.assertEqual(drill.main(), 1)
            summary = json.loads((output / "summary.json").read_text())
            self.assertTrue(summary["cases"][0]["result"]["passed"])
            self.assertFalse(summary["cases"][0]["passed"])
            self.assertEqual(summary["cases"][0]["recv_cap"].get("reads", 0), 0)


class TriageOutputTests(unittest.TestCase):
    def test_burst_cases_report_delivery_and_pending_waits(self) -> None:
        gap: dict[str, object] = {
            "packets": 3,
            "polls": 3,
            "largest_delivery_gap": {"after": 1, "us": 1140000},
            "largest_poll_interval_us": 900,
        }
        variants: dict[str, dict[str, object]] = {
            "passing": {
                "passed": True,
                "packets": "((1000, 0), (2000, 1), (1142000, 39))",
                "pending_wait": [],
                "exit": 0,
                "delivery": gap,
            },
            "gapped": {
                "passed": False,
                "packets": "((1000, 0), (2000, 1), (1142000, 39))",
                "pending_wait": [{"expected": 39, "waited_ms": 1000, "deadline_margin_ms": 0}],
                "exit": 1,
                "delivery": gap,
            },
            "stalled": {
                "passed": False,
                "packets": "()",
                "pending_wait": [{"expected": 0, "waited_ms": 1000, "deadline_margin_ms": 0}],
                "exit": 1,
                "delivery": {
                    "packets": 0,
                    "polls": 3,
                    "largest_delivery_gap": None,
                    "largest_poll_interval_us": 900,
                },
            },
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, variant in variants.items():
                output = root / f"results-{name}"
                target = root / f"target-{name}.py"
                target.write_text(
                    "#!/usr/bin/env python3\n"
                    "import json, sys\n"
                    "assert '--headless' in sys.argv\n"
                    "for start_us in (1000, 2000, 3000):\n"
                    " print('WEBSOCKET_RECEIVE_POLL ' + json.dumps("
                    "{'start_us': start_us, 'interval_us': 900, 'duration_us': 5,"
                    " 'queued_before': 0, 'queued_after': 0}))\n"
                    "for start_us, sequence in " + str(variant["packets"]) + ":\n"
                    " print('WEBSOCKET_RECEIVE_PACKET ' + json.dumps("
                    "{'sequence': sequence, 'bytes': 4095, 'exact': True,"
                    " 'exact_mode': True, 'delivered_us': start_us}))\n"
                    "print('WEBSOCKET_RECEIVE_RESULT ' + json.dumps("
                    "{'passed': " + str(variant["passed"]) + ", 'wire': {'writes': 2,"
                    " 'error': 0}, 'pending_wait': " + repr(variant["pending_wait"]) + "}))\n"
                )
                target.chmod(0o755)
                command = [
                    str(SCRIPT),
                    "--godot",
                    str(target),
                    "--importer",
                    str(target),
                    "--output",
                    str(output),
                    "--case",
                    "chunk-burst-alternating-none",
                ]
                printed = io.StringIO()
                with patch.object(sys, "argv", command), redirect_stdout(printed):
                    self.assertEqual(drill.main(), variant["exit"], name)
                case = json.loads((output / "chunk-burst-alternating-none.json").read_text())
                self.assertEqual(case["passed"], variant["passed"], name)
                self.assertEqual(case["delivery"], variant["delivery"], name)
                self.assertEqual(case["result"]["pending_wait"], variant["pending_wait"], name)
                lines = {
                    line.split(" ", 1)[0]: json.loads(line.split(" ", 1)[1])
                    for line in printed.getvalue().splitlines()
                    if line.startswith(("delivery ", "diagnostics "))
                }
                if variant["passed"]:
                    self.assertEqual(lines.get("delivery"), variant["delivery"], name)
                    self.assertNotIn("diagnostics", lines, name)
                else:
                    self.assertNotIn("delivery", lines, name)
                    self.assertEqual(
                        lines["diagnostics"].get("delivery"), variant["delivery"], name
                    )
                    self.assertEqual(
                        lines["diagnostics"].get("pending_wait"),
                        variant["pending_wait"],
                        name,
                    )

    def test_failed_import_prints_diagnostics_without_cases(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "target"
            target.write_text("#!/bin/sh\nexit 1\n")
            target.chmod(0o755)
            output = root / "results"
            printed = io.StringIO()
            command = [
                str(SCRIPT),
                "--godot",
                str(target),
                "--importer",
                str(target),
                "--output",
                str(output),
                "--case",
                "close-1-empty-server",
            ]
            with patch.object(sys, "argv", command), redirect_stdout(printed):
                self.assertEqual(drill.main(), 1)
            self.assertEqual(
                [
                    line
                    for line in printed.getvalue().splitlines()
                    if line.startswith("diagnostics ")
                ],
                [
                    "diagnostics "
                    + json.dumps(
                        {"engine_errors": False, "returncode": 1, "timed_out": False},
                        sort_keys=True,
                    )
                ],
            )
            summary = json.loads((output / "summary.json").read_text())
            self.assertEqual(summary["import"]["returncode"], 1)
            self.assertEqual(summary["cases"], [])

    def test_run_repro_command_failure_prints_diagnostics_without_command(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "target"
            target.write_text(
                "#!/usr/bin/env python3\n"
                "import json, sys\n"
                "if '--editor' in sys.argv:\n"
                " exit(0)\n"
                "print('CLOSE_REASON_RESULT ' + json.dumps({'passed': False,"
                " 'wire': {'writes': 1, 'error': 0}}))\n"
                "sys.exit(1)\n"
            )
            target.chmod(0o755)
            output = root / "results"
            printed = io.StringIO()
            command = [
                str(SCRIPT),
                "--godot",
                str(target),
                "--importer",
                str(target),
                "--output",
                str(output),
                "--run-repro",
            ]
            with patch.object(sys, "argv", command), redirect_stdout(printed):
                self.assertEqual(drill.main(), 0)
            report = json.loads((output / "standalone-report.json").read_text())
            expected = [
                {key: value for key, value in command.items() if key != "command"}
                for command in report["commands"]
            ]
            self.assertTrue(all(not command["passed"] for command in report["commands"]))
            lines = [
                json.loads(line.split(" ", 1)[1])
                for line in printed.getvalue().splitlines()
                if line.startswith("diagnostics ")
            ]
            self.assertEqual(lines, expected)

    def test_failing_case_without_delivery_still_prints_diagnostics(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "target"
            target.write_text(
                "#!/bin/sh\n"
                'echo \'CLOSE_REASON_RESULT {"passed":false,'
                '"wire":{"writes":1,"error":0}}\'\n'
            )
            target.chmod(0o755)
            output = root / "results"
            printed = io.StringIO()
            command = [
                str(SCRIPT),
                "--godot",
                str(target),
                "--importer",
                str(target),
                "--output",
                str(output),
                "--case",
                "close-1-empty-server",
            ]
            with patch.object(sys, "argv", command), redirect_stdout(printed):
                self.assertEqual(drill.main(), 1)
            case = json.loads((output / "close-1-empty-server.json").read_text())
            self.assertFalse(case["passed"])
            self.assertNotIn("delivery", case)
            lines = {
                line.split(" ", 1)[0]: json.loads(line.split(" ", 1)[1])
                for line in printed.getvalue().splitlines()
                if line.startswith(("delivery ", "diagnostics "))
            }
            self.assertNotIn("delivery", lines)
            self.assertEqual(lines["diagnostics"]["passed"], False)

    def test_cases_without_delivery_records_carry_no_summary(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "target"
            target.write_text(
                "#!/bin/sh\n"
                'echo \'CLOSE_REASON_RESULT {"passed":true,'
                '"wire":{"writes":1,"error":0}}\'\n'
            )
            target.chmod(0o755)
            output = root / "results"
            command = [
                str(SCRIPT),
                "--godot",
                str(target),
                "--importer",
                str(target),
                "--output",
                str(output),
                "--case",
                "close-1-empty-server",
            ]
            with patch.object(sys, "argv", command), redirect_stdout(io.StringIO()):
                self.assertEqual(drill.main(), 0)
            case = json.loads((output / "close-1-empty-server.json").read_text())
            self.assertNotIn("delivery", case)


class ActiveShutdownEmulatorTests(unittest.TestCase):
    def test_emulator_keeps_native_importer_and_target_identities_separate(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "target with spaces.py"
            target.write_text(
                "import json, sys\n"
                "assert '--headless' in sys.argv\n"
                "for generation in (1, 2):\n"
                " print('ACTIVE_SHUTDOWN_GENERATION ' + json.dumps("
                "{'generation': generation, 'complete': True}))\n"
                "print('ACTIVE_SHUTDOWN_TERMINAL {}')\n"
                "print('ACTIVE_SHUTDOWN_RESULT {\"passed\": true}')\n"
            )
            target.chmod(0o755)
            importer = root / "native importer"
            importer.write_text("native editor identity")
            extension = root / "extension"
            extension.mkdir()
            server = root / "server"
            server.write_text("service identity")
            config = root / "config.json"
            config.write_text('{"server": {}}')
            output = root / "results"
            service = Mock(starts=2, faults=1)
            service.lock = active.threading.Lock()
            http = Mock(server_port=12345)
            command = [
                str(ACTIVE_SCRIPT),
                "--server-binary",
                str(server),
                "--server-config",
                str(config),
                "--server-revision",
                "fixture",
                "--godot",
                target.name,
                "--import-godot",
                str(importer),
                "--native-extension",
                str(extension),
                "--runtime=native",
                "--mode=graceful",
                "--output",
                str(output),
                "--runner",
                sys.executable,
                "--runner-arg=-I",
            ]

            def prepared(project: Path, _extension: Path, _root: Path) -> None:
                (project / "tests/smoke").mkdir(parents=True)
                (project / "project.godot").write_text(active.interop.SCENE)
                (project / "export_presets.cfg").write_text('include_filter=""')

            with (
                patch.object(sys, "argv", command),
                patch.dict(os.environ, {"PATH": str(root) + os.pathsep + os.environ["PATH"]}),
                patch.object(active, "Service", return_value=service),
                patch.object(active, "ThreadingHTTPServer", return_value=http),
                patch.object(active.interop, "prepare", side_effect=prepared),
                patch.object(active.interop, "checked") as imported,
                redirect_stdout(io.StringIO()),
            ):
                self.assertEqual(active.main(), 0)
            self.assertEqual(imported.call_args.args[0][0], str(importer))
            report = json.loads((output / "native-graceful/assessment.json").read_text())
            self.assertEqual(
                report["command"][:3],
                [str(Path(sys.executable).resolve()), "-I", str(target)],
            )
            self.assertEqual(
                report["identities"][str(target)], hashlib.sha256(target.read_bytes()).hexdigest()
            )
            provenance = json.loads((output / "provenance.json").read_text())
            self.assertEqual(
                provenance["runner_sha256"],
                hashlib.sha256(Path(sys.executable).resolve().read_bytes()).hexdigest(),
            )
            self.assertEqual(
                provenance["import_engine_sha256"][str(importer)],
                hashlib.sha256(importer.read_bytes()).hexdigest(),
            )

    def test_invalid_emulator_options_leave_no_results(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "results"
            required = [
                str(ACTIVE_SCRIPT),
                "--server-binary",
                sys.executable,
                "--server-config",
                str(root / "config.json"),
                "--server-revision",
                "fixture",
                "--native-extension",
                str(root),
                "--output",
                str(output),
            ]
            for options in (
                ["--runtime=native", "--runner-arg=-L"],
                ["--runtime=native", "--runner", sys.executable],
                ["--runtime=all", "--runner", sys.executable],
                ["--runtime=web", "--runner", sys.executable],
                [
                    "--runtime=native",
                    "--import-godot",
                    sys.executable,
                    "--runner",
                    str(root / "missing"),
                ],
                [
                    "--runtime=native",
                    "--import-godot",
                    sys.executable,
                    "--runner",
                    sys.executable,
                    "--godot",
                    str(root / "missing-target"),
                ],
            ):
                with (
                    self.subTest(options=options),
                    patch.object(sys, "argv", [*required, *options]),
                    redirect_stderr(io.StringIO()),
                    self.assertRaises(SystemExit) as raised,
                ):
                    active.main()
                self.assertEqual(raised.exception.code, 2)
                self.assertFalse(output.exists())
