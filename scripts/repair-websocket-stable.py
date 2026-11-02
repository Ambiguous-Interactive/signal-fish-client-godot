#!/usr/bin/env python3
"""Apply the opt-in native WebSocket receive repair to pinned Godot source."""

from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path

PATCHES = {
    "49a5bc7b616bd04689a2c89e89bda41f50241464": "godot-44-websocket-assembly.patch",
    "6ce3de25aa58466e14ef354703ba8d9791a417da": "godot-45-websocket-assembly.patch",
    "35e80b3a8822a9df9be390814b62f44c0a9c69e8": "godot-46-websocket-assembly.patch",
    "ed1daf0bf001b61586d9930840f2f1394092c079": "godot-47-websocket-assembly.patch",
    # Master revision submitted upstream; see the websocket-native-x64 workflow.
    "95c0fa5fe8a019adc29d074c16b64469b04571f7": "godot-master-websocket-assembly.patch",
}


def apply(source: Path, check_only: bool) -> dict[str, object]:
    script = Path(__file__).resolve().with_name("backport-websocket-43.py")
    spec = importlib.util.spec_from_file_location("websocket_receive_patch", script)
    if spec is None or spec.loader is None:
        raise ValueError(f"Could not load {script}")
    backport = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(backport)
    revision = backport.git(source, "rev-parse", "HEAD")
    base = revision.stdout.strip()
    if revision.returncode or base not in PATCHES:
        raise ValueError(
            "source HEAD must be a pinned Godot 4.4.1, 4.5.2, 4.6.3, 4.7.2 stable or master revision"
        )
    patch = script.parent / "patches" / PATCHES[base]
    return {
        **backport.apply_patch(source, check_only, base, patch),
        "issues": [485, 491, 492, 496, 498],
        "scope": "experimental native receive/assembly repair; build and runtime qualification required",
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
