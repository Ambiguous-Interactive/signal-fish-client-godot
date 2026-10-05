#!/usr/bin/env python3
"""Merge a Dependabot PR only after its current head passes required checks."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time
from typing import cast


def record(value: object) -> dict[str, object]:
    return cast("dict[str, object]", value) if isinstance(value, dict) else {}


def records(value: object) -> list[dict[str, object]]:
    if not isinstance(value, list):
        return []
    return [record(item) for item in value if isinstance(item, dict)]


def required_records(value: object, name: str) -> list[dict[str, object]]:
    if not isinstance(value, list) or any(not isinstance(item, dict) for item in value):
        raise ValueError(f"{name} must be a list of objects")
    return records(value)


def field(value: object, key: str) -> object:
    return record(value).get(key)


def gh(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["gh", *args], capture_output=True, text=True, check=False)  # noqa: S603,S607


def gh_json(*args: str) -> object:
    result = gh(*args)
    if result.returncode != 0:
        raise RuntimeError(
            f"gh {' '.join(args[:2])} failed (exit {result.returncode}): {result.stderr.strip()}"
        )
    return cast("object", json.loads(result.stdout))


def dispatch_workflow(repo: str, target: str, merge_sha: str, workflow: str, **inputs: str) -> int:
    current = field(gh_json("api", f"/repos/{repo}/git/ref/heads/{target}"), "object")
    if field(current, "sha") != merge_sha:
        raise RuntimeError(f"{target} moved before CI dispatch for {merge_sha}")
    try:
        response = gh_json(
            "api",
            "--method",
            "POST",
            f"/repos/{repo}/actions/workflows/{workflow}/dispatches",
            "-F",
            "return_run_details=true",
            "-f",
            f"ref={target}",
            "-f",
            f"inputs[expected_sha]={merge_sha}",
            *(arg for key, value in inputs.items() for arg in ("-f", f"inputs[{key}]={value}")),
        )
    except RuntimeError as exc:
        raise RuntimeError(f"Failed to dispatch {workflow}: {exc}") from exc
    result = record(response)
    run_id = result.get("workflow_run_id")
    if not isinstance(run_id, int) or run_id < 1:
        raise RuntimeError(f"{workflow} dispatch did not return a run ID for {merge_sha}")
    print(f"Dispatched {workflow} for {merge_sha}: run {run_id}.")
    return run_id


def tip_is_descendant(repo: str, merge_sha: str, observed: str) -> bool:
    # Compare "ahead" means the observed tip is a strict descendant of the
    # merge SHA (issue #298): only then does a newer merge own the dispatches.
    comparison = record(gh_json("api", f"/repos/{repo}/compare/{merge_sha}...{observed}"))
    return comparison.get("status") == "ahead"


def dispatch_main_checks(repo: str, target: str, merge_sha: str) -> None:
    current = field(gh_json("api", f"/repos/{repo}/git/ref/heads/{target}"), "object")
    observed = field(current, "sha")
    if isinstance(observed, str) and observed != merge_sha:
        try:
            newer_tip = tip_is_descendant(repo, merge_sha, observed)
        except RuntimeError:
            # A failed compare defers to dispatch_workflow's own ref re-check:
            # it dispatches only while main still holds the merge SHA and
            # fails loudly otherwise (issue #298).
            newer_tip = False
        if newer_tip:
            print(
                f"{target} moved to {observed} before CI dispatch; "
                "the newer merge owns the dispatches for the tip."
            )
            return
    dispatch_workflow(repo, target, merge_sha, "ci.yml")
    dispatch_workflow(repo, target, merge_sha, "llm-harness.yml")
    docs_run_id = dispatch_workflow(repo, target, merge_sha, "docs-validation.yml")
    dispatch_workflow(repo, target, merge_sha, "docs-deploy.yml", validated_run_id=str(docs_run_id))


def needs_dev_container(pr: dict[str, object]) -> bool:
    if str(pr.get("headRefName", "")).startswith("dependabot/devcontainers/"):
        return True
    files = pr.get("files")
    return isinstance(files, list) and any(
        isinstance(item, dict)
        and (
            str(item.get("path", "")).startswith(".devcontainer/")
            or item.get("path") == ".github/workflows/devcontainer.yml"
        )
        for item in files
    )


def pr_is_current(number: str, sha: str) -> bool:
    current = record(gh_json("pr", "view", number, "--json", "headRefOid,state"))
    return current.get("state") == "OPEN" and current.get("headRefOid") == sha


MERGED_RECHECK_ATTEMPTS = 6
MERGED_RECHECK_SECONDS = 5.0


def merge_snapshot_complete(merged: dict[str, object]) -> bool:
    oid = field(merged.get("mergeCommit"), "oid")
    head = merged.get("headRefOid")
    return (
        merged.get("state") == "MERGED"
        and isinstance(head, str)
        and bool(head)
        and isinstance(oid, str)
        and bool(oid)
    )


def merged_state(number: str) -> dict[str, object] | None:
    # Back-to-back merges race this script against itself: the API can serve
    # a pre-merge snapshot for seconds after a merge lands (issue #307).
    for attempt in range(1, MERGED_RECHECK_ATTEMPTS + 1):
        result = gh("pr", "view", number, "--json", "state,headRefOid,mergeCommit")
        merged = record(json.loads(result.stdout)) if result.returncode == 0 else None
        if merged is not None and merge_snapshot_complete(merged):
            return merged
        if merged is None:
            reason = result.stderr.strip()
            detail = f"gh exit {result.returncode}" + (f": {reason}" if reason else "")
        else:
            detail = (
                f"state={merged.get('state', 'unreadable')},"
                f" head={merged.get('headRefOid') or 'missing'},"
                f" mergeCommit={field(merged.get('mergeCommit'), 'oid') or 'missing'}"
            )
        print(f"PR #{number} merge recheck {attempt}/{MERGED_RECHECK_ATTEMPTS}: {detail}")
        if attempt < MERGED_RECHECK_ATTEMPTS:
            time.sleep(MERGED_RECHECK_SECONDS)
    return None


def main() -> int:
    if shutil.which("gh") is None:
        print("::error::Required command 'gh' was not found on PATH.")
        return 1
    for name in ("GITHUB_REPOSITORY", "GH_TOKEN"):
        if not os.environ.get(name):
            print(f"::error::Required environment variable '{name}' is not set.")
            return 1

    repo = os.environ["GITHUB_REPOSITORY"]
    sha = os.environ.get("HEAD_SHA", "")
    target = os.environ.get("DEPENDABOT_TARGET_BRANCH", "main")
    login = os.environ.get("DEPENDABOT_LOGIN", "dependabot[bot]")
    workflows = os.environ.get("REQUIRED_WORKFLOWS", "Runtime CI|LLM Harness|Docs Validation")
    if not sha:
        print("Missing check head SHA; skipping.")
        return 0

    pulls = required_records(
        gh_json(
            "api", "-H", "Accept: application/vnd.github+json", f"/repos/{repo}/commits/{sha}/pulls"
        ),
        "commit pulls",
    )
    numbers = [
        pr.get("number")
        for pr in pulls
        if pr.get("state") == "open"
        and field(pr.get("user"), "login") == login
        and field(pr.get("base"), "ref") == target
        and field(field(pr.get("head"), "repo"), "full_name") == repo
        and field(pr.get("head"), "sha") == sha
    ]
    if not numbers:
        print(f"No open Dependabot PR found for {sha}; skipping.")
        return 0
    if len(numbers) != 1 or not isinstance(numbers[0], int):
        print(f"Expected exactly one Dependabot PR for {sha}, found {len(numbers)}: {numbers}")
        return 1
    number = str(numbers[0])

    pr = record(
        gh_json(
            "pr", "view", number, "--json", "baseRefName,files,headRefName,headRefOid,isDraft,state"
        )
    )
    if (
        pr.get("state") != "OPEN"
        or pr.get("baseRefName") != target
        or pr.get("isDraft") is not False
    ):
        print(f"PR #{number} is not an open, ready Dependabot PR targeting {target}; skipping.")
        return 0
    if pr.get("headRefOid") != sha:
        print(
            f"PR #{number} moved from {sha} to {pr.get('headRefOid')}; skipping stale workflow_run."
        )
        return 0

    deadline = time.monotonic() + 35 * 60
    required = [part.strip() for part in workflows.split("|") if part.strip()]
    if needs_dev_container(pr) and "Dev Container" not in required:
        required.append("Dev Container")
    while True:
        pages = required_records(
            gh_json(
                "api",
                "--paginate",
                "--slurp",
                f"/repos/{repo}/actions/runs?head_sha={sha}&event=pull_request&per_page=100",
            ),
            "workflow run pages",
        )
        runs = [
            run
            for page in pages
            for run in records(page.get("workflow_runs"))
            if run.get("head_sha") == sha
        ]
        pending = False
        for workflow in required:
            matching = [run for run in runs if run.get("name") == workflow]
            latest = max(matching, key=lambda run: str(run.get("run_started_at") or ""), default={})
            status = str(latest.get("status") or "missing")
            conclusion = str(latest.get("conclusion") or "")
            print(f"{workflow}: status={status} conclusion={conclusion or 'none'}")
            if status != "completed":
                pending = True
            elif conclusion != "success":
                print(f"{workflow} concluded {conclusion}; not merging.")
                return 0
        if not pending:
            break
        if time.monotonic() >= deadline:
            raise RuntimeError(f"PR #{number} workflow runs stayed pending for 35 minutes")
        print(f"PR #{number} workflow runs are pending; checking again.")
        time.sleep(10)
        if not pr_is_current(number, sha):
            print(f"PR #{number} moved or closed while waiting for workflow runs; skipping.")
            return 0

    while True:
        checks_result = gh("pr", "checks", number, "--json", "bucket,name,state,workflow")
        if checks_result.returncode not in (0, 8):
            print(f"Unable to read PR checks for #{number}; gh exited {checks_result.returncode}.")
            return checks_result.returncode
        checks = required_records(json.loads(checks_result.stdout), "PR checks")
        failing = [
            check for check in checks if check.get("bucket") not in ("pass", "skipping", "pending")
        ]
        if failing:
            print(f"PR #{number} has non-passing checks; not merging:")
            for check in failing:
                print(
                    f"{check.get('workflow', '')}\t{check.get('name', '')}\t{check.get('state', '')}"
                )
            return 0
        if checks_result.returncode == 0 and not any(
            check.get("bucket") == "pending" for check in checks
        ):
            break
        if time.monotonic() >= deadline:
            raise RuntimeError(f"PR #{number} checks stayed pending for 35 minutes")
        print(f"PR #{number} still has pending checks; checking again.")
        time.sleep(10)
        if not pr_is_current(number, sha):
            print(f"PR #{number} moved or closed while waiting for checks; skipping.")
            return 0

    result = gh("pr", "merge", number, "--squash", "--delete-branch", "--match-head-commit", sha)
    merged = merged_state(number)
    if result.returncode != 0:
        if merged is not None and merged.get("headRefOid") == sha:
            print(f"PR #{number} was already merged by a racing workflow_run; treating as success.")
            return 0
        print(f"gh pr merge failed for #{number} (exit {result.returncode}).")
        return result.returncode
    if merged is None:
        raise RuntimeError(f"PR #{number} merged but its merge snapshot never completed")
    merge_sha = field(merged.get("mergeCommit"), "oid")
    if not isinstance(merge_sha, str) or not merge_sha:
        raise RuntimeError(f"PR #{number} merged but its merge commit was not available")
    dispatch_main_checks(repo, target, merge_sha)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError) as exc:
        print(f"::error::{exc}", file=sys.stderr)
        sys.exit(1)
