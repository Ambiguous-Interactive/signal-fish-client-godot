#!/usr/bin/env python3
"""Verify the dev container's pinned Python tooling is installed and working."""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VENV = ROOT / ".venv-ci"


def run(*command: str) -> bool:
    try:
        result = subprocess.run(  # noqa: S603
            command, cwd=ROOT, check=False, capture_output=True, text=True
        )
    except OSError:
        return False
    if result.returncode != 0:
        print(result.stderr.strip() or result.stdout.strip(), file=sys.stderr)
        return False
    output = (result.stdout or result.stderr).strip().splitlines()
    if output:
        print(f"    {output[0]}")
    return True


def main() -> int:
    missing: list[str] = []
    uv = shutil.which("uv")
    if uv is None:
        missing.append("uv")
    else:
        print("==> uv")
        if not run(uv, "--version"):
            missing.append("uv")
    python = VENV / "bin" / "python"
    if not python.is_file():
        missing.extend((".venv-ci python", "gdformat", "ruff"))
    else:
        for label, command in (
            ("venv Python", (str(python), "-c", "import yaml")),
            ("gdformat", (str(VENV / "bin" / "gdformat"), "--version")),
            ("ruff", (str(VENV / "bin" / "ruff"), "--version")),
        ):
            print(f"==> {label}")
            if not run(*command):
                missing.append(label)
    if missing:
        print(
            f"Container tool check failed: {', '.join(missing)}. Rebuild the container.",
            file=sys.stderr,
        )
        return 1
    print("==> All container tools verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
