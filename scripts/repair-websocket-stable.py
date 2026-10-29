#!/usr/bin/env python3
"""Apply the opt-in native WebSocket assembly repair to Godot 4.4.1 source."""

from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path

BASE = "49a5bc7b616bd04689a2c89e89bda41f50241464"
PATCH = Path(__file__).resolve().parent / "patches/godot-44-websocket-assembly.patch"


def apply(source: Path, check_only: bool) -> dict[str, object]:
    script = Path(__file__).resolve().with_name("backport-websocket-43.py")
    spec = importlib.util.spec_from_file_location("websocket_receive_patch", script)
    if spec is None or spec.loader is None:
        raise ValueError(f"Could not load {script}")
    backport = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(backport)
    return {
        **backport.apply_patch(source, check_only, BASE, PATCH),
        "issues": [491, 492],
        "scope": "experimental native assembly repair; build and runtime qualification required",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--check", action="store_true", help="Check without modifying source")
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    if args.report.exists():
        parser.error("report already exists; retain each attempt in a new file")
    try:
        report = apply(args.source.resolve(), args.check)
    except ValueError as error:
        report = {"status": "failed", "error": str(error)}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))
    return 1 if report["status"] == "failed" else 0


if __name__ == "__main__":
    raise SystemExit(main())
