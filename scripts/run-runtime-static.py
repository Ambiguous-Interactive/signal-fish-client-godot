#!/usr/bin/env python3
"""Run the runtime gate's static checks with ordered, parallel output."""

from __future__ import annotations

import importlib.metadata
import os
import subprocess
import sys
from collections.abc import Callable, Sequence
from concurrent.futures import ThreadPoolExecutor
from functools import partial
from pathlib import Path

GD_DIRS = ("addons/signal_fish", "tests", "demo", "scripts")
Result = tuple[int, str]


def capture(command: Sequence[str]) -> Result:
    try:
        result = subprocess.run(  # noqa: S603
            command,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            errors="replace",
        )
    except OSError as exc:
        return 1, f"{command[0]}: {exc}\n"
    return result.returncode, result.stdout


def parallel(checks: Sequence[Callable[[], Result]]) -> Result:
    if not checks:
        return 0, ""
    with ThreadPoolExecutor(max_workers=len(checks)) as pool:
        futures = [pool.submit(check) for check in checks]
        results = [future.result() for future in futures]
    return int(any(status != 0 for status, _ in results)), "".join(output for _, output in results)


def git_files(pattern: str) -> list[str]:
    result = subprocess.run(  # noqa: S603
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", pattern],  # noqa: S607
        check=False,
        capture_output=True,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.decode(errors="replace") or "git ls-files failed")
    return [os.fsdecode(path) for path in result.stdout.split(b"\0") if path]


def gd_files() -> list[str]:
    return sorted(
        str(path)
        for directory in GD_DIRS
        for path in Path(directory).rglob("*.gd")
        if path.is_file() and not path.is_symlink()
    )


def check_gdscript_roots() -> Result:
    misplaced = [
        path
        for path in git_files("*.gd")
        if not any(path.startswith(f"{directory}/") for directory in GD_DIRS)
    ]
    return int(bool(misplaced)), "".join(
        f"GDScript outside checked roots: {path}\n" for path in misplaced
    )


def prepare_gdtoolkit_cache() -> None:
    version = importlib.metadata.version("gdtoolkit")
    Path(os.environ["HOME"], ".cache", "gdtoolkit", version).mkdir(parents=True, exist_ok=True)


def sharded(tool: str, arguments: Sequence[str], files: Sequence[str], count: int) -> Result:
    if not files:
        return 0, ""
    size = (len(files) + count - 1) // count
    commands = [
        [tool, *arguments, *files[index : index + size]] for index in range(0, len(files), size)
    ]
    return parallel([partial(capture, command) for command in commands])


def private_helpers(files: Sequence[str] | None = None) -> Result:
    args = ["--self-test", *GD_DIRS] if files is None else list(files)
    return capture([sys.executable, "scripts/check-gdscript-private-helpers.py", *args])


def python_types() -> Result:
    files = [path for path in git_files("*.py") if Path(path).is_file()]
    if not files:
        return 0, ""
    output = ""
    for command in (
        ["ruff", "check", "--output-format", "concise", "--", *files],
        ["ruff", "format", "--check", "--output-format", "concise", "--", *files],
        ["mypy", "--strict", "--disallow-any-explicit", "--show-error-codes", "--", *files],
    ):
        status, result = capture(command)
        output += result
        if status != 0:
            return status, output
    return 0, output


def gdscript_static() -> Result:
    status, output = check_gdscript_roots()
    if status != 0:
        return status, output
    prepare_gdtoolkit_cache()
    files = gd_files()
    count = 2 if os.environ.get("CI") == "true" else 4
    return parallel(
        [
            private_helpers,
            lambda: sharded("gdformat", ("--diff", "--check"), files, count),
            lambda: sharded("gdlint", (), files, count),
        ]
    )


def scoped(files: Sequence[str]) -> Result:
    if not files:
        return 0, ""
    prepare_gdtoolkit_cache()
    return parallel(
        [
            lambda: private_helpers(files),
            lambda: sharded("gdformat", ("--diff", "--check"), files, 4),
            lambda: sharded("gdlint", (), files, 4),
        ]
    )


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: run-runtime-static.py <mode> [files...]", file=sys.stderr)
        return 2
    mode, *files = sys.argv[1:]
    try:
        if mode == "static":
            status, output = parallel([gdscript_static, python_types])
        elif mode == "gdscript-static":
            status, output = gdscript_static()
        elif mode == "python-types":
            status, output = python_types()
        elif mode == "private-helpers":
            status, output = private_helpers()
        elif mode in ("format", "lint"):
            prepare_gdtoolkit_cache()
            tool = "gdformat" if mode == "format" else "gdlint"
            args = ("--diff", "--check") if mode == "format" else ()
            count = 2 if os.environ.get("CI") == "true" else 4
            status, output = sharded(tool, args, gd_files(), count)
        elif mode == "scoped":
            status, output = scoped(files)
        else:
            print(f"unknown static check: {mode}", file=sys.stderr)
            return 2
    except (OSError, RuntimeError, importlib.metadata.PackageNotFoundError) as exc:
        print(f"runtime static check failed: {exc}", file=sys.stderr)
        return 1
    print(output, end="")
    return status


if __name__ == "__main__":
    sys.exit(main())
