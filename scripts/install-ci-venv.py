#!/usr/bin/env python3
"""Create a CI virtual environment with the pinned uv version."""

import argparse
import subprocess
import sys

UV_VERSION = "0.12.19"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("venv", help="virtual environment directory")
    parser.add_argument("requirements", nargs="+", help="requirements files")
    args = parser.parse_args()

    subprocess.run([sys.executable, "-m", "pip", "install", f"uv=={UV_VERSION}"], check=True)  # noqa: S603
    subprocess.run([sys.executable, "-m", "uv", "venv", args.venv], check=True)  # noqa: S603
    subprocess.run(  # noqa: S603
        [
            sys.executable,
            "-m",
            "uv",
            "pip",
            "install",
            "--python",
            f"{args.venv}/bin/python",
            *(item for requirement in args.requirements for item in ("-r", requirement)),
        ],
        check=True,
    )


if __name__ == "__main__":
    main()
