"""Verify browser cleanup runs before the Playwright driver stops."""

import asyncio
import importlib.util
import io
import unittest
from collections.abc import Callable
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace, TracebackType
from unittest.mock import AsyncMock, patch

from playwright.async_api import Error as PlaywrightError

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/check-docs-accessibility.py"
SPEC = importlib.util.spec_from_file_location("docs_accessibility", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("could not load docs accessibility checker")
accessibility = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(accessibility)


class CleanupTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self) -> None:
        self.events: list[str] = []
        self.stdout = io.StringIO()
        self.page_events: dict[str, Callable[[object], None]] = {}
        self.browser_events: dict[str, Callable[[object], None]] = {}
        page = SimpleNamespace(
            set_default_timeout=lambda _value: None,
            set_default_navigation_timeout=lambda _value: None,
            on=lambda name, callback: self.page_events.__setitem__(name, callback),
            close=AsyncMock(),
        )
        self.page = page
        context = SimpleNamespace(new_page=AsyncMock(return_value=page))
        self.context = context
        self.browser = SimpleNamespace(
            new_context=AsyncMock(return_value=context),
            close=self.close_browser,
            on=lambda name, callback: self.browser_events.__setitem__(name, callback),
            is_connected=lambda: True,
        )
        self.launch = AsyncMock(return_value=self.browser)

        class PlaywrightContext:
            async def __aenter__(inner_self) -> SimpleNamespace:
                return SimpleNamespace(chromium=SimpleNamespace(launch=self.launch))

            async def __aexit__(
                inner_self,
                _type: type[BaseException] | None,
                _value: BaseException | None,
                _traceback: TracebackType | None,
            ) -> None:
                self.events.append("playwright.exit")

        replacements = {
            "assert_build_freshness": AsyncMock(),
            "start_server": lambda: (object(), object(), "http://127.0.0.1"),
            "close_server": lambda _server, _thread: self.events.append("server.close"),
            "async_playwright": PlaywrightContext,
            "attach_error_capture": lambda *_args: None,
            "check_closed_boundaries": AsyncMock(),
            "check_drawer_resize": AsyncMock(),
            "check_search_resize": AsyncMock(),
        }
        for name, replacement in replacements.items():
            patcher = patch.object(accessibility, name, replacement)
            patcher.start()
            self.addCleanup(patcher.stop)

    async def close_browser(self) -> None:
        self.events.append("browser.close")

    async def fail_browser_close(self) -> None:
        self.events.append("browser.close")
        raise RuntimeError("close failed")

    async def test_success_closes_browser_before_driver_and_server(self) -> None:
        with redirect_stdout(self.stdout):
            await accessibility.run_checks()
        self.assertEqual(self.events, ["browser.close", "playwright.exit", "server.close"])
        self.assertIn("checks passed", self.stdout.getvalue())

    async def test_check_failure_keeps_primary_error_and_cleans_up(self) -> None:
        with (
            patch.object(
                accessibility,
                "check_closed_boundaries",
                AsyncMock(side_effect=ValueError("check failed")),
            ),
            redirect_stdout(self.stdout),
            self.assertRaisesRegex(ValueError, "check failed"),
        ):
            await accessibility.run_checks()
        self.assertEqual(self.events, ["browser.close", "playwright.exit", "server.close"])
        self.assertEqual(self.stdout.getvalue(), "")

    async def test_crash_restarts_browser_and_retries_phase(self) -> None:
        replacement = SimpleNamespace(
            new_context=self.browser.new_context,
            close=AsyncMock(side_effect=lambda: self.events.append("replacement.close")),
            on=lambda *_args: None,
            is_connected=lambda: True,
        )
        with (
            patch.object(
                accessibility,
                "check_closed_boundaries",
                AsyncMock(side_effect=[PlaywrightError("Page.evaluate: Target crashed"), None]),
            ) as check,
            redirect_stdout(self.stdout),
        ):
            self.launch.side_effect = [self.browser, replacement]
            await accessibility.run_checks()
        self.assertEqual(check.await_count, 2)
        self.assertEqual(self.launch.await_count, 2)
        self.assertEqual(
            self.events,
            ["browser.close", "replacement.close", "playwright.exit", "server.close"],
        )

    async def test_repeated_crash_fails_after_one_restart(self) -> None:
        self.launch.side_effect = [self.browser, self.browser]
        with (
            patch.object(
                accessibility,
                "check_closed_boundaries",
                AsyncMock(side_effect=PlaywrightError("Target crashed")),
            ) as check,
            self.assertRaisesRegex(RuntimeError, 'phase "closed boundaries" crashed twice'),
        ):
            await accessibility.run_checks()
        self.assertEqual(check.await_count, 2)
        self.assertEqual(self.launch.await_count, 2)

    async def test_other_playwright_error_does_not_restart(self) -> None:
        with (
            patch.object(
                accessibility,
                "check_closed_boundaries",
                AsyncMock(side_effect=PlaywrightError("selector failed")),
            ),
            self.assertRaisesRegex(PlaywrightError, "selector failed"),
        ):
            await accessibility.run_checks()
        self.assertEqual(self.launch.await_count, 1)

    async def test_disconnected_browser_retries_closed_target_error(self) -> None:
        calls = 0

        async def check(*_args: object) -> None:
            nonlocal calls
            calls += 1
            if calls == 1:
                self.browser_events["disconnected"](self.browser)
                raise PlaywrightError("Target page, context or browser has been closed")

        with patch.object(accessibility, "check_closed_boundaries", check):
            await accessibility.run_checks()
        self.assertEqual(calls, 2)
        self.assertEqual(self.launch.await_count, 2)

    async def test_disconnected_browser_retries_timeout(self) -> None:
        calls = 0

        async def check(*_args: object) -> None:
            nonlocal calls
            calls += 1
            if calls == 1:
                self.browser_events["disconnected"](self.browser)
                raise TimeoutError("wait expired")

        with patch.object(accessibility, "check_closed_boundaries", check):
            await accessibility.run_checks()
        self.assertEqual(calls, 2)
        self.assertEqual(self.launch.await_count, 2)

    async def test_old_page_crash_does_not_retry_new_page_error(self) -> None:
        new_page = SimpleNamespace(
            set_default_timeout=lambda _value: None,
            set_default_navigation_timeout=lambda _value: None,
            on=lambda *_args: None,
        )
        self.context.new_page.side_effect = [self.page, new_page]
        calls = 0

        async def check(*_args: object) -> None:
            nonlocal calls
            calls += 1
            if calls == 1:
                self.old_crash = self.page_events["crash"]
                raise TimeoutError("timed out")
            self.old_crash(self.page)
            raise PlaywrightError("selector failed")

        with (
            patch.object(accessibility, "check_closed_boundaries", check),
            self.assertRaisesRegex(PlaywrightError, "selector failed"),
        ):
            await accessibility.run_checks()
        self.assertEqual(calls, 2)
        self.assertEqual(self.launch.await_count, 1)

    async def test_global_timeout_cleans_up_and_reports_timeout(self) -> None:
        never = asyncio.Event()
        with (
            patch.object(accessibility, "GLOBAL_TIMEOUT", 0.01),
            patch.object(accessibility, "check_closed_boundaries", lambda *_args: never.wait()),
            redirect_stdout(self.stdout),
            self.assertRaisesRegex(TimeoutError, "exceeded 0.01 seconds"),
        ):
            await accessibility.main()
        self.assertEqual(self.events, ["browser.close", "playwright.exit", "server.close"])
        self.assertEqual(self.stdout.getvalue(), "")

    async def test_timeout_survives_browser_cleanup_failure(self) -> None:
        never = asyncio.Event()
        self.browser.close = self.fail_browser_close
        with (
            patch.object(accessibility, "GLOBAL_TIMEOUT", 0.01),
            patch.object(accessibility, "check_closed_boundaries", lambda *_args: never.wait()),
            redirect_stdout(self.stdout),
            self.assertRaisesRegex(TimeoutError, "exceeded 0.01 seconds"),
        ):
            await accessibility.main()
        self.assertEqual(self.events, ["browser.close", "playwright.exit", "server.close"])
        self.assertEqual(self.stdout.getvalue(), "")

    async def test_cleanup_failure_prevents_success_message(self) -> None:
        self.browser.close = self.fail_browser_close
        with redirect_stdout(self.stdout), self.assertRaisesRegex(RuntimeError, "close failed"):
            await accessibility.run_checks()
        self.assertEqual(self.events, ["browser.close", "playwright.exit", "server.close"])
        self.assertEqual(self.stdout.getvalue(), "")


if __name__ == "__main__":
    unittest.main()
