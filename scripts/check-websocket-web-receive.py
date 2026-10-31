#!/usr/bin/env python3
"""Run exact finite WebSocket bursts at the Godot Web callback boundary."""

from __future__ import annotations

import argparse
import base64
import functools
import hashlib
import json
import shutil
import struct
import subprocess
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import cast

ROOT = Path(__file__).resolve().parents[1]
BODY_BYTES = 4096
PACKETS = 64


class ApplicationCredit:
    def __init__(self, credit_bytes: int, credit_packets: int = 0) -> None:
        self.credit_bytes = credit_bytes
        self.credit_packets = credit_packets
        self.sent = 0
        self.acknowledged = 0
        self.started = False
        self.receipts: list[dict[str, int]] = []
        self.windows: list[dict[str, int]] = []

    def receive(self, command: str) -> range:
        if command == "start":
            if self.started:
                raise ValueError("duplicate application-credit start")
            self.started = True
        else:
            if not self.started or not command.startswith("ack:"):
                raise ValueError("application receipt before start or invalid command")
            prefix = command[4:]
            if not prefix.isascii() or not prefix.isdecimal():
                raise ValueError("invalid application receipt")
            received = int(prefix)
            if not self.acknowledged < received <= self.sent:
                raise ValueError("application receipt is stale or beyond offered prefix")
            self.acknowledged = received
            self.receipts.append({"prefix_packets": received, "received_ns": time.monotonic_ns()})
        start = self.sent
        while self.sent <= PACKETS:
            if self.sent == PACKETS and self.acknowledged != PACKETS:
                break
            if (self.sent - self.acknowledged + 1) * BODY_BYTES > self.credit_bytes:
                break
            if self.credit_packets and self.sent - self.acknowledged + 1 > self.credit_packets:
                break
            self.sent += 1
        self.windows.append(
            {
                "acknowledged_packets": self.acknowledged,
                "offered_packets": self.sent,
                "outstanding_bytes": (self.sent - self.acknowledged) * BODY_BYTES,
            }
        )
        return range(start, self.sent)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def frame(sequence: int) -> bytes:
    body = (f"{sequence:08d}" + "x" * (BODY_BYTES - 8)).encode()
    return b"\x81\x7e" + struct.pack("!H", len(body)) + body


def receive_evidence(
    trace: dict[str, object], result: dict[str, object], commands: list[dict[str, object]]
) -> dict[str, object]:
    sockets = cast(list[dict[str, object]], trace.get("sockets", []))
    socket = sockets[0] if len(sockets) == 1 else {}
    callbacks = cast(list[dict[str, object]], socket.get("callbacks", []))
    drops = cast(list[dict[str, object]], trace.get("rejections", []))
    delivered = cast(list[int], result.get("received", []))
    sequences = [int(cast(str, row["prefix"])[:8]) for row in callbacks]
    scoped = [cast(dict[str, object], row["callback"]) for row in drops if row.get("callback")]
    rejected = [int(cast(str, row["prefix"])[:8]) for row in scoped]
    offered = [
        sequence
        for command in commands
        for sequence in range(
            cast(int, command["start"]), cast(int, command["start"]) + cast(int, command["count"])
        )
    ]
    complete = (
        len(sockets) == 1
        and trace.get("omitted") == 0
        and socket.get("omitted") == 0
        and socket.get("received") == PACKETS + 1
        and sequences == list(range(PACKETS + 1))
        and all(
            row.get("ordinal") == index + 1
            and row.get("connection") == socket.get("connection")
            and row.get("bytes") == BODY_BYTES
            for index, row in enumerate(callbacks)
        )
        and len(scoped) == len(drops)
        and len(set(rejected)) == len(rejected)
        and all(
            row.get("callback_scope") == "engine_onmessage" and row.get("callback") in callbacks
            for row in drops
        )
        and not set(rejected).intersection(delivered)
    )
    unread = [sequence for sequence in sequences if sequence not in delivered]
    return {
        "trace_complete": complete,
        "rejected_sequences": rejected,
        "callback_not_read_sequences": unread,
        "unresolved_callback_sequences": [
            sequence for sequence in unread if sequence not in rejected
        ],
        "server_offer_complete": offered == list(range(PACKETS + 1)),
        "reliable_delivery": complete
        and not drops
        and delivered == list(range(PACKETS + 1))
        and offered == list(range(PACKETS + 1)),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default="godot")
    parser.add_argument("--chromium", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--capacity", type=int, default=0)
    parser.add_argument("--max-queued-packets", type=int, default=0)
    parser.add_argument("--credit-bytes", type=int, default=0)
    parser.add_argument("--credit-packets", type=int, default=0)
    parser.add_argument("--credit-transport", choices=("local", "app-ack"), default="local")
    parser.add_argument("--ack-delay-ms", type=int, default=0)
    parser.add_argument("--hold-ms", type=int, default=100)
    args = parser.parse_args()
    if args.capacity < 0 or 0 < args.capacity < BODY_BYTES or args.max_queued_packets < 0:
        parser.error("capacity must admit a body; zero capacity/count keeps engine defaults")
    if args.credit_bytes < 0 or 0 < args.credit_bytes < BODY_BYTES:
        parser.error("credit must be zero or admit one body")
    if args.credit_packets < 0:
        parser.error("credit packets must be zero or positive")
    if args.credit_packets and args.credit_transport != "app-ack":
        parser.error("credit packets require application ACK credit")
    if args.credit_transport == "app-ack" and args.credit_bytes == 0:
        parser.error("application ACK credit requires a positive byte window")
    if not 0 <= args.ack_delay_ms <= 1000 or (
        args.ack_delay_ms and args.credit_transport != "app-ack"
    ):
        parser.error("ACK delay must be 0..1000 ms and requires application ACK credit")
    if not 1 <= args.hold_ms <= 1000:
        parser.error("hold must be 1..1000 ms")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    project = output / "project"
    project.mkdir()
    shutil.copy2(ROOT / "tests/smoke/websocket_receive_boundary.gd", project)
    (project / "main.tscn").write_text(
        "[gd_scene load_steps=2 format=3]\n"
        '[ext_resource type="Script" path="res://websocket_receive_boundary.gd" id="1"]\n'
        '[node name="ReceiveBoundary" type="Node"]\nscript = ExtResource("1")\n'
    )
    debug = (ROOT / "project.godot").read_text().split("[debug]\n", 1)[1].split("\n[", 1)[0]
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="WebSocket receive boundary"\n'
        'run/main_scene="res://main.tscn"\n[rendering]\nrenderer/rendering_method="gl_compatibility"\n'
        + "[debug]\n"
        + debug
    )
    preset = (ROOT / "export_presets.cfg").read_text()
    preset = preset.replace('include_filter=""', 'include_filter="receive-options.json"')
    (project / "export_presets.cfg").write_text(preset)
    (project / "build/web").mkdir(parents=True)
    commands: list[dict[str, object]] = []
    server_errors: list[str] = []
    application_credit = ApplicationCredit(args.credit_bytes, args.credit_packets)

    class Handler(SimpleHTTPRequestHandler):
        def log_message(self, _format: str, *_args: object) -> None:
            pass

        def end_headers(self) -> None:
            self.send_header("Cross-Origin-Opener-Policy", "same-origin")
            self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
            super().end_headers()

        def do_GET(self) -> None:
            if self.path != "/receive-boundary":
                super().do_GET()
                return
            self.connection.settimeout(25)
            key = self.headers["Sec-WebSocket-Key"]
            accept = base64.b64encode(
                hashlib.sha1(  # noqa: S324
                    (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()
                ).digest()
            ).decode()
            self.send_response(101, "Switching Protocols")
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.send_header("Sec-WebSocket-Accept", accept)
            self.end_headers()
            try:
                while True:
                    header = self.rfile.read(2)
                    if len(header) != 2:
                        return
                    if header[0] & 15 == 8:
                        return
                    length = header[1] & 127
                    if header[0] != 0x81 or not header[1] & 128 or length > 125:
                        raise ValueError("unexpected command frame")
                    mask = self.rfile.read(4)
                    payload = self.rfile.read(length)
                    if len(mask) != 4 or len(payload) != length:
                        raise ValueError("short command frame")
                    command = bytes(byte ^ mask[i % 4] for i, byte in enumerate(payload)).decode()
                    if args.credit_transport == "app-ack":
                        sequences = application_credit.receive(command)
                        start, count = sequences.start, len(sequences)
                    else:
                        start, count = (int(value) for value in command.split(":"))
                    if (
                        not 0 <= start <= PACKETS
                        or not 0 <= count <= PACKETS
                        or (count == 0 and args.credit_transport != "app-ack")
                        or start + count > PACKETS + 1
                    ):
                        raise ValueError("invalid finite burst")
                    for sequence in range(start, start + count):
                        self.connection.sendall(frame(sequence))
                    if count:
                        commands.append(
                            {"start": start, "count": count, "completed_ns": time.monotonic_ns()}
                        )
            except (OSError, ValueError) as exc:
                server_errors.append(str(exc))

    server = ThreadingHTTPServer(
        ("127.0.0.1", 0), functools.partial(Handler, directory=str(project / "build/web"))
    )
    batch_packets = (
        PACKETS if args.credit_bytes == 0 else min(PACKETS, args.credit_bytes // BODY_BYTES)
    )
    if args.credit_packets:
        batch_packets = min(batch_packets, args.credit_packets)
    batches = (PACKETS + batch_packets - 1) // batch_packets
    watchdog_ms = 5000 + batches * (args.hold_ms + args.ack_delay_ms + 1000) + 2000
    options = {
        "watchdog_ms": watchdog_ms,
        "url": f"ws://127.0.0.1:{server.server_port}/receive-boundary",
        "capacity": args.capacity,
        "max_queued_packets": args.max_queued_packets,
        "credit_bytes": args.credit_bytes,
        "credit_packets": args.credit_packets,
        "credit_transport": args.credit_transport,
        "ack_delay_ms": args.ack_delay_ms,
        "hold_ms": args.hold_ms,
    }
    (project / "receive-options.json").write_text(json.dumps(options))
    sources = [
        Path(__file__).resolve(),
        ROOT / "scripts/websocket-browser-observation.js",
        ROOT / "tests/smoke/websocket_receive_boundary.gd",
    ]
    engine = Path(shutil.which(args.godot) or args.godot).resolve()
    report: dict[str, object] = {
        "passed": False,
        "options": options,
        "engine_sha256": digest(engine),
        "source_sha256": {str(path.relative_to(ROOT)): digest(path) for path in sources},
        "credit_scope": (
            "complete callback message bytes; cumulative exact-prefix WebSocket receipts"
            if args.credit_transport == "app-ack"
            else "local consumer body bytes; no network acknowledgement"
        )
        + (f"; at most {args.credit_packets} outstanding packets" if args.credit_packets else ""),
    }
    lines: list[str] = []
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        for name, flags in (
            ("import", ["--editor", "--import"]),
            ("export", ["--export-debug", "Web"]),
        ):
            with (output / f"{name}.log").open("w") as log:
                subprocess.run(  # noqa: S603
                    [str(engine), "--headless", "--path", str(project), *flags],
                    stdout=log,
                    stderr=subprocess.STDOUT,
                    timeout=90,
                    check=True,
                )
        for name in ("import", "export"):
            text = (output / f"{name}.log").read_text()
            if "SCRIPT ERROR" in text or "ERROR:" in text:
                raise RuntimeError(f"Engine {name} reported errors")
        report["export_sha256"] = {
            path.name: digest(path) for path in (project / "build/web").iterdir() if path.is_file()
        }
        from playwright.sync_api import sync_playwright

        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(
                executable_path=str(args.chromium) if args.chromium else None,
                headless=True,
                args=["--no-sandbox"],
            )
            report["browser"] = browser.version
            page = browser.new_page()
            page.add_init_script(path=ROOT / "scripts/websocket-browser-observation.js")
            page.on(
                "console",
                lambda message: lines.append(
                    ("CONSOLE_ERROR " if message.type == "error" else "") + message.text
                ),
            )
            page.on("pageerror", lambda error: lines.append("PAGE_ERROR " + str(error)))
            try:
                page.goto(f"http://127.0.0.1:{server.server_port}/index.html")
                deadline = time.monotonic() + watchdog_ms / 1000 + 10
                while not any(line.startswith("WEBSOCKET_WEB_RESULT ") for line in lines):
                    if time.monotonic() > deadline:
                        raise RuntimeError("Web finite burst did not finish")
                    page.wait_for_timeout(20)
            finally:
                try:
                    report["receive_trace"] = page.evaluate("window.websocketReceiveSnapshot()")
                except Exception as exc:
                    report["receive_trace_error"] = f"{type(exc).__name__}: {exc}"
                    report["receive_trace"] = {}
                finally:
                    browser.close()
        records = [
            json.loads(line.split(" ", 1)[1])
            for line in lines
            if line.startswith("WEBSOCKET_WEB_RESULT ")
        ]
        report["results"] = records
        evidence = receive_evidence(
            cast(dict[str, object], report["receive_trace"]),
            records[0] if len(records) == 1 else {},
            commands,
        )
        report["receive_evidence"] = evidence
        application_complete = (
            application_credit.started
            and application_credit.acknowledged == PACKETS
            and application_credit.sent == PACKETS + 1
            and all(
                window["outstanding_bytes"] <= args.credit_bytes
                for window in application_credit.windows
            )
            and (
                not args.credit_packets
                or all(
                    window["offered_packets"] - window["acknowledged_packets"]
                    <= args.credit_packets
                    for window in application_credit.windows
                )
            )
        )
        report["passed"] = (
            len(records) == 1
            and records[0].get("passed") is True
            and evidence["reliable_delivery"] is True
            and not report.get("receive_trace_error")
            and not server_errors
            and (args.credit_transport != "app-ack" or application_complete)
            and not any("ERROR" in line or "Dropping data" in line for line in lines)
        )
    except Exception as exc:
        report["error"] = f"{type(exc).__name__}: {exc}"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
        report["commands"] = commands
        report["server_errors"] = server_errors
        if args.credit_transport == "app-ack":
            report["application_receipts"] = application_credit.receipts
            report["application_sent_packets"] = application_credit.sent
            report["application_acknowledged_packets"] = application_credit.acknowledged
            report["application_windows"] = application_credit.windows
        (output / "godot.log").write_text("\n".join(lines) + "\n")
        (output / "assessment.json").write_text(json.dumps(report, indent=2) + "\n")
    print(
        json.dumps(
            {"passed": report["passed"], "error": report.get("error"), "output": str(output)}
        )
    )
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
