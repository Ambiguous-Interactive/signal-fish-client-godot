#!/usr/bin/env python3
"""Import and export the demo, then prepare its HTTPS smoke certificate."""

import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WEB_ROOT = ROOT / "build/web"
CERT_ROOT = ROOT / "build/smoke-certs"


def main() -> int:
    godot = shutil.which("godot")
    openssl = shutil.which("openssl")
    if godot is None or openssl is None:
        print("web export requires godot and openssl on PATH", file=sys.stderr)
        return 1

    if WEB_ROOT.exists():
        shutil.rmtree(WEB_ROOT)
    WEB_ROOT.mkdir(parents=True)
    subprocess.run([godot, "--headless", "--import", "--path", str(ROOT)], check=True)  # noqa: S603
    subprocess.run(  # noqa: S603
        [
            godot,
            "--headless",
            "--path",
            str(ROOT),
            "--export-release",
            "Web",
            str(WEB_ROOT / "index.html"),
        ],
        check=True,
    )

    missing = [name for name in ("index.html", "index.wasm") if not (WEB_ROOT / name).is_file()]
    if missing:
        print(f"web export missing: {', '.join(missing)}", file=sys.stderr)
        return 1
    for path in sorted(WEB_ROOT.iterdir()):
        print(f"web export: {path.name} ({path.stat().st_size} bytes)")

    CERT_ROOT.mkdir(parents=True, exist_ok=True)
    subprocess.run(  # noqa: S603
        [
            openssl,
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-days",
            "1",
            "-nodes",
            "-keyout",
            str(CERT_ROOT / "key.pem"),
            "-out",
            str(CERT_ROOT / "cert.pem"),
            "-subj",
            "/CN=localhost",
            "-addext",
            "subjectAltName=DNS:localhost,IP:127.0.0.1",
        ],
        check=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
