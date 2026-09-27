#!/usr/bin/env python3
"""Install the pinned Godot editor or its web export templates."""

from __future__ import annotations

import argparse
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import zipfile
import zlib
from pathlib import Path

RELEASES = "https://github.com/godotengine/godot/releases/download"
EDITOR_MIN_BYTES = 1_000_000
TEMPLATES_MIN_BYTES = 100_000_000


def archive_valid(path: Path, minimum_bytes: int) -> bool:
    if not path.is_file() or path.stat().st_size < minimum_bytes:
        return False
    try:
        with zipfile.ZipFile(path) as archive:
            return archive.testzip() is None
    except (OSError, zipfile.BadZipFile, RuntimeError, EOFError, zlib.error):
        return False


def download_archive(version: str, name: str, cache_dir: Path, minimum_bytes: int) -> Path:
    cache_dir.mkdir(parents=True, exist_ok=True)
    target = cache_dir / name
    if archive_valid(target, minimum_bytes):
        print(f"==> Using cached {target}")
        return target

    url = f"{RELEASES}/{version}/{name}"
    print(f"==> Downloading {url}")
    target.unlink(missing_ok=True)
    for attempt in range(6):
        with tempfile.NamedTemporaryFile(dir=cache_dir, prefix=f".{name}.", delete=False) as part:
            part_path = Path(part.name)
        try:
            with (
                urllib.request.urlopen(url, timeout=90) as response,  # noqa: S310
                part_path.open("wb") as output,
            ):
                shutil.copyfileobj(response, output)
            if not archive_valid(part_path, minimum_bytes):
                raise ValueError(f"Downloaded archive is too small or corrupt: {name}")
            os.replace(part_path, target)
            return target
        except (OSError, urllib.error.URLError, ValueError):
            part_path.unlink(missing_ok=True)
            if attempt == 5:
                raise
            time.sleep(2)
    raise RuntimeError("download attempts exhausted")


def install_editor(version: str, cache_dir: Path, target: Path) -> None:
    architecture = {"x86_64": "linux.x86_64", "aarch64": "linux.arm64"}.get(platform.machine())
    if architecture is None:
        raise ValueError(f"Unsupported architecture: {platform.machine()}")
    name = f"Godot_v{version}_{architecture}.zip"
    path = download_archive(version, name, cache_dir, EDITOR_MIN_BYTES)
    print("==> Verifying archive")
    with zipfile.ZipFile(path) as archive:
        binaries = [
            member
            for member in archive.infolist()
            if not member.is_dir() and Path(member.filename).name.startswith(f"Godot_v{version}_")
        ]
        if len(binaries) != 1:
            raise ValueError(f"Expected one Godot binary in {name}, found {len(binaries)}")
        print(f"==> Installing to {target}")
        target.parent.mkdir(parents=True, exist_ok=True)
        with (
            archive.open(binaries[0]) as source,
            tempfile.NamedTemporaryFile(
                dir=target.parent, prefix=".godot-", delete=False
            ) as output,
        ):
            part_path = Path(output.name)
            shutil.copyfileobj(source, output)
    try:
        part_path.chmod(0o755)
        result = subprocess.run(  # noqa: S603
            [str(part_path), "--headless", "--version"],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            raise RuntimeError(f"Godot binary failed to run: {result.stderr.strip()}")
        os.replace(part_path, target)
    finally:
        part_path.unlink(missing_ok=True)
    print(f"==> Installed: {result.stdout.strip()}")


def install_templates(version: str, cache_dir: Path, templates_root: Path) -> None:
    name = f"Godot_v{version}_export_templates.tpz"
    path = download_archive(version, name, cache_dir, TEMPLATES_MIN_BYTES)
    print("==> Verifying archive")
    editor = shutil.which("godot")
    result = (
        subprocess.run([editor, "--version"], capture_output=True, text=True, check=False)  # noqa: S603
        if editor
        else None
    )
    editor_version = result.stdout.strip() if result and result.returncode == 0 else ""
    version_dir = (
        editor_version.split(".official", maxsplit=1)[0]
        if editor_version
        else version.replace("-stable", ".stable")
    )
    target_dir = templates_root / version_dir
    print(f"==> Extracting web templates into {target_dir}")
    with zipfile.ZipFile(path) as archive:
        web_members = [
            member
            for member in archive.infolist()
            if not member.is_dir() and re.fullmatch(r"templates/web_[^/]+", member.filename)
        ]
        if not web_members:
            raise ValueError(f"No web templates found in {name}; archive layout may have changed")
        target_dir.mkdir(parents=True, exist_ok=True)
        for member in web_members:
            target = target_dir / Path(member.filename).name
            with (
                archive.open(member) as source,
                tempfile.NamedTemporaryFile(dir=target_dir, prefix=".web-", delete=False) as output,
            ):
                part_path = Path(output.name)
                shutil.copyfileobj(source, output)
            try:
                part_path.chmod(0o644)
                os.replace(part_path, target)
            finally:
                part_path.unlink(missing_ok=True)
    print(f"==> Installed web templates for {version_dir}: {len(web_members)} files")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="kind", required=True)
    editor = commands.add_parser("editor")
    editor.add_argument("version")
    editor.add_argument("cache_dir", nargs="?")
    editor.add_argument("--target", type=Path, default=Path("/usr/local/bin/godot"))
    templates = commands.add_parser("templates")
    templates.add_argument("version")
    templates.add_argument("cache_dir", type=Path)
    templates.add_argument("templates_root", type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]*", args.version):
        parser.error("version must be a release tag without path separators")
    try:
        if args.kind == "editor":
            if args.cache_dir:
                install_editor(args.version, Path(args.cache_dir), args.target)
            else:
                with tempfile.TemporaryDirectory(prefix="sf-godot-") as temporary:
                    install_editor(args.version, Path(temporary), args.target)
        else:
            install_templates(args.version, args.cache_dir, args.templates_root)
    except (OSError, ValueError, RuntimeError, urllib.error.URLError) as exc:
        print(f"Godot install failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
