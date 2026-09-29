"""Verify the web smoke check retries only browser crashes."""

import importlib.util
import io
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

from playwright.sync_api import Error as PlaywrightError

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/check-web-export-browser.py"
SPEC = importlib.util.spec_from_file_location("web_export_browser", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("could not load web export browser checker")
browser_check = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(browser_check)


class BrowserRetryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.stdout = io.StringIO()
        self.stderr = io.StringIO()
        self.paths = (Path("web"), Path("key"), Path("cert"))

    def test_one_crash_retries_both_scenarios(self) -> None:
        with (
            patch.object(
                browser_check,
                "run_attempt",
                side_effect=[browser_check.BrowserCrash("Target crashed"), None],
            ) as attempt,
            redirect_stdout(self.stdout),
            redirect_stderr(self.stderr),
        ):
            browser_check.run_check(*self.paths)
        self.assertEqual(attempt.call_count, 2)
        self.assertIn("attempt 1/2", self.stderr.getvalue())
        self.assertIn("check passed", self.stdout.getvalue())

    def test_second_crash_fails(self) -> None:
        with (
            patch.object(
                browser_check,
                "run_attempt",
                side_effect=browser_check.BrowserCrash("Target crashed"),
            ) as attempt,
            redirect_stderr(self.stderr),
            self.assertRaisesRegex(RuntimeError, "Chromium crashed twice"),
        ):
            browser_check.run_check(*self.paths)
        self.assertEqual(attempt.call_count, 2)

    def test_assertion_does_not_retry(self) -> None:
        with (
            patch.object(
                browser_check,
                "run_attempt",
                side_effect=AssertionError("smoke failed"),
            ) as attempt,
            self.assertRaisesRegex(AssertionError, "smoke failed"),
        ):
            browser_check.run_check(*self.paths)
        self.assertEqual(attempt.call_count, 1)

    def test_disconnected_browser_is_classified_and_cleaned_up(self) -> None:
        for failure in (
            PlaywrightError("Target page, context or browser has been closed"),
            TimeoutError("server wait expired"),
        ):
            with self.subTest(failure=type(failure).__name__):
                self.assert_disconnected_failure(failure)

    def assert_disconnected_failure(self, failure: Exception) -> None:
        events: list[str] = []
        callbacks = {}
        browser = SimpleNamespace(
            on=lambda name, callback: callbacks.__setitem__(name, callback),
            is_connected=lambda: False,
            close=lambda: events.append("browser.close"),
        )
        page = MagicMock()

        def fail_navigation(*_args: object, **_kwargs: object) -> None:
            callbacks["disconnected"](browser)
            raise failure

        page.goto.side_effect = fail_navigation
        browser.new_context = lambda **_kwargs: SimpleNamespace(
            add_init_script=lambda *_args: None, new_page=lambda: page
        )
        server = MagicMock()
        server.stop.side_effect = lambda: events.append("server.stop")

        class FakePlaywright:
            def __enter__(self) -> SimpleNamespace:
                return SimpleNamespace(chromium=SimpleNamespace(launch=lambda **_kwargs: browser))

            def __exit__(self, *_args: object) -> None:
                events.append("playwright.exit")

        with (
            patch.object(browser_check, "SmokeServer", return_value=server),
            patch.object(browser_check, "sync_playwright", FakePlaywright),
            self.assertRaisesRegex(browser_check.BrowserCrash, "HTTPS and WSS"),
        ):
            browser_check.run_attempt(*self.paths)
        self.assertEqual(events, ["server.stop", "browser.close", "playwright.exit"])


if __name__ == "__main__":
    unittest.main()
