"""Host maintenance command contract tests with a fake Docker CLI."""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / ".devcontainer/storage-host.ps1"
PWSH = shutil.which("pwsh")


@unittest.skipUnless(PWSH and os.name != "nt", "Requires PowerShell and POSIX fake tools")
class HostCommands(unittest.TestCase):
    def setUp(self) -> None:
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.directory = Path(self.folder.name)
        self.log = self.directory / "calls.jsonl"
        docker = self.directory / "docker"
        docker.write_text("""#!/usr/bin/env python3
import json, os, sys
with open(os.environ["DOCKER_TEST_LOG"], "a") as log:
    log.write(json.dumps(sys.argv[1:]) + "\\n")
if "--help" in sys.argv: print("--max-used-space")
elif sys.argv[1:3] == ["context", "show"]: print("fake-context")
elif sys.argv[1:3] == ["container", "inspect"]: print("sha256:" + "a" * 64)
elif sys.argv[1:3] == ["image", "inspect"]: print(os.environ.get("DOCKER_TEST_SIZE", "12345"))
elif "inspect" in sys.argv: print("Name: fake-builder\\nDriver: docker")
elif "-q" in sys.argv: print(os.environ.get("DOCKER_TEST_RUNNING", ""))
elif sys.argv[1:] == ["ps", "-a", "--no-trunc", "--format", "{{.ID}}"]: print(os.environ.get("DOCKER_TEST_CONTAINERS", "a" * 64))
else: print("{}")
""")
        docker.chmod(0o755)
        self.env = {
            **os.environ,
            "PATH": f"{self.directory}{os.pathsep}{os.environ['PATH']}",
            "DOCKER_TEST_LOG": str(self.log),
        }

    def invoke(self, *args: str) -> subprocess.CompletedProcess[str]:
        if PWSH is None:
            raise RuntimeError("PowerShell is unavailable")
        return subprocess.run(  # noqa: S603
            [PWSH, "-NoProfile", "-File", str(SCRIPT), "-AsJson", *args],
            env=self.env,
            capture_output=True,
            text=True,
            check=False,
            timeout=30,
        )

    def calls(self) -> list[list[str]]:
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_image_budget_accepts_and_rejects(self) -> None:
        command = [sys.executable, str(SCRIPT.parent / "measure-storage.py"), "a" * 64]
        result = subprocess.run(  # noqa: S603
            command, env=self.env, capture_output=True, text=True, check=False, timeout=30
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["uncompressed_bytes"], 12345)
        env = {**self.env, "DOCKER_TEST_SIZE": str(9 * 1024**3)}
        result = subprocess.run(  # noqa: S603
            command, env=env, capture_output=True, text=True, check=False, timeout=30
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(json.loads(result.stdout)["within_budget"])

    def test_report_is_read_only(self) -> None:
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["context"]["output"], "fake-context")
        self.assertFalse(
            any("prune" in call or "rm" in call or "exec" in call for call in self.calls())
        )

    def test_prune_whatif_and_explicit_builder(self) -> None:
        result = self.invoke("-Action", "PruneBuildCache", "-Builder", "selected", "-WhatIf")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any("--force" in call for call in self.calls()))
        result = self.invoke("-Action", "PruneBuildCache", "-Builder", "selected")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            ["buildx", "--builder", "selected", "prune", "--max-used-space", "10GB", "--force"],
            self.calls(),
        )

    def test_shared_cache_requires_closed_sessions(self) -> None:
        result = self.invoke("-Action", "CleanExtensions", "-ContainerId", "a" * 64)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any("exec" in call for call in self.calls()))

    def test_shared_cache_refuses_other_running_containers(self) -> None:
        self.env["DOCKER_TEST_RUNNING"] = "b" * 64
        result = self.invoke(
            "-Action", "CleanExtensions", "-ContainerId", "a" * 64, "-SessionsClosed"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any("exec" in call for call in self.calls()))

    def test_shared_cache_previews_then_applies(self) -> None:
        self.env["DOCKER_TEST_RUNNING"] = "a" * 64
        result = self.invoke(
            "-Action", "CleanExtensions", "-ContainerId", "a" * 64, "-SessionsClosed"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = [call for call in self.calls() if call[:1] == ["exec"]]
        self.assertEqual(len(commands), 2)
        self.assertNotIn("--apply", commands[0])
        self.assertEqual(commands[1][-2:], ["--apply", "--sessions-closed"])

    def test_shared_cache_whatif_never_applies(self) -> None:
        self.env["DOCKER_TEST_RUNNING"] = "a" * 64
        result = self.invoke(
            "-Action", "CleanExtensions", "-ContainerId", "a" * 64, "-SessionsClosed", "-WhatIf"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = [call for call in self.calls() if call[:1] == ["exec"]]
        self.assertEqual(len(commands), 1)
        self.assertNotIn("--apply", commands[0])

    def test_removal_never_forces_or_removes_volumes(self) -> None:
        result = self.invoke("-Action", "RemoveContainer", "-ResourceId", "a" * 64)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(["container", "rm", "a" * 64], self.calls())
        self.assertFalse(any("--force" in call or "--volumes" in call for call in self.calls()))

    def test_container_prefix_is_resolved_before_removal(self) -> None:
        prefix = "a" * 12
        result = self.invoke("-Action", "RemoveContainer", "-ResourceId", prefix)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(["container", "rm", "a" * 64], self.calls())
        self.assertNotIn(["container", "rm", prefix], self.calls())

    def test_container_prefix_must_have_one_match(self) -> None:
        for identifiers in ("", "a" * 12 + "1" * 52 + "\n" + "a" * 12 + "2" * 52):
            with self.subTest(identifiers=identifiers):
                self.env["DOCKER_TEST_CONTAINERS"] = identifiers
                result = self.invoke("-Action", "RemoveContainer", "-ResourceId", "a" * 12)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(call[:2] == ["container", "rm"] for call in self.calls()))

    def test_image_removal_requires_full_digest_and_normalizes_it(self) -> None:
        result = self.invoke("-Action", "RemoveImage", "-ResourceId", "a" * 12)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(call[:2] == ["image", "rm"] for call in self.calls()))
        result = self.invoke("-Action", "RemoveImage", "-ResourceId", "a" * 64)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(["image", "rm", "sha256:" + "a" * 64], self.calls())
        self.assertNotIn(["image", "rm", "a" * 64], self.calls())

    def test_image_removal_lowercases_digest(self) -> None:
        for resource in ("A" * 64, "SHA256:" + "A" * 64):
            with self.subTest(resource=resource):
                self.log.unlink(missing_ok=True)
                result = self.invoke("-Action", "RemoveImage", "-ResourceId", resource)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(["image", "rm", "sha256:" + "a" * 64], self.calls())
                self.assertNotIn(["image", "rm", "sha256:" + "A" * 64], self.calls())

    def test_image_removal_rejects_short_digest(self) -> None:
        short = "sha256:" + "a" * 12
        result = self.invoke("-Action", "RemoveImage", "-ResourceId", short)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(["image", "rm", short], self.calls())
        full = "sha256:" + "a" * 64
        result = self.invoke("-Action", "RemoveImage", "-ResourceId", full)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(["image", "rm", full], self.calls())


if __name__ == "__main__":
    unittest.main()
