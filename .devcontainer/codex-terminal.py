#!/usr/bin/env python3
"""Launch the npm CLI without depending on the editor's shared daemon."""

import os
import subprocess
import sys
from pathlib import Path


def launch_args(binary: str, args: list[str]) -> list[str]:
    if os.environ.get("SF_CODEX_SHARED_SERVER") == "1" or any(
        arg in ("--remote", "--no-daemon") or arg.startswith("--remote=") for arg in args
    ):
        return [binary, *args]
    # Older npm overrides predate --no-daemon.
    help_text = subprocess.run(  # noqa: S603
        [binary, "--help"], capture_output=True, text=True, check=False, timeout=30
    )
    standalone = ["--no-daemon"] if "--no-daemon" in help_text.stdout else []
    return [binary, *standalone, *args]


def main() -> int:
    prefix = Path(os.environ.get("NPM_CONFIG_PREFIX", str(Path.home() / ".npm-global")))
    binary = str(prefix / "bin/codex")
    if not os.access(binary, os.X_OK):
        print("Codex is missing. Run python3 .devcontainer/install-agent-tools.py", file=sys.stderr)
        return 127
    try:
        os.execv(binary, launch_args(binary, sys.argv[1:]))  # noqa: S606
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"Codex launch failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
