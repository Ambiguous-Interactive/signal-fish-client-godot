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
from collections import OrderedDict, deque
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


class RelayObservation:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.enqueued = 0
        self.dequeued = 0
        self.evicted = 0
        self.pending: OrderedDict[int, tuple[int, str, float]] = OrderedDict()
        self.recent: deque[tuple[int, str, float | None, float]] = deque(maxlen=128)

    def enqueue(self, seat: int, message: object) -> None:
        if not isinstance(message, dict) or not isinstance(message.get("marker"), str):
            return
        with self.lock:
            self.enqueued += 1
            self.pending[id(message)] = (seat, message["marker"], time.monotonic())
            if len(self.pending) > 128:
                self.pending.popitem(last=False)
                self.evicted += 1

    def dequeue(self, seat: int, messages: list[object]) -> None:
        with self.lock:
            now = time.monotonic()
            for message in messages:
                if not isinstance(message, dict) or not isinstance(message.get("marker"), str):
                    continue
                self.dequeued += 1
                pending = self.pending.pop(id(message), None)
                self.recent.append((seat, message["marker"], pending[2] if pending else None, now))

    def snapshot(self) -> dict[str, object]:
        with self.lock:
            now = time.monotonic()
            return {
                "enqueued_markers": self.enqueued,
                "dequeued_markers": self.dequeued,
                "queued_markers": self.enqueued - self.dequeued,
                "evicted_pending_records": self.evicted,
                "pending_markers": [
                    {"seat": seat, "marker": marker, "age_ms": round((now - started) * 1000)}
                    for seat, marker, started in self.pending.values()
                ],
                "recent_dequeues": [
                    {
                        "seat": seat,
                        "marker": marker,
                        "queue_ms": round((finished - started) * 1000)
                        if started is not None
                        else None,
                        "age_ms": round((now - finished) * 1000),
                    }
                    for seat, marker, started, finished in self.recent
                ],
            }


class RelayHandler(SimpleHTTPRequestHandler):
    queues: ClassVar[list[list[object]]] = [[], []]
    lock = threading.Lock()
    observation = RelayObservation()

    def log_message(self, _format: str, *_args: object) -> None:
        pass

    def do_GET(self) -> None:
        if self.path in tuple(f"/signal/{seat}" for seat in range(len(self.queues))):
            seat = int(self.path[-1])
            with self.lock:
                messages = self.queues[seat]
                self.queues[seat] = []
                self.observation.dequeue(seat, messages)
            self.reply(json.dumps(messages).encode())
        else:
            super().do_GET()

    def do_POST(self) -> None:
        if self.path not in tuple(f"/signal/{seat}" for seat in range(len(self.queues))):
            self.send_error(404)
            return
        message = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with self.lock:
            seat = int(self.path[-1])
            self.queues[seat].append(message)
            self.observation.enqueue(seat, message)
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
        self.markers: dict[Request, str] = {}
        self.completed = 0
        self.failed = 0
        self.last_console: float | None = None
        self.last_progress: float | None = None
        self.recent: deque[dict[str, object]] = deque(maxlen=16)
        self.stats: deque[tuple[float, dict[str, object]]] = deque(maxlen=16)
        self.last_stats: float | None = None

    def console(self, message: str) -> None:
        self.last_console = time.monotonic()
        if message.startswith("WEBRTC_INTEROP_PROGRESS "):
            self.last_progress = self.last_console
        if message.startswith("WEBRTC_BROWSER_STATS "):
            try:
                sample = json.loads(message.removeprefix("WEBRTC_BROWSER_STATS "))
            except json.JSONDecodeError:
                return
            if isinstance(sample, dict):
                self.last_stats = self.last_console
                self.stats.append((self.last_stats, sample))

    def started(self, request: Request) -> None:
        if request.url.startswith(self.signal_url):
            self.inflight[request] = time.monotonic()
            body = request.post_data
            if isinstance(body, str):
                with contextlib.suppress(json.JSONDecodeError):
                    payload = json.loads(body)
                    if isinstance(payload, dict) and isinstance(payload.get("marker"), str):
                        self.markers[request] = payload["marker"]

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
                "marker": self.markers.pop(request, None),
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
                    "marker": self.markers.get(request),
                    "age_ms": round((now - started) * 1000),
                }
                for request, started in self.inflight.items()
            ],
            "recent_requests": list(self.recent),
            "last_stats_age_ms": (
                round((now - self.last_stats) * 1000) if self.last_stats is not None else None
            ),
            "webrtc_stats": [
                {"age_ms": round((now - observed_at) * 1000), "sample": sample}
                for observed_at, sample in self.stats
            ],
        }


def prepare(project: Path, extension: Path | None, addon_root: Path) -> None:
    shutil.copytree(addon_root / "addons/signal_fish", project / "addons/signal_fish")
    if extension:
        shutil.copytree(extension, project / "addons/webrtc_native")
    tests = project / "tests/smoke"
    tests.mkdir(parents=True)
    for name in (
        "webrtc_interop_drill.gd",
        "webrtc_interop_drill.tscn",
        "webrtc_rpc_probe.gd",
        "webrtc_multipeer_drill.gd",
        "webrtc_multipeer_rpc_probe.gd",
    ):
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


def seat_evidence(
    output: str, seat: int, *, retirement_case: int | None = None, require_multi_rpc: bool = False
) -> dict[str, object]:
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
    rpc_phases = []
    multi_peer_phases = []
    multi_peer_interruptions = []
    for line in lines:
        if line.startswith("WEBRTC_RPC_RECOVERY_PHASE "):
            with contextlib.suppress(json.JSONDecodeError):
                rpc_phases.append(json.loads(line.removeprefix("WEBRTC_RPC_RECOVERY_PHASE ")))
        if line.startswith("WEBRTC_MULTIPEER_PHASE "):
            with contextlib.suppress(json.JSONDecodeError):
                multi_peer_phases.append(json.loads(line.removeprefix("WEBRTC_MULTIPEER_PHASE ")))
        if line.startswith("WEBRTC_MULTIPEER_INTERRUPTION "):
            with contextlib.suppress(json.JSONDecodeError):
                multi_peer_interruptions.append(
                    json.loads(line.removeprefix("WEBRTC_MULTIPEER_INTERRUPTION "))
                )
    scenario_complete = None
    if retirement_case is not None:
        scenario_complete = (
            [phase.get("phase") for phase in multi_peer_phases] == [1, 2, 3]
            and len(multi_peer_interruptions) == 1
            and all(
                record.get("retirement_case") == retirement_case
                for record in [*multi_peer_phases, *multi_peer_interruptions]
            )
        )
        if require_multi_rpc:
            scenario_complete = scenario_complete and all(
                phase.get("rpc_traffic") is True
                and phase.get("same_safe_receiver") is True
                and phase.get("rpc_service_poll_count", 0) > 0
                and phase.get("rpc", {}).get("failure") == ""
                for phase in multi_peer_phases
            )
        passed = passed and scenario_complete
    return {
        "scenario_complete": scenario_complete,
        "multi_peer_interruptions": multi_peer_interruptions,
        "multi_peer_phases": multi_peer_phases,
        "rpc_recovery_phases": rpc_phases,
        "seat": seat,
        "engine_banner": next((line for line in lines if line.startswith("Godot Engine v")), ""),
        "passed": passed,
        "last_stage": next((line for line in reversed(lines) if "interop stage:" in line), ""),
        "last_ready": next((line for line in reversed(lines) if "interop ready:" in line), ""),
        "failure": failure,
        "diagnostic": diagnostic,
        "last_progress": progress,
    }


def observe_browser(
    page: Page,
    process: subprocess.Popen[bytes],
    messages: list[str],
    seat: int = 1,
    *,
    timeout_seconds: int = 60,
) -> str:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        page.wait_for_timeout(200)
        if any(
            message == f"WEBRTC_INTEROP_PASS seat={seat}"
            or message.startswith("WEBRTC_INTEROP_FAIL ")
            or message.startswith("PAGE_ERROR ")
            or message == "BROWSER_CRASH"
            or engine_failed(message)
            for message in messages
        ):
            return ""
        if process.poll() not in (None, 0):
            return "native seat exited before browser completion"
    return f"browser observation timed out after {timeout_seconds} seconds"


def wait_web_startup(page: Page, outputs: list[tuple[int, list[str]]]) -> None:
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        for seat, messages in outputs:
            if any(
                engine_failed(message)
                or message.startswith(("PAGE_ERROR ", "BROWSER_CRASH", "WEBRTC_INTEROP_FAIL "))
                for message in messages
            ):
                raise RuntimeError(f"Web seat {seat} failed during engine startup")
        if all(f"WEBRTC_MULTIPEER_LOADED seat={seat}" in messages for seat, messages in outputs):
            return
        page.wait_for_timeout(200)
    missing = [
        seat for seat, messages in outputs if f"WEBRTC_MULTIPEER_LOADED seat={seat}" not in messages
    ]
    raise RuntimeError(f"Web engine startup timed out after 60 seconds; missing seats: {missing}")


def prepare_pair(args: argparse.Namespace, directory: Path, addon_root: Path) -> tuple[Path, Path]:
    native = directory / "native"
    web = directory / "web"
    prepare(native, args.native_extension, addon_root)
    prepare(web, None, addon_root)
    if args.multi_peer:
        for project in (native, web):
            scene = project / SCENE
            scene.write_text(
                scene.read_text().replace("webrtc_interop_drill.gd", "webrtc_multipeer_drill.gd")
            )
    for project, engine in ((native, args.godot), (web, args.web_godot or args.godot)):
        checked(
            [engine, "--headless", "--path", str(project), "--editor", "--import"],
            project / "import.log",
        )
    checked(
        [args.web_godot or args.godot, "--headless", "--path", str(web), "--export-debug", "Web"],
        web / "export.log",
    )
    return native, web


def run_seats(
    args: argparse.Namespace, directory: Path, native: Path, web: Path, *, retirement_case: int = 0
) -> None:
    directory.mkdir(parents=True)

    class TrialRelayHandler(RelayHandler):
        queues: ClassVar[list[list[object]]] = [[] for _ in range(3 if args.multi_peer else 2)]
        lock = threading.Lock()
        observation = RelayObservation()

    handler = functools.partial(TrialRelayHandler, directory=str(web / "build/web"))
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    url = f"http://127.0.0.1:{server.server_port}"
    native_log = (directory / "native.log").open("w")
    process = None
    messages: list[str] = []
    extra_messages: list[str] = []
    extra_observation = BrowserObservation(url)
    driver_error = ""
    browser_version = ""
    observation = BrowserObservation(url)
    browser_observation: dict[str, object] = {}
    browser_2_observation: dict[str, object] = {}
    relay_observation: dict[str, object] = {}
    try:
        native_command = [
            args.godot,
            "--headless",
            "--path",
            str(native),
            "--",
            url,
            *([f"--retirement-case={retirement_case}"] if args.multi_peer else []),
            *(["--mixed-traffic"] if args.mixed_traffic else []),
            *(["--rpc-traffic"] if args.rpc_traffic else []),
            *(["--rpc-recovery"] if args.rpc_recovery else []),
            *(["--rpc-plan-recovery"] if args.rpc_plan_recovery else []),
            *(["--metadata-probe"] if args.metadata_probe else []),
            *(["--channel-receive"] if args.channel_receive else []),
            *(["--safe-receive"] if args.safe_receive else []),
            *(["--slow-receiver"] if args.slow_receiver else []),
        ]
        if not args.multi_peer:
            process = subprocess.Popen(native_command, stdout=native_log, stderr=subprocess.STDOUT)  # noqa: S603
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(
                headless=True,
                executable_path=args.chromium,
                args=["--no-sandbox", "--enable-unsafe-swiftshader"],
            )
            browser_version = browser.version
            try:
                page = browser.new_page()
                page.add_init_script(path=ROOT / "scripts/webrtc-browser-observation.js")

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
                if args.slow_receiver:
                    query = "?slow_receiver=1"
                if args.metadata_probe:
                    query = "?metadata_probe=1"
                if args.rpc_recovery:
                    query += ("&" if query else "?") + "rpc_recovery=1"
                if args.rpc_plan_recovery:
                    query += ("&" if query else "?") + "rpc_plan_recovery=1"
                if args.rpc_traffic:
                    query += ("&" if query else "?") + "rpc_traffic=1"
                if args.safe_receive:
                    query += ("&" if query else "?") + "safe_receive=1"
                if args.channel_receive:
                    query += ("&" if query else "?") + "channel_receive=1"
                if args.multi_peer:
                    query += ("&" if query else "?") + f"retirement_case={retirement_case}"
                page.goto(url + "/index.html" + query)
                extra_page = None
                if args.multi_peer:
                    extra_page = browser.new_page()
                    extra_page.add_init_script(path=ROOT / "scripts/webrtc-browser-observation.js")

                    def extra_console(message: str) -> None:
                        extra_messages.append(message)
                        extra_observation.console(message)

                    extra_page.on("console", lambda message: extra_console(message.text))
                    extra_page.on("crash", lambda _: extra_console("BROWSER_CRASH"))
                    extra_page.on(
                        "pageerror", lambda error: extra_console("PAGE_ERROR " + str(error))
                    )
                    extra_page.on("request", extra_observation.started)
                    extra_page.on("requestfinished", extra_observation.finished)
                    extra_page.on(
                        "requestfailed",
                        lambda request: extra_observation.finished(request, failed=True),
                    )
                    extra_page.goto(
                        url
                        + f"/index.html?seat=2&retirement_case={retirement_case}"
                        + ("&slow_receiver=1" if args.slow_receiver else "")
                        + ("&rpc_traffic=1" if args.rpc_traffic else "")
                    )
                    wait_web_startup(page, [(1, messages), (2, extra_messages)])
                    process = subprocess.Popen(  # noqa: S603
                        native_command, stdout=native_log, stderr=subprocess.STDOUT
                    )
                    page.evaluate("window.sfMeshStart = true")
                    extra_page.evaluate("window.sfMeshStart = true")
                if process is None:
                    raise RuntimeError("Native seat was not started")
                timeout_seconds = 120 if args.multi_peer and args.rpc_traffic else 60
                driver_error = observe_browser(
                    page, process, messages, timeout_seconds=timeout_seconds
                )
                if extra_page is not None and not driver_error:
                    driver_error = observe_browser(
                        extra_page, process, extra_messages, seat=2, timeout_seconds=timeout_seconds
                    )
            finally:
                browser_observation = observation.snapshot()
                if args.multi_peer:
                    browser_2_observation = extra_observation.snapshot()
                relay_observation = TrialRelayHandler.observation.snapshot()
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
            expected_case = retirement_case if args.multi_peer else None
            seat_results = [
                seat_evidence(
                    native_output,
                    0,
                    retirement_case=expected_case,
                    require_multi_rpc=args.multi_peer and args.rpc_traffic,
                ),
                seat_evidence(
                    "\n".join(messages),
                    1,
                    retirement_case=expected_case,
                    require_multi_rpc=args.multi_peer and args.rpc_traffic,
                ),
            ]
            if args.multi_peer:
                (directory / "browser-2.log").write_text("\n".join(extra_messages))
                seat_results.append(
                    seat_evidence(
                        "\n".join(extra_messages),
                        2,
                        retirement_case=expected_case,
                        require_multi_rpc=args.multi_peer and args.rpc_traffic,
                    )
                )
            if process is None or process.returncode != 0:
                seat_results[0]["passed"] = False
            evidence = {
                "driver_error": driver_error,
                "browser_version": browser_version,
                "browser_observation": browser_observation,
                "browser_2_observation": browser_2_observation,
                "relay_observation": relay_observation or TrialRelayHandler.observation.snapshot(),
                "retirement_case": retirement_case,
                "multi_peer": args.multi_peer,
                "slow_receiver": args.slow_receiver,
                "godot": args.godot,
                "web_godot": args.web_godot or args.godot,
                "channel_receive": args.channel_receive,
                "safe_receive": args.safe_receive,
                "metadata_probe": args.metadata_probe,
                "mixed_traffic": args.mixed_traffic,
                "rpc_traffic": args.rpc_traffic,
                "rpc_recovery": args.rpc_recovery,
                "rpc_plan_recovery": args.rpc_plan_recovery,
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
            for retirement_case in range(18 if args.retirement_matrix else 1):
                logs = directory / f"trial-{trial:03d}" / name
                if args.retirement_matrix:
                    logs /= f"case-{retirement_case:02d}"
                started = time.monotonic()
                error = ""
                try:
                    run_seats(args, logs, native, web, retirement_case=retirement_case)
                except Exception as exc:  # Keep both sides of a failed comparison.
                    error = f"{type(exc).__name__}: {exc}"
                    print(f"{name} trial {trial} retirement case {retirement_case} failed: {error}")
                results.append(
                    {
                        "source": name,
                        "addon_root": str(sources[name]),
                        "trial": trial,
                        "retirement_case": retirement_case,
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
    parser.add_argument("--web-godot", help="Web export engine (defaults to --godot)")
    parser.add_argument("--native-extension", type=Path, required=True)
    parser.add_argument("--chromium", help="Optional Playwright Chromium executable")
    parser.add_argument("--output", type=Path, help="Keep projects and logs in this new directory")
    parser.add_argument("--repeat", type=positive_count, default=1, help="Trials per addon version")
    parser.add_argument(
        "--rpc-traffic", action="store_true", help="Check safe-peer RPC snapshots and positions"
    )
    parser.add_argument(
        "--slow-receiver",
        action="store_true",
        help="With --multi-peer, hold one reader until the other pair finishes",
    )
    parser.add_argument(
        "--retirement-matrix",
        action="store_true",
        help="With --multi-peer, close each required channel on all six directed links",
    )
    scenarios = parser.add_mutually_exclusive_group()
    scenarios.add_argument(
        "--multi-peer",
        action="store_true",
        help="Check three-seat mixed traffic and selective link recovery",
    )
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
    scenarios.add_argument(
        "--rpc-plan-recovery",
        action="store_true",
        help="Keep the assigned RPC peer through plan and membership link replacement",
    )
    scenarios.add_argument(
        "--rpc-recovery",
        action="store_true",
        help="Keep SceneMultiplayer through queued RPC interruption and replacement",
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
    if args.retirement_matrix and not args.multi_peer:
        parser.error("--retirement-matrix requires --multi-peer")
    if args.slow_receiver and not args.multi_peer:
        parser.error("--slow-receiver requires --multi-peer")
    if args.multi_peer and args.channel_receive:
        parser.error("--multi-peer uses the safe receiver")
    if (args.rpc_recovery or args.rpc_plan_recovery) and (
        not args.safe_receive or args.rpc_traffic
    ):
        parser.error("RPC recovery needs --safe-receive and replaces --rpc-traffic")
    directory = args.output or Path(tempfile.mkdtemp(prefix="sf-webrtc-interop-"))
    directory.mkdir(parents=True, exist_ok=True)
    run(args, directory)


if __name__ == "__main__":
    main()
