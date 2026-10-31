"""Exercise emulator qualification without a cross-compiled engine."""

import hashlib
import importlib.util
import io
import json
import os
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
