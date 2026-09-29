#!/usr/bin/env python3
"""Run the pinned formatters and static analyzers over tracked source files."""

import argparse
import os
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PRETTIER_SUFFIXES = (
    "*.js",
    "*.cjs",
    "*.mjs",
    "*.json",
    "*.jsonc",
    "*.yml",
    "*.yaml",
    "*.toml",
    "*.md",
    "*.css",
    "*.html",
)


def tracked(*patterns: str) -> list[str]:
    output = subprocess.check_output(  # noqa: S603
        [tool("git"), "ls-files", "-z", "--", *patterns], cwd=ROOT
    )
    return [os.fsdecode(path) for path in output.split(b"\0") if path]


def tool(name: str, env_name: str | None = None) -> str:
    candidate = os.environ.get(env_name, name) if env_name else name
    found = shutil.which(candidate)
    if found is None:
        raise RuntimeError(f"{name} is required.")
    return found


def node_tool(name: str) -> str:
    suffix = ".cmd" if os.name == "nt" else ""
    path = ROOT / "node_modules" / ".bin" / f"{name}{suffix}"
    found = shutil.which(str(path))
    if found is None:
        raise RuntimeError("Run npm ci first.")
    return found


def run(*command: str) -> None:
    subprocess.run(command, cwd=ROOT, check=True)  # noqa: S603


def format_sources(mode: str) -> None:
    prettier = node_tool("prettier")
    pwsh = tool("pwsh")
    run(prettier, "--write" if mode == "write" else "--check", *tracked(*PRETTIER_SUFFIXES))
    command = [pwsh, "-NoProfile", "-File", "scripts/format-powershell.ps1"]
    if mode == "write":
        command.append("-Write")
    run(*command)


def analyze_sources() -> None:
    eslint = node_tool("eslint")
    pwsh = tool("pwsh")
    run(eslint, "--max-warnings", "0", *tracked("*.js", "*.cjs", "*.mjs"))
    run(pwsh, "-NoProfile", "-File", "scripts/check-powershell-quality.ps1")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("format", "quality"))
    parser.add_argument("mode", nargs="?", choices=("check", "write"), default="check")
    args = parser.parse_args()
    if args.command == "quality" and args.mode != "check":
        parser.error("quality does not accept write mode")
    try:
        if args.command == "format":
            format_sources(args.mode)
        else:
            analyze_sources()
    except RuntimeError as error:
        parser.exit(1, f"{error}\n")
    except subprocess.CalledProcessError as error:
        return error.returncode
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
