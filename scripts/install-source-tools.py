#!/usr/bin/env python3
"""Install the pinned source formatting and analysis tools for CI."""

from __future__ import annotations

import shlex
import subprocess
from collections.abc import Sequence

PSSCRIPTANALYZER_VERSION = "1.25.0"


def run(command: Sequence[str]) -> None:
    printable = shlex.join(command)
    print(f"==> {printable}", flush=True)
    result = subprocess.run(command, check=False)  # noqa: S603
    if result.returncode != 0:
        raise RuntimeError(f"{printable} failed with exit code {result.returncode}")


def main() -> int:
    try:
        run(["npm", "ci", "--ignore-scripts"])
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
    except (OSError, RuntimeError) as error:
        raise SystemExit(f"{error}\n") from error
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
