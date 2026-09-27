#!/usr/bin/env python3
"""Check the Godot installer's cache and extraction behavior with small archives."""

from __future__ import annotations

import importlib.util
import io
import os
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

INSTALLER = Path(__file__).resolve().parents[1] / ".devcontainer" / "install-godot.py"
SPEC = importlib.util.spec_from_file_location("sf_install_godot", INSTALLER)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Cannot load {INSTALLER}")
installer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(installer)


class GodotInstallerTests(unittest.TestCase):
    def test_archive_integrity_and_web_only_templates(self) -> None:
        with tempfile.TemporaryDirectory(prefix="sf-godot-test-") as temporary:
            root = Path(temporary)
            cache = root / "cache"
            cache.mkdir()
            archive_path = cache / "Godot_v4.3-stable_export_templates.tpz"
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr("templates/web_release.zip", b"web-release")
                archive.writestr("templates/web_debug.zip", b"web-debug")
                archive.writestr("templates/windows.exe", b"not-web")
            self.assertTrue(installer.archive_valid(archive_path, 1))
            self.assertFalse(installer.archive_valid(archive_path, 100_000_000))
            with (
                patch.object(installer, "TEMPLATES_MIN_BYTES", 1),
                patch.object(installer.shutil, "which", return_value=None),
            ):
                installer.install_templates("4.3-stable", cache, root / "installed")
            target = root / "installed" / "4.3.stable"
            self.assertEqual(
                sorted(path.name for path in target.iterdir()),
                ["web_debug.zip", "web_release.zip"],
            )
            self.assertEqual((target / "web_release.zip").read_bytes(), b"web-release")
            self.assertEqual((target / "web_release.zip").stat().st_mode & 0o777, 0o644)
            with (
                patch.object(installer, "TEMPLATES_MIN_BYTES", 1),
                patch.object(installer.shutil, "which", return_value="/fake/godot"),
                patch.object(
                    installer.subprocess,
                    "run",
                    return_value=subprocess.CompletedProcess(
                        [], 0, "4.4.stable.official.test\n", ""
                    ),
                ),
            ):
                installer.install_templates("4.3-stable", cache, root / "editor-version")
            self.assertTrue((root / "editor-version" / "4.4.stable" / "web_debug.zip").is_file())
            valid_bytes = archive_path.read_bytes()
            archive_path.write_bytes(b"corrupt")
            self.assertFalse(installer.archive_valid(archive_path, 1))
            with patch.object(
                installer.urllib.request, "urlopen", return_value=io.BytesIO(valid_bytes)
            ):
                installer.download_archive("4.3-stable", archive_path.name, cache, 1)
            self.assertEqual(archive_path.read_bytes(), valid_bytes)
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr("templates/windows.exe", b"not-web")
            with (
                patch.object(installer, "TEMPLATES_MIN_BYTES", 1),
                patch.object(installer.shutil, "which", return_value=None),
                self.assertRaisesRegex(ValueError, "No web templates found"),
            ):
                installer.install_templates("4.3-stable", cache, root / "missing-web")
            self.assertFalse((root / "missing-web").exists())

    @unittest.skipUnless(os.name == "posix", "editor fixture uses a POSIX executable")
    def test_editor_verifies_before_replacing_target(self) -> None:
        with tempfile.TemporaryDirectory(prefix="sf-godot-test-") as temporary:
            root = Path(temporary)
            cache = root / "cache"
            cache.mkdir()
            name = "Godot_v4.3-stable_linux.x86_64"
            archive_path = cache / f"{name}.zip"
            target = root / "godot"
            with (
                patch.object(installer, "EDITOR_MIN_BYTES", 1),
                patch.object(installer.platform, "machine", return_value="x86_64"),
            ):
                with zipfile.ZipFile(archive_path, "w") as archive:
                    archive.writestr(name, b"#!/bin/sh\necho 4.3.stable.official.test\n")
                installer.install_editor("4.3-stable", cache, target)
                self.assertEqual(target.stat().st_mode & 0o777, 0o755)
                good_binary = target.read_bytes()
                with zipfile.ZipFile(archive_path, "w") as archive:
                    archive.writestr(name, b"not an executable")
                with self.assertRaises(OSError):
                    installer.install_editor("4.3-stable", cache, target)
                self.assertEqual(target.read_bytes(), good_binary)


if __name__ == "__main__":
    unittest.main()
