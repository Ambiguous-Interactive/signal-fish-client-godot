"""Check the link-check policy against lychee report shapes pinned to v0.24.2."""

from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from typing import cast

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "check-link-report.py"
SPEC = importlib.util.spec_from_file_location("check_link_report", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Could not load {SCRIPT}")
policy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(policy)

# Per-file failure shapes measured from `lychee --format json` (v0.24.2).
# Typed as JSON-ish mappings, not Python value types.
HTTP_FAILURE: dict[str, object] = {
    "url": "https://github.com/example/repo/blob/main/README.md",
    "status": {"text": "Rejected status code: 404 Not Found", "code": 404},
    "span": {"line": 3},
}
GITHUB_5XX: dict[str, object] = {
    **HTTP_FAILURE,
    "url": "https://github.com/example/repo/releases",
    "status": {"text": "Rejected status code: 503 Service Unavailable", "code": 503},
}
EXTERNAL_5XX: dict[str, object] = {
    **HTTP_FAILURE,
    "url": "https://docs.example.com/guide",
    "status": {"text": "Rejected status code: 503 Service Unavailable", "code": 503},
}
TIMEOUT: dict[str, object] = {
    "url": "https://github.com/example/repo/blob/main/CHANGELOG.md",
    "status": {"text": "Timeout", "details": "Request timed out"},
    "span": {"line": 7},
}
NETWORK_ERROR: dict[str, object] = {
    "url": "http://github.com/example/repo/wiki",
    "status": {
        "text": (
            "Network error: Connection refused - server may be down or port "
            "blocked (error sending request for url (http://github.com/example/repo/wiki))"
        ),
        "details": "Connection refused - server may be down or port blocked",
    },
    "span": {"line": 2},
}


def report(
    *routed: tuple[str, dict[str, object]],
    total: int = 3,
    errors: int | None = None,
    timeouts: int = 0,
) -> dict[str, object]:
    out: dict[str, object] = {
        "total": total,
        "errors": len(routed) if errors is None else errors,
        "timeouts": timeouts,
    }
    for map_name, failure in routed:
        file_map = cast("dict[str, object]", out.setdefault(map_name, {}))
        failures_for_file = cast("list[object]", file_map.setdefault("doc.md", []))
        failures_for_file.append(failure)
    return out


class LinkReportPolicyTests(unittest.TestCase):
    def test_clean_report_passes(self) -> None:
        tolerated, hard = policy.evaluate(report(total=12, errors=0))
        self.assertEqual((tolerated, hard), ([], []))

    def test_only_github_5xx_is_indeterminate(self) -> None:
        tolerated, hard = policy.evaluate(report(("error_map", GITHUB_5XX)))
        self.assertEqual(len(tolerated), 1)
        self.assertEqual(hard, [])

    def test_hard_failures(self) -> None:
        # github.com 4xx, other-host 5xx, timeouts, network errors: the URL
        # result is known, so the gate stays strict (issue #352). Each
        # failure is routed to the map lychee v0.24.2 actually uses: only
        # timeouts go to timeout_map; network errors land in error_map
        # with no status code.
        for map_name, fixture in (
            ("error_map", HTTP_FAILURE),
            ("error_map", EXTERNAL_5XX),
            ("timeout_map", TIMEOUT),
            ("error_map", NETWORK_ERROR),
        ):
            with self.subTest(url=fixture["url"]):
                tolerated, hard = policy.evaluate(report((map_name, fixture)))
                self.assertEqual(tolerated, [])
                self.assertEqual(len(hard), 1)

    def test_lookalike_hosts_stay_strict(self) -> None:
        for url in (
            "https://github.com.evil.com/x",
            "https://evil.com/?u=github.com/x",
            "ftp://github.com/x",
            "https://raw.githubusercontent.com/x",
        ):
            with self.subTest(url=url):
                failure = {**HTTP_FAILURE, "url": url, "status": {"text": "503", "code": 503}}
                tolerated, _ = policy.evaluate(report(("error_map", failure)))
                self.assertEqual(tolerated, [])

    def test_uppercase_github_host_is_tolerated(self) -> None:
        tolerated, _ = policy.evaluate(
            report(("error_map", {**GITHUB_5XX, "url": "https://GitHub.com/example/repo/releases"}))
        )
        self.assertEqual(len(tolerated), 1)

    def test_timeout_only_report_is_hard(self) -> None:
        tolerated, hard = policy.evaluate(report(("timeout_map", TIMEOUT)))
        self.assertEqual((tolerated, len(hard)), ([], 1))

    def test_zero_checked_links_fails(self) -> None:
        # The action's failIfEmpty grep only matches its markdown output, so
        # JSON mode relies on this rejection.
        with self.assertRaisesRegex(ValueError, "checked 0 links"):
            policy.evaluate(report(total=0))

    def test_summary_total_drift_fails(self) -> None:
        # A lychee output-schema change must fail loudly, never drop a
        # failure class silently.
        with self.assertRaisesRegex(ValueError, "schema changed"):
            policy.evaluate(report(("error_map", GITHUB_5XX), errors=2))
        with self.assertRaisesRegex(ValueError, "schema changed"):
            policy.evaluate(report(("error_map", GITHUB_5XX), errors=0))

    def test_non_integer_totals_fail(self) -> None:
        with self.assertRaisesRegex(ValueError, "not an integer"):
            policy.evaluate(report(("error_map", GITHUB_5XX), errors="2"))  # type: ignore[arg-type]

    def test_malformed_report_fails(self) -> None:
        malformed: dict[str, object] = {
            "total": 3,
            "errors": 0,
            "timeouts": 0,
            "error_map": ["unexpected"],
        }
        with self.assertRaisesRegex(ValueError, "not a mapping"):
            policy.evaluate(malformed)
        with self.assertRaisesRegex(ValueError, "not a list"):
            policy.evaluate(
                {"total": 3, "errors": 1, "timeouts": 0, "error_map": {"doc.md": "boom"}}
            )
        with self.assertRaisesRegex(ValueError, "non-integer status code"):
            policy.evaluate(report(("error_map", {**HTTP_FAILURE, "status": {"code": "404"}})))


class MainExitTests(unittest.TestCase):
    def write_report(self, tmp: Path, payload: str) -> str:
        path = tmp / "report.json"
        path.write_text(payload, encoding="utf-8")
        return str(path)

    def test_exit_codes(self) -> None:
        with tempfile.TemporaryDirectory() as name:
            tmp = Path(name)
            self.assertEqual(
                policy.main(["check-link-report.py", self.write_report(tmp, "{not json")]), 1
            )
            self.assertEqual(
                policy.main(["check-link-report.py", self.write_report(tmp, "[1, 2]")]), 1
            )
            self.assertEqual(policy.main(["check-link-report.py", str(tmp / "missing.json")]), 1)
            self.assertEqual(
                policy.main(
                    [
                        "check-link-report.py",
                        self.write_report(tmp, json.dumps(report(("error_map", HTTP_FAILURE)))),
                    ]
                ),
                1,
            )
            self.assertEqual(
                policy.main(
                    [
                        "check-link-report.py",
                        self.write_report(tmp, json.dumps(report(("error_map", GITHUB_5XX)))),
                    ]
                ),
                0,
            )
            self.assertEqual(policy.main(["check-link-report.py"]), 2)


if __name__ == "__main__":
    unittest.main()
