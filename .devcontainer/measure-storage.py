#!/usr/bin/env python3
"""Measure one final image and enforce the devcontainer image budget."""

import argparse
import json
import shutil
import subprocess


def docker(*args: str) -> str:
    binary = shutil.which("docker")
    if binary is None:
        raise RuntimeError("Docker CLI is unavailable")
    return subprocess.run(  # noqa: S603
        [binary, *args], capture_output=True, text=True, check=True, timeout=60
    ).stdout.strip()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("container_id")
    parser.add_argument("--budget-gib", type=int, default=8)
    args = parser.parse_args()
    image = docker("container", "inspect", "--format", "{{.Image}}", args.container_id)
    size = int(docker("image", "inspect", "--format", "{{.Size}}", image))
    budget = args.budget_gib * 1024**3
    print(
        json.dumps(
            {
                "image": image,
                "uncompressed_bytes": size,
                "budget_bytes": budget,
                "within_budget": size <= budget,
                "accounting": "One image, including shared layers; excludes writable data, volumes and build cache.",
            },
            indent=2,
        )
    )
    if size > budget:
        raise SystemExit(f"Devcontainer image exceeds its {args.budget_gib} GiB budget")


if __name__ == "__main__":
    main()
