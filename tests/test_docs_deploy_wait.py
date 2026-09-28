"""Check the Docs Deploy handoff against selected and unrelated runs."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time
import unittest
from pathlib import Path
from subprocess import CompletedProcess
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import wait_for_docs_validation as wait

REPO = "Ambiguous-Interactive/signal-fish-client-godot"
SHA = "a" * 40
RUN = {
    "repository": {"full_name": REPO},
    "path": ".github/workflows/docs-validation.yml",
    "event": "workflow_dispatch",
    "head_branch": "main",
    "head_sha": SHA,
    "status": "completed",
    "conclusion": "success",
}


class DocsDeployWaitTests(unittest.TestCase):
    def test_only_exact_main_run_is_accepted(self) -> None:
        self.assertEqual(wait.run_state(RUN, REPO, SHA), ("completed", "success"))
        for field, value in (
            ("path", ".github/workflows/ci.yml"),
            ("event", "pull_request"),
            ("head_branch", "feature"),
            ("head_sha", "b" * 40),
        ):
            with self.subTest(field=field), self.assertRaises(ValueError):
                wait.run_state({**RUN, field: value}, REPO, SHA)
        with self.assertRaises(ValueError):
            wait.run_state({**RUN, "repository": {"full_name": "other/repo"}}, REPO, SHA)

    def test_retry_then_accept_or_reject_completed_run(self) -> None:
        retry = CompletedProcess([], 1, "", "temporary error")
        success = CompletedProcess([], 0, json.dumps(RUN), "")
        with (
            patch.object(shutil, "which", return_value="/usr/bin/gh"),
            patch.object(subprocess, "run", side_effect=[retry, success]) as gh,
            patch.object(time, "sleep") as sleep,
        ):
            wait.wait_for_run(REPO, "42", SHA)
        self.assertEqual(gh.call_count, 2)
        sleep.assert_called_once_with(10)

        failed = {**RUN, "conclusion": "failure"}
        with (
            patch.object(shutil, "which", return_value="/usr/bin/gh"),
            patch.object(
                subprocess,
                "run",
                return_value=CompletedProcess([], 0, json.dumps(failed), ""),
            ),
            self.assertRaisesRegex(ValueError, "did not succeed"),
        ):
            wait.wait_for_run(REPO, "42", SHA)

    def test_timeout_and_invalid_dispatch_inputs(self) -> None:
        with (
            patch.object(shutil, "which", return_value="/usr/bin/gh"),
            patch.object(
                subprocess, "run", return_value=CompletedProcess([], 1, "", "temporary error")
            ) as gh,
            patch.object(time, "sleep") as sleep,
            self.assertRaises(TimeoutError),
        ):
            wait.wait_for_run(REPO, "42", SHA)
        self.assertEqual(gh.call_count, 150)
        self.assertEqual(sleep.call_count, 149)

        env = {
            "VALIDATED_RUN_ID": "abc",
            "EXPECTED_SHA": SHA,
            "GITHUB_SHA": SHA,
            "GITHUB_REPOSITORY": REPO,
        }
        with patch.dict(os.environ, env), self.assertRaises(ValueError):
            wait.main()
        env["VALIDATED_RUN_ID"] = "42"
        env["GITHUB_SHA"] = "b" * 40
        with patch.dict(os.environ, env), self.assertRaises(ValueError):
            wait.main()


if __name__ == "__main__":
    unittest.main()
