"""Regression checks: python .devcontainer/test_portability.py."""
import json
from pathlib import Path
import re
import os
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parent


def config():
    text = (ROOT / "devcontainer.json").read_text(encoding="utf-8")
    text = re.sub(r'"(?:\\.|[^"\\])*"|//[^\n]*',
                  lambda m: "" if m[0].startswith("//") else m[0], text)
    return json.loads(text)


class Portability(unittest.TestCase):
    def test_host_requires_only_docker(self):
        command = config()["initializeCommand"]
        self.assertEqual(command[0], "docker")
        self.assertIn("${localWorkspaceFolder}:/workspace", command)

    def test_agents_installed_in_image(self):
        dockerfile = (ROOT / "Dockerfile").read_text(encoding="utf-8")
        self.assertIn("bash /usr/local/share/devcontainer/install-agent-tools.sh", dockerfile)
        for package in ("@openai/codex", "@opencode/cli",
                        "@nanocollective/nanocoder", "@anthropic-ai/claude-code"):
            self.assertIn(f"https://registry.npmjs.org/{package}/latest", dockerfile)
        self.assertNotIn("ghcr.io/devcontainers/features/node:2", config()["features"])

    def test_restart_updates_are_opt_in(self):
        script = (ROOT / "post-start.sh").read_text(encoding="utf-8")
        guard = script.index('"${SF_DEVCONTAINER_MAINTENANCE:-0}" != "1"')
        self.assertLess(guard, script.index('install-agent-tools.sh" --update'))
        self.assertIn("exit 0", script[guard:script.index('install-agent-tools.sh" --update')])

    def test_env_guard_chown_is_best_effort(self):
        # Some bind mounts reject ownership changes; create must survive
        # that (Bugbot on PR #159). Static pin for the source of the
        # docker-level behavior test below; the `||` fallback may ride a
        # line continuation, so scan a window past the chown line.
        script = (ROOT / "initialize.sh").read_text(encoding="utf-8")
        chown = script.index("chown --reference=")
        window = script[chown:script.index("Created .env.local", chown)]
        self.assertIn("||", window)
        self.assertIn("WARN", window)


@unittest.skipUnless(os.environ.get("SF_TEST_DOCKER") == "1", "set SF_TEST_DOCKER=1")
class DockerBehavior(unittest.TestCase):
    def test_bootstrap_and_offline_restart(self):
        with tempfile.TemporaryDirectory(prefix="sf container ' spaces ") as folder:
            workspace = Path(folder)
            scripts = workspace / ".devcontainer"
            scripts.mkdir()
            for name in ("initialize.sh", "post-start.sh"):
                shutil.copyfile(ROOT / name, scripts / name)
            command = [arg.replace("${localWorkspaceFolder}", folder)
                       for arg in config()["initializeCommand"]]
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

    def test_create_survives_failing_chown(self):
        # Some bind mounts reject ownership changes; the real guard must
        # still materialize .env.local and exit 0 (Bugbot on PR #159).
        with tempfile.TemporaryDirectory(prefix="sf chown fail ") as folder:
            workspace = Path(folder)
            scripts = workspace / ".devcontainer"
            scripts.mkdir()
            shutil.copyfile(ROOT / "initialize.sh", scripts / "initialize.sh")
            example = b"SF_TEST=placeholder\n"
            (workspace / ".env.example").write_bytes(example)
            command = [arg.replace("${localWorkspaceFolder}", folder)
                       for arg in config()["initializeCommand"]]
            image = next(i for i, arg in enumerate(command)
                         if arg.startswith("mcr.microsoft.com/devcontainers/"))
            shim = ('mkdir -p /tmp/shim && printf "#!/bin/sh\\nexit 1\\n" > /tmp/shim/chown '
                    '&& chmod +x /tmp/shim/chown '
                    '&& PATH="/tmp/shim:$PATH" bash .devcontainer/initialize.sh')
            shimmed = command[:image + 1] + ["bash", "-c", shim]
            result = subprocess.run(shimmed, capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((workspace / ".env.local").read_bytes(), example)
            self.assertIn("WARN", result.stderr)


if __name__ == "__main__":
    unittest.main()
