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

STABLE_RELEASES = "https://github.com/godotengine/godot/releases/download"
# Dev, beta and release-candidate builds ship on godot-builds, not the
# main repository's release page.
PRE_RELEASES = "https://github.com/godotengine/godot-builds/releases/download"
EDITOR_MIN_BYTES = 1_000_000
TEMPLATES_MIN_BYTES = 100_000_000
# Headless Godot loads only fontconfig, freetype, and udev; the X11/GL/audio
# stack is never loaded, so installing it only wastes CI minutes.
RUNTIME_PACKAGES = ("libfontconfig1", "libfreetype6", "libudev1")
EXTRA_RUNTIME_PACKAGES = ("ca-certificates", "curl", "unzip")


def archive_valid(path: Path, minimum_bytes: int) -> bool:
    """Return true when path is a readable zip above the minimum size."""
    if not path.is_file() or path.stat().st_size < minimum_bytes:
        return False
    try:
        with zipfile.ZipFile(path) as archive:
            return archive.testzip() is None
    except (OSError, zipfile.BadZipFile, RuntimeError, EOFError, zlib.error):
        return False


def download_archive(version: str, name: str, cache_dir: Path, minimum_bytes: int) -> Path:
    """Download a release archive from the repository that hosts it."""
    cache_dir.mkdir(parents=True, exist_ok=True)
    target = cache_dir / name
    if archive_valid(target, minimum_bytes):
        print(f"==> Using cached {target}")
        return target

    base = STABLE_RELEASES if version.endswith("-stable") else PRE_RELEASES
    url = f"{base}/{version}/{name}"
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


def binary_failure(result: subprocess.CompletedProcess[str]) -> str:
    """Summarize why an editor binary probe failed."""
    tail = [
        *result.stdout.strip().splitlines()[-2:],
        *result.stderr.strip().splitlines()[-2:],
    ]
    detail = " | ".join(tail) if tail else "no output"
    return f"exit {result.returncode}: {detail}"


def install_editor(version: str, cache_dir: Path, target: Path) -> None:
    """Install the editor binary for this platform at target."""
    if sys.platform == "darwin":
        install_macos_editor(version, cache_dir, target)
        return
    if sys.platform == "win32":
        install_windows_editor(version, cache_dir, target)
        return
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
            raise RuntimeError(f"Godot binary failed to run: {binary_failure(result)}")
        os.replace(part_path, target)
    finally:
        part_path.unlink(missing_ok=True)
    print(f"==> Installed: {result.stdout.strip()}")


def install_windows_editor(version: str, cache_dir: Path, target: Path) -> None:
    """Install the official Windows editor executable at target.

    The win64 archive also ships a console wrapper; only the editor binary is
    installed, and the target keeps its .exe suffix so Windows can launch it.
    """
    if target.suffix.lower() != ".exe":
        raise ValueError(f"Windows editor target must end with .exe: {target}")
    name = f"Godot_v{version}_win64.exe.zip"
    path = download_archive(version, name, cache_dir, EDITOR_MIN_BYTES)
    print("==> Verifying archive")
    with zipfile.ZipFile(path) as archive:
        binaries = [
            member
            for member in archive.infolist()
            if not member.is_dir()
            and Path(member.filename).name.startswith(f"Godot_v{version}_win64")
            and not Path(member.filename).name.endswith("_console.exe")
        ]
        if len(binaries) != 1:
            raise ValueError(f"Expected one Godot binary in {name}, found {len(binaries)}")
        print(f"==> Installing to {target}")
        target.parent.mkdir(parents=True, exist_ok=True)
        with (
            archive.open(binaries[0]) as source,
            tempfile.NamedTemporaryFile(
                dir=target.parent, prefix=".godot-", suffix=".exe", delete=False
            ) as output,
        ):
            part_path = Path(output.name)
            shutil.copyfileobj(source, output)
    try:
        result = subprocess.run(  # noqa: S603
            [str(part_path), "--headless", "--version"],
            capture_output=True,
            text=True,
            check=False,
            timeout=60,
        )
        if result.returncode != 0:
            raise RuntimeError(f"Godot binary failed to run: {binary_failure(result)}")
        os.replace(part_path, target)
    finally:
        part_path.unlink(missing_ok=True)
    print(f"==> Installed: {result.stdout.strip()}")


def install_macos_editor(version: str, cache_dir: Path, target: Path) -> None:
    """Install the official macOS editor bundle at target/Godot.app.

    The engine binary is code-signed for Apple platforms and only runs from
    inside its bundle, so target names the directory that receives Godot.app.
    """
    name = f"Godot_v{version}_macos.universal.zip"
    path = download_archive(version, name, cache_dir, EDITOR_MIN_BYTES)
    print("==> Verifying archive")
    executable_member = "Godot.app/Contents/MacOS/Godot"
    app_root = target / "Godot.app"
    if target.exists() and not target.is_dir():
        raise ValueError(f"{target} exists and is not a directory")
    staging = target / f".godot-app-{os.getpid()}"
    backup = staging / ".previous-Godot.app"
    if staging.is_dir():
        shutil.rmtree(staging, ignore_errors=True)
    else:
        staging.unlink(missing_ok=True)
    staging.mkdir(parents=True)
    promoted_ok = False
    try:
        with zipfile.ZipFile(path) as archive:
            found = [
                member
                for member in archive.infolist()
                if not member.is_dir() and member.filename == executable_member
            ]
            if len(found) != 1:
                raise ValueError(f"Expected one Godot binary in {name}, found {len(found)}")
            staging_root = staging.resolve()
            for member in archive.infolist():
                destination = (staging / member.filename).resolve()
                if not destination.is_relative_to(staging_root):
                    raise ValueError(f"Unsafe archive member path: {member.filename}")
                if member.is_dir():
                    destination.mkdir(parents=True, exist_ok=True)
                    continue
                destination.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(member) as source, destination.open("wb") as output:
                    shutil.copyfileobj(source, output)
            executable = staging / executable_member
        executable.chmod(0o755)
        try:
            result = subprocess.run(  # noqa: S603
                [str(executable), "--headless", "--version"],
                capture_output=True,
                text=True,
                check=False,
                timeout=60,
            )
        except subprocess.TimeoutExpired as error:
            raise RuntimeError(f"Godot binary did not exit: {error}") from error
        if result.returncode != 0:
            raise RuntimeError(f"Godot binary failed to run: {binary_failure(result)}")
        promoted = staging / "Godot.app"
        if not promoted.is_dir():
            raise ValueError(f"Archive did not contain Godot.app at its root: {name}")
        if app_root.is_dir():
            os.replace(app_root, backup)
        try:
            os.replace(promoted, app_root)
            promoted_ok = True
        except OSError:
            try:
                if not app_root.exists() and backup.is_dir():
                    os.replace(backup, app_root)
            except OSError:
                # Keep the previous bundle even when staging cleanup would
                # otherwise delete the only copy.
                os.replace(backup, target / f".Godot.app-lost-{os.getpid()}")
            raise
    finally:
        if promoted_ok:
            shutil.rmtree(staging, ignore_errors=True)
        elif backup.is_dir():
            # The previous bundle still lives in staging after a failed
            # promotion; cleanup would delete the only copy.
            print(f"==> Kept {staging} for recovery")
        else:
            shutil.rmtree(staging, ignore_errors=True)
    print(f"==> Installed bundle: {app_root}")


def install_templates(version: str, cache_dir: Path, templates_root: Path) -> None:
    """Install the archive's web templates under the version it declares."""
    name = f"Godot_v{version}_export_templates.tpz"
    path = download_archive(version, name, cache_dir, TEMPLATES_MIN_BYTES)
    print("==> Verifying archive")
    with zipfile.ZipFile(path) as archive:
        version_dir = archive.read("templates/version.txt").decode("utf-8").strip()
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]*", version_dir):
            raise ValueError(f"Invalid template version in {name}: {version_dir!r}")
        target_dir = templates_root / version_dir
        print(f"==> Extracting web templates into {target_dir}")
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


def install_runtime_deps() -> None:
    """Install the libraries headless Godot loads on Linux."""
    if os.geteuid() != 0:
        raise RuntimeError("runtime-deps must run as root (sudo)")
    dpkg = shutil.which("dpkg")
    if dpkg is None:
        raise RuntimeError("dpkg is required to check Godot runtime libraries")
    probe = subprocess.run(  # noqa: S603
        (dpkg, "-s", *RUNTIME_PACKAGES), capture_output=True, check=False
    )
    if probe.returncode == 0:
        print("==> Godot runtime libraries already present")
        return
    apt_get = shutil.which("apt-get")
    if apt_get is None:
        raise RuntimeError("apt-get is required to install Godot runtime libraries")
    for command in (
        (apt_get, "update"),
        (
            apt_get,
            "install",
            "-y",
            "--no-install-recommends",
            *EXTRA_RUNTIME_PACKAGES,
            *RUNTIME_PACKAGES,
        ),
    ):
        print(f"==> {' '.join(command)}")
        result = subprocess.run(command, check=False)  # noqa: S603
        if result.returncode != 0:
            raise RuntimeError(f"apt-get failed with exit code {result.returncode}")
    print("==> Installed Godot runtime libraries")


def main() -> int:
    """Dispatch the installer command line."""
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
    commands.add_parser("runtime-deps")
    args = parser.parse_args()
    if args.kind != "runtime-deps" and not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]*", args.version):
        parser.error("version must be a release tag without path separators")
    try:
        if args.kind == "editor":
            if args.cache_dir:
                install_editor(args.version, Path(args.cache_dir), args.target)
            else:
                with tempfile.TemporaryDirectory(prefix="sf-godot-") as temporary:
                    install_editor(args.version, Path(temporary), args.target)
        elif args.kind == "templates":
            install_templates(args.version, args.cache_dir, args.templates_root)
        else:
            install_runtime_deps()
    except (OSError, ValueError, RuntimeError, urllib.error.URLError) as exc:
        print(f"Godot install failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
