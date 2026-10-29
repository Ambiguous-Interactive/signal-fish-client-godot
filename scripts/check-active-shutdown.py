#!/usr/bin/env python3
"""Qualify active relay sends and cached mesh retirement on service shutdown."""

from __future__ import annotations

import argparse
import functools
import hashlib
import importlib.util
import json
import os
import shutil
import signal
import socket
import subprocess
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import cast

from delayed_tcp_proxy import DelayedTCPProxy

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("interop", ROOT / "scripts/check-webrtc-interop.py")
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("Could not load WebRTC project preparation")
interop = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(interop)

WEB_SOCKET_TRACE = """
(() => {
  const Original = window.WebSocket;
  let next = 0;
  window.WebSocket = class extends Original {
    constructor(url, protocols) {
      super(url, protocols);
      if (!String(url).endsWith('/v3/ws')) return;
      this.drillConnection = ++next;
      for (const event of ['open', 'error', 'close']) {
        this.addEventListener(event, (value) => this.drillTrace(event, value.code));
      }
    }
    drillTrace(event, code) {
      console.log('ACTIVE_SHUTDOWN_BROWSER_SOCKET ' + JSON.stringify({
        connection: this.drillConnection, event, code,
        browser_ms: performance.now(), state: super.readyState
      }));
    }
    get readyState() {
      const state = super.readyState;
      if (this.drillConnection && (state === 2 || state === 3)) {
        this.drillTrace('terminal_state_read');
      }
      return state;
    }
  };
})();
"""


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        checksum = hashlib.sha256()
        while chunk := stream.read(65536):
            checksum.update(chunk)
        return checksum.hexdigest()


def free_port() -> int:
    with socket.socket() as bound:
        bound.bind(("127.0.0.1", 0))
        return cast(int, bound.getsockname()[1])


class Service:
    def __init__(self, binary: Path, directory: Path, port: int) -> None:
        self.binary = binary
        self.directory = directory
        self.port = port
        self.process: subprocess.Popen[bytes] | None = None
        self.log = (directory / "server.log").open("wb")
        self.stopped = False
        self.starts = 0
        self.faults = 0
        self.lock = threading.Lock()

    def start(self) -> None:
        self.process = subprocess.Popen(  # noqa: S603
            [str(self.binary)], cwd=self.directory, stdout=self.log, stderr=subprocess.STDOUT
        )
        self.starts += 1
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise RuntimeError("Service exited before listening")
            try:
                with socket.create_connection(("127.0.0.1", self.port), timeout=0.1):
                    return
            except OSError:
                time.sleep(0.02)
        raise RuntimeError("Service did not listen within 10 seconds")

    def fault(self, mode: str) -> None:
        if self.faults != 0 or self.process is None or self.process.poll() is not None:
            raise RuntimeError("Shutdown requires one live owned service")
        self.faults += 1
        if mode == "graceful":
            self.process.terminate()
        elif mode == "reset":
            self.process.kill()
        else:
            os.kill(self.process.pid, signal.SIGSTOP)
            self.stopped = True

    def stop(self) -> None:
        if self.process is None:
            return
        if self.stopped:
            os.kill(self.process.pid, signal.SIGCONT)
            self.stopped = False
        if self.process.poll() is None:
            self.process.terminate()
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=5)

    def restart(self) -> None:
        if self.faults != 1 or self.starts != 1:
            raise RuntimeError("Restart requires the shutdown control")
        self.stop()
        self.start()


def prepare(
    args: argparse.Namespace, directory: Path, runtime: str, options: dict[str, object]
) -> Path:
    project = directory / "project"
    interop.prepare(project, args.native_extension if runtime == "native" else None, ROOT)
    scene = "tests/smoke/active_shutdown.tscn"
    shutil.copy2(ROOT / "tests/smoke/active_shutdown.gd", project / "tests/smoke")
    (project / scene).write_text(
        "[gd_scene load_steps=2 format=3]\n"
        '[ext_resource type="Script" path="res://tests/smoke/active_shutdown.gd" id="1"]\n'
        '[node name="ActiveShutdown" type="Node"]\nscript = ExtResource("1")\n'
    )
    settings = project / "project.godot"
    settings.write_text(settings.read_text().replace(interop.SCENE, scene))
    (project / "shutdown-options.json").write_text(json.dumps(options))
    preset = project / "export_presets.cfg"
    preset.write_text(
        preset.read_text().replace('include_filter=""', 'include_filter="shutdown-options.json"')
    )
    interop.checked(
        [args.godot, "--headless", "--path", str(project), "--editor", "--import"],
        directory / "import.log",
    )
    if runtime == "web":
        interop.checked(
            [args.godot, "--headless", "--path", str(project), "--export-debug", "Web"],
            directory / "export.log",
        )
    return project


def assess(args: argparse.Namespace, runtime: str, mode: str, directory: Path) -> dict[str, object]:
    directory.mkdir(parents=True)
    server_directory = directory / "server"
    server_directory.mkdir()
    config = json.loads(args.server_config.read_text())
    port = free_port()
    config["port"] = port
    config["server"]["drain_grace_secs"] = 3
    (server_directory / "config.json").write_text(json.dumps(config, indent=2) + "\n")
    service = Service(args.server_binary, server_directory, port)
    proxy = (
        DelayedTCPProxy(port, args.network_delay_ms, args.network_chunk_bytes)
        if args.network_delay_ms or args.network_chunk_bytes != 65536
        else None
    )
    errors: list[str] = []

    class Handler(SimpleHTTPRequestHandler):
        def end_headers(self) -> None:
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Cross-Origin-Opener-Policy", "same-origin")
            self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
            super().end_headers()

        def log_message(self, _format: str, *arguments: object) -> None:
            pass

        def do_GET(self) -> None:
            if self.path not in ("/shutdown", "/restart"):
                super().do_GET()
                return
            try:
                with service.lock:
                    service.fault(mode) if self.path == "/shutdown" else service.restart()
                self.send_response(200)
            except Exception as exc:
                errors.append(f"{self.path}: {exc}")
                self.send_response(500)
            self.send_header("Content-Length", "0")
            self.end_headers()

    http = ThreadingHTTPServer(
        ("127.0.0.1", 0), functools.partial(Handler, directory=str(directory / "project/build/web"))
    )
    http.daemon_threads = False
    thread = threading.Thread(target=http.serve_forever, daemon=True)
    thread.start()
    options = {
        "service_url": f"ws://127.0.0.1:{port}/v3/ws",
        "control_url": f"http://127.0.0.1:{http.server_port}",
        "mode": mode,
        "relay_packets_per_frame": args.relay_packets_per_frame,
        "relay_packets_per_second": args.relay_packets_per_second,
        "relay_credit_bytes": args.relay_credit_bytes,
        "receive_pause_ms": args.receive_pause_ms,
        "inbound_buffer_bytes": args.inbound_buffer_bytes,
        "max_queued_packets": args.max_queued_packets,
    }
    report: dict[str, object] = {"runtime": runtime, "mode": mode, "passed": False}
    output = ""
    try:
        if proxy is not None:
            proxy.start()
            options["service_url"] = f"ws://127.0.0.1:{proxy.port}/v3/ws"
        project = prepare(args, directory, runtime, options)
        report["identities"] = interop.setup_identities([args.godot, "--path", str(project)])
        service.start()
        if runtime == "native":
            command = [args.godot, "--headless", "--path", str(project)]
            report["command"] = command
            with (directory / "godot.log").open("w") as log:
                result = subprocess.run(  # noqa: S603
                    command, stdout=log, stderr=subprocess.STDOUT, timeout=70, check=False
                )
            report["returncode"] = result.returncode
            output = (directory / "godot.log").read_text()
        else:
            from playwright.sync_api import sync_playwright

            lines: list[str] = []
            with sync_playwright() as playwright:
                browser = playwright.chromium.launch(
                    executable_path=str(args.chromium) if args.chromium else None,
                    headless=True,
                    args=["--no-sandbox", "--autoplay-policy=no-user-gesture-required"],
                )
                report["browser"] = browser.version
                page = browser.new_page()
                page.add_init_script(WEB_SOCKET_TRACE)
                page.on(
                    "console",
                    lambda message: lines.append(
                        ("CONSOLE_ERROR " if message.type == "error" else "") + message.text
                    ),
                )
                page.on("pageerror", lambda error: lines.append("PAGE_ERROR " + str(error)))
                page.on("crash", lambda _: lines.append("BROWSER_CRASH"))
                try:
                    page.goto(str(options["control_url"]) + "/index.html", timeout=30000)
                    deadline = time.monotonic() + 70
                    while not any(line.startswith("ACTIVE_SHUTDOWN_RESULT ") for line in lines):
                        if time.monotonic() >= deadline:
                            raise RuntimeError("Web runtime did not finish within 70 seconds")
                        page.wait_for_timeout(20)
                finally:
                    browser.close()
                    output = "\n".join(lines)
                    (directory / "godot.log").write_text(output + "\n")
        records = [
            json.loads(line.split(" ", 1)[1])
            for line in output.splitlines()
            if line.startswith("ACTIVE_SHUTDOWN_RESULT ")
        ]
        terminals = [
            json.loads(line.split(" ", 1)[1])
            for line in output.splitlines()
            if line.startswith("ACTIVE_SHUTDOWN_TERMINAL ")
        ]
        generations = [
            json.loads(line.split(" ", 1)[1])
            for line in output.splitlines()
            if line.startswith("ACTIVE_SHUTDOWN_GENERATION ")
        ]
        report.update(
            browser_sockets=[
                json.loads(line.split(" ", 1)[1])
                for line in output.splitlines()
                if line.startswith("ACTIVE_SHUTDOWN_BROWSER_SOCKET ")
            ],
            generations=generations,
            results=records,
            terminals=terminals,
            service_starts=service.starts,
            shutdown_requests=service.faults,
            passed=(
                len(records) == 1
                and records[0].get("passed") is True
                and len(terminals) == 1
                and [generation.get("generation") for generation in generations] == [1, 2]
                and all(generation.get("complete") is True for generation in generations)
                and service.starts == 2
                and service.faults == 1
                and report.get("returncode", 0) == 0
                and not errors
                and not interop.engine_failed(output)
                and not any(
                    token in output for token in ("PAGE_ERROR", "CONSOLE_ERROR", "BROWSER_CRASH")
                )
            ),
        )
    except Exception as exc:
        report["error"] = f"{type(exc).__name__}: {exc}"
    finally:
        http.shutdown()
        thread.join(timeout=5)
        http.server_close()
        if proxy is not None and proxy.thread.is_alive():
            try:
                network = proxy.stop()
                report["network"] = network
                forwarded = network["forwarded_connections"]
                minimum = network["minimum_forward_delay_ms"]
                if (
                    not isinstance(forwarded, int)
                    or forwarded < 4
                    or not isinstance(minimum, (int, float))
                    or minimum < args.network_delay_ms - 0.1
                ):
                    errors.append("Proxy did not qualify four delayed bidirectional connections")
            except Exception as exc:
                errors.append(f"proxy stop: {exc}")
            if proxy.errors or errors:
                report["passed"] = False
        with service.lock:
            service.stop()
        service.log.close()
        report["control_errors"] = errors
        (directory / "assessment.json").write_text(json.dumps(report, indent=2) + "\n")
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server-binary", type=Path, required=True)
    parser.add_argument("--server-config", type=Path, required=True)
    parser.add_argument("--server-revision", required=True)
    parser.add_argument("--godot", default="godot")
    parser.add_argument("--native-extension", type=Path)
    parser.add_argument("--chromium", type=Path)
    parser.add_argument("--runtime", choices=("all", "native", "web"), default="all")
    parser.add_argument("--mode", choices=("all", "graceful", "reset", "stall"), default="all")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--relay-packets-per-frame", type=int, choices=range(1, 17), default=4)
    parser.add_argument("--relay-packets-per-second", type=int, default=0)
    parser.add_argument("--relay-credit-bytes", type=int, default=0)
    parser.add_argument("--inbound-buffer-bytes", type=int, default=0)
    parser.add_argument("--max-queued-packets", type=int, default=0)
    parser.add_argument("--receive-pause-ms", type=int, default=0)
    parser.add_argument("--network-delay-ms", type=int, default=0)
    parser.add_argument("--network-chunk-bytes", type=int, default=65536)
    args = parser.parse_args()
    if not 0 <= args.network_delay_ms <= 500 or not 1 <= args.network_chunk_bytes <= 65536:
        parser.error("Network delay must be 0..500 ms and chunk size 1..65536 bytes")
    if not 0 <= args.receive_pause_ms <= 1000:
        parser.error("Receive pause must be between 0 and 1000 milliseconds")
    if args.relay_packets_per_second < 0 or args.relay_credit_bytes < 0:
        parser.error("Relay rate and payload-byte credit must be nonnegative")
    if 0 < args.relay_credit_bytes < 4096:
        parser.error("Relay credit must admit at least one 4096-byte body")
    if args.inbound_buffer_bytes < 0 or args.max_queued_packets < 0:
        parser.error("Receive capacity must be nonnegative; zero uses the engine default")
    if 0 < args.inbound_buffer_bytes < 4096:
        parser.error("Receive capacity must admit a 4096-byte body and one packet")
    if args.runtime in ("all", "native") and args.native_extension is None:
        parser.error("--native-extension is required for native or all runtime")
    if os.name != "posix":
        parser.error("This local process control requires POSIX signals")
    args.server_binary = args.server_binary.resolve()
    if args.native_extension is not None:
        args.native_extension = args.native_extension.resolve()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    provenance = {
        "server_revision_declared": args.server_revision,
        "server_binary_sha256": digest(args.server_binary),
        "server_config_input_sha256": digest(args.server_config),
        "relay_packets_per_frame": args.relay_packets_per_frame,
        "relay_packets_per_second": args.relay_packets_per_second,
        "relay_credit_bytes": args.relay_credit_bytes,
        "receive_pause_ms": args.receive_pause_ms,
        "inbound_buffer_bytes": args.inbound_buffer_bytes,
        "max_queued_packets": args.max_queued_packets,
        "network_delay_ms": args.network_delay_ms,
        "network_chunk_bytes": args.network_chunk_bytes,
        "client_revision": subprocess.check_output(  # noqa: S603
            [shutil.which("git") or "git", "rev-parse", "HEAD"], cwd=ROOT, text=True, timeout=30
        ).strip(),
        "source_sha256": {
            str(path.relative_to(ROOT)): digest(path)
            for path in (
                Path(__file__).resolve(),
                ROOT / "scripts/delayed_tcp_proxy.py",
                ROOT / "scripts/check-webrtc-interop.py",
                ROOT / "tests/smoke/active_shutdown.gd",
                ROOT / "addons/signal_fish/webrtc/sf_webrtc_mesh.gd",
                ROOT / "addons/signal_fish/webrtc/sf_webrtc_multiplayer_peer.gd",
                ROOT / "addons/signal_fish/signal_fish_client.gd",
                ROOT / "addons/signal_fish/transport/sf_websocket_transport.gd",
            )
        },
    }
    (args.output / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    results = []
    for runtime in ("native", "web") if args.runtime == "all" else (args.runtime,):
        for mode in ("graceful", "reset", "stall") if args.mode == "all" else (args.mode,):
            result = assess(args, runtime, mode, args.output / f"{runtime}-{mode}")
            results.append(result)
            print(
                f"{runtime}-{mode}: passed={result['passed']} error={result.get('error', '')}",
                flush=True,
            )
    (args.output / "summary.json").write_text(json.dumps(results, indent=2) + "\n")
    return 0 if all(result["passed"] for result in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
