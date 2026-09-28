#!/usr/bin/env python3
"""Serve the weekly browser smoke over HTTPS and a small WSS handshake."""

import argparse
import base64
import hashlib
import json
import mimetypes
import os
import shutil
import signal
import ssl
import struct
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlsplit

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
MAX_FRAME = 65535


def emit(event: str, **fields: object) -> None:
    print("SMOKE " + json.dumps({"event": event, **fields}), flush=True)


def frame(text: str) -> bytes:
    payload = text.encode("utf-8")
    if len(payload) > MAX_FRAME:
        raise ValueError("smoke frame too large")
    header = (
        bytes((0x81, len(payload)))
        if len(payload) < 126
        else b"\x81\x7e" + struct.pack("!H", len(payload))
    )
    return header + payload


class SmokeHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    web_root: Path
    expected_origin: str
    websocket: bool

    def log_message(self, _format: str, *_args: object) -> None:
        pass

    def do_GET(self) -> None:
        if self.websocket:
            self.serve_websocket()
        else:
            self.serve_file()

    def serve_file(self) -> None:
        try:
            url_path = unquote(urlsplit(self.path).path)
            candidate = (self.web_root / url_path.lstrip("/")).resolve()
            if url_path == "/":
                candidate = self.web_root / "index.html"
            if not candidate.is_relative_to(self.web_root) or not candidate.is_file():
                self.send_error(404)
                return
            source = candidate.open("rb")
            size = os.fstat(source.fileno()).st_size
        except (OSError, ValueError):
            self.send_error(400)
            return
        with source:
            self.send_response(200)
            self.send_header(
                "Content-Type",
                mimetypes.guess_type(candidate.name)[0] or "application/octet-stream",
            )
            self.send_header("Content-Length", str(size))
            self.end_headers()
            shutil.copyfileobj(source, self.wfile, length=65536)

    def serve_websocket(self) -> None:
        origin = self.headers.get("Origin")
        origin_ok = origin == self.expected_origin
        emit("ws_open", origin=origin, origin_ok=origin_ok)
        key = self.headers.get("Sec-WebSocket-Key", "")
        try:
            valid_key = len(base64.b64decode(key, validate=True)) == 16
        except ValueError:
            valid_key = False
        if not origin_ok or not valid_key or self.headers.get("Upgrade", "").lower() != "websocket":
            self.send_error(403)
            return
        accept = base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()  # noqa: S324
        self.send_response(101, "Switching Protocols")
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        try:
            while True:
                header = self.rfile.read(2)
                if not header:
                    return
                if len(header) != 2:
                    raise ValueError("short frame header")
                opcode = header[0] & 15
                masked = bool(header[1] & 128)
                length = header[1] & 127
                if length == 126:
                    length = struct.unpack("!H", self.rfile.read(2))[0]
                elif length == 127:
                    length = struct.unpack("!Q", self.rfile.read(8))[0]
                if not masked or opcode not in (1, 8, 9) or length > MAX_FRAME:
                    raise ValueError("unexpected client frame")
                mask = self.rfile.read(4)
                payload = self.rfile.read(length)
                if len(mask) != 4 or len(payload) != length:
                    raise ValueError("short client frame")
                decoded = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
                if opcode == 8:
                    emit("ws_close")
                    return
                if opcode == 9:
                    continue
                try:
                    message_type = str(json.loads(decoded).get("type", ""))
                except (UnicodeDecodeError, ValueError, AttributeError):
                    message_type = "<unparseable>"
                emit("message", type=message_type)
                if message_type == "Authenticate":
                    self.wfile.write(
                        frame(
                            json.dumps(
                                {
                                    "type": "Authenticated",
                                    "data": {
                                        "app_name": "web-smoke",
                                        "organization": "smoke",
                                        "rate_limits": {
                                            "per_minute": 60,
                                            "per_hour": 600,
                                            "per_day": 6000,
                                        },
                                    },
                                }
                            )
                        )
                    )
                    self.wfile.flush()
                elif message_type == "Ping":
                    self.wfile.write(frame('{"type":"Pong"}'))
                    self.wfile.flush()
                    emit("pong_sent")
        except (OSError, ValueError, struct.error) as error:
            emit("ws_fatal", reason=str(error))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--web-root", type=Path, default=Path("build/web"))
    parser.add_argument("--https-port", type=int, default=8443)
    parser.add_argument("--wss-port", type=int, default=8444)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--expected-origin")
    parser.add_argument("--key", default="build/smoke-certs/key.pem")
    parser.add_argument("--cert", default="build/smoke-certs/cert.pem")
    args = parser.parse_args()
    root = args.web_root.resolve()
    origin = args.expected_origin or f"https://{args.host}:{args.https_port}"
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(args.cert, args.key)

    servers = []
    for role, port, websocket in (("https", args.https_port, False), ("wss", args.wss_port, True)):
        handler = type(
            f"{role.upper()}Handler",
            (SmokeHandler,),
            {
                "web_root": root,
                "expected_origin": origin,
                "websocket": websocket,
            },
        )
        server = ThreadingHTTPServer((args.host, port), handler)
        server.daemon_threads = True
        server.socket = context.wrap_socket(server.socket, server_side=True)
        servers.append(server)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        emit("listening", role=role, port=port)

    stopped = threading.Event()
    signal.signal(signal.SIGTERM, lambda _signum, _frame: stopped.set())
    signal.signal(signal.SIGINT, lambda _signum, _frame: stopped.set())
    stopped.wait()
    for server in servers:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
