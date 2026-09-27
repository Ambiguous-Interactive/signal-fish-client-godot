#!/usr/bin/env python3
"""Merge a Dependabot PR only after its current head passes required checks."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
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
    branch = os.environ.get("HEAD_BRANCH", "")
    target = os.environ.get("DEPENDABOT_TARGET_BRANCH", "main")
    login = os.environ.get("DEPENDABOT_LOGIN", "dependabot[bot]")
    workflows = os.environ.get("REQUIRED_WORKFLOWS", "Runtime CI|LLM Harness")
    if not sha or not branch:
        print("Missing workflow_run head metadata; skipping.")
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

    pr = record(gh_json("pr", "view", number, "--json", "baseRefName,headRefOid,isDraft,state"))
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
    for workflow in (part.strip() for part in workflows.split("|")):
        if not workflow:
            continue
        matching = [run for run in runs if run.get("name") == workflow]
        latest = max(matching, key=lambda run: str(run.get("run_started_at") or ""), default={})
        status = str(latest.get("status") or "missing")
        conclusion = str(latest.get("conclusion") or "")
        print(f"{workflow}: status={status} conclusion={conclusion or 'none'}")
        if status != "completed":
            print(f"{workflow} is {status}; waiting for another workflow_run event.")
            return 0
        if conclusion != "success":
            print(f"{workflow} concluded {conclusion}; not merging.")
            return 0

    checks_result = gh("pr", "checks", number, "--json", "bucket,name,state,workflow")
    if checks_result.returncode == 8:
        print(f"PR #{number} still has pending checks; waiting for another workflow_run event.")
        return 0
    if checks_result.returncode != 0:
        print(f"Unable to read PR checks for #{number}; gh exited {checks_result.returncode}.")
        return checks_result.returncode
    checks = required_records(json.loads(checks_result.stdout), "PR checks")
    failing = [check for check in checks if check.get("bucket") not in ("pass", "skipping")]
    if failing:
        print(f"PR #{number} has non-passing checks; not merging:")
        for check in failing:
            print(f"{check.get('workflow', '')}\t{check.get('name', '')}\t{check.get('state', '')}")
        return 0

    result = gh("pr", "merge", number, "--squash", "--delete-branch", "--match-head-commit", sha)
    if result.returncode == 0:
        return 0
    recheck = gh("pr", "view", number, "--json", "state,headRefOid")
    state: object = "UNKNOWN"
    if recheck.returncode == 0:
        merged = record(json.loads(recheck.stdout))
        state = merged.get("state", "UNKNOWN")
        if state == "MERGED" and merged.get("headRefOid") == sha:
            print(f"PR #{number} was already merged by a racing workflow_run; treating as success.")
            return 0
    print(f"gh pr merge failed for #{number} (exit {result.returncode}, state {state}).")
    return result.returncode


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError) as exc:
        print(f"::error::{exc}", file=sys.stderr)
        sys.exit(1)
