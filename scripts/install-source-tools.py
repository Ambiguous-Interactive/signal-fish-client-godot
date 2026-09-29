#!/usr/bin/env python3
"""Install the pinned source formatting and analysis tools for CI."""

from __future__ import annotations

import argparse
import os
import shlex
import subprocess
import sys
from collections.abc import Sequence
from pathlib import Path

PSSCRIPTANALYZER_VERSION = "1.25.0"


def run(command: Sequence[str]) -> None:
    printable = shlex.join(command)
    print(f"==> {printable}", flush=True)
    result = subprocess.run(command, check=False)  # noqa: S603
    if result.returncode != 0:
        raise RuntimeError(f"{printable} failed with exit code {result.returncode}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--tool-dir",
        type=Path,
        default=Path(os.environ["RUNNER_TEMP"]) if "RUNNER_TEMP" in os.environ else None,
        help="Directory receiving the pinned shfmt and shellcheck binaries",
    )
    args = parser.parse_args()
    if args.tool_dir is None:
        parser.error("--tool-dir is required when RUNNER_TEMP is unset")
    try:
        run(("npm", "ci", "--ignore-scripts"))
        run(
            (
                "pwsh",
                "-NoProfile",
                "-Command",
                "Install-Module PSScriptAnalyzer "
                f"-RequiredVersion {PSSCRIPTANALYZER_VERSION} "
                "-Scope CurrentUser -Force -AcceptLicense",
            )
        )
        installer = Path(__file__).resolve().parent / "install-source-tool.py"
        for tool in ("shfmt", "shellcheck"):
            run((sys.executable, str(installer), tool, str(args.tool_dir / tool)))
    except (OSError, RuntimeError) as error:
        parser.exit(1, f"{error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
