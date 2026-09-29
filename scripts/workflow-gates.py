#!/usr/bin/env python3
"""Verify dispatched commits and required workflow job results."""

import argparse
import json
import os
import sys
from collections.abc import Mapping, Sequence


def verify_sha(environment: Mapping[str, str]) -> None:
    actual = environment.get("GITHUB_SHA")
    expected = environment.get("EXPECTED_SHA")
    if not actual or not expected:
        raise ValueError("GITHUB_SHA and EXPECTED_SHA are required")
    if actual != expected:
        raise ValueError("dispatched commit does not match EXPECTED_SHA")


def require_jobs(text: str, required: Sequence[str], allow_skipped: Sequence[str]) -> None:
    needs: object = json.loads(text)
    if not isinstance(needs, dict) or not needs:
        raise ValueError("NEEDS_JSON must contain job results")
    missing = set(required) - needs.keys()
    if missing:
        raise ValueError(f"missing required jobs: {', '.join(sorted(missing))}")
    failures = []
    for name, job in needs.items():
        result = job.get("result") if isinstance(job, dict) else None
        if result == "success" or (name in allow_skipped and result == "skipped"):
            continue
        failures.append(f"{name}={result!r}")
    if failures:
        raise ValueError(f"required jobs did not succeed: {', '.join(failures)}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("verify-sha")
    jobs = commands.add_parser("require-jobs")
    jobs.add_argument("jobs", nargs="+")
    jobs.add_argument("--allow-skipped", action="append", default=[])
    arguments = parser.parse_args()
    try:
        if arguments.command == "verify-sha":
            verify_sha(os.environ)
        else:
            require_jobs(os.environ.get("NEEDS_JSON", ""), arguments.jobs, arguments.allow_skipped)
    except ValueError as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
