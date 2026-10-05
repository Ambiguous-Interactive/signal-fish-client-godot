"""Exercise the last workflow event race in Dependabot auto merge."""

from __future__ import annotations

import importlib.util
import io
import json
import os
import unittest
from collections.abc import Callable
from contextlib import redirect_stdout
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
                    if args[:2] == ("pr", "view"):
                        body = {
                            "state": "MERGED",
                            "headRefOid": SHA,
                            "mergeCommit": {"oid": "b" * 40},
                        }
                        return CompletedProcess(args, 0, json.dumps(body), "")
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


MERGED_BODY = {"state": "MERGED", "headRefOid": SHA, "mergeCommit": {"oid": "b" * 40}}
OPEN_BODY = {"state": "OPEN", "headRefOid": SHA, "mergeCommit": {}}


class RecheckScript:
    """Fake ``gh`` merged-state reader; a None response is a gh failure."""

    def __init__(self, *responses: object) -> None:
        self.responses = responses
        self.reads = 0

    def __call__(self, *args: str) -> CompletedProcess[str]:
        if args[:2] != ("pr", "view"):
            raise AssertionError(args)
        response = self.responses[self.reads]
        self.reads += 1
        if response is None:
            return CompletedProcess(args, 1, "", "gh: view failed")
        return CompletedProcess(args, 0, json.dumps(response), "")


class MergedStateTests(unittest.TestCase):
    def test_merged_state_retries_incomplete_snapshots(self) -> None:
        empty_head = {"state": "MERGED", "headRefOid": "", "mergeCommit": {"oid": "b" * 40}}
        lagging = {"state": "MERGED", "headRefOid": SHA, "mergeCommit": {}}
        scenarios: tuple[tuple[str, tuple[object, ...], object], ...] = (
            ("complete on first read", (MERGED_BODY,), MERGED_BODY),
            ("open then merged", (OPEN_BODY, MERGED_BODY), MERGED_BODY),
            ("gh blip then merged", (None, MERGED_BODY), MERGED_BODY),
            ("empty head lags state", (empty_head, MERGED_BODY), MERGED_BODY),
            ("merge commit lags state", (lagging, MERGED_BODY), MERGED_BODY),
            (
                "still open after bounded retries",
                (OPEN_BODY,) * merge.MERGED_RECHECK_ATTEMPTS,
                None,
            ),
        )
        for name, responses, expected in scenarios:
            with self.subTest(name=name):
                read = RecheckScript(*responses)
                with (
                    patch.object(merge, "gh", side_effect=read),
                    patch.object(merge.time, "sleep"),
                ):
                    self.assertEqual(merge.merged_state("12"), expected)
                self.assertEqual(read.reads, len(responses))

    def test_merged_state_is_silent_on_a_clean_read(self) -> None:
        read = RecheckScript(MERGED_BODY)
        with (
            patch.object(merge, "gh", side_effect=read),
            patch.object(merge.time, "sleep"),
            redirect_stdout(io.StringIO()) as out,
        ):
            self.assertEqual(merge.merged_state("12"), MERGED_BODY)
        self.assertEqual(out.getvalue(), "")
        self.assertEqual(read.reads, 1)


class MergeRaceTests(unittest.TestCase):
    def test_lost_merge_race_rechecks_merged_state(self) -> None:
        wrong_head = {"state": "MERGED", "headRefOid": "c" * 40, "mergeCommit": {"oid": "d" * 40}}
        scenarios: tuple[tuple[str, tuple[object, ...], int, int], ...] = (
            # (name, merged-state recheck script, exit code, expected reads)
            ("merged on first read", (MERGED_BODY,), 0, 1),
            ("stale open reads then merged", (OPEN_BODY, OPEN_BODY, MERGED_BODY), 0, 3),
            ("gh blip then merged", (None, MERGED_BODY), 0, 2),
            (
                "never merged",
                (OPEN_BODY,) * merge.MERGED_RECHECK_ATTEMPTS,
                1,
                merge.MERGED_RECHECK_ATTEMPTS,
            ),
            ("merged at another head", (wrong_head,), 1, 1),
        )
        for name, responses, expected, expected_reads in scenarios:
            with self.subTest(name=name):
                sleeps = 0
                merged = False
                dispatched = False

                def fake_json(*args: str) -> object:
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
                        return {
                            "state": "OPEN",
                            "baseRefName": "main",
                            "headRefOid": SHA,
                            "isDraft": False,
                            "files": [],
                        }
                    if "/actions/runs?" in joined:
                        runs = [
                            workflow_run("Runtime CI"),
                            workflow_run("LLM Harness"),
                            workflow_run("Docs Validation"),
                        ]
                        return [{"workflow_runs": runs}]
                    raise AssertionError(args)

                def fake_sleep(_seconds: float) -> None:
                    nonlocal sleeps
                    sleeps += 1

                def fake_dispatch(*_args: str) -> None:
                    nonlocal dispatched
                    dispatched = True

                read = RecheckScript(*responses)

                def fake_gh(*args: str, read: RecheckScript = read) -> CompletedProcess[str]:
                    nonlocal merged
                    if args[:2] == ("pr", "checks"):
                        return CompletedProcess(args, 0, '[{"bucket":"pass"}]', "")
                    if args[:2] == ("pr", "merge"):
                        merged = True
                        return CompletedProcess(args, 1, "", "already merged by a racing run")
                    return read(*args)

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
                    patch.object(merge.time, "sleep", side_effect=fake_sleep),
                ):
                    self.assertEqual(merge.main(), expected)
                self.assertEqual(read.reads, expected_reads)
                self.assertEqual(sleeps, read.reads - 1)
                self.assertTrue(merged)
                self.assertFalse(dispatched)


class DispatchSequenceTests(unittest.TestCase):
    SHA = "a" * 40

    @staticmethod
    def fake_gh_json(
        dispatches: list[tuple[str, tuple[str, ...], int]],
        ref_reads: list[str],
        compare_status: str = "ahead",
        compare_error: str | None = None,
    ) -> Callable[[str], object]:
        counter = iter(range(1000, 2000))
        state = {"read": 0}

        def fake(*args: str) -> object:
            joined = " ".join(args)
            if "/git/ref/heads/" in joined:
                index = min(state["read"], len(ref_reads) - 1)
                state["read"] += 1
                return {"object": {"sha": ref_reads[index]}}
            if "/compare/" in joined:
                if compare_error is not None:
                    raise RuntimeError(compare_error)
                return {"status": compare_status}
            if "/dispatches" in joined:
                workflow = args[3].rsplit("/", 2)[-2]
                run_id = next(counter)
                dispatches.append((workflow, args, run_id))
                return {"workflow_run_id": run_id}
            raise AssertionError(args)

        return fake

    def test_dispatch_order_and_validated_run_handoff(self) -> None:
        dispatches: list[tuple[str, tuple[str, ...], int]] = []
        with patch.object(merge, "gh_json", side_effect=self.fake_gh_json(dispatches, [self.SHA])):
            merge.dispatch_main_checks("owner/repo", "main", self.SHA)
        self.assertEqual(
            [name for name, _, _ in dispatches],
            ["ci.yml", "llm-harness.yml", "docs-validation.yml", "docs-deploy.yml"],
        )
        for name, args, _ in dispatches:
            with self.subTest(workflow=name):
                self.assertIn("--method POST", " ".join(args))
                self.assertIn(f"workflows/{name}/dispatches", " ".join(args))
                self.assertIn("-F return_run_details=true", " ".join(args))
                self.assertIn("-f ref=main", " ".join(args))
                self.assertIn(f"-f inputs[expected_sha]={self.SHA}", " ".join(args))
        docs_run_id = dispatches[2][2]
        deploy_args = " ".join(dispatches[3][1])
        self.assertIn(f"inputs[validated_run_id]={docs_run_id}", deploy_args)

    def test_displaced_merge_defers_dispatch_to_newer_tip(self) -> None:
        dispatches: list[tuple[str, tuple[str, ...], int]] = []
        with patch.object(merge, "gh_json", side_effect=self.fake_gh_json(dispatches, ["b" * 40])):
            merge.dispatch_main_checks("owner/repo", "main", self.SHA)
        self.assertEqual(dispatches, [])

    def test_stale_ref_read_redispatches_for_the_merge_tip(self) -> None:
        dispatches: list[tuple[str, tuple[str, ...], int]] = []
        stale = self.fake_gh_json(dispatches, ["c" * 40, self.SHA], compare_status="behind")
        with patch.object(merge, "gh_json", side_effect=stale):
            merge.dispatch_main_checks("owner/repo", "main", self.SHA)
        self.assertEqual(
            [name for name, _, _ in dispatches],
            ["ci.yml", "llm-harness.yml", "docs-validation.yml", "docs-deploy.yml"],
        )

    def test_failed_compare_redispatches_through_the_ref_recheck(self) -> None:
        dispatches: list[tuple[str, tuple[str, ...], int]] = []
        stale = self.fake_gh_json(
            dispatches, ["c" * 40, self.SHA], compare_error="gh api compare failed (exit 500)"
        )
        with patch.object(merge, "gh_json", side_effect=stale):
            merge.dispatch_main_checks("owner/repo", "main", self.SHA)
        self.assertEqual(
            [name for name, _, _ in dispatches],
            ["ci.yml", "llm-harness.yml", "docs-validation.yml", "docs-deploy.yml"],
        )

    def test_non_descendant_tips_never_skip_silently(self) -> None:
        for compare_status in ("behind", "diverged", "identical"):
            with self.subTest(compare_status=compare_status):
                dispatches: list[tuple[str, tuple[str, ...], int]] = []
                moved = self.fake_gh_json(dispatches, ["b" * 40], compare_status=compare_status)
                with (
                    patch.object(merge, "gh_json", side_effect=moved),
                    self.assertRaisesRegex(RuntimeError, "moved before CI dispatch"),
                ):
                    merge.dispatch_main_checks("owner/repo", "main", self.SHA)
                self.assertEqual(dispatches, [])

    def test_dispatch_rejects_moved_branch_and_missing_run_id(self) -> None:
        dispatches: list[tuple[str, tuple[str, ...], int]] = []
        with (
            patch.object(merge, "gh_json", side_effect=self.fake_gh_json(dispatches, ["b" * 40])),
            self.assertRaisesRegex(RuntimeError, "moved before CI dispatch"),
        ):
            merge.dispatch_workflow("owner/repo", "main", self.SHA, "ci.yml")
        self.assertEqual(dispatches, [])

        def no_run_id(*args: str) -> object:
            if "/git/ref/heads/" in " ".join(args):
                return {"object": {"sha": self.SHA}}
            return {}

        with (
            patch.object(merge, "gh_json", side_effect=no_run_id),
            self.assertRaisesRegex(RuntimeError, "did not return a run ID"),
        ):
            merge.dispatch_workflow("owner/repo", "main", self.SHA, "ci.yml")


if __name__ == "__main__":
    unittest.main()
