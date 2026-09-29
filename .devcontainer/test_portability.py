"""Regression checks: python .devcontainer/test_portability.py."""

import importlib.util
import json
import os
import re
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from typing import TypedDict
from unittest.mock import patch


class DevcontainerConfig(TypedDict):
    initializeCommand: list[str]
    features: dict[str, object]


ROOT = Path(__file__).resolve().parent


def config() -> DevcontainerConfig:
    text = (ROOT / "devcontainer.json").read_text(encoding="utf-8")
    text = re.sub(
        r'"(?:\\.|[^"\\])*"|//[^\n]*', lambda m: "" if m[0].startswith("//") else m[0], text
    )
    parsed: object = json.loads(text)
    if not isinstance(parsed, dict):
        raise ValueError("devcontainer config must be an object")
    command = parsed.get("initializeCommand")
    features = parsed.get("features")
    if not isinstance(command, list) or not isinstance(features, dict):
        raise ValueError("devcontainer config lacks command or features")
    command_values: list[str] = []
    for value in command:
        if not isinstance(value, str):
            raise ValueError("devcontainer initializeCommand must contain text")
        command_values.append(value)
    feature_values: dict[str, object] = {}
    for key, value in features.items():
        if not isinstance(key, str):
            raise ValueError("devcontainer feature keys must be text")
        feature_values[key] = value
    return {"initializeCommand": command_values, "features": feature_values}


class Portability(unittest.TestCase):
    def test_post_create_runs_strict_setup_and_offline_maintenance(self) -> None:
        spec = importlib.util.spec_from_file_location("post_create", ROOT / "post-create.py")
        if spec is None or spec.loader is None:
            self.fail("post-create.py could not be loaded")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        calls: list[tuple[tuple[str, ...], dict[str, str] | None]] = []

        def fake_run(*args: str, check: bool = True, env: dict[str, str] | None = None) -> bool:
            calls.append((args, env))
            return True

        def fake_writable(path: Path) -> None:
            if path != Path("/commandhistory"):
                path.mkdir(parents=True, exist_ok=True)

        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder)
            profile_dir = home / ".config/powershell"
            profile_dir.mkdir(parents=True)
            original = home / "user-profile.ps1"
            original.write_text("user content\n", encoding="utf-8")
            (profile_dir / "profile.ps1").symlink_to(original)
            with (
                patch.object(module, "run", side_effect=fake_run),
                patch.object(module, "ensure_writable_dir", side_effect=fake_writable),
                patch.object(module, "toolchain_summary"),
                patch.object(module.shutil, "which", return_value="/usr/bin/tool"),
                patch.object(module.Path, "home", return_value=home),
            ):
                self.assertEqual(module.main(), 0)
            self.assertEqual(
                (profile_dir / "profile.ps1").read_bytes(),
                (ROOT / "pwsh-profile.ps1").read_bytes(),
            )
            self.assertFalse((profile_dir / "profile.ps1").is_symlink())
            self.assertEqual(original.read_text(encoding="utf-8"), "user content\n")
        commands = [args for args, _ in calls]
        self.assertIn(
            ("pwsh", "-NoProfile", "-File", "scripts/install-git-hooks.ps1", "-Force"), commands
        )
        self.assertIn(("bash", str(ROOT / "install-agent-tools.sh"), "--verify"), commands)
        mcp = next(env for args, env in calls if "install-mcp-servers.py" in args[1])
        if mcp is None:
            self.fail("MCP installer did not receive its environment")
        self.assertEqual(mcp["SF_MCP_SKIP_PLAYWRIGHT_BROWSER"], "1")
        maintenance = next(env for args, env in calls if "post-start.sh" in args[1])
        if maintenance is None:
            self.fail("post-start did not receive its environment")
        self.assertEqual(maintenance["SF_DEVCONTAINER_SKIP_TOOL_UPDATES"], "1")

    def test_host_requires_only_docker(self) -> None:
        command = config()["initializeCommand"]
        self.assertEqual(command[0], "docker")
        self.assertIn("${localWorkspaceFolder}:/workspace", command)

    def test_agents_installed_in_image(self) -> None:
        dockerfile = (ROOT / "Dockerfile").read_text(encoding="utf-8")
        self.assertIn("COPY install-agent-tools.sh install-agent-tools.py", dockerfile)
        self.assertIn("bash /usr/local/share/devcontainer/install-agent-tools.sh", dockerfile)
        for package in (
            "@openai/codex",
            "@opencode/cli",
            "@nanocollective/nanocoder",
            "@anthropic-ai/claude-code",
        ):
            self.assertIn(f"https://registry.npmjs.org/{package}/latest", dockerfile)
        self.assertNotIn("ghcr.io/devcontainers/features/node:2", config()["features"])

    def test_restart_updates_are_opt_in(self) -> None:
        with tempfile.TemporaryDirectory(prefix="sf post start ") as folder:
            workspace = Path(folder)
            scripts = workspace / ".devcontainer"
            scripts.mkdir()
            for name in ("post-start.sh", "post-start.py"):
                shutil.copyfile(ROOT / name, scripts / name)
            home = workspace / "home"
            home.mkdir()
            env = os.environ.copy()
            env["HOME"] = str(home)
            env.pop("SF_DEVCONTAINER_MAINTENANCE", None)
            bash = shutil.which("bash") or "bash"
            for _ in range(2):
                result = subprocess.run(
                    (bash, str(scripts / "post-start.sh")),
                    cwd=workspace,
                    env=env,
                    capture_output=True,
                    text=True,
                    check=True,
                )
                self.assertIn("Container ready. Rebuild to update tools.", result.stdout)
                self.assertNotIn("refresh", result.stderr)
            self.assertFalse((workspace / ".venv-ci").exists())
            config = (home / ".gitconfig").read_text(encoding="utf-8")
            self.assertEqual(config.count(str(workspace)), 1)

    def test_broken_venv_is_warn_only(self) -> None:
        with tempfile.TemporaryDirectory(prefix="sf broken venv ") as folder:
            workspace = Path(folder)
            scripts = workspace / ".devcontainer"
            scripts.mkdir()
            for name in ("post-start.sh", "post-start.py"):
                shutil.copyfile(ROOT / name, scripts / name)
            (workspace / ".venv-ci" / "bin").mkdir(parents=True)
            home = workspace / "home"
            home.mkdir()
            env = os.environ.copy()
            env["HOME"] = str(home)
            env["SF_DEVCONTAINER_MAINTENANCE"] = "1"
            env["SF_DEVCONTAINER_SKIP_TOOL_UPDATES"] = "1"
            result = subprocess.run(
                (shutil.which("bash") or "bash", str(scripts / "post-start.sh")),
                cwd=workspace,
                env=env,
                capture_output=True,
                text=True,
                check=True,
                timeout=30,
            )
            self.assertIn("could not provision .venv-ci", result.stderr)
            self.assertIn("Container ready.", result.stdout)

    def test_failed_updates_are_warn_only(self) -> None:
        with tempfile.TemporaryDirectory(prefix="sf failed updates ") as folder:
            workspace = Path(folder)
            scripts = workspace / ".devcontainer"
            scripts.mkdir()
            for name in ("post-start.sh", "post-start.py"):
                shutil.copyfile(ROOT / name, scripts / name)
            (scripts / "install-agent-tools.sh").write_text("exit 1\n", encoding="utf-8")
            for name in ("install-mcp-servers.py", "seed-mcp-config.py"):
                (scripts / name).write_text("raise SystemExit(1)\n", encoding="utf-8")
            venv_bin = workspace / ".venv-ci" / "bin"
            venv_bin.mkdir(parents=True)
            (venv_bin / "activate").touch()
            for name in ("python", "gdformat", "ruff"):
                tool = venv_bin / name
                tool.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
                tool.chmod(0o755)
            home = workspace / "home"
            home.mkdir()
            env = os.environ.copy()
            env["HOME"] = str(home)
            env["SF_DEVCONTAINER_MAINTENANCE"] = "1"
            env.pop("SF_DEVCONTAINER_SKIP_TOOL_UPDATES", None)
            result = subprocess.run(
                (shutil.which("bash") or "bash", str(scripts / "post-start.sh")),
                cwd=workspace,
                env=env,
                capture_output=True,
                text=True,
                check=True,
                timeout=15,
            )
            for message in (
                "agent CLI refresh failed",
                "MCP server refresh failed",
                "MCP configuration seeding failed",
            ):
                self.assertIn(message, result.stderr)
            self.assertIn("Container ready.", result.stdout)

    def test_env_guard(self) -> None:
        spec = importlib.util.spec_from_file_location("initialize", ROOT / "initialize.py")
        if spec is None or spec.loader is None:
            self.fail("initialize.py could not be loaded")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as folder:
            workspace = Path(folder)
            target = workspace / ".env.local"
            self.assertEqual(module.initialize(workspace), 1)
            self.assertFalse(target.exists())

            source = workspace / ".env.example"
            source.write_bytes(b"SF_TEST=placeholder\r\n")
            self.assertEqual(module.initialize(workspace), 0)
            self.assertEqual(target.read_bytes(), source.read_bytes())
            self.assertEqual(target.stat().st_mode & 0o777, 0o600)

            target.write_bytes(b"SF_TEST=preserve-canary\n")
            self.assertEqual(module.initialize(workspace), 0)
            self.assertEqual(target.read_bytes(), b"SF_TEST=preserve-canary\n")
            target.unlink()
            target.mkdir()
            self.assertEqual(module.initialize(workspace), 1)

    def test_env_guard_chown_is_best_effort(self) -> None:
        spec = importlib.util.spec_from_file_location("initialize", ROOT / "initialize.py")
        if spec is None or spec.loader is None:
            self.fail("initialize.py could not be loaded")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as folder:
            workspace = Path(folder)
            (workspace / ".env.example").write_bytes(b"SF_TEST=placeholder\n")
            with patch.object(module.os, "chown", side_effect=PermissionError):
                self.assertEqual(module.initialize(workspace), 0)
            target = workspace / ".env.local"
            self.assertEqual(target.stat().st_mode & 0o444, 0o444)

    def test_env_guard_keeps_concurrent_file(self) -> None:
        spec = importlib.util.spec_from_file_location("initialize", ROOT / "initialize.py")
        if spec is None or spec.loader is None:
            self.fail("initialize.py could not be loaded")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as folder:
            workspace = Path(folder)
            (workspace / ".env.example").write_bytes(b"SF_TEST=template\n")
            concurrent = b"SF_TEST=other-window\n"

            def concurrent_create(*_args: object) -> int:
                (workspace / ".env.local").write_bytes(concurrent)
                raise FileExistsError

            with patch.object(module.os, "open", side_effect=concurrent_create):
                self.assertEqual(module.initialize(workspace), 0)
            self.assertEqual((workspace / ".env.local").read_bytes(), concurrent)


@unittest.skipUnless(os.environ.get("SF_TEST_DOCKER") == "1", "set SF_TEST_DOCKER=1")
class DockerBehavior(unittest.TestCase):
    def test_bootstrap_and_offline_restart(self) -> None:
        with tempfile.TemporaryDirectory(prefix="sf container ' spaces ") as folder:
            workspace = Path(folder)
            scripts = workspace / ".devcontainer"
            scripts.mkdir()
            for name in ("initialize.py", "post-start.sh", "post-start.py"):
                shutil.copyfile(ROOT / name, scripts / name)
            command = [
                arg.replace("${localWorkspaceFolder}", folder)
                for arg in config()["initializeCommand"]
            ]
            missing = subprocess.run(command, capture_output=True, text=True, timeout=60)
            self.assertNotEqual(missing.returncode, 0)
            self.assertFalse((workspace / ".env.local").exists())
            example = b"SF_TEST=placeholder\r\n"
            (workspace / ".env.example").write_bytes(example)
            subprocess.run(command, check=True, capture_output=True, timeout=60)
            self.assertEqual((workspace / ".env.local").read_bytes(), example)
            existing = b"SF_TEST=preserve-canary\n"
            (workspace / ".env.local").write_bytes(existing)
            result = subprocess.run(command, check=True, capture_output=True, timeout=60)
            self.assertEqual((workspace / ".env.local").read_bytes(), existing)
            self.assertNotIn(b"preserve-canary", result.stdout + result.stderr)
            command[-3:] = [
                "mcr.microsoft.com/devcontainers/base:ubuntu-24.04",
                "bash",
                ".devcontainer/post-start.sh",
            ]
            started = time.monotonic()
            result = subprocess.run(command, check=True, capture_output=True, timeout=15)
            self.assertIn(b"Container ready", result.stdout)
            print(f"Offline restart including Docker launch: {time.monotonic() - started:.2f}s")

    def test_create_survives_failing_chown(self) -> None:
        # Some bind mounts reject ownership changes; the real guard must
        # still materialize .env.local and exit 0 (Bugbot on PR #159).
        with tempfile.TemporaryDirectory(prefix="sf chown fail ") as folder:
            workspace = Path(folder)
            scripts = workspace / ".devcontainer"
            scripts.mkdir()
            shutil.copyfile(ROOT / "initialize.py", scripts / "initialize.py")
            example = b"SF_TEST=placeholder\n"
            (workspace / ".env.example").write_bytes(example)
            command = [
                arg.replace("${localWorkspaceFolder}", folder)
                for arg in config()["initializeCommand"]
            ]
            image = command.index("python:3.12-slim-bookworm")
            shim = (
                "import runpy\n"
                "from unittest.mock import patch\n"
                "with patch('os.chown', side_effect=PermissionError):\n"
                "    runpy.run_path('.devcontainer/initialize.py', run_name='__main__')\n"
            )
            shimmed = [*command[: image + 1], "python3", "-c", shim]
            result = subprocess.run(shimmed, capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((workspace / ".env.local").read_bytes(), example)
            self.assertIn("WARN", result.stderr)
            # Content is read inside the container: with chown refused the
            # file is deliberately root-owned, and the degraded path keeps
            # it host-readable only via the chmod fallback.


if __name__ == "__main__":
    unittest.main()
