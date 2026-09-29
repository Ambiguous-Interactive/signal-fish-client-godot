"""Exercise the last workflow event race in Dependabot auto merge."""

from __future__ import annotations

import importlib.util
import os
import unittest
from pathlib import Path
from subprocess import CompletedProcess
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "dependabot-auto-merge.py"
SPEC = importlib.util.spec_from_file_location("dependabot_auto_merge", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Could not load {SCRIPT}")
merge = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(merge)

REPO = "owner/repo"
SHA = "a" * 40


def workflow_run(
    name: str, status: str = "completed", conclusion: str = "success"
) -> dict[str, str]:
    return {
        "name": name,
        "head_sha": SHA,
        "run_started_at": "2026-09-29T00:00:00Z",
        "status": status,
        "conclusion": conclusion,
    }


class AutoMergeTests(unittest.TestCase):
    def test_path_filtered_dev_container_gate(self) -> None:
        for path in (".devcontainer/devcontainer.json", ".github/workflows/devcontainer.yml"):
            with self.subTest(path=path):
                self.assertTrue(merge.needs_dev_container({"files": [{"path": path}]}))
        self.assertTrue(
            merge.needs_dev_container({"headRefName": "dependabot/devcontainers/main/foo"})
        )
        self.assertFalse(merge.needs_dev_container({"files": [{"path": "requirements.txt"}]}))

    def test_last_workflow_must_appear_and_succeed(self) -> None:
        for last in ("Docs Validation", "Dev Container", "Head moved"):
            with self.subTest(last=last):
                calls = 0
                merged = False
                dispatched = False

                def fake_json(*args: str, last: str = last) -> object:
                    nonlocal calls
                    joined = " ".join(args)
                    if "/commits/" in joined:
                        return [
                            {
                                "number": 12,
                                "state": "open",
                                "user": {"login": "dependabot[bot]"},
                                "base": {"ref": "main"},
                                "head": {"repo": {"full_name": REPO}, "sha": SHA},
                            }
                        ]
                    if args[:2] == ("pr", "view"):
                        if "mergeCommit" in joined:
                            return {"state": "MERGED", "mergeCommit": {"oid": "b" * 40}}
                        return {
                            "state": "OPEN",
                            "baseRefName": "main",
                            "headRefOid": "b" * 40 if last == "Head moved" and calls else SHA,
                            "isDraft": False,
                            "files": [{"path": ".devcontainer/devcontainer.json"}]
                            if last == "Dev Container"
                            else [],
                        }
                    if "/actions/runs?" in joined:
                        calls += 1
                        runs = [workflow_run("Runtime CI"), workflow_run("LLM Harness")]
                        runs.append(
                            workflow_run("Docs Validation", "in_progress", "")
                            if calls == 1 and last in ("Docs Validation", "Head moved")
                            else workflow_run("Docs Validation")
                        )
                        if last == "Dev Container" and calls > 1:
                            runs.append(workflow_run("Dev Container"))
                        return [{"workflow_runs": runs}]
                    raise AssertionError(args)

                def fake_gh(*args: str) -> CompletedProcess[str]:
                    nonlocal merged
                    if args[:2] == ("pr", "checks"):
                        return CompletedProcess(args, 0, '[{"bucket":"pass"}]', "")
                    if args[:2] == ("pr", "merge"):
                        merged = True
                        return CompletedProcess(args, 0, "", "")
                    raise AssertionError(args)

                def fake_dispatch(*_args: str) -> None:
                    nonlocal dispatched
                    dispatched = True

                env = {
                    "GITHUB_REPOSITORY": REPO,
                    "GH_TOKEN": "test-token",
                    "HEAD_SHA": SHA,
                    "REQUIRED_WORKFLOWS": "Runtime CI|LLM Harness|Docs Validation",
                }
                with (
                    patch.dict(os.environ, env),
                    patch.object(merge.shutil, "which", return_value="/usr/bin/gh"),
                    patch.object(merge, "gh_json", side_effect=fake_json),
                    patch.object(merge, "gh", side_effect=fake_gh),
                    patch.object(merge, "dispatch_main_checks", side_effect=fake_dispatch),
                    patch.object(merge.time, "sleep"),
                ):
                    self.assertEqual(merge.main(), 0)
                self.assertEqual(calls, 1 if last == "Head moved" else 2)
                self.assertEqual(merged, last != "Head moved")
                self.assertEqual(dispatched, last != "Head moved")


if __name__ == "__main__":
    unittest.main()
