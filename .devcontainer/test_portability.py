"""Regression checks: python .devcontainer/test_portability.py."""

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
    def test_host_requires_only_docker(self) -> None:
        command = config()["initializeCommand"]
        self.assertEqual(command[0], "docker")
        self.assertIn("${localWorkspaceFolder}:/workspace", command)

    def test_agents_installed_in_image(self) -> None:
        dockerfile = (ROOT / "Dockerfile").read_text(encoding="utf-8")
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

    def test_env_guard_chown_is_best_effort(self) -> None:
        # Some bind mounts reject ownership changes; create must survive
        # that (Bugbot on PR #159). Static pin for the source of the
        # docker-level behavior test below: the guard must attempt to
        # keep the file readable and warn on the degraded path.
        script = (ROOT / "initialize.sh").read_text(encoding="utf-8")
        chown = script.index("chown --reference=")
        window = script[chown : script.index("Created .env.local", chown)]
        self.assertIn("chmod a+r", window)
        self.assertIn("WARN", window)


@unittest.skipUnless(os.environ.get("SF_TEST_DOCKER") == "1", "set SF_TEST_DOCKER=1")
class DockerBehavior(unittest.TestCase):
    def test_bootstrap_and_offline_restart(self) -> None:
        with tempfile.TemporaryDirectory(prefix="sf container ' spaces ") as folder:
            workspace = Path(folder)
            scripts = workspace / ".devcontainer"
            scripts.mkdir()
            for name in ("initialize.sh", "post-start.sh", "post-start.py"):
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
            command[-1] = ".devcontainer/post-start.sh"
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
            shutil.copyfile(ROOT / "initialize.sh", scripts / "initialize.sh")
            example = b"SF_TEST=placeholder\n"
            (workspace / ".env.example").write_bytes(example)
            command = [
                arg.replace("${localWorkspaceFolder}", folder)
                for arg in config()["initializeCommand"]
            ]
            image = next(
                i
                for i, arg in enumerate(command)
                if arg.startswith("mcr.microsoft.com/devcontainers/")
            )
            shim = (
                'mkdir -p /tmp/shim && printf "#!/bin/sh\\nexit 1\\n" > /tmp/shim/chown '
                "&& chmod +x /tmp/shim/chown "
                '&& PATH="/tmp/shim:$PATH" bash .devcontainer/initialize.sh '
                "&& cat .env.local"
            )
            shimmed = [*command[: image + 1], "bash", "-c", shim]
            result = subprocess.run(shimmed, capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("SF_TEST=placeholder", result.stdout)
            self.assertIn("WARN", result.stderr)
            # Content is read inside the container: with chown refused the
            # file is deliberately root-owned, and the degraded path keeps
            # it host-readable only via the chmod fallback.


if __name__ == "__main__":
    unittest.main()
