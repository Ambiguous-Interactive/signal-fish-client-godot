#!/usr/bin/env python3
"""Wait for the exact main Docs Validation run selected by Docs Deploy."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import time
from typing import cast


def run_state(value: object, repo: str, sha: str) -> tuple[str, str]:
    if not isinstance(value, dict):
        raise ValueError("Docs Validation run response is not an object")
    run = cast("dict[str, object]", value)
    repository = run.get("repository")
    name = repository.get("full_name") if isinstance(repository, dict) else None
    if (
        name != repo
        or run.get("path") != ".github/workflows/docs-validation.yml"
        or run.get("event") != "workflow_dispatch"
        or run.get("head_branch") != "main"
        or run.get("head_sha") != sha
    ):
        raise ValueError("The selected run is not main Docs Validation for this commit")
    return str(run.get("status", "")), str(run.get("conclusion", ""))


def wait_for_run(repo: str, run_id: str, sha: str) -> None:
    gh = shutil.which("gh")
    if gh is None:
        raise OSError("gh is required")
    for attempt in range(150):
        result = subprocess.run(  # noqa: S603
            [gh, "api", f"/repos/{repo}/actions/runs/{run_id}"],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode == 0:
            status, conclusion = run_state(json.loads(result.stdout), repo, sha)
            if status == "completed":
                if conclusion != "success":
                    raise ValueError("Docs Validation did not succeed")
                return
        if attempt < 149:
            time.sleep(10)
    raise TimeoutError("Timed out waiting for Docs Validation")


def main() -> int:
    run_id = os.environ.get("VALIDATED_RUN_ID", "")
    expected_sha = os.environ.get("EXPECTED_SHA", "")
    if not run_id.isascii() or not run_id.isdecimal() or int(run_id or 0) < 1:
        raise ValueError("Invalid validated run ID or commit SHA")
    if not expected_sha or os.environ.get("GITHUB_SHA") != expected_sha:
        raise ValueError("Invalid validated run ID or commit SHA")
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    if not repo:
        raise ValueError("GITHUB_REPOSITORY is missing")
    wait_for_run(repo, run_id, expected_sha)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, TimeoutError, json.JSONDecodeError) as exc:
        print(f"::error::{exc}", file=sys.stderr)
        sys.exit(1)
