#!/usr/bin/env python3
"""Finish devcontainer setup after features and the remote user are ready."""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONTAINER = ROOT / ".devcontainer"


def configure_path() -> None:
    home = str(Path.home())
    os.environ["PATH"] = f"/usr/local/bin:{home}/.local/bin:{os.environ.get('PATH', '')}"


def run(*command: str, check: bool = True, env: dict[str, str] | None = None) -> bool:
    try:
        result = subprocess.run(command, cwd=ROOT, env=env, check=False)  # noqa: S603
    except OSError as exc:
        if check:
            raise RuntimeError(f"Could not run {command[0]}: {exc}") from exc
        return False
    if check and result.returncode != 0:
        raise RuntimeError(f"{command[0]} failed (exit {result.returncode})")
    return result.returncode == 0


def ensure_safe_directory() -> None:
    try:
        result = subprocess.run(
            ("git", "config", "--global", "--get-all", "safe.directory"),  # noqa: S607
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        return
    if result.returncode == 0 and str(ROOT) in result.stdout.splitlines():
        return
    run("git", "config", "--global", "--add", "safe.directory", str(ROOT), check=False)


def ensure_writable_dir(path: Path) -> None:
    try:
        path.mkdir(parents=True, exist_ok=True)
    except OSError:
        if shutil.which("sudo"):
            run("sudo", "mkdir", "-p", str(path), check=False)
    if path.is_dir() and not os.access(path, os.W_OK) and shutil.which("sudo"):
        run("sudo", "chown", "-R", f"{os.getuid()}:{os.getgid()}", str(path), check=False)
    if not path.is_dir() or not os.access(path, os.W_OK):
        print(
            f"WARN: {path} is not writable; related tooling may fall back or fail.", file=sys.stderr
        )


def version(*command: str) -> str:
    try:
        result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, check=False)  # noqa: S603
    except OSError:
        return "NOT FOUND"
    if result.returncode != 0:
        return "NOT FOUND"
    output = result.stdout or result.stderr
    return output.splitlines()[0].strip() if output.strip() else "NOT FOUND"


def toolchain_summary() -> None:
    commands = {
        "bash": ("bash", "--version"),
        "git": ("git", "--version"),
        "pwsh": ("pwsh", "-NoProfile", "-Command", "$PSVersionTable.PSVersion.ToString()"),
        "python": (sys.executable, "--version"),
        "uv": ("uv", "--version"),
        "node": ("node", "--version"),
        "gh": ("gh", "--version"),
        "godot": ("godot", "--version"),
        "codex": ("codex", "--version"),
        "opencode": ("opencode", "--version"),
        "nanocoder": ("nanocoder", "--version"),
        "claude": ("claude", "--version"),
        "github-mcp-server": ("github-mcp-server", "--version"),
        "pre-commit (optional)": ("pre-commit", "--version"),
    }
    summary = (
        "\n".join(f"  {name:22}: {version(*command)}" for name, command in commands.items()) + "\n"
    )
    print("==> Toolchain summary")
    print(summary, end="")
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", prefix="sf-toolchain.", delete=False
    ) as output:
        output.write(summary)
        print(f"==> Toolchain summary saved to {output.name}")


def main() -> int:
    configure_path()
    print("==> Configuring git safe.directory", flush=True)
    ensure_safe_directory()

    print("==> Preparing writable mounted directories", flush=True)
    ensure_writable_dir(Path("/commandhistory"))
    ensure_writable_dir(Path.home() / ".cache")

    print("==> Installing direct git hooks", flush=True)
    run("pwsh", "-NoProfile", "-File", "scripts/install-git-hooks.ps1", "-Force")

    print("==> Verifying image agent CLIs (codex, opencode, nanocoder, claude)", flush=True)
    run("bash", str(CONTAINER / "install-agent-tools.sh"), "--verify")
    for cli in ("codex", "opencode", "nanocoder", "claude"):
        if shutil.which(cli) is None:
            raise RuntimeError(f"agent CLI '{cli}' is missing after post-create install")

    print("==> Checking npm-based MCP servers", flush=True)
    mcp_env = os.environ.copy()
    mcp_env["SF_MCP_SKIP_PLAYWRIGHT_BROWSER"] = "1"
    run(sys.executable, str(CONTAINER / "install-mcp-servers.py"), env=mcp_env)

    print("==> Seeding agent MCP configurations", flush=True)
    run(sys.executable, str(CONTAINER / "seed-mcp-config.py"))

    print("==> Installing PowerShell user profile", flush=True)
    source = CONTAINER / "pwsh-profile.ps1"
    if shutil.which("pwsh") and source.is_file():
        profile_dir = Path.home() / ".config/powershell"
        ensure_writable_dir(profile_dir)
        destination = profile_dir / "profile.ps1"
        temporary: Path | None = None
        try:
            with tempfile.NamedTemporaryFile(
                dir=profile_dir, prefix="profile.", delete=False
            ) as output:
                temporary = Path(output.name)
                with source.open("rb") as input_file:
                    shutil.copyfileobj(input_file, output)
                os.fchmod(output.fileno(), 0o644)
            os.replace(temporary, destination)
        except OSError as exc:
            raise RuntimeError(
                f"Failed to install PowerShell profile to {destination}: {exc}"
            ) from exc
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)
    else:
        print(
            "WARN: pwsh or profile source not found; skipping PowerShell profile.", file=sys.stderr
        )

    toolchain_summary()
    maintenance_env = os.environ.copy()
    maintenance_env.update(SF_DEVCONTAINER_MAINTENANCE="1", SF_DEVCONTAINER_SKIP_TOOL_UPDATES="1")
    run("bash", str(CONTAINER / "post-start.sh"), env=maintenance_env)
    print("==> Dev container ready.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except RuntimeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
