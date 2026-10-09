#!/usr/bin/env python3
"""Apply the docs link-check policy to a lychee JSON report.

Why (issue #352): a minutes-long GitHub-wide 5xx episode failed the required
link-check job on a PR whose diff touched no links. lychee config cannot
scope accepted status codes per URL, so CI runs lychee with ``fail: false``
and this script decides. A 5xx from github.com is treated as indeterminate
and only warned: the host is up, the status says nothing about the URL
(truly dead paths return 4xx), and the next run re-checks it. Every other
failure - 4xx, timeouts, network errors, other hosts - fails the job.

The script also keeps guarantees that lychee's JSON mode loses: a report
with zero checked links fails (the action's failIfEmpty grep only matches
its markdown output), and the per-file error entries must reconcile with
the summary totals, so a lychee output-schema change cannot silently drop
a failure class. Extend the tolerated hosts only with measured data.
"""

import json
import os
import sys
from typing import cast
from urllib.parse import urlsplit

TOLERATED_HOSTS = frozenset({"github.com", "www.github.com"})

# (file, line, url, status code or None, status text). A None code means a
# non-HTTP failure (timeout, network error, ...); those always fail.
Failure = tuple[str, int, str, int | None, str]

LYCHEE_MAPS = ("error_map", "timeout_map")


def record(value: object) -> dict[str, object]:
    return cast("dict[str, object]", value) if isinstance(value, dict) else {}


def line_number(span: object) -> int:
    value = record(span).get("line", 0)
    return value if isinstance(value, int) and not isinstance(value, bool) else 0


def failure_entries(report: dict[str, object]) -> list[Failure]:
    entries: list[Failure] = []
    for source in LYCHEE_MAPS:
        failures = report.get(source)
        if failures is None:
            continue
        if not isinstance(failures, dict):
            raise ValueError(f"lychee report {source!r} is not a mapping")
        for file, items in failures.items():
            if items is None:
                continue
            if not isinstance(items, list):
                raise ValueError(f"lychee report {source!r}[{file!r}] is not a list")
            for item in items:
                status = record(record(item).get("status"))
                code = status.get("code")
                if code is not None and not isinstance(code, int):
                    raise ValueError(f"non-integer status code for {item!r}")
                entries.append(
                    (
                        str(file),
                        line_number(record(item).get("span")),
                        str(record(item).get("url", "")),
                        code,
                        str(status.get("text", "")),
                    )
                )
    return entries


def is_indeterminate(url: str, code: int | None) -> bool:
    if code is None or not 500 <= code <= 599:
        return False
    parts = urlsplit(url)
    return parts.scheme in ("http", "https") and (parts.hostname or "") in TOLERATED_HOSTS


def evaluate(report: dict[str, object]) -> tuple[list[Failure], list[Failure]]:
    """Split failures into (tolerated, hard); raise ValueError on drift."""
    total = report.get("total", 0)
    if not isinstance(total, int) or isinstance(total, bool) or total < 1:
        raise ValueError("report checked 0 links; the glob or report is broken")
    counted = 0
    for key in ("errors", "timeouts"):
        value = report.get(key, 0)
        if not isinstance(value, int) or isinstance(value, bool):
            raise ValueError(f"report summary total {key!r} is not an integer")
        counted += value
    entries = failure_entries(report)
    if counted != len(entries):
        raise ValueError(
            f"report lists {len(entries)} failures but counts {counted}; "
            "the lychee output schema changed"
        )
    tolerated: list[Failure] = []
    hard: list[Failure] = []
    for entry in entries:
        (tolerated if is_indeterminate(entry[2], entry[3]) else hard).append(entry)
    return tolerated, hard


def load_report(path: str) -> dict[str, object]:
    with open(path, "rb") as handle:
        parsed = json.loads(handle.read().decode("utf-8"))
    if not isinstance(parsed, dict):
        raise ValueError("report is not a JSON object")
    return cast("dict[str, object]", parsed)


def summary_lines(tolerated: list[Failure], hard: list[Failure]) -> list[str]:
    lines: list[str] = []
    if tolerated:
        lines += [
            "GitHub returned 5xx for these URLs, so they were not verified.",
            "Nothing to fix; the next run re-checks them.",
            "",
        ]
        lines.extend(f"- `{file}:{line}` {url}" for file, line, url, _, _ in tolerated)
    if hard:
        if lines:
            lines.append("")
        lines.append("Broken links:")
        lines.extend(f"- `{file}:{line}` {url} - {text}" for file, line, url, _, text in hard)
    return lines


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {os.path.basename(argv[0])} <lychee-report.json>", file=sys.stderr)
        return 2
    try:
        report = load_report(argv[1])
    except (OSError, ValueError) as error:
        print(f"link-report: unusable report {argv[1]}: {error}", file=sys.stderr)
        return 1
    try:
        tolerated, hard = evaluate(report)
    except ValueError as error:
        print(f"link-report: {error}", file=sys.stderr)
        return 1
    for file, line, url, _, text in hard:
        print(f"{file}:{line}: {url} - {text}", file=sys.stderr)
    if tolerated:
        print(
            f"link-report: {len(tolerated)} indeterminate (github.com 5xx), "
            "re-checked on the next run"
        )
    summary = summary_lines(tolerated, hard)
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary and summary_path:
        try:
            with open(summary_path, "a", encoding="utf-8") as handle:
                handle.write("\n".join(summary) + "\n")
        except OSError as error:
            print(f"link-report: could not write job summary: {error}", file=sys.stderr)
    if hard:
        print(f"link-report: {len(hard)} broken link(s)", file=sys.stderr)
        return 1
    if not tolerated:
        print("link-report: all checked links resolved")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
