#!/usr/bin/env python3
"""Apply the opt-in native WebSocket receive backport to Godot 4.3 source."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
from pathlib import Path

BASE = "77dcf97d82cbfe4e4615475fa52ca03da645dbd8"
UPSTREAM = [
    "3114bda4e1ee88f04f55451697f24c9ee79be54f",
    "d798068a0816a66b80b8096aa77212468c0155c4",
    "81181c594170057612eb1bf3224858a474f19722",
    "a2f5eb9cf095a8d942d9518a2ef5848cd47ce8f1",
]
PATCH = Path(__file__).resolve().parent / "patches/godot-43-websocket-receive.patch"


def git(source: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
    executable = shutil.which("git")
    if executable is None:
        raise ValueError("git is required")
    return subprocess.run(  # noqa: S603
        [executable, "-C", str(source), *arguments], capture_output=True, text=True, check=False
    )


def apply(source: Path, check_only: bool) -> dict[str, object]:
    revision = git(source, "rev-parse", "HEAD")
    if revision.returncode or revision.stdout.strip() != BASE:
        raise ValueError(f"source HEAD must be Godot 4.3-stable {BASE}")
    paths = [
        line.split(" b/", 1)[1]
        for line in PATCH.read_text().splitlines()
        if line.startswith("diff --git ")
    ]
    if git(source, "diff", "--cached", "--exit-code", "--", *paths).returncode:
        raise ValueError("backport paths contain staged changes")
    forward = git(source, "apply", "--check", str(PATCH))
    reverse = git(source, "apply", "--reverse", "--check", str(PATCH))
    if reverse.returncode == 0:
        actual = git(
            source,
            "-c",
            "diff.context=3",
            "diff",
            "--no-ext-diff",
            "--no-textconv",
            "--no-color",
            "--full-index",
            "--src-prefix=a/",
            "--dst-prefix=b/",
            "--diff-algorithm=myers",
            "--no-indent-heuristic",
            "--unified=3",
            "--",
            *paths,
        )
        if actual.returncode or actual.stdout != PATCH.read_text():
            raise ValueError("backport paths contain additional local changes")
        status = "already_applied"
    elif forward.returncode == 0:
        if git(source, "diff", "--exit-code", "--", *paths).returncode:
            raise ValueError("backport paths contain local changes")
        status = "applicable" if check_only else "applied"
        if not check_only:
            applied = git(source, "apply", str(PATCH))
            if applied.returncode:
                raise ValueError(applied.stderr.strip())
    else:
        raise ValueError("backport paths differ from the pinned source or complete backport")
    return {
        "status": status,
        "source": str(source),
        "base": BASE,
        "upstream_commits": UPSTREAM,
        "local_repairs": [
            {
                "issue": 491,
                "change": "Exclude interleaved control-frame bytes from message assembly",
                "cause": "wslay emits chunk callbacks for data and control frames",
            },
            {
                "issue": 492,
                "change": "Clear partial message assembly when replacing a connection",
                "cause": "A CLOSING peer can be reused before old assembly completes",
            },
        ],
        "patch_sha256": hashlib.sha256(PATCH.read_bytes()).hexdigest(),
        "source_sha256": {
            path: hashlib.sha256((source / path).read_bytes()).hexdigest() for path in paths
        },
        "scope": "experimental native receive repair; build and runtime qualification required",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--check", action="store_true", help="Check without modifying source")
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    if args.report.exists():
        parser.error("report already exists; retain each attempt in a new file")
    try:
        report = apply(args.source.resolve(), args.check)
    except ValueError as error:
        report = {"status": "failed", "error": str(error)}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))
    return 1 if report["status"] == "failed" else 0


if __name__ == "__main__":
    raise SystemExit(main())
