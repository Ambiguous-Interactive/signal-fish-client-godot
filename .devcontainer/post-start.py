#!/usr/bin/env python3
"""Keep devcontainer startup cheap; repair tooling only on request."""

from __future__ import annotations

import glob
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VENV = ROOT / ".venv-ci"
GIT = shutil.which("git") or "git"


def run(*command: str, env: dict[str, str] | None = None, quiet: bool = False) -> bool:
    try:
        result = subprocess.run(  # noqa: S603
            command,
            cwd=ROOT,
            env=env,
            check=False,
            stdout=subprocess.DEVNULL if quiet else None,
            stderr=subprocess.DEVNULL if quiet else None,
        )
    except OSError:
        return False
    return result.returncode == 0


def safe_directory() -> None:
    print("==> Configuring git safe.directory")
    try:
        result = subprocess.run(  # noqa: S603
            (GIT, "config", "--global", "--get-all", "safe.directory"),
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        trusted = str(ROOT) in result.stdout.splitlines()
    except OSError:
        trusted = False
    if not trusted:
        run(GIT, "config", "--global", "--add", "safe.directory", str(ROOT))


def try_update(label: str, command: tuple[str, ...], success: str, warning: str) -> None:
    print(f"==> {label}")
    if run(*command):
        print(f"==> {success}")
    else:
        print(f"WARN: {warning}", file=sys.stderr)


def ensure_user_yaml() -> None:
    print("==> Ensuring Python automation dependencies (warn-only)")
    if run(sys.executable, "-c", "import yaml", quiet=True):
        return
    requirements = str(ROOT / "requirements-automation.txt")
    if run(
        sys.executable, "-m", "pip", "install", "--user", "-r", requirements, quiet=True
    ) and run(sys.executable, "-c", "import yaml", quiet=True):
        print("==> Installed PyYAML into user site-packages")
        return
    print(
        "WARN: python3 cannot import PyYAML; GitHub config validation fails until it is installed "
        "(python3 -m pip install --user -r requirements-automation.txt).",
        file=sys.stderr,
    )
    if glob.glob("/usr/lib/python3*/EXTERNALLY-MANAGED"):
        print(
            "WARN: this interpreter enforces PEP 668 (EXTERNALLY-MANAGED); install with "
            "'python3 -m pip install --user --break-system-packages "
            "-r requirements-automation.txt' or fix PATH.",
            file=sys.stderr,
        )


def venv_environment() -> dict[str, str]:
    environment = os.environ.copy()
    environment["VIRTUAL_ENV"] = str(VENV)
    environment["PATH"] = f"{VENV / 'bin'}{os.pathsep}{environment.get('PATH', '')}"
    environment.pop("PYTHONHOME", None)
    return environment


def venv_ok() -> bool:
    python = VENV / "bin" / "python"
    if not python.is_file() or not (VENV / "bin" / "activate").is_file():
        return False
    environment = venv_environment()
    return all(
        run(*command, env=environment, quiet=True)
        for command in (
            (str(python), "-c", "import yaml"),
            (str(VENV / "bin" / "gdformat"), "--version"),
            (str(VENV / "bin" / "ruff"), "--version"),
        )
    )


def ensure_venv() -> None:
    if venv_ok():
        return
    try:
        if VENV.is_symlink():
            VENV.unlink()
        elif VENV.exists():
            shutil.rmtree(VENV)
    except OSError:
        print(
            "WARN: could not provision .venv-ci; runtime checks fall back to user site-packages.",
            file=sys.stderr,
        )
        return
    if (
        run(sys.executable, "-m", "venv", str(VENV))
        and run(
            str(VENV / "bin" / "python"),
            "-m",
            "pip",
            "install",
            "-r",
            str(ROOT / "requirements-python-quality.txt"),
            "-r",
            str(ROOT / "requirements-automation.txt"),
            env=venv_environment(),
            quiet=True,
        )
        and venv_ok()
    ):
        print("==> .venv-ci ready with runtime and automation dependencies")
    else:
        print(
            "WARN: could not provision .venv-ci; runtime checks fall back to user site-packages.",
            file=sys.stderr,
        )


def main() -> int:
    safe_directory()
    if os.environ.get("SF_DEVCONTAINER_MAINTENANCE") != "1":
        print("==> Container ready. Rebuild to update tools.")
        return 0
    if os.environ.get("SF_DEVCONTAINER_SKIP_TOOL_UPDATES") != "1":
        try_update(
            "Checking agent CLI versions (best-effort refresh)",
            ("bash", str(ROOT / ".devcontainer/install-agent-tools.sh"), "--update"),
            "Agent CLI refresh attempted",
            "agent CLI refresh failed; using installed versions.",
        )
        try_update(
            "Checking npm-based MCP servers (best-effort refresh)",
            (sys.executable, str(ROOT / ".devcontainer/install-mcp-servers.py"), "--update"),
            "MCP server refresh attempted",
            "MCP server refresh failed; using installed versions.",
        )
        try_update(
            "Seeding agent MCP configurations (best-effort)",
            (sys.executable, str(ROOT / ".devcontainer/seed-mcp-config.py"), "--update"),
            "MCP configuration seeding attempted",
            "MCP configuration seeding failed; using existing configurations.",
        )
    ensure_user_yaml()
    ensure_venv()
    print("==> Container ready.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
