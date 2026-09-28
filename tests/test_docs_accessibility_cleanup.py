"""Verify browser cleanup runs before the Playwright driver stops."""

import asyncio
import importlib.util
import io
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

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
        page = SimpleNamespace(
            set_default_timeout=lambda _value: None,
            set_default_navigation_timeout=lambda _value: None,
        )
        context = SimpleNamespace(new_page=AsyncMock(return_value=page))
        self.browser = SimpleNamespace(
            new_context=AsyncMock(return_value=context), close=self.close_browser
        )

        class PlaywrightContext:
            async def __aenter__(inner_self):
                return SimpleNamespace(
                    chromium=SimpleNamespace(launch=AsyncMock(return_value=self.browser))
                )

            async def __aexit__(inner_self, _type, _value, _traceback):
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
