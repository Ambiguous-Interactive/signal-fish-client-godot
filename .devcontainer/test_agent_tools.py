"""Regression checks for native npm failures and terminal daemon isolation."""

import errno
import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from types import ModuleType
from typing import Protocol, cast
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent


class Runner(Protocol):
    def __call__(self, *args: str) -> subprocess.CompletedProcess[str]: ...


def load(name: str) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), ROOT / f"{name}.py")
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {name}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@unittest.skipIf(os.name == "nt", "npm global layout and symlinks use Linux")
class AgentTools(unittest.TestCase):
    def setUp(self) -> None:
        self.module = load("install-agent-tools")
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.prefix = Path(self.folder.name)
        self.installer = self.module.Installer("install")
        self.installer.prefix = self.prefix
        self.installer.bin_dir = self.prefix / "bin"
        self.spec = "@openai/codex@1.0.0"
        self.old = self.package(self.prefix, "old")

    def package(self, prefix: Path, version: str, broken: bool = False) -> Path:
        root = prefix / "lib/node_modules/@openai/codex"
        root.mkdir(parents=True)
        (root / "package.json").write_text(
            json.dumps(
                {
                    "name": "@openai/codex",
                    "version": "1.0.0",
                    "bin": {"codex": "cli"},
                }
            )
        )
        command = "echo 'Missing optional dependency' >&2; exit 1" if broken else f"echo {version}"
        (root / "cli").write_text(f"#!/bin/sh\n{command}\n")
        (root / "cli").chmod(0o755)
        (prefix / "bin").mkdir(exist_ok=True)
        (prefix / "bin/codex").symlink_to("../lib/node_modules/@openai/codex/cli")
        return root

    def fake_npm(self, broken: bool = False, status: int = 0) -> Runner:
        def run(*args: str) -> subprocess.CompletedProcess[str]:
            if args[:2] == ("npm", "install"):
                self.assertIn("--include=optional", args)
                candidate = Path(args[args.index("--prefix") + 1])
                self.assertNotEqual(candidate, self.prefix)
                self.package(candidate, "new", broken=broken)
                return subprocess.CompletedProcess(args, status, "added 2 packages", "")
            return cast(subprocess.CompletedProcess[str], self.real_run(*args))

        return run

    def candidate(self, broken: bool = False, status: int = 0) -> bool:
        self.real_run = self.module.run
        with (
            patch.object(self.module, "run", side_effect=self.fake_npm(broken, status)),
            patch.object(self.installer, "refresh_versions"),
        ):
            return bool(self.installer.install_candidate(self.spec, "codex"))

    def test_npm_exit_zero_with_missing_native_dependency_retains_previous(self) -> None:
        before = (self.old / "cli").read_bytes()
        self.assertFalse(self.candidate(broken=True))
        self.assertEqual((self.old / "cli").read_bytes(), before)
        self.assertTrue(self.installer.healthy(self.prefix / "bin/codex"))

    def test_failed_npm_retains_previous(self) -> None:
        self.assertFalse(self.candidate(status=1))
        self.assertEqual(
            self.module.run(str(self.prefix / "bin/codex"), "--version").stdout, "old\n"
        )

    def test_good_candidate_replaces_package_and_relative_link(self) -> None:
        self.assertTrue(self.candidate())
        self.assertEqual(
            self.module.run(str(self.prefix / "bin/codex"), "--version").stdout, "new\n"
        )
        self.assertTrue((self.prefix / "bin/codex").is_symlink())
        self.assertFalse(list(self.prefix.glob(".agent-tools-*")))

    def test_activation_failure_restores_package_and_bin(self) -> None:
        with patch.object(self.installer, "healthy", side_effect=[True, False]):
            self.assertFalse(self.candidate())
        self.assertEqual(
            self.module.run(str(self.prefix / "bin/codex"), "--version").stdout, "old\n"
        )

    def test_image_layer_exdev_uses_copy_fallback(self) -> None:
        rename = os.rename

        def overlay_rename(source: str | os.PathLike[str], target: str | os.PathLike[str]) -> None:
            if Path(source) == self.old and Path(target).name.startswith(".agent-tools-backup-"):
                raise OSError(errno.EXDEV, "Invalid cross-device link")
            rename(source, target)

        with patch.object(os, "rename", side_effect=overlay_rename):
            self.assertTrue(self.candidate())
        self.assertEqual(
            self.module.run(str(self.prefix / "bin/codex"), "--version").stdout, "new\n"
        )

    def test_same_version_broken_executable_is_repaired(self) -> None:
        self.installer.versions = {"@openai/codex": "1.0.0"}
        (self.old / "cli").write_text("#!/bin/sh\necho 'Missing optional dependency' >&2; exit 1\n")
        with (
            patch.object(self.module, "SPECS", (self.spec,)),
            patch.object(self.module, "BINARIES", ("codex",)),
            patch.object(self.installer, "refresh_versions"),
            patch.object(
                self.installer,
                "probe",
                return_value=subprocess.CompletedProcess([], 0, "1.0.0", ""),
            ),
            patch.object(self.installer, "install_candidate", return_value=True) as install,
        ):
            self.assertTrue(self.installer.provision(self.prefix))
        install.assert_called_once_with(self.spec, "codex")

    def test_verify_cannot_use_healthy_foreign_path(self) -> None:
        (self.old / "cli").unlink()
        with (
            patch.object(self.module.shutil, "which", return_value="/foreign/codex"),
            self.assertRaises(RuntimeError),
        ):
            self.installer.verify()


class CodexTerminal(unittest.TestCase):
    def setUp(self) -> None:
        self.module = load("codex-terminal")

    def test_supported_cli_uses_standalone_and_preserves_arguments(self) -> None:
        with (
            patch.dict(os.environ, {"SF_CODEX_SHARED_SERVER": "0"}),
            patch.object(
                self.module.subprocess,
                "run",
                return_value=subprocess.CompletedProcess([], 0, "--no-daemon", ""),
            ),
        ):
            self.assertEqual(
                self.module.launch_args("/npm/codex", ["--yolo", "a b"]),
                ["/npm/codex", "--no-daemon", "--yolo", "a b"],
            )

    def test_explicit_remote_and_shared_opt_in_are_preserved(self) -> None:
        with patch.object(self.module.subprocess, "run") as run:
            for args in (
                ["--remote=unix:///tmp/test"],
                ["--remote", "ws://localhost:1"],
                ["--no-daemon", "--version"],
            ):
                self.assertEqual(self.module.launch_args("/npm/codex", args), ["/npm/codex", *args])
            with patch.dict(os.environ, {"SF_CODEX_SHARED_SERVER": "1"}):
                self.assertEqual(self.module.launch_args("/npm/codex", []), ["/npm/codex"])
            run.assert_not_called()

    def test_older_override_omits_unsupported_flag(self) -> None:
        with (
            patch.dict(os.environ, {"SF_CODEX_SHARED_SERVER": "0"}),
            patch.object(
                self.module.subprocess,
                "run",
                return_value=subprocess.CompletedProcess([], 0, "old help", ""),
            ),
        ):
            self.assertEqual(
                self.module.launch_args("/npm/codex", ["--version"]), ["/npm/codex", "--version"]
            )


if __name__ == "__main__":
    unittest.main()
