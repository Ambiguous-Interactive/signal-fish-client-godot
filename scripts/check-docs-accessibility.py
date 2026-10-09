#!/usr/bin/env python3
"""Check rendered documentation focus behavior in Chromium."""

import asyncio
import json
import mimetypes
import os
import sys
import threading
import time
import traceback
from collections.abc import Awaitable, Callable
from contextlib import suppress
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import TypedDict, cast
from urllib.parse import unquote, urlsplit

from playwright.async_api import Browser, BrowserContext, Page, async_playwright
from playwright.async_api import Error as PlaywrightError

ROOT = Path(__file__).resolve().parents[1]
HOST = "127.0.0.1"
GLOBAL_TIMEOUT = 600
PHASE_TIMEOUT = 150


def expect_state(condition: bool, message: str, evidence: object) -> None:
    if not condition:
        raise AssertionError(f"{message}: {json.dumps(evidence)}")


async def assert_build_freshness() -> None:
    for relative in ("javascripts/accessibility.js", "stylesheets/extra.css"):
        source = (ROOT / "docs" / relative).read_bytes()
        built = (ROOT / "site" / relative).read_bytes()
        expect_state(
            source == built,
            f"site/{relative} is stale; run mkdocs build --strict first",
            {"relative": relative},
        )


class SiteHandler(BaseHTTPRequestHandler):
    site_root: Path

    def do_GET(self) -> None:
        try:
            path = (self.site_root / ("." + unquote(urlsplit(self.path).path))).resolve()
            if not path.is_relative_to(self.site_root):
                self.send_error(403)
                return
            if path.is_dir():
                path = (path / "index.html").resolve()
            if not path.is_relative_to(self.site_root):
                self.send_error(403)
                return
            data = path.read_bytes()
        except (FileNotFoundError, IsADirectoryError):
            self.send_error(404)
            return
        except (OSError, ValueError):
            self.send_error(500)
            return
        content_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
        if content_type.startswith(("text/", "application/javascript")):
            content_type += "; charset=utf-8"
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, format: str, *args: object) -> None:
        pass


def start_server() -> tuple[ThreadingHTTPServer, threading.Thread, str]:
    site_root = (ROOT / "site").resolve(strict=True)
    handler = type("DocsHandler", (SiteHandler,), {"site_root": site_root})
    server = ThreadingHTTPServer((HOST, int(os.environ.get("DOCS_A11Y_PORT", "0"))), handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, thread, f"http://{HOST}:{server.server_port}"


def close_server(server: ThreadingHTTPServer, thread: threading.Thread) -> None:
    server.shutdown()
    server.server_close()
    thread.join(timeout=5)


DRAWER_FOCUS_SCRIPT = """() => {
    const sidebar = document.querySelector('.md-sidebar--primary');
    const scrollwrap = sidebar.querySelector('.md-sidebar__scrollwrap');
    const toc = sidebar.querySelector('.md-nav--secondary');
    const focused = document.activeElement;
    const sidebarBounds = sidebar.getBoundingClientRect();
    const focusBounds = focused.getBoundingClientRect();
    const tocBounds = toc.getBoundingClientRect();
    return {
        drawerChecked: document.querySelector('#__drawer').checked,
        tocChecked: document.querySelector('#__toc').checked,
        modal: sidebar.getAttribute('aria-modal'),
        inert: sidebar.inert,
        scrollLeft: scrollwrap.scrollLeft,
        maxScroll: scrollwrap.scrollWidth - scrollwrap.clientWidth,
        tocVisible: tocBounds.width > 0 && tocBounds.height > 0,
        focusLabel: focused.getAttribute('aria-label'),
        focusInside: sidebar.contains(focused),
        focusVisible: focusBounds.width > 0 && focusBounds.height > 0,
        focusContained: focusBounds.left >= sidebarBounds.left - 0.5 &&
            focusBounds.right <= sidebarBounds.right + 0.5,
        focusInert: Boolean(focused.closest('[inert]')),
        sidebarBounds: [sidebarBounds.left, sidebarBounds.right],
        focusBounds: [focusBounds.left, focusBounds.right],
        tocBounds: [tocBounds.left, tocBounds.right]
    };
}"""

SEARCH_FOCUS_SCRIPT = """() => {
    const search = document.querySelector('.md-search');
    const focused = document.activeElement;
    const bounds = focused.getBoundingClientRect();
    return {
        checked: document.querySelector('#__search').checked,
        modal: search.getAttribute('aria-modal'),
        inert: search.inert,
        focusInside: search.contains(focused),
        focusVisible: bounds.width > 0 && bounds.height > 0,
        focusInViewport: bounds.left >= -0.5 &&
            bounds.right <= window.innerWidth + 0.5 &&
            bounds.top >= -0.5 && bounds.bottom <= window.innerHeight + 0.5,
        focusInert: Boolean(focused.closest('[inert]')),
        focusLabel: focused.getAttribute('aria-label'),
        focusBounds: [bounds.left, bounds.top, bounds.right, bounds.bottom]
    };
}"""

BOUNDARIES_SCRIPT = """() => {
    const sidebar = document.querySelector('.md-sidebar--primary');
    const search = document.querySelector('.md-search');
    const opener = document.querySelector('label.md-header__button[for="__drawer"]');
    const sidebarBounds = sidebar.getBoundingClientRect();
    const openerBounds = opener.getBoundingClientRect();
    return {
        drawerInert: sidebar.inert,
        drawerHidden: sidebar.getAttribute('aria-hidden'),
        drawerBounds: [sidebarBounds.left, sidebarBounds.right, sidebarBounds.width],
        openerVisible: openerBounds.width > 0 && openerBounds.height > 0,
        searchInert: search.inert,
        searchHidden: search.getAttribute('aria-hidden'),
        overflow: document.documentElement.scrollWidth - document.documentElement.clientWidth
    };
}"""


class DrawerState(TypedDict):
    drawerChecked: bool
    tocChecked: bool
    modal: str | None
    inert: bool
    scrollLeft: float
    maxScroll: float
    tocVisible: bool
    focusLabel: str | None
    focusInside: bool
    focusVisible: bool
    focusContained: bool
    focusInert: bool
    sidebarBounds: list[float]
    focusBounds: list[float]
    tocBounds: list[float]


class SearchState(TypedDict):
    checked: bool
    modal: str | None
    inert: bool
    focusInside: bool
    focusVisible: bool
    focusInViewport: bool
    focusInert: bool
    focusLabel: str | None
    focusBounds: list[float]


class BoundaryState(TypedDict):
    drawerInert: bool
    drawerHidden: str | None
    drawerBounds: list[float]
    openerVisible: bool
    searchInert: bool
    searchHidden: str | None
    overflow: float


async def settle_shell(page: Page) -> None:
    await page.wait_for_timeout(75)


async def drawer_focus_state(page: Page) -> DrawerState:
    return cast("DrawerState", await page.evaluate(DRAWER_FOCUS_SCRIPT))


def valid_drawer_focus(state: DrawerState) -> bool:
    return bool(
        state["focusInside"]
        and state["focusVisible"]
        and state["focusContained"]
        and not state["focusInert"]
    )


def restored_phone_toc(state: DrawerState) -> bool:
    return bool(
        state["tocVisible"]
        and abs(abs(state["scrollLeft"]) - state["maxScroll"]) <= 0.5
        and str(state["focusLabel"]).startswith("Back from Installation")
        and valid_drawer_focus(state)
    )


async def wait_for_restored_phone_toc(page: Page) -> DrawerState:
    # The reopened drawer settles its selected-item focus across animation
    # frames, and the site script's post-resize settle pass adds one more
    # frame (#354); poll instead of sampling once.
    state = await drawer_focus_state(page)
    for _ in range(100):
        if restored_phone_toc(state):
            return state
        await page.wait_for_timeout(50)
        state = await drawer_focus_state(page)
    return state


async def wait_for_drawer_modal_focus(page: Page) -> DrawerState:
    # The drawer checkbox changes before its animation-frame focus move.
    state = await drawer_focus_state(page)
    for _ in range(100):
        if state["drawerChecked"] and state["modal"] == "true" and valid_drawer_focus(state):
            return state
        await page.wait_for_timeout(50)
        state = await drawer_focus_state(page)
    raise AssertionError(f"drawer modal focus did not settle: {json.dumps(state)}")


async def assert_trapped_drawer_focus(page: Page, keys: list[str], context: str) -> None:
    for key in keys:
        await page.keyboard.press(key)
        state = await drawer_focus_state(page)
        expect_state(
            valid_drawer_focus(state), f"{context}: {key} left a fully visible drawer target", state
        )


async def search_focus_state(page: Page) -> SearchState:
    return cast("SearchState", await page.evaluate(SEARCH_FOCUS_SCRIPT))


def valid_search_focus(state: SearchState) -> bool:
    return bool(
        state["focusInside"]
        and state["focusVisible"]
        and state["focusInViewport"]
        and not state["focusInert"]
    )


async def wait_for_search_modal_focus(page: Page) -> SearchState:
    state: SearchState | None = None
    for _ in range(100):
        state = await search_focus_state(page)
        if (
            state["checked"]
            and state["modal"] == "true"
            and not state["inert"]
            and valid_search_focus(state)
        ):
            return state
        await page.wait_for_timeout(50)
    if state is None:
        raise RuntimeError("search focus state was not sampled")
    return state


async def check_closed_boundaries(page: Page, origin: str) -> None:
    cases = [
        (719, True, True),
        (720, True, True),
        (800, True, True),
        (959, True, True),
        (960, True, False),
        (1100, True, False),
        (1219, True, False),
        (1220, False, False),
    ]
    await page.goto(origin, wait_until="networkidle")
    for width, drawer_overlay, search_overlay in cases:
        await page.set_viewport_size({"width": width, "height": 800})
        await settle_shell(page)
        state = cast("BoundaryState", await page.evaluate(BOUNDARIES_SCRIPT))
        expect_state(
            state["drawerInert"] == drawer_overlay
            and (state["drawerHidden"] == "true") == drawer_overlay
            and state["openerVisible"] == drawer_overlay
            and (
                state["drawerBounds"][1] <= 0.5
                if drawer_overlay
                else state["drawerBounds"][0] >= -0.5 and state["drawerBounds"][2] > 0
            ),
            f"drawer boundary mismatch at {width}px",
            state,
        )
        expect_state(
            state["searchInert"] == search_overlay
            and (state["searchHidden"] == "true") == search_overlay,
            f"search boundary mismatch at {width}px",
            state,
        )
        expect_state(state["overflow"] <= 1, f"document overflow at {width}px", state)


async def check_drawer_resize(page: Page, origin: str, direction: str) -> None:
    await page.set_viewport_size({"width": 800, "height": 800})
    await page.goto(f"{origin}/getting-started/", wait_until="networkidle")
    await page.evaluate("dir => { document.body.dir = dir; }", direction)
    await page.locator('label.md-header__button[for="__drawer"]').focus()
    await page.keyboard.press("Enter")
    await wait_for_drawer_modal_focus(page)
    await page.locator('.md-sidebar--primary label.md-nav__link[for="__toc"]').focus()
    await page.keyboard.press("Enter")
    await settle_shell(page)
    state = await drawer_focus_state(page)
    expect_state(
        state["drawerChecked"]
        and state["tocChecked"]
        and state["tocVisible"]
        and state["modal"] == "true"
        and valid_drawer_focus(state),
        f"{direction}: phone TOC did not open inside the drawer",
        state,
    )

    await page.set_viewport_size({"width": 1100, "height": 800})
    await settle_shell(page)
    state = await drawer_focus_state(page)
    expect_state(
        state["drawerChecked"]
        and state["tocChecked"]
        and not state["tocVisible"]
        and state["modal"] == "true"
        and abs(state["scrollLeft"]) <= 0.5
        and state["focusLabel"] == "Back from Start Here"
        and valid_drawer_focus(state),
        f"{direction}: tablet resize did not restore the root drawer geometry",
        state,
    )
    await assert_trapped_drawer_focus(
        page, ["Tab"] * 20 + ["Shift+Tab"] * 20, f"{direction}: tablet drawer"
    )

    await page.set_viewport_size({"width": 1219, "height": 800})
    await settle_shell(page)
    state = await drawer_focus_state(page)
    expect_state(
        state["drawerChecked"]
        and state["modal"] == "true"
        and abs(state["scrollLeft"]) <= 0.5
        and valid_drawer_focus(state),
        f"{direction}: upper drawer boundary lost geometry or focus",
        state,
    )
    await assert_trapped_drawer_focus(
        page, ["Tab"] * 10 + ["Shift+Tab"] * 10, f"{direction}: 1219px drawer"
    )
    await page.keyboard.press("Escape")
    await settle_shell(page)
    state = await drawer_focus_state(page)
    expect_state(
        not state["drawerChecked"]
        and state["inert"]
        and state["focusLabel"] == "Open primary navigation",
        f"{direction}: drawer Escape did not restore its opener",
        state,
    )
    await page.keyboard.press("Enter")
    state = await wait_for_drawer_modal_focus(page)
    expect_state(
        state["drawerChecked"] and state["modal"] == "true" and valid_drawer_focus(state),
        f"{direction}: drawer did not reopen at 1219px",
        state,
    )

    await page.set_viewport_size({"width": 800, "height": 800})
    state = await wait_for_restored_phone_toc(page)
    expect_state(
        restored_phone_toc(state),
        f"{direction}: phone resize did not restore the selected TOC geometry",
        state,
    )
    await assert_trapped_drawer_focus(
        page, ["Tab"] * 10 + ["Shift+Tab"] * 10, f"{direction}: restored phone TOC"
    )

    await page.set_viewport_size({"width": 1280, "height": 800})
    await settle_shell(page)
    state = await drawer_focus_state(page)
    expect_state(
        state["modal"] is None and not state["inert"] and state["focusVisible"],
        f"{direction}: desktop resize retained modal or hidden focus state",
        state,
    )


async def check_search_resize(page: Page, origin: str) -> None:
    await page.set_viewport_size({"width": 959, "height": 800})
    await page.goto(origin, wait_until="networkidle")
    await page.locator('label.md-header__button[for="__search"]').focus()
    await page.keyboard.press("Enter")
    state = await wait_for_search_modal_focus(page)
    expect_state(
        state["checked"]
        and state["modal"] == "true"
        and not state["inert"]
        and valid_search_focus(state),
        "959px search did not open as a modal",
        state,
    )
    for key in ["Tab"] * 10 + ["Shift+Tab"] * 10:
        await page.keyboard.press(key)
        state = await search_focus_state(page)
        expect_state(valid_search_focus(state), f"959px search trap failed on {key}", state)

    await page.set_viewport_size({"width": 960, "height": 800})
    await settle_shell(page)
    state = await search_focus_state(page)
    expect_state(
        state["checked"]
        and state["modal"] is None
        and not state["inert"]
        and state["focusVisible"]
        and state["focusInViewport"]
        and not state["focusInert"],
        "960px search did not become a usable non-modal control",
        state,
    )

    await page.set_viewport_size({"width": 959, "height": 800})
    state = await wait_for_search_modal_focus(page)
    expect_state(
        state["checked"]
        and state["modal"] == "true"
        and not state["inert"]
        and valid_search_focus(state),
        "959px search did not return to a usable modal",
        state,
    )
    await page.keyboard.press("Escape")
    await settle_shell(page)
    state = await search_focus_state(page)
    expect_state(
        not state["checked"] and state["inert"] and state["focusLabel"] == "Search documentation",
        "search Escape did not restore its trigger",
        state,
    )


def attach_error_capture(page: Page, errors: list[str], origin: str) -> None:
    page.on("pageerror", lambda error: errors.append(str(error)))
    page.on(
        "console",
        lambda message: (
            errors.append(message.text)
            if message.type == "error" and not message.text.startswith("Failed to load resource:")
            else None
        ),
    )
    page.on(
        "response",
        lambda response: (
            errors.append(f"{response.status} {response.url}")
            if response.url.startswith(origin) and response.status >= 400
            else None
        ),
    )


async def run_checks() -> None:
    start = time.monotonic()
    errors: list[str] = []
    server: ThreadingHTTPServer | None = None
    server_thread: threading.Thread | None = None
    browser: Browser | None = None
    context: BrowserContext | None = None
    page: Page | None = None
    origin = ""
    crash_state = {"page": False, "browser": False}

    def current_page() -> Page:
        if page is None:
            raise RuntimeError("browser page is unavailable")
        return page

    def mark_browser_crash(target: Browser) -> None:
        if target is browser:
            crash_state["browser"] = True

    def mark_page_crash(target: Page) -> None:
        if target is page:
            crash_state["page"] = True

    async def restart_browser() -> None:
        nonlocal browser, context, page
        if browser is None:
            raise RuntimeError("browser is unavailable for crash recovery")
        try:
            await asyncio.wait_for(browser.close(), timeout=10)
        except Exception as close_error:
            print(f"Accessibility cleanup failed: {close_error}", file=sys.stderr)
        browser = None
        context = None
        page = None
        crash_state.update(page=False, browser=False)
        browser = await playwright.chromium.launch(args=["--disable-gpu"], headless=True)
        browser.on("disconnected", mark_browser_crash)
        context = await browser.new_context(
            reduced_motion="reduce", viewport={"width": 1220, "height": 800}
        )
        page = await context.new_page()
        page.on("crash", mark_page_crash)
        page.set_default_timeout(5000)
        page.set_default_navigation_timeout(15000)
        attach_error_capture(page, errors, origin)

    async def run_phase(name: str, check: Callable[[], Awaitable[None]]) -> None:
        nonlocal browser, context, page
        print(
            f"Accessibility: start {name} at {time.monotonic() - start:.1f}s",
            file=sys.stderr,
            flush=True,
        )
        for attempt in range(3):
            try:
                await asyncio.wait_for(check(), timeout=PHASE_TIMEOUT)
                break
            except PlaywrightError as exc:
                if "Target crashed" not in str(exc) and not any(crash_state.values()):
                    raise
                print(
                    f"Accessibility: Chromium crash in {name} (attempt {attempt + 1}/3): "
                    f"{exc}; browser connected: {browser.is_connected() if browser else False}",
                    file=sys.stderr,
                    flush=True,
                )
                if attempt == 2:
                    raise RuntimeError(f'phase "{name}" crashed three times in Chromium') from exc
                await restart_browser()
                print(f"Accessibility: retrying {name} in a fresh browser", file=sys.stderr)
            except TimeoutError as exc:
                if any(crash_state.values()):
                    print(
                        f"Accessibility: Chromium crashed while waiting in {name} "
                        f"(attempt {attempt + 1}/3)",
                        file=sys.stderr,
                    )
                    if attempt == 2:
                        raise RuntimeError(
                            f'phase "{name}" crashed three times in Chromium'
                        ) from exc
                    await restart_browser()
                    print(f"Accessibility: retrying {name} in a fresh browser", file=sys.stderr)
                    continue
                if attempt or context is None or page is None:
                    suffix = " again after a retry" if attempt else ""
                    raise TimeoutError(
                        f'phase "{name}" exceeded {PHASE_TIMEOUT} seconds{suffix}'
                    ) from exc
                print(
                    f"Accessibility: retrying {name} on a fresh page at {time.monotonic() - start:.1f}s",
                    file=sys.stderr,
                    flush=True,
                )
                previous = page
                page = await context.new_page()
                crash_state["page"] = False
                page.on("crash", mark_page_crash)
                page.set_default_timeout(5000)
                page.set_default_navigation_timeout(15000)
                attach_error_capture(page, errors, origin)
                with suppress(Exception):
                    await asyncio.wait_for(previous.close(), timeout=5)
        print(
            f"Accessibility: done {name} at {time.monotonic() - start:.1f}s",
            file=sys.stderr,
            flush=True,
        )

    try:
        await run_phase("build freshness", assert_build_freshness)
        server, server_thread, origin = start_server()
        async with async_playwright() as playwright:
            try:
                browser = await playwright.chromium.launch(args=["--disable-gpu"], headless=True)
                browser.on("disconnected", mark_browser_crash)
                context = await browser.new_context(
                    reduced_motion="reduce", viewport={"width": 1220, "height": 800}
                )
                page = await context.new_page()
                page.on("crash", mark_page_crash)
                page.set_default_timeout(5000)
                page.set_default_navigation_timeout(15000)
                attach_error_capture(page, errors, origin)
                await run_phase(
                    "closed boundaries", lambda: check_closed_boundaries(current_page(), origin)
                )
                await run_phase(
                    "drawer resize ltr", lambda: check_drawer_resize(current_page(), origin, "ltr")
                )
                await run_phase(
                    "drawer resize rtl", lambda: check_drawer_resize(current_page(), origin, "rtl")
                )
                await run_phase(
                    "search resize", lambda: check_search_resize(current_page(), origin)
                )
                expect_state(not errors, "documentation pages emitted browser errors", errors)
            finally:
                primary_error = sys.exception()
                if browser is not None:
                    try:
                        await asyncio.wait_for(browser.close(), timeout=10)
                    except Exception as exc:
                        print(f"Accessibility cleanup failed: {exc}", file=sys.stderr)
                        if primary_error is None:
                            raise
    finally:
        primary_error = sys.exception()
        cleanup_error: Exception | None = None
        if server is not None and server_thread is not None:
            try:
                await asyncio.to_thread(close_server, server, server_thread)
            except Exception as exc:
                cleanup_error = exc
                print(f"Accessibility cleanup failed: {exc}", file=sys.stderr)
        if primary_error is None and cleanup_error is not None:
            raise cleanup_error
    print("Documentation accessibility browser checks passed.")


async def main() -> None:
    try:
        await asyncio.wait_for(run_checks(), timeout=GLOBAL_TIMEOUT)
    except TimeoutError as exc:
        if not str(exc).startswith('phase "'):
            raise TimeoutError(
                f"Documentation accessibility checks exceeded {GLOBAL_TIMEOUT} seconds."
            ) from exc
        raise


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except Exception:
        traceback.print_exc()
        sys.exit(1)
