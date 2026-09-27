#!/usr/bin/env python3
"""Install pinned source tools after verifying their release archives."""

import argparse
import hashlib
import io
import os
import platform
import tarfile
import tempfile
import urllib.request
from pathlib import Path

SHFMT_VERSION = "3.14.1"
SHELLCHECK_VERSION = "0.11.0"
SHFMT_SHA256 = {
    "x86_64": "76e77641faa025814b77f153b29796b8e6fa2fca03e0c76a691608b86c7ea7bf",
    "aarch64": "5f2db09dae91fca848f7adbdd014632e921a383863a2ad7e0450ad3aba0c6489",
}
SHELLCHECK_SHA256 = {
    "x86_64": "8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198",
    "aarch64": "12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588",
}


def architecture() -> str:
    if platform.system() != "Linux":
        raise RuntimeError("Pinned source tools require Linux.")
    machine = platform.machine().lower()
    if machine in ("aarch64", "arm64"):
        return "aarch64"
    if machine == "x86_64":
        return machine
    raise RuntimeError(f"Unsupported architecture: {machine}.")


def release(tool: str, arch: str) -> tuple[str, str, str | None]:
    if tool == "shfmt":
        asset_arch = "amd64" if arch == "x86_64" else "arm64"
        url = (
            f"https://github.com/mvdan/sh/releases/download/v{SHFMT_VERSION}/"
            f"shfmt_v{SHFMT_VERSION}_linux_{asset_arch}"
        )
        return url, SHFMT_SHA256[arch], None
    url = (
        f"https://github.com/koalaman/shellcheck/releases/download/v{SHELLCHECK_VERSION}/"
        f"shellcheck-v{SHELLCHECK_VERSION}.linux.{arch}.tar.xz"
    )
    return url, SHELLCHECK_SHA256[arch], f"shellcheck-v{SHELLCHECK_VERSION}/shellcheck"


def install(tool: str, destination: Path) -> None:
    url, expected_sha256, archive_member = release(tool, architecture())
    request = urllib.request.Request(  # noqa: S310
        url, headers={"User-Agent": "signal-fish-tool-installer"}
    )
    with urllib.request.urlopen(request, timeout=120) as response:  # noqa: S310
        download = response.read()
    actual_sha256 = hashlib.sha256(download).hexdigest()
    if actual_sha256 != expected_sha256:
        raise RuntimeError(f"{tool} SHA-256 mismatch: {actual_sha256}.")
    if archive_member is None:
        binary = download
    else:
        with tarfile.open(fileobj=io.BytesIO(download), mode="r:xz") as archive:
            member = archive.getmember(archive_member)
            if not member.isfile():
                raise RuntimeError(f"{tool} release member is not a file.")
            extracted = archive.extractfile(member)
            if extracted is None:
                raise RuntimeError(f"{tool} release member is missing.")
            binary = extracted.read()
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as temporary:
        temporary.write(binary)
        temporary_path = Path(temporary.name)
    try:
        temporary_path.chmod(0o755)
        os.replace(temporary_path, destination)
    finally:
        temporary_path.unlink(missing_ok=True)
    print(f"Installed {tool} to {destination}.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tool", choices=("shfmt", "shellcheck"))
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    try:
        install(args.tool, args.destination)
    except (OSError, RuntimeError, KeyError, tarfile.TarError) as error:
        parser.exit(1, f"{error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
