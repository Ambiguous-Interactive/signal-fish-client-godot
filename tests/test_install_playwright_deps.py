"""Check the shared Playwright system dependency setup."""

import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import install_playwright_deps as deps


def result(code: int, output: str = "") -> subprocess.CompletedProcess[str]:
    return subprocess.CompletedProcess([], code, output, "")


class PlaywrightDepsTests(unittest.TestCase):
    def test_matching_stamp_skips_probe(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            stamp = Path(directory) / ".cache/ms-playwright/.sf-system-deps"
            stamp.parent.mkdir(parents=True)
            stamp.write_text("image-1 1.63.0\n")
            with patch.object(subprocess, "run") as run:
                deps.install("python", "1.63.0", "image-1", Path(directory))
            run.assert_not_called()

    def test_probe_success_stamps_only_known_image(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            with patch.object(
                subprocess,
                "run",
                return_value=result(0, "All system dependencies are installed.\n"),
            ) as run:
                deps.install("python", "1.63.0", "image-2", home)
                self.assertEqual(
                    (home / ".cache/ms-playwright/.sf-system-deps").read_text(),
                    "image-2 1.63.0\n",
                )
                deps.install("python", "1.63.0", "unknown", home)
            self.assertEqual(run.call_count, 2)

    def test_failed_probe_installs_and_retries(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            stamp = home / ".cache/ms-playwright/.sf-system-deps"
            stamp.parent.mkdir(parents=True)
            stamp.write_text("old-image 1.63.0\n")
            with (
                patch.object(
                    subprocess, "run", side_effect=[result(1), result(1), result(0)]
                ) as run,
                patch.object(Path, "glob", return_value=[]),
                patch.object(time, "sleep") as sleep,
            ):
                deps.install("python", "1.63.0", "new-image", home)
            self.assertEqual(run.call_count, 3)
            self.assertEqual(run.call_args_list[0].args[0][-2:], ["--dry-run", "chromium"])
            sleep.assert_called_once_with(20)
            self.assertEqual(stamp.read_text(), "new-image 1.63.0\n")

    def test_ambiguous_probe_and_install_failure_leave_no_stamp(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            with (
                patch.object(
                    subprocess,
                    "run",
                    side_effect=[result(0, "unexpected output"), result(1), result(1), result(1)],
                ) as run,
                patch.object(Path, "glob", return_value=[]),
                patch.object(time, "sleep") as sleep,
                self.assertRaisesRegex(RuntimeError, "after 3 attempts"),
            ):
                deps.install("python", "1.63.0", "image-3", home)
            self.assertEqual(run.call_count, 4)
            self.assertEqual(sleep.call_count, 2)
            self.assertFalse((home / ".cache/ms-playwright/.sf-system-deps").exists())


if __name__ == "__main__":
    unittest.main()
