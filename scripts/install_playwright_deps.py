#!/usr/bin/env python3
"""Install Playwright Chromium system packages on GitHub runners."""

import argparse
import os
import shutil
import subprocess
import time
from pathlib import Path


def install(python: str, version: str, image: str, home: Path) -> None:
    stamp = home / ".cache/ms-playwright/.sf-system-deps"
    identity = f"{image} {version}\n"
    if image != "unknown" and stamp.is_file() and stamp.read_text() == identity:
        print("chromium system dependencies already installed (stamp)")
        return

    probe = subprocess.run(  # noqa: S603
        [python, "-m", "playwright", "install-deps", "--dry-run", "chromium"],
        capture_output=True,
        text=True,
        check=False,
    )
    if probe.returncode == 0 and probe.stdout.strip() == "All system dependencies are installed.":
        print("chromium system dependencies already present")
        if image != "unknown":
            stamp.parent.mkdir(parents=True, exist_ok=True)
            stamp.write_text(identity)
        return

    chrome_sources = sorted(Path("/etc/apt/sources.list.d").glob("google-chrome*.list"))
    if chrome_sources:
        sudo = shutil.which("sudo")
        if sudo is None:
            raise RuntimeError("sudo is required to remove stale Chrome apt sources")
        subprocess.run([sudo, "rm", "-f", *map(str, chrome_sources)], check=True)  # noqa: S603

    for attempt in range(1, 4):
        result = subprocess.run(  # noqa: S603
            [python, "-m", "playwright", "install-deps", "chromium"], check=False
        )
        if result.returncode == 0:
            if image != "unknown":
                stamp.parent.mkdir(parents=True, exist_ok=True)
                stamp.write_text(identity)
            return
        if attempt == 3:
            raise RuntimeError("playwright install-deps failed after 3 attempts")
        print(f"playwright install-deps attempt {attempt} failed; retrying", flush=True)
        time.sleep(20)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--python", required=True)
    parser.add_argument("--playwright-version", required=True)
    args = parser.parse_args()
    try:
        install(
            args.python,
            args.playwright_version,
            os.environ.get("IMAGE_VERSION", "unknown"),
            Path.home(),
        )
    except (OSError, RuntimeError) as error:
        parser.exit(1, f"{error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
