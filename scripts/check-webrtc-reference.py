#!/usr/bin/env python3
"""Assess browser reference Engine channels against native and Web Godot (#355)."""

import argparse
import functools
import hashlib
import importlib.util
import json
import shutil
import subprocess
import tempfile
import threading
import time
from http.server import ThreadingHTTPServer
from pathlib import Path
from typing import ClassVar, Protocol, cast

from playwright.sync_api import Page, sync_playwright

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "webrtc_interop", ROOT / "scripts/check-webrtc-interop.py"
)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("Could not load interoperability driver")
interop = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(interop)


def page_failed(messages: list[str]) -> bool:
    return any(
        line.startswith(("PAGE_ERROR ", "CONSOLE_ERROR ", "BROWSER_CRASH")) for line in messages
    )


def watch_page(page: Page, messages: list[str]) -> None:
    page.on(
        "console",
        lambda message: messages.append(
            ("CONSOLE_ERROR " if message.type == "error" else "") + message.text
        ),
    )
    page.on("pageerror", lambda error: messages.append("PAGE_ERROR " + str(error)))
    page.on("crash", lambda _: messages.append("BROWSER_CRASH"))


class Observation(Protocol):
    def snapshot(self) -> dict[str, object]: ...


def observe_page(page: Page, url: str) -> Observation:
    observer = interop.BrowserObservation(url)
    page.on("console", lambda message: observer.console(message.text))
    page.on("request", observer.started)
    page.on("requestfinished", observer.finished)
    page.on("requestfailed", lambda request: observer.finished(request, failed=True))
    page.add_init_script(path=ROOT / "scripts/webrtc-browser-observation.js")
    return cast(Observation, observer)


def phase_evidence(output: str) -> list[object]:
    phases: list[object] = []
    for line in output.splitlines():
        if line.startswith("WEBRTC_REFERENCE_PHASE "):
            try:
                phases.append(json.loads(line.removeprefix("WEBRTC_REFERENCE_PHASE ")))
            except json.JSONDecodeError:
                continue
    return phases


def gameplay_phase_passed(
    phase: dict[str, object],
    *,
    mixed_traffic: bool = False,
    credit_transport: str = "http",
    slow_receiver: bool = False,
) -> bool:
    return (
        phase.get("sent") is True
        and phase.get("received") in (["reliable", "unreliable"], ["unreliable", "reliable"])
        and phase.get("snapshot_sent") == 128
        and phase.get("snapshot_received") == 128
        and phase.get("partial_sent") == 4
        and phase.get("partial_received") == 4
        and phase.get("remote_closed") is True
        and phase.get("mixed_traffic") is mixed_traffic
        and phase.get("credit_transport") == credit_transport
        and (not slow_receiver or slow_receiver_passed(phase.get("receive_pause"), mixed_traffic))
        and phase.get("snapshot_acknowledged") == 128
        and phase.get("positions_sent") == (32 if mixed_traffic else 0)
        and phase.get("positions_received") == (32 if mixed_traffic else 0)
        and type(phase.get("peak_outstanding")) is int
        and 0 < cast(int, phase["peak_outstanding"]) <= 32
    )


def slow_receiver_passed(value: object, mixed_traffic: bool) -> bool:
    if not isinstance(value, dict):
        return False
    return (
        value.get("resumed") is True
        and type(value.get("elapsed_ms")) is int
        and value["elapsed_ms"] >= 1500
        and type(value.get("received")) is int
        and 8 <= value["received"] < 128
        and value.get("received_at_resume") == value["received"]
        and type(value.get("queued_reliable")) is int
        and value["queued_reliable"] >= 24
        and (
            not mixed_traffic
            or (type(value.get("queued_unreliable")) is int and value["queued_unreliable"] > 0)
        )
    )


def wait_for_godot(page: Page, messages: list[str]) -> str:
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if any(
            line == "WEBRTC_INTEROP_PASS seat=1" or line.startswith("WEBRTC_INTEROP_FAIL ")
            for line in messages
        ) or page_failed(messages):
            return ""
        page.wait_for_timeout(100)
    return "Godot Web completion observation timed out after 15 seconds"


def prepare(args: argparse.Namespace, directory: Path, *, web: bool) -> Path:
    project = directory / "project"
    interop.prepare(project, None if web else args.native_extension, ROOT)
    script = project / "tests/smoke/webrtc_interop_drill.gd"
    source = script.read_text()
    fragment = (ROOT / "tests/smoke/webrtc_reference_phase.gd.inc").read_text()
    variables, methods = fragment.split("\n\nfunc _run_phase", 1)
    start = source.index("func _run_phase(phase: int) -> bool:")
    end = source.index("\n\nfunc _probe_packet_metadata", start)
    ready = source.index("func _ready() -> void:")
    source = source[:start] + "func _run_phase" + methods + source[end:]
    source = source[:ready] + variables + "\n\n" + source[ready:]
    if source.count('"peers": []') != 1:
        raise ValueError("Reference diagnostic insertion point changed")
    source = source.replace('"peers": []', '"reference": _reference_evidence(), "peers": []')
    script.write_text(source)
    (project / "reference-options.json").write_text(
        json.dumps(
            {
                "godot_offer": args.godot_offer,
                "safe_receive": args.safe_receive,
                "mixed_traffic": args.mixed_traffic,
                "credit_transport": args.credit_transport,
                "slow_receiver": getattr(args, "slow_receiver", False),
            }
        )
    )
    preset = project / "export_presets.cfg"
    preset.write_text(
        preset.read_text().replace('include_filter=""', 'include_filter="reference-options.json"')
    )
    interop.checked(
        [args.godot, "--headless", "--path", str(project), "--editor", "--import"],
        directory / "import.log",
    )
    if web:
        interop.checked(
            [args.godot, "--headless", "--path", str(project), "--export-debug", "Web"],
            directory / "export.log",
        )
    return project


def assess(args: argparse.Namespace, directory: Path, *, web: bool) -> dict[str, object]:
    directory.mkdir(parents=True)
    project = prepare(args, directory, web=web)
    assets = directory / "assets"
    assets.mkdir()
    shutil.copytree(args.reference_assets, assets / "reference")
    shutil.copy2(ROOT / "tests/smoke/webrtc_reference.js", assets / "assess.js")
    (assets / "index.html").write_text(
        '<link rel="icon" href="data:,"><script type="module" src="/assess.js"></script>'
    )
    if web:
        shutil.copytree(project / "build/web", assets / "godot")

    class Handler(interop.RelayHandler):  # type: ignore[name-defined,misc]
        queues: ClassVar[list[list[object]]] = [[], []]
        lock = threading.Lock()
        observation = interop.RelayObservation()
        credit_delayed = threading.Event()

        def do_GET(self) -> None:
            delay_ms = getattr(args, "http_credit_delay_ms", 0)
            hold = False
            if (
                delay_ms
                and self.path == f"/signal/{0 if web else 1}"
                and not self.credit_delayed.is_set()
            ):
                with self.lock:
                    hold = any(
                        isinstance(message, dict)
                        and str(message.get("marker", "")).startswith("snapshot-ack-1-")
                        for message in self.queues[0 if web else 1]
                    )
                    if hold:
                        self.credit_delayed.set()
                if hold:
                    time.sleep(delay_ms / 1000)
            super().do_GET()

    server = ThreadingHTTPServer(
        ("127.0.0.1", 0), functools.partial(Handler, directory=str(assets))
    )
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{server.server_port}"
    messages: list[str] = []
    reference_messages: list[str] = []
    native = None
    observations: dict[str, Observation] = {}
    report: dict[str, object] = {
        "assessment_complete": False,
        "driver_error": "",
        "runtime": "web" if web else "native",
        "safe_receive": args.safe_receive,
        "godot_offer": args.godot_offer,
        "mixed_traffic": args.mixed_traffic,
        "credit_transport": args.credit_transport,
        "slow_receiver": getattr(args, "slow_receiver", False),
        "http_credit_delay_ms": getattr(args, "http_credit_delay_ms", 0),
        "godot": args.godot,
        "reference_revision": args.reference_revision,
    }
    try:
        with (directory / "godot.log").open("w") as log, sync_playwright() as playwright:
            browser = playwright.chromium.launch(
                headless=True,
                executable_path=args.chromium,
                args=["--no-sandbox", "--enable-unsafe-swiftshader"],
            )
            try:
                reference = browser.new_page()
                watch_page(reference, reference_messages)
                reference_observation = observe_page(reference, url)
                observations["reference"] = reference_observation
                reference.goto(url)
                reference.wait_for_function("typeof window.runReference === 'function'")
                reference.evaluate(
                    "([seat, offer, mixed, credit]) => { void window.runReference(seat, offer, mixed, credit); }",
                    [1 if web else 0, args.godot_offer, args.mixed_traffic, args.credit_transport],
                )
                if web:
                    page = browser.new_page()
                    watch_page(page, messages)
                    observations["godot"] = observe_page(page, url)
                    page.goto(url + "/godot/index.html")
                else:
                    native = subprocess.Popen(  # noqa: S603
                        [args.godot, "--headless", "--path", str(project), "--", url],
                        stdout=log,
                        stderr=subprocess.STDOUT,
                    )
                reference.wait_for_function(
                    "window.referenceDone === true || window.referenceError !== null", timeout=40000
                )
                result = reference.evaluate(
                    "({phases:window.referenceResults, error:window.referenceError, done:window.referenceDone === true})"
                )
                driver_error = ""
                if native:
                    native.wait(timeout=10)
                    log.flush()
                    output = (directory / "godot.log").read_text()
                else:
                    driver_error = wait_for_godot(page, messages)
                    output = "\n".join(messages)
                    log.write(output)
                phases = [
                    json.loads(line.removeprefix("WEBRTC_REFERENCE_PHASE "))
                    for line in output.splitlines()
                    if line.startswith("WEBRTC_REFERENCE_PHASE ")
                ]
                complete = (
                    result["done"]
                    and not result["error"]
                    and [phase["phase"] for phase in phases] == [1, 2]
                    and [phase["phase"] for phase in result["phases"]] == [1, 2]
                    and interop.seat_evidence(output, 1 if web else 0)["passed"]
                    and (native is None or native.returncode == 0)
                    and not page_failed(reference_messages)
                    and not page_failed(messages)
                    and not driver_error
                )
                gameplay = (
                    complete
                    and (
                        not getattr(args, "http_credit_delay_ms", 0)
                        or Handler.credit_delayed.is_set()
                    )
                    and all(
                        gameplay_phase_passed(
                            godot,
                            mixed_traffic=args.mixed_traffic,
                            credit_transport=args.credit_transport,
                            slow_receiver=getattr(args, "slow_receiver", False),
                        )
                        and gameplay_phase_passed(
                            ref,
                            mixed_traffic=args.mixed_traffic,
                            credit_transport=args.credit_transport,
                        )
                        and (not args.safe_receive or godot.get("same_receiver") is True)
                        for godot, ref in zip(phases, result["phases"], strict=True)
                    )
                )
                report.update(
                    {
                        "assessment_complete": complete,
                        "driver_error": driver_error,
                        "gameplay_passed": gameplay,
                        "browser": browser.version,
                        "reference_engine_sha256": hashlib.sha256(
                            (args.reference_assets / "engine.js").read_bytes()
                        ).hexdigest(),
                        "godot_phases": phases,
                        "reference": result,
                    }
                )
            finally:
                report["browser_observations"] = {
                    name: observer.snapshot() for name, observer in observations.items()
                }
                report["relay_observation"] = Handler.observation.snapshot()
                browser.close()
    except Exception as exc:
        report.update(
            assessment_complete=False,
            driver_error=f"{type(exc).__name__}: {exc}",
        )
    finally:
        if native is not None and native.poll() is None:
            native.kill()
            native.wait(timeout=10)
        report["http_credit_delay_applied"] = Handler.credit_delayed.is_set()
        server.shutdown()
        server.server_close()
        if "relay_observation" not in report:
            report["relay_observation"] = Handler.observation.snapshot()
        if web:
            (directory / "godot.log").write_text("\n".join(messages))
        output = (directory / "godot.log").read_text()
        report["godot_evidence"] = interop.seat_evidence(output, 1 if web else 0)
        report["godot_phases"] = phase_evidence(output)
        report["reference_phases"] = phase_evidence("\n".join(reference_messages))
        report["engine_banner"] = next(
            (line for line in output.splitlines() if line.startswith("Godot Engine")), ""
        )
        report["godot_errors"] = [line for line in messages if page_failed([line])]
        report["reference_errors"] = [line for line in reference_messages if page_failed([line])]
        (directory / "reference.log").write_text("\n".join(reference_messages))
        (directory / "assessment.json").write_text(json.dumps(report, indent=2) + "\n")
    if not report.get("assessment_complete"):
        raise RuntimeError(f"Incomplete reference assessment; see {directory}")
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default="godot")
    parser.add_argument("--native-extension", type=Path, required=True)
    parser.add_argument(
        "--reference-assets",
        type=Path,
        required=True,
        help="Directory containing engine.js and its imports",
    )
    parser.add_argument(
        "--reference-revision", required=True, help="Source commit used to build the Engine modules"
    )
    parser.add_argument(
        "--runtime",
        choices=("all", "native", "web"),
        default="all",
        help="Select Godot runtimes to assess",
    )
    parser.add_argument(
        "--offerer",
        choices=("both", "godot", "reference"),
        default="both",
        help="Select the offer role to assess",
    )
    parser.add_argument("--chromium")
    parser.add_argument(
        "--safe-receive", action="store_true", help="Read through the RPC-safe peer"
    )
    parser.add_argument(
        "--mixed-traffic",
        action="store_true",
        help="Interleave exact position samples with snapshots",
    )
    parser.add_argument(
        "--credit-transport",
        choices=("http", "webrtc"),
        default="http",
        help="Return consumption credit over HTTP markers or reliable data-channel packets",
    )
    parser.add_argument(
        "--slow-receiver",
        action="store_true",
        help="Pause Godot reads for 1500 ms and require queued snapshot recovery",
    )
    parser.add_argument(
        "--http-credit-delay-ms",
        type=int,
        default=0,
        help="Hold one first-generation reference credit GET for 0-8000 ms",
    )
    parser.add_argument("--output", type=Path)
    parser.add_argument(
        "--require-gameplay",
        action="store_true",
        help="Fail when any pairing lacks exact probes and snapshots in both generations",
    )
    args = parser.parse_args()
    if not 0 <= args.http_credit_delay_ms <= 8000:
        parser.error("--http-credit-delay-ms must be between 0 and 8000")
    if args.http_credit_delay_ms and args.credit_transport != "http":
        parser.error("--http-credit-delay-ms needs --credit-transport http")
    directory = args.output or Path(tempfile.mkdtemp(prefix="sf-reference-assessment-"))
    results = []
    runtimes = (False, True) if args.runtime == "all" else (args.runtime == "web",)
    offers = (True, False) if args.offerer == "both" else (args.offerer == "godot",)
    for web in runtimes:
        for godot_offer in offers:
            args.godot_offer = godot_offer
            name = ("web" if web else "native") + (
                "-godot-offer" if godot_offer else "-reference-offer"
            )
            result = assess(args, directory / name, web=web)
            results.append(result)
            (directory / "summary.json").write_text(json.dumps(results, indent=2) + "\n")
            print(f"{name}: assessed; gameplay={result['gameplay_passed']}")
    if args.require_gameplay and not all(result["gameplay_passed"] for result in results):
        raise RuntimeError(
            f"Reference gameplay is unsupported for one or more pairings; see {directory}"
        )


if __name__ == "__main__":
    main()
