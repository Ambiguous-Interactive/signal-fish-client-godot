"""Check workflow gates through their command-line interface."""

import json
import os
import subprocess
import sys
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/workflow-gates.py"


def run_gate(
    command: str, values: dict[str, str], *arguments: str
) -> subprocess.CompletedProcess[str]:
    environment = dict(os.environ)
    for name in ("GITHUB_SHA", "EXPECTED_SHA", "NEEDS_JSON"):
        environment.pop(name, None)
    environment.update(values)
    jobs = ["test"] if command == "require-jobs" and not arguments else []
    return subprocess.run(  # noqa: S603
        [sys.executable, str(SCRIPT), command, *jobs, *arguments],
        env=environment,
        capture_output=True,
        text=True,
        check=False,
    )


class WorkflowGateTests(unittest.TestCase):
    def test_dispatched_commit(self) -> None:
        for actual, expected, success in (
            ("a" * 40, "a" * 40, True),
            ("a" * 40, "b" * 40, False),
            ("", "a" * 40, False),
            ("a" * 40, "", False),
            ("", "", False),
        ):
            with self.subTest(actual=actual, expected=expected):
                result = run_gate("verify-sha", {"GITHUB_SHA": actual, "EXPECTED_SHA": expected})
                self.assertEqual(result.returncode == 0, success, result.stderr)
                if not success:
                    self.assertIn("::error::", result.stderr)

    def test_required_job_results(self) -> None:
        for name in ("verify-dispatch", "markdownlint", "link-check", "accessibility"):
            for status in ("success", "failure", "cancelled", "skipped", "pending", ""):
                with self.subTest(name=name, status=status):
                    needs = {
                        job: {"result": "success", "outputs": {}}
                        for job in (
                            "verify-dispatch",
                            "markdownlint",
                            "link-check",
                            "accessibility",
                        )
                    }
                    needs[name]["result"] = status
                    result = run_gate(
                        "require-jobs",
                        {"NEEDS_JSON": json.dumps(needs)},
                        "verify-dispatch",
                        "markdownlint",
                        "link-check",
                        "accessibility",
                        "--allow-skipped",
                        "verify-dispatch",
                    )
                    success = status == "success" or (
                        name == "verify-dispatch" and status == "skipped"
                    )
                    self.assertEqual(result.returncode == 0, success, result.stderr)
                    if not success:
                        self.assertIn(name, result.stderr)

    def test_skips_require_explicit_allowance(self) -> None:
        result = run_gate("require-jobs", {"NEEDS_JSON": '{"test":{"result":"skipped"}}'})
        self.assertNotEqual(result.returncode, 0)

    def test_missing_required_job_fails(self) -> None:
        result = run_gate("require-jobs", {"NEEDS_JSON": '{"other":{"result":"success"}}'})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing required jobs: test", result.stderr)

    def test_extra_jobs_are_checked(self) -> None:
        result = run_gate(
            "require-jobs",
            {"NEEDS_JSON": '{"test":{"result":"success"},"extra":{"result":"failure"}}'},
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("extra", result.stderr)

    def test_invalid_needs_fail(self) -> None:
        for value in (
            "",
            "{",
            "null",
            "[]",
            "{}",
            "true",
            "1",
            '"text"',
            '{"test":null}',
            '{"test":[]}',
            '{"test":{}}',
            '{"test":{"result":null}}',
            '{"test":{"result":true}}',
        ):
            with self.subTest(value=value):
                result = run_gate("require-jobs", {"NEEDS_JSON": value})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("::error::", result.stderr)
                self.assertNotIn("Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main()
