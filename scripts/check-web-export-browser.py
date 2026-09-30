#!/usr/bin/env python3
"""Check the exported demo over HTTPS with a real browser and WSS server."""

import argparse
import json
import subprocess
import sys
import threading
import time
import traceback
from pathlib import Path
from typing import cast
from urllib.parse import urlencode

from playwright.sync_api import Error as PlaywrightError
from playwright.sync_api import Page, sync_playwright

ROOT = Path(__file__).resolve().parents[1]
HOST = "127.0.0.1"
HTTPS_PORT = 8443
WSS_PORT = 8444
BOOT_TIMEOUT_MS = 90_000


class SmokeServer:
    def __init__(self, web_root: Path, key: Path, cert: Path) -> None:
        self.web_root = web_root
        self.key = key
        self.cert = cert
        self.events: list[dict[str, object]] = []
        self.process: subprocess.Popen[str] | None = None
        self.reader: threading.Thread | None = None
        self.condition = threading.Condition()

    def start(self) -> None:
        self.events = []
        self.process = subprocess.Popen(  # noqa: S603
            [
                sys.executable,
                str(ROOT / "scripts/web_smoke_server.py"),
                "--web-root",
                str(self.web_root),
                "--https-port",
                str(HTTPS_PORT),
                "--wss-port",
                str(WSS_PORT),
                "--key",
                str(self.key),
                "--cert",
                str(self.cert),
            ],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        self.reader = threading.Thread(target=self._read_events, daemon=True)
        self.reader.start()
        self.wait_event("listening", role="wss")

    def _read_events(self) -> None:
        process = self.process
        if process is None or process.stdout is None:
            raise RuntimeError("smoke server output is unavailable")
        for line in process.stdout:
            if line.startswith("SMOKE "):
                event = json.loads(line.removeprefix("SMOKE "))
                with self.condition:
                    self.events.append(event)
                    self.condition.notify_all()
        with self.condition:
            self.condition.notify_all()

    def wait_event(self, name: str, timeout: float = 30, **fields: object) -> None:
        deadline = time.monotonic() + timeout
        with self.condition:
            while True:
                if any(
                    event.get("event") == name
                    and all(event.get(key) == value for key, value in fields.items())
                    for event in self.events
                ):
                    return
                if self.process is not None and self.process.poll() is not None:
                    raise RuntimeError(
                        f"smoke server exited while waiting for {name}: {self.events}"
                    )
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError(f"timed out waiting for {name}; events: {self.events}")
                self.condition.wait(min(remaining, 0.1))

    def stop(self) -> None:
        if self.process is None:
            return
        process = self.process
        self.process = None
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        if self.reader is not None:
            self.reader.join(timeout=5)
            self.reader = None
        if process.stdout is not None:
            process.stdout.close()


def wait_for_log(page: Page, needle: str) -> None:
    page.wait_for_function(
        "needle => Array.isArray(window.__sfSmokeLogs) && "
        "window.__sfSmokeLogs.some(line => line.includes(needle))",
        arg=needle,
        timeout=BOOT_TIMEOUT_MS,
        polling=250,
    )


def logs_for(page: Page) -> list[str]:
    return cast("list[str]", page.evaluate("() => [...(window.__sfSmokeLogs ?? [])]"))


def demo_url(endpoint: str) -> str:
    params = urlencode({"sf_smoke_endpoint": endpoint, "sf_smoke_app_id": "web-smoke"})
    return f"https://{HOST}:{HTTPS_PORT}/index.html?{params}"


def run_attempt(web_root: Path, key: Path, cert: Path) -> None:
    server = SmokeServer(web_root, key, cert)
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(args=["--no-sandbox"])
        crash_state = {"page": False, "browser": False}
        browser.on("disconnected", lambda _target: crash_state.__setitem__("browser", True))
        stage = "browser setup"
        try:
            context = browser.new_context(ignore_https_errors=True)
            context.add_init_script(
                "window.__sfSmokeLogs = []; "
                "window.__sfSmokeLog = line => window.__sfSmokeLogs.push(String(line));"
            )
            page = context.new_page()
            page.on("crash", lambda _target: crash_state.__setitem__("page", True))
            page_errors: list[str] = []
            page.on("pageerror", lambda error: page_errors.append(str(error)))

            server.start()
            stage = "HTTPS and WSS"
            response = page.goto(
                demo_url(f"wss://{HOST}:{WSS_PORT}"),
                wait_until="domcontentloaded",
                timeout=30_000,
            )
            if response is None or response.status != 200:
                raise AssertionError(
                    f"index.html did not load over HTTPS (status {response.status if response else None})"
                )
            wait_for_log(page, "fill in endpoint + app id, then Connect")
            wait_for_log(page, "pong")
            logs = logs_for(page)
            expected = [
                "connect: OK",
                "connected",
                "authenticated as app 'web-smoke' (smoke)",
                "ping: OK",
                "pong",
            ]
            missing = [line for line in expected if not any(line in log for log in logs)]
            if missing:
                raise AssertionError(f"wss flow missing log lines: {missing}; demo log: {logs}")
            server.wait_event("ws_open", origin_ok=True)
            server.wait_event("message", type="Authenticate")
            server.wait_event("pong_sent")

            server.stop()
            server.start()
            stage = "secure-page ws:// refusal"
            page.goto(
                demo_url(f"ws://{HOST}:{WSS_PORT}"),
                wait_until="domcontentloaded",
                timeout=30_000,
            )
            wait_for_log(page, "protocol error: ws:// is blocked from secure pages")
            wait_for_log(page, "connect: Invalid parameter")
            insecure_logs = logs_for(page)
            if "connected" in insecure_logs:
                raise AssertionError(f"ws:// dial unexpectedly connected: {insecure_logs}")
            if any(event.get("event") == "ws_open" for event in server.events):
                raise AssertionError(f"ws:// dial reached the smoke server: {insecure_logs}")
            if page_errors:
                raise AssertionError(f"page errors during smoke: {page_errors}; demo log: {logs}")
        except PlaywrightError as exc:
            if "Target crashed" in str(exc) or any(crash_state.values()):
                raise BrowserCrash(
                    f"Chromium crashed during {stage}: {exc}; "
                    f"browser connected: {browser.is_connected()}"
                ) from exc
            raise
        except TimeoutError as exc:
            if any(crash_state.values()):
                raise BrowserCrash(
                    f"Chromium crashed while waiting during {stage}: {exc}; "
                    f"browser connected: {browser.is_connected()}"
                ) from exc
            raise
        finally:
            primary_error = sys.exception()
            cleanup_error: Exception | None = None
            try:
                server.stop()
            except Exception as exc:
                cleanup_error = exc
                print(f"web-export cleanup failed: {exc}", file=sys.stderr)
            try:
                browser.close()
            except Exception as exc:
                if cleanup_error is None:
                    cleanup_error = exc
                print(f"web-export cleanup failed: {exc}", file=sys.stderr)
            if primary_error is None and cleanup_error is not None:
                raise cleanup_error


class BrowserCrash(RuntimeError):
    pass


def run_check(web_root: Path, key: Path, cert: Path) -> None:
    for attempt in range(3):
        try:
            run_attempt(web_root, key, cert)
            print("web-export browser check passed: HTTPS boot, wss+Origin, ws:// predial refusal")
            return
        except BrowserCrash as exc:
            print(f"web-export browser crash (attempt {attempt + 1}/3): {exc}", file=sys.stderr)
            if attempt == 2:
                raise RuntimeError("web-export Chromium crashed three times") from exc
            print("web-export: retrying both scenarios in a fresh browser", file=sys.stderr)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--web-root", type=Path, default=ROOT / "build/web")
    parser.add_argument("--key", type=Path, default=ROOT / "build/smoke-certs/key.pem")
    parser.add_argument("--cert", type=Path, default=ROOT / "build/smoke-certs/cert.pem")
    args = parser.parse_args()
    try:
        run_check(args.web_root.resolve(), args.key.resolve(), args.cert.resolve())
    except Exception:
        traceback.print_exc()
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
