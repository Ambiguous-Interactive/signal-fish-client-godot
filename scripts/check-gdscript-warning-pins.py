#!/usr/bin/env python3
"""Keep project.godot GDScript warning pins complete for the CI engine matrix.

The [debug] section pins every warning class each matrix engine registers, at
error level unless documented otherwise. project.godot keys an engine does not
know are ignored by that engine, so one pin list serves the whole matrix. The
failure modes this check catches:

- An engine registers a warning class that project.godot does not pin, so the
  untyped-code hole silently reopens at that engine's default severity.
- A pin's level drifts off the documented invariant (error level, except the
  two classes that must stay ignorable), so a downgrade silently weakens CI.
- project.godot pins a key no matrix engine knows (typo or dead key), so the
  pin looks enforced while every engine ignores it.

Warning codes per engine come from tests/fixtures/gdscript_warnings.json,
captured from the upstream GDScriptWarning::Code enum at each matrix tag.
After bumping an engine version in ci.yml, refresh that engine's list from
<repo>/blob/<tag>/modules/gdscript/gdscript_warning.h.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import tempfile
from pathlib import Path

FIXTURES = Path("tests/fixtures/gdscript_warnings.json")
PROJECT = Path("project.godot")
CI_WORKFLOW = Path(".github/workflows/ci.yml")

# missing_await stays unpinned: the smoke test's deliberate fire-and-forget
# kickoff trips it, and the rationale lives in project.godot.
EXEMPT_WARNINGS = frozenset({"missing_await"})

# The two pins the project comment deliberately keeps at ignore level.
KNOWN_IGNORED = frozenset({"inferred_declaration", "return_value_discarded"})

PIN_LINE = re.compile(r"^gdscript/warnings/([a-z0-9_]+)=(\d+)$")
MATRIX_LINE = re.compile(r"^\s*godot:\s*\[([^\]]*)\]$")
VERSIONS = re.compile(r'"([^"]+)"')


def parse_pins(text: str) -> dict[str, int]:
    pins: dict[str, int] = {}
    section = ""
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            section = stripped
            continue
        if section != "[debug]":
            continue
        match = PIN_LINE.match(stripped)
        if match:
            pins[match.group(1)] = int(match.group(2))
    return pins


def parse_matrix_versions(text: str) -> list[str]:
    for line in text.splitlines():
        match = MATRIX_LINE.search(line)
        if match:
            return VERSIONS.findall(match.group(1))
    return []


def find_failures(
    versions: list[str], engines: dict[str, list[str]], pins: dict[str, int]
) -> list[str]:
    failures: list[str] = []
    for version in versions:
        if version not in engines:
            failures.append(
                f"{version} is in the CI matrix but has no entry in {FIXTURES}; "
                "capture its GDScriptWarning::Code list from the upstream tag."
            )
            continue
        unpinned = sorted(set(engines[version]) - set(pins) - EXEMPT_WARNINGS)
        if unpinned:
            failures.append(
                f"{version} registers warning classes project.godot does not pin "
                f"(add gdscript/warnings/<name>=2 under [debug] or extend the "
                f"documented exemptions): {', '.join(unpinned)}"
            )
    for name in sorted(set(pins) - KNOWN_IGNORED):
        if pins[name] != 2:
            failures.append(
                f"gdscript/warnings/{name}={pins[name]} in project.godot; the "
                f"documented invariant is error level 2 (only "
                f"{', '.join(sorted(KNOWN_IGNORED))} may be 0)."
            )
    for name in sorted(KNOWN_IGNORED & set(pins)):
        if pins[name] != 0:
            failures.append(
                f"gdscript/warnings/{name}={pins[name]} in project.godot; the "
                "project comment keeps this class ignorable, so it must stay 0."
            )
    known = {code for codes in engines.values() for code in codes}
    dead = sorted(set(pins) - known)
    if dead:
        failures.append(
            f"project.godot pins warning classes no matrix engine registers "
            f"(typo or stale key): {', '.join(dead)}"
        )
    return failures


def run_check(root: Path) -> int:
    fixtures_path = root / FIXTURES
    project_path = root / PROJECT
    workflow_path = root / CI_WORKFLOW
    try:
        fixtures = json.loads(fixtures_path.read_text(encoding="utf-8"))
        pins = parse_pins(project_path.read_text(encoding="utf-8"))
        versions = parse_matrix_versions(workflow_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        print(f"error: cannot read check inputs: {exc}", file=sys.stderr)
        return 2
    engines = {
        str(version): [str(code) for code in entry["codes"]]
        for version, entry in fixtures["engines"].items()
    }
    if not versions:
        print(
            f"error: no single-line double-quoted godot: [...] matrix in {CI_WORKFLOW}",
            file=sys.stderr,
        )
        return 2
    failures = find_failures(versions, engines, pins)
    for failure in failures:
        print(f"error: {failure}", file=sys.stderr)
    if failures:
        return 1
    print(
        f"warning pins cover {len(versions)} matrix engines "
        f"({', '.join(versions)}): {len(pins)} pinned."
    )
    return 0


def self_test() -> int:
    engines = {
        "1.0-stable": ["alpha", "beta"],
        "2.0-stable": ["alpha", "gamma"],
    }
    versions = ["1.0-stable", "2.0-stable"]
    cases: list[tuple[dict[str, int], list[str]]] = [
        ({"alpha": 2, "beta": 2, "gamma": 2}, []),
        (
            {"alpha": 2, "beta": 2},
            [
                "2.0-stable registers warning classes project.godot "
                "does not pin (add gdscript/warnings/<name>=2 under "
                "[debug] or extend the documented exemptions): gamma"
            ],
        ),
        ({"alpha": 2, "beta": 2, "gamma": 2, "delta": 2}, ["project.godot pins warning classes"]),
        (
            {},
            ["1.0-stable registers warning classes", "2.0-stable registers warning classes"],
        ),
        ({"alpha": 1, "beta": 2, "gamma": 2}, ["gdscript/warnings/alpha=1"]),
        ({"alpha": 2, "beta": 0, "gamma": 2}, ["gdscript/warnings/beta=0"]),
    ]
    for index, (pins, expected_fragments) in enumerate(cases):
        failures = find_failures(versions, engines, pins)
        if len(failures) != len(expected_fragments):
            print(
                f"self-test case {index}: expected {len(expected_fragments)} "
                f"failures, got {failures}",
                file=sys.stderr,
            )
            return 1
        for fragment in expected_fragments:
            if not any(fragment in failure for failure in failures):
                print(
                    f"self-test case {index}: missing failure text {fragment!r} in {failures}",
                    file=sys.stderr,
                )
                return 1
    exempt = find_failures(["1.0-stable"], {"1.0-stable": ["missing_await"]}, {})
    if exempt:
        print(f"self-test: exemption not honored: {exempt}", file=sys.stderr)
        return 1
    missing = find_failures(["9.9-stable"], {"1.0-stable": ["alpha"]}, {"alpha": 2})
    if len(missing) != 1 or "has no entry in" not in missing[0]:
        print(f"self-test: missing fixture entry not reported: {missing}", file=sys.stderr)
        return 1
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        project = tmp_path / "project.godot"
        project.write_text(
            "[debug]\ngdscript/warnings/alpha=2\ngdscript/warnings/beta=0\n",
            encoding="utf-8",
        )
        other = tmp_path / "other.godot"
        other.write_text("[rendering]\ngdscript/warnings/gamma=2\n", encoding="utf-8")
        if parse_pins(project.read_text(encoding="utf-8")) != {"alpha": 2, "beta": 0}:
            print("self-test: pin parser missed [debug] keys or levels", file=sys.stderr)
            return 1
        if parse_pins(other.read_text(encoding="utf-8")) != {}:
            print("self-test: pin parser read a non-[debug] section", file=sys.stderr)
            return 1
        workflow = tmp_path / "ci.yml"
        workflow.write_text(
            '            matrix:\n                godot: ["1.0-stable", "2.0-stable"]\n',
            encoding="utf-8",
        )
        if parse_matrix_versions(workflow.read_text(encoding="utf-8")) != versions:
            print("self-test: matrix parser returned wrong versions", file=sys.stderr)
            return 1
        workflow.write_text(
            '                # godot: ["9.9-stable"]\n'
            '                other-godot: ["8.8-stable"]\n',
            encoding="utf-8",
        )
        if parse_matrix_versions(workflow.read_text(encoding="utf-8")) != []:
            print("self-test: matrix parser matched a comment or suffix key", file=sys.stderr)
            return 1
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    return run_check(Path.cwd())


if __name__ == "__main__":
    raise SystemExit(main())
