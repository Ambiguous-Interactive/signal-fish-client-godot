#!/usr/bin/env python3
"""Check the Godot installer's cache and extraction behavior with small archives."""

from __future__ import annotations

import importlib.util
import io
import os
import tempfile
import unittest
import zipfile
from collections.abc import Callable
from pathlib import Path
from unittest.mock import patch

INSTALLER = Path(__file__).resolve().parents[1] / ".devcontainer" / "install-godot.py"
SPEC = importlib.util.spec_from_file_location("sf_install_godot", INSTALLER)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Cannot load {INSTALLER}")
installer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(installer)


class GodotInstallerTests(unittest.TestCase):
    """Exercise the installer with small synthetic archives."""

    def test_archive_integrity_and_web_only_templates(self) -> None:
        """Extract only web templates and reject corrupt or empty archives."""
        with tempfile.TemporaryDirectory(prefix="sf-godot-test-") as temporary:
            root = Path(temporary)
            cache = root / "cache"
            cache.mkdir()
            archive_path = cache / "Godot_v4.3-stable_export_templates.tpz"
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr("templates/version.txt", b"4.3.stable\n")
                archive.writestr("templates/web_release.zip", b"web-release")
                archive.writestr("templates/web_debug.zip", b"web-debug")
                archive.writestr("templates/windows.exe", b"not-web")
            self.assertTrue(installer.archive_valid(archive_path, 1))
            self.assertFalse(installer.archive_valid(archive_path, 100_000_000))
            with patch.object(installer, "TEMPLATES_MIN_BYTES", 1):
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
                    return_value=installer.subprocess.CompletedProcess(
                        [], 0, "4.4.stable.official.test\n", ""
                    ),
                ),
            ):
                installer.install_templates("4.3-stable", cache, root / "mismatched-editor")
            self.assertTrue((root / "mismatched-editor" / "4.3.stable" / "web_debug.zip").is_file())
            beta_archive = cache / "Godot_v4.8-beta2_export_templates.tpz"
            with zipfile.ZipFile(beta_archive, "w") as archive:
                archive.writestr("templates/version.txt", b"4.8.beta2\n")
                archive.writestr("templates/web_release.zip", b"beta-web")
            with patch.object(installer, "TEMPLATES_MIN_BYTES", 1):
                installer.install_templates("4.8-beta2", cache, root / "beta-installed")
            self.assertTrue((root / "beta-installed" / "4.8.beta2" / "web_release.zip").is_file())
            valid_bytes = archive_path.read_bytes()
            archive_path.write_bytes(b"corrupt")
            self.assertFalse(installer.archive_valid(archive_path, 1))
            with patch.object(
                installer.urllib.request, "urlopen", return_value=io.BytesIO(valid_bytes)
            ):
                installer.download_archive("4.3-stable", archive_path.name, cache, 1)
            self.assertEqual(archive_path.read_bytes(), valid_bytes)
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr("templates/version.txt", b"4.3.stable\n")
                archive.writestr("templates/windows.exe", b"not-web")
            with (
                patch.object(installer, "TEMPLATES_MIN_BYTES", 1),
                self.assertRaisesRegex(ValueError, "No web templates found"),
            ):
                installer.install_templates("4.3-stable", cache, root / "missing-web")
            self.assertFalse((root / "missing-web").exists())
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr("templates/version.txt", b"../escape\n")
                archive.writestr("templates/web_release.zip", b"web-release")
            with (
                patch.object(installer, "TEMPLATES_MIN_BYTES", 1),
                self.assertRaisesRegex(ValueError, "Invalid template version"),
            ):
                installer.install_templates("4.3-stable", cache, root / "bad-version")
            self.assertFalse((root / "escape").exists())

    def test_windows_editor_installs_the_editor_not_the_console_wrapper(self) -> None:
        """Install the win64 editor binary and keep a failed replacement intact."""
        with tempfile.TemporaryDirectory(prefix="sf-godot-test-") as temporary:
            root = Path(temporary)
            cache = root / "cache"
            cache.mkdir()
            name = "Godot_v4.7.2-stable_win64.exe.zip"
            archive_path = cache / name
            target = root / "official-godot" / "godot.exe"
            calls: list[list[str]] = []

            def run(command: list[str], *args: object, **kwargs: object) -> object:
                calls.append(command)
                return installer.subprocess.CompletedProcess(
                    command, 0, "4.7.2.stable.official.test\n", ""
                )

            with (
                patch.object(installer, "EDITOR_MIN_BYTES", 1),
                patch.object(installer.subprocess, "run", side_effect=run),
            ):
                with zipfile.ZipFile(archive_path, "w") as archive:
                    archive.writestr("Godot_v4.7.2-stable_win64_console.exe", b"wrapper")
                    archive.writestr("Godot_v4.7.2-stable_win64.exe", b"editor")
                installer.install_windows_editor("4.7.2-stable", cache, target)
                self.assertEqual(target.read_bytes(), b"editor")
                self.assertEqual(calls[0][1:], ["--headless", "--version"])
                self.assertTrue(calls[0][0].endswith(".exe"))
                self.assertFalse(list(target.parent.glob(".godot-*")))
                good_binary = target.read_bytes()
                with zipfile.ZipFile(archive_path, "w") as archive:
                    archive.writestr("Godot_v4.7.2-stable_win64.exe", b"replacement")
                calls.clear()

                def fail(command: list[str], *args: object, **kwargs: object) -> object:
                    calls.append(command)
                    return installer.subprocess.CompletedProcess(command, 3, "", "missing")

                with (
                    patch.object(installer.subprocess, "run", side_effect=fail),
                    self.assertRaisesRegex(RuntimeError, "Godot binary failed to run: exit 3"),
                ):
                    installer.install_windows_editor("4.7.2-stable", cache, target)
                self.assertEqual(target.read_bytes(), good_binary)
                self.assertFalse(list(target.parent.glob(".godot-*")))
                with self.assertRaisesRegex(ValueError, "must end with .exe"):
                    installer.install_windows_editor(
                        "4.7.2-stable", cache, root / "extensionless"
                    )

    def test_downloads_use_the_repository_that_hosts_the_release(self) -> None:
        """Fetch stable and pre-release tags from their hosting repository."""
        with tempfile.TemporaryDirectory(prefix="sf-godot-test-") as temporary:
            root = Path(temporary)
            buffer = io.BytesIO()
            with zipfile.ZipFile(buffer, "w") as archive:
                archive.writestr("templates/version.txt", b"4.8.beta2\n")
            valid = buffer.getvalue()
            urls: list[str] = []
            for version, host in (
                ("4.3-stable", "https://github.com/godotengine/godot/releases/download"),
                ("4.8-beta2", "https://github.com/godotengine/godot-builds/releases/download"),
            ):
                urls.clear()

                def open_url(url: str, *args: object, **kwargs: object) -> io.BytesIO:
                    urls.append(url)
                    return io.BytesIO(valid)

                with patch.object(installer.urllib.request, "urlopen", side_effect=open_url):
                    path = installer.download_archive(version, f"{version}.zip", root, 1)
                self.assertEqual(path.read_bytes(), valid)
                self.assertEqual(urls, [f"{host}/{version}/{version}.zip"])

    @unittest.skipUnless(os.name == "posix", "editor fixture uses a POSIX executable")
    def test_editor_verifies_before_replacing_target(self) -> None:
        """Keep the previous editor when a new binary cannot run."""
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
                patch.object(installer.sys, "platform", "linux"),
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

    @unittest.skipUnless(os.name == "posix", "editor fixture uses a POSIX executable")
    def test_editor_installs_macos_bundle_binary(self) -> None:
        """Install and restore the macOS app bundle without escaping it."""
        with tempfile.TemporaryDirectory(prefix="sf-godot-test-") as temporary:
            root = Path(temporary)
            cache = root / "cache"
            cache.mkdir()
            name = "Godot_v4.3-stable_macos.universal.zip"
            archive_path = cache / name
            target = root / "godot"
            with (
                patch.object(installer, "EDITOR_MIN_BYTES", 1),
                patch.object(installer.sys, "platform", "darwin"),
            ):
                with zipfile.ZipFile(archive_path, "w") as archive:
                    archive.writestr("Godot.app/Contents/Info.plist", b"plist")
                    archive.writestr(
                        "Godot.app/Contents/MacOS/Godot",
                        b"#!/bin/sh\necho 4.3.stable.official.test\n",
                    )
                installer.install_editor("4.3-stable", cache, target)
                installed = target / "Godot.app" / "Contents" / "MacOS" / "Godot"
                self.assertEqual(installed.stat().st_mode & 0o777, 0o755)
                self.assertEqual(
                    installed.read_bytes(), b"#!/bin/sh\necho 4.3.stable.official.test\n"
                )
                self.assertEqual(
                    (target / "Godot.app" / "Contents" / "Info.plist").read_bytes(), b"plist"
                )
                with zipfile.ZipFile(archive_path, "w") as archive:
                    archive.writestr("Godot.app/Contents/Info.plist", b"plist")
                    archive.writestr(
                        "Godot.app/Contents/MacOS/Godot",
                        b"#!/bin/sh\necho 4.4.upgraded.official.test\n",
                    )
                installer.install_editor("4.3-stable", cache, target)
                self.assertEqual(
                    installed.read_bytes(), b"#!/bin/sh\necho 4.4.upgraded.official.test\n"
                )
                self.assertEqual([path.name for path in target.iterdir()], ["Godot.app"])
                with zipfile.ZipFile(archive_path, "w") as archive:
                    archive.writestr("Godot.app/Contents/Info.plist", b"plist")
                    archive.writestr("Godot.app/Contents/MacOS/Godot", b"#!/bin/sh\nexit 3\n")
                with self.assertRaisesRegex(RuntimeError, "Godot binary failed to run: exit 3"):
                    installer.install_editor("4.3-stable", cache, target)
                self.assertEqual([path.name for path in target.iterdir()], ["Godot.app"])
                self.assertEqual(
                    installed.read_bytes(), b"#!/bin/sh\necho 4.4.upgraded.official.test\n"
                )

                real_replace: Callable[[Path, Path], None] = installer.os.replace
                promotion_failed = [False]
                promoted_bytes = installed.read_bytes()

                def fail_first_promotion(source: Path, destination: Path) -> None:
                    if (
                        not promotion_failed[0]
                        and source.parent.name.startswith(".godot-app-")
                        and source.name == "Godot.app"
                        and destination.name == "Godot.app"
                    ):
                        promotion_failed[0] = True
                        raise OSError("promotion forced failure")
                    real_replace(source, destination)

                with zipfile.ZipFile(archive_path, "w") as archive:
                    archive.writestr("Godot.app/Contents/Info.plist", b"plist")
                    archive.writestr(
                        "Godot.app/Contents/MacOS/Godot",
                        b"#!/bin/sh\necho 4.4.stable.official.test\n",
                    )
                with (
                    patch.object(installer.os, "replace", side_effect=fail_first_promotion),
                    self.assertRaises(OSError),
                ):
                    installer.install_editor("4.3-stable", cache, target)
                self.assertEqual(installed.read_bytes(), promoted_bytes)
                self.assertEqual([path.name for path in target.iterdir()], ["Godot.app"])
                with zipfile.ZipFile(archive_path, "w") as archive:
                    archive.writestr("Godot4.app/Contents/MacOS/Godot", b"#!/bin/sh\nexit 3\n")
                with self.assertRaisesRegex(ValueError, "Expected one Godot binary"):
                    installer.install_editor("4.3-stable", cache, target)
                self.assertEqual([path.name for path in target.iterdir()], ["Godot.app"])
                with zipfile.ZipFile(archive_path, "w") as archive:
                    archive.writestr(
                        "Godot.app/Contents/MacOS/Godot",
                        b"#!/bin/sh\necho 4.3.stable.official.test\n",
                    )
                    archive.writestr("../escape", b"evil")
                with self.assertRaisesRegex(ValueError, "Unsafe archive member path"):
                    installer.install_editor("4.3-stable", cache, target)
                self.assertFalse((root / "escape").exists())
                self.assertEqual([path.name for path in target.iterdir()], ["Godot.app"])


if __name__ == "__main__":
    unittest.main()
