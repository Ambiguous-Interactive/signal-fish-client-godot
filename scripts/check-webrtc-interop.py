#!/usr/bin/env python3
"""Run the opt-in Godot native/browser mesh gameplay drill."""

import argparse
import contextlib
import functools
import json
import shutil
import subprocess
import tempfile
import threading
import time
from collections import deque
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import ClassVar

from playwright.sync_api import Page, Request, sync_playwright

ROOT = Path(__file__).resolve().parents[1]
SCENE = "tests/smoke/webrtc_interop_drill.tscn"
PROJECT = f"""config_version=5
[application]
config/name="Mesh interoperability drill"
run/main_scene="res://{SCENE}"
[rendering]
renderer/rendering_method="gl_compatibility"
"""


class RelayHandler(SimpleHTTPRequestHandler):
    queues: ClassVar[list[list[object]]] = [[], []]
    lock = threading.Lock()

    def log_message(self, _format: str, *_args: object) -> None:
        pass

    def do_GET(self) -> None:
        if self.path in ("/signal/0", "/signal/1"):
            seat = int(self.path[-1])
            with self.lock:
                messages = self.queues[seat]
                self.queues[seat] = []
            self.reply(json.dumps(messages).encode())
        else:
            super().do_GET()

    def do_POST(self) -> None:
        if self.path not in ("/signal/0", "/signal/1"):
            self.send_error(404)
            return
        message = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with self.lock:
            self.queues[int(self.path[-1])].append(message)
        self.reply(b"{}")

    def reply(self, body: bytes) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class BrowserObservation:
    def __init__(self, signal_url: str) -> None:
        self.signal_url = signal_url + "/signal/"
        self.inflight: dict[Request, float] = {}
        self.completed = 0
        self.failed = 0
        self.last_console: float | None = None
        self.last_progress: float | None = None
        self.recent: deque[dict[str, object]] = deque(maxlen=16)

    def console(self, message: str) -> None:
        self.last_console = time.monotonic()
        if message.startswith("WEBRTC_INTEROP_PROGRESS "):
            self.last_progress = self.last_console

    def started(self, request: Request) -> None:
        if request.url.startswith(self.signal_url):
            self.inflight[request] = time.monotonic()

    def finished(self, request: Request, *, failed: bool = False) -> None:
        started = self.inflight.pop(request, None)
        if started is None:
            return
        self.completed += not failed
        self.failed += failed
        self.recent.append(
            {
                "method": request.method,
                "seat": request.url.removeprefix(self.signal_url),
                "elapsed_ms": round((time.monotonic() - started) * 1000),
                "failed": failed,
            }
        )

    def snapshot(self) -> dict[str, object]:
        now = time.monotonic()
        return {
            "last_console_age_ms": (
                round((now - self.last_console) * 1000) if self.last_console is not None else None
            ),
            "last_progress_age_ms": (
                round((now - self.last_progress) * 1000) if self.last_progress is not None else None
            ),
            "completed_requests": self.completed,
            "failed_requests": self.failed,
            "inflight_requests": [
                {
                    "method": request.method,
                    "seat": request.url.removeprefix(self.signal_url),
                    "age_ms": round((now - started) * 1000),
                }
                for request, started in self.inflight.items()
            ],
            "recent_requests": list(self.recent),
        }


def prepare(project: Path, extension: Path | None, addon_root: Path) -> None:
    shutil.copytree(addon_root / "addons/signal_fish", project / "addons/signal_fish")
    if extension:
        shutil.copytree(extension, project / "addons/webrtc_native")
    tests = project / "tests/smoke"
    tests.mkdir(parents=True)
    for name in ("webrtc_interop_drill.gd", "webrtc_interop_drill.tscn", "webrtc_rpc_probe.gd"):
        shutil.copy2(ROOT / "tests/smoke" / name, tests / name)
    debug = (ROOT / "project.godot").read_text().split("[debug]\n", 1)[1].split("\n[", 1)[0]
    (project / "project.godot").write_text(PROJECT + "\n[debug]\n" + debug)
    preset = (ROOT / "export_presets.cfg").read_text()
    preset = preset.replace('exclude_filter="tests/*,', 'exclude_filter="')
    (project / "export_presets.cfg").write_text(preset)
    (project / "build/web").mkdir(parents=True)


def engine_failed(output: str) -> bool:
    return "SCRIPT ERROR" in output or any(
        line.startswith(("ERROR:", "USER ERROR:")) for line in output.splitlines()
    )


def checked(command: list[str], log: Path) -> None:
    result = subprocess.run(  # noqa: S603
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=120,
    )
    log.write_bytes(result.stdout)
    if result.returncode or engine_failed(result.stdout.decode(errors="replace")):
        raise RuntimeError(f"Command failed; see {log}")


def seat_evidence(output: str, seat: int) -> dict[str, object]:
    print(output)
    lines = output.splitlines()
    passed = f"WEBRTC_INTEROP_PASS seat={seat}" in lines and not any(
        token in output
        for token in ("SCRIPT ERROR", "PAGE_ERROR", "WEBRTC_INTEROP_FAIL", "BROWSER_CRASH")
    )
    passed = passed and not engine_failed(output)
    failure = next((line for line in lines if line.startswith("WEBRTC_INTEROP_FAIL ")), "")
    diagnostic = None
    if failure:
        with contextlib.suppress(json.JSONDecodeError):
            diagnostic = json.loads(failure.removeprefix("WEBRTC_INTEROP_FAIL "))
    progress = None
    for line in reversed(lines):
        if line.startswith("WEBRTC_INTEROP_PROGRESS "):
            try:
                progress = json.loads(line.removeprefix("WEBRTC_INTEROP_PROGRESS "))
            except json.JSONDecodeError:
                continue
            break
    return {
        "seat": seat,
        "passed": passed,
        "last_stage": next((line for line in reversed(lines) if "interop stage:" in line), ""),
        "last_ready": next((line for line in reversed(lines) if "interop ready:" in line), ""),
        "failure": failure,
        "diagnostic": diagnostic,
        "last_progress": progress,
    }


def observe_browser(page: Page, process: subprocess.Popen[bytes], messages: list[str]) -> str:
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        page.wait_for_timeout(200)
        if any(
            message == "WEBRTC_INTEROP_PASS seat=1"
            or message.startswith("WEBRTC_INTEROP_FAIL ")
            or message.startswith("PAGE_ERROR ")
            or message == "BROWSER_CRASH"
            for message in messages
        ):
            return ""
        if process.poll() not in (None, 0):
            return "native seat exited before browser completion"
    return "browser observation timed out after 60 seconds"


def prepare_pair(args: argparse.Namespace, directory: Path, addon_root: Path) -> tuple[Path, Path]:
    native = directory / "native"
    web = directory / "web"
    prepare(native, args.native_extension, addon_root)
    prepare(web, None, addon_root)
    for project in (native, web):
        checked(
            [args.godot, "--headless", "--path", str(project), "--editor", "--import"],
            project / "import.log",
        )
    checked(
        [args.godot, "--headless", "--path", str(web), "--export-debug", "Web"],
        web / "export.log",
    )
    return native, web


def run_seats(args: argparse.Namespace, directory: Path, native: Path, web: Path) -> None:
    directory.mkdir(parents=True)

    class TrialRelayHandler(RelayHandler):
        queues: ClassVar[list[list[object]]] = [[], []]
        lock = threading.Lock()

    handler = functools.partial(TrialRelayHandler, directory=str(web / "build/web"))
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    url = f"http://127.0.0.1:{server.server_port}"
    native_log = (directory / "native.log").open("w")
    process = None
    messages: list[str] = []
    driver_error = ""
    browser_version = ""
    observation = BrowserObservation(url)
    browser_observation: dict[str, object] = {}
    try:
        process = subprocess.Popen(  # noqa: S603
            [
                args.godot,
                "--headless",
                "--path",
                str(native),
                "--",
                url,
                *(["--mixed-traffic"] if args.mixed_traffic else []),
                *(["--rpc-traffic"] if args.rpc_traffic else []),
                *(["--metadata-probe"] if args.metadata_probe else []),
                *(["--channel-receive"] if args.channel_receive else []),
                *(["--safe-receive"] if args.safe_receive else []),
            ],
            stdout=native_log,
            stderr=subprocess.STDOUT,
        )
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(
                headless=True,
                executable_path=args.chromium,
                args=["--no-sandbox", "--enable-unsafe-swiftshader"],
            )
            browser_version = browser.version
            try:
                page = browser.new_page()

                def console_message(message: str) -> None:
                    messages.append(message)
                    observation.console(message)

                page.on("console", lambda message: console_message(message.text))
                page.on("crash", lambda _: console_message("BROWSER_CRASH"))
                page.on("request", observation.started)
                page.on("requestfinished", observation.finished)
                page.on("requestfailed", lambda request: observation.finished(request, failed=True))
                page.on("pageerror", lambda error: messages.append("PAGE_ERROR " + str(error)))
                query = "?mixed_traffic=1" if args.mixed_traffic else ""
                if args.metadata_probe:
                    query = "?metadata_probe=1"
                if args.rpc_traffic:
                    query += ("&" if query else "?") + "rpc_traffic=1"
                if args.safe_receive:
                    query += ("&" if query else "?") + "safe_receive=1"
                if args.channel_receive:
                    query += ("&" if query else "?") + "channel_receive=1"
                page.goto(url + "/index.html" + query)
                driver_error = observe_browser(page, process, messages)
            finally:
                browser_observation = observation.snapshot()
                (directory / "browser.log").write_text("\n".join(messages))
                browser.close()
    except Exception as exc:
        driver_error = f"{type(exc).__name__}: {exc}"
    finally:
        if process is not None:
            try:
                process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                driver_error += " native seat did not exit within 20 seconds"
        try:
            if process is not None and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=10)
        finally:
            native_log.close()
            (directory / "browser.log").write_text("\n".join(messages))
            native_output = (directory / "native.log").read_text()
            seat_results = [
                seat_evidence(native_output, 0),
                seat_evidence("\n".join(messages), 1),
            ]
            if process is None or process.returncode != 0:
                seat_results[0]["passed"] = False
            evidence = {
                "driver_error": driver_error,
                "browser_version": browser_version,
                "browser_observation": browser_observation,
                "godot": args.godot,
                "channel_receive": args.channel_receive,
                "safe_receive": args.safe_receive,
                "metadata_probe": args.metadata_probe,
                "mixed_traffic": args.mixed_traffic,
                "rpc_traffic": args.rpc_traffic,
                "native_exit_code": process.returncode if process is not None else None,
                "seats": seat_results,
            }
            (directory / "seats.json").write_text(json.dumps(evidence, indent=2) + "\n")
            server.shutdown()
            server.server_close()
    if driver_error or any(not seat["passed"] for seat in seat_results):
        raise RuntimeError(
            f"Interoperability drill failed: {driver_error}; "
            f"native exit={evidence['native_exit_code']}; see {directory / 'seats.json'}"
        )
    print("Native/browser interoperability passed; logs: " + str(directory))


def positive_count(value: str) -> int:
    count = int(value)
    if count < 1:
        raise argparse.ArgumentTypeError("must be at least 1")
    return count


def run(args: argparse.Namespace, directory: Path) -> None:
    sources = {"current": ROOT}
    if args.baseline:
        sources["baseline"] = args.baseline.resolve()
    projects = {
        name: prepare_pair(args, directory / name, source) for name, source in sources.items()
    }
    results: list[dict[str, object]] = []
    for trial in range(1, args.repeat + 1):
        order = list(projects)
        if trial % 2 == 0:
            order.reverse()
        for name in order:
            native, web = projects[name]
            logs = directory / f"trial-{trial:03d}" / name
            started = time.monotonic()
            error = ""
            try:
                run_seats(args, logs, native, web)
            except Exception as exc:  # Keep both sides of a failed comparison.
                error = f"{type(exc).__name__}: {exc}"
                print(f"{name} trial {trial} failed: {error}")
            results.append(
                {
                    "source": name,
                    "addon_root": str(sources[name]),
                    "trial": trial,
                    "passed": not error,
                    "error": error,
                    "elapsed_sec": round(time.monotonic() - started, 3),
                    "logs": str(logs),
                }
            )
            (directory / "summary.json").write_text(json.dumps(results, indent=2) + "\n")
    if any(not result["passed"] for result in results):
        raise RuntimeError(f"Interoperability trial failed; see {directory / 'summary.json'}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default="godot")
    parser.add_argument("--native-extension", type=Path, required=True)
    parser.add_argument("--chromium", help="Optional Playwright Chromium executable")
    parser.add_argument("--output", type=Path, help="Keep projects and logs in this new directory")
    parser.add_argument("--repeat", type=positive_count, default=1, help="Trials per addon version")
    parser.add_argument(
        "--rpc-traffic", action="store_true", help="Check safe-peer RPC snapshots and positions"
    )
    scenarios = parser.add_mutually_exclusive_group()
    scenarios.add_argument(
        "--mixed-traffic",
        action="store_true",
        help="Probe concurrent modes; Godot 4.3 can return mismatched packet metadata",
    )
    scenarios.add_argument(
        "--metadata-probe",
        action="store_true",
        help="Reproduce queued-channel metadata mismatch (issue #403)",
    )
    receivers = parser.add_mutually_exclusive_group()
    receivers.add_argument(
        "--channel-receive",
        action="store_true",
        help="Read raw gameplay through SFWebRTCMesh.receive_packet() (no RPC)",
    )
    receivers.add_argument(
        "--safe-receive",
        action="store_true",
        help="Read packets through the metadata-safe RPC peer",
    )
    parser.add_argument(
        "--baseline", type=Path, help="Compare a checkout's addon using the same drill and tools"
    )
    args = parser.parse_args()
    directory = args.output or Path(tempfile.mkdtemp(prefix="sf-webrtc-interop-"))
    directory.mkdir(parents=True, exist_ok=True)
    run(args, directory)


if __name__ == "__main__":
    main()
