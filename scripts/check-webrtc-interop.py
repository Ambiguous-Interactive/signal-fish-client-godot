#!/usr/bin/env python3
"""Run the opt-in Godot native/browser mesh gameplay drill."""

import argparse
import functools
import json
import shutil
import subprocess
import tempfile
import threading
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import ClassVar

from playwright.sync_api import sync_playwright

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


def prepare(project: Path, extension: Path | None) -> None:
    shutil.copytree(ROOT / "addons/signal_fish", project / "addons/signal_fish")
    if extension:
        shutil.copytree(extension, project / "addons/webrtc_native")
    tests = project / "tests/smoke"
    tests.mkdir(parents=True)
    for name in ("webrtc_interop_drill.gd", "webrtc_interop_drill.tscn"):
        shutil.copy2(ROOT / "tests/smoke" / name, tests / name)
    debug = (ROOT / "project.godot").read_text().split("[debug]\n", 1)[1].split("\n[", 1)[0]
    (project / "project.godot").write_text(PROJECT + "\n[debug]\n" + debug)
    preset = (ROOT / "export_presets.cfg").read_text()
    preset = preset.replace('exclude_filter="tests/*,', 'exclude_filter="')
    (project / "export_presets.cfg").write_text(preset)
    (project / "build/web").mkdir(parents=True)


def checked(command: list[str], log: Path) -> None:
    result = subprocess.run(  # noqa: S603
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=120,
    )
    log.write_bytes(result.stdout)
    if result.returncode or b"SCRIPT ERROR" in result.stdout:
        raise RuntimeError(f"Command failed; see {log}")


def run(args: argparse.Namespace, directory: Path) -> None:
    native = directory / "native"
    web = directory / "web"
    prepare(native, args.native_extension)
    prepare(web, None)
    for project in (native, web):
        checked(
            [args.godot, "--headless", "--path", str(project), "--editor", "--quit"],
            project / "import.log",
        )
    checked(
        [args.godot, "--headless", "--path", str(web), "--export-debug", "Web"],
        web / "export.log",
    )
    handler = functools.partial(RelayHandler, directory=str(web / "build/web"))
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    url = f"http://127.0.0.1:{server.server_port}"
    native_log = (directory / "native.log").open("w")
    process = None
    messages: list[str] = []
    try:
        process = subprocess.Popen(  # noqa: S603
            [args.godot, "--headless", "--path", str(native), "--", url],
            stdout=native_log,
            stderr=subprocess.STDOUT,
        )
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(
                headless=True,
                executable_path=args.chromium,
                args=["--no-sandbox", "--enable-unsafe-swiftshader"],
            )
            try:
                page = browser.new_page()
                page.on("console", lambda message: messages.append(message.text))
                page.on("pageerror", lambda error: messages.append("PAGE_ERROR " + str(error)))
                page.goto(url + "/index.html")
                for _ in range(300):
                    page.wait_for_timeout(200)
                    if any("WEBRTC_INTEROP_" in message for message in messages):
                        break
            finally:
                (directory / "browser.log").write_text("\n".join(messages))
                browser.close()
        process.wait(timeout=20)
        native_log.flush()
        native_output = (directory / "native.log").read_text()
        browser_output = "\n".join(messages)
        for output in (native_output, browser_output):
            print(output)
            if "WEBRTC_INTEROP_PASS" not in output or any(
                token in output for token in ("SCRIPT ERROR", "PAGE_ERROR", "WEBRTC_INTEROP_FAIL")
            ):
                raise RuntimeError(f"Interoperability drill failed; see {directory}")
        if process.returncode:
            raise RuntimeError(f"Native seat exited {process.returncode}")
        print("Native/browser interoperability passed; logs: " + str(directory))
    finally:
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
            server.shutdown()
            server.server_close()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default="godot")
    parser.add_argument("--native-extension", type=Path, required=True)
    parser.add_argument("--chromium", help="Optional Playwright Chromium executable")
    parser.add_argument("--output", type=Path, help="Keep projects and logs in this new directory")
    args = parser.parse_args()
    directory = args.output or Path(tempfile.mkdtemp(prefix="sf-webrtc-interop-"))
    directory.mkdir(parents=True, exist_ok=True)
    run(args, directory)


if __name__ == "__main__":
    main()
