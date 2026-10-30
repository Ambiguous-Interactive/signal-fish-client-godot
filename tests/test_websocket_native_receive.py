"""Exercise emulator qualification without a cross-compiled engine."""

import hashlib
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/check-websocket-native-receive.py"
SPEC = importlib.util.spec_from_file_location("native_receive", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Could not load {SCRIPT}")
drill = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(drill)


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
