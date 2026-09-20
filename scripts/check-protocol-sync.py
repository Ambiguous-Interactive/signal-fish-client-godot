#!/usr/bin/env python3
"""Check the Godot client's pinned protocol sources against upstream.

The Signal Fish wire contract is pinned to an upstream server commit. The
Rust client SDK (the reference implementation) records its current binding
in ``tests/compatibility.toml``. This script fetches that file and fails
when the commit pinned here (fixture headers and
``.llm/research/protocol-fixtures.md``) differs, so protocol drift surfaces
as a scheduled CI failure instead of a silent codec divergence.

Network is only used by the default mode; ``--self-test`` is offline.
"""

import argparse
import re
import sys
import urllib.request
from pathlib import Path

DEFAULT_REPO_ROOT = Path(__file__).resolve().parent.parent

COMPATIBILITY_URL = (
    "https://raw.githubusercontent.com/Ambiguous-Interactive/"
    "signal-fish-client-rust/main/tests/compatibility.toml"
)

FIXTURE_FILES = (
    Path("tests/fixtures/v2_client_messages.jsonl"),
    Path("tests/fixtures/v2_server_messages.jsonl"),
    Path("tests/fixtures/malformed.jsonl"),
)

FIXTURES_DOC = Path(".llm/research/protocol-fixtures.md")

COMMIT_RE = r"[0-9a-f]{40}"
FIXTURE_HEADER_RE = re.compile(r"^# Source: signal-fish-server@(" + COMMIT_RE + r")", re.M)
DOC_PIN_RE = re.compile(r"- `signal-fish-server`: `(" + COMMIT_RE + r")`")
UPSTREAM_COMMIT_RE = re.compile(r'^server_commit\s*=\s*"(' + COMMIT_RE + r')"', re.M)
UPSTREAM_VERSION_RE = re.compile(r'^server_version\s*=\s*"([^"]+)"', re.M)


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise RuntimeError(f"cannot read {path}: {exc}") from exc


def extract_unique(pattern: re.Pattern[str], text: str, source: str) -> str:
    matches = pattern.findall(text)
    if not matches:
        raise RuntimeError(f"no protocol pin found in {source}")
    unique = sorted(set(matches))
    if len(unique) != 1:
        raise RuntimeError(
            f"conflicting protocol pins in {source}: {', '.join(unique)}"
        )
    return unique[0]


def local_pins(repo_root: Path) -> dict[str, str]:
    pins: dict[str, str] = {}
    for fixture in FIXTURE_FILES:
        text = read_text(repo_root / fixture)
        pins[fixture.as_posix()] = extract_unique(FIXTURE_HEADER_RE, text, str(fixture))
    doc = read_text(repo_root / FIXTURES_DOC)
    pins[FIXTURES_DOC.as_posix()] = extract_unique(DOC_PIN_RE, doc, str(FIXTURES_DOC))
    return pins


def upstream_binding() -> tuple[str, str]:
    with urllib.request.urlopen(COMPATIBILITY_URL, timeout=30) as response:
        raw = response.read()
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise RuntimeError(f"{COMPATIBILITY_URL} is not valid UTF-8: {exc}") from exc
    commit = extract_unique(UPSTREAM_COMMIT_RE, text, COMPATIBILITY_URL)
    version_match = UPSTREAM_VERSION_RE.search(text)
    version = version_match.group(1) if version_match else "unknown"
    return commit, version


def check(repo_root: Path) -> int:
    try:
        pins = local_pins(repo_root)
        upstream_commit, upstream_version = upstream_binding()
    except (RuntimeError, OSError, ValueError) as exc:
        print(f"protocol-sync: FAILED: {exc}", file=sys.stderr)
        return 1

    drifted = {source: pin for source, pin in pins.items() if pin != upstream_commit}
    if not drifted:
        print(
            f"protocol-sync: OK (server {upstream_version} @ {upstream_commit[:12]} "
            f"matches {len(pins)} pinned source(s))"
        )
        return 0

    print("protocol drift detected against the upstream reference SDK:", file=sys.stderr)
    print(f"  upstream binding: {upstream_version} @ {upstream_commit}", file=sys.stderr)
    for source, pin in drifted.items():
        print(f"  {source}: pinned {pin}", file=sys.stderr)
    print(
        "Re-pin the fixtures and .llm/research/protocol-fixtures.md to the new "
        "upstream commit, diff the protocol surface (messages, types, error "
        "codes), and re-verify the codec. See issue #12 for the ritual.",
        file=sys.stderr,
    )
    return 1


def self_test() -> int:
    sample_toml = (
        '# comment\nserver_version = "0.9.1"\n'
        'server_commit = "24a5d10b9e1700cdbef24f05dfe7fe1f0719ac3d"\n'
    )
    commit = extract_unique(UPSTREAM_COMMIT_RE, sample_toml, "sample.toml")
    assert commit == "24a5d10b9e1700cdbef24f05dfe7fe1f0719ac3d", commit
    version = UPSTREAM_VERSION_RE.search(sample_toml)
    assert version is not None and version.group(1) == "0.9.1"

    sample_fixture = (
        "# Signal Fish v2 server message fixtures\n"
        "# Source: signal-fish-server@24a5d10b9e1700cdbef24f05dfe7fe1f0719ac3d "
        "src/protocol/messages.rs\n"
        "# Source: signal-fish-server@24a5d10b9e1700cdbef24f05dfe7fe1f0719ac3d "
        "docs/protocol.md\n"
    )
    pinned = extract_unique(FIXTURE_HEADER_RE, sample_fixture, "fixture.jsonl")
    assert pinned == "24a5d10b9e1700cdbef24f05dfe7fe1f0719ac3d", pinned

    conflicting = (
        "# Source: signal-fish-server@24a5d10b9e1700cdbef24f05dfe7fe1f0719ac3d\n"
        "# Source: signal-fish-server@4f766b7856bead1e1cc07d4e7a1057831a045749\n"
    )
    try:
        extract_unique(FIXTURE_HEADER_RE, conflicting, "conflict.jsonl")
    except RuntimeError:
        pass
    else:
        raise AssertionError("conflicting pins must be rejected")

    doc = "- `signal-fish-server`: `24a5d10b9e1700cdbef24f05dfe7fe1f0719ac3d`\n"
    assert extract_unique(DOC_PIN_RE, doc, "doc.md") == (
        "24a5d10b9e1700cdbef24f05dfe7fe1f0719ac3d"
    )

    for empty in ("", "# no pins here"):
        try:
            extract_unique(DOC_PIN_RE, empty, "empty.md")
        except RuntimeError:
            pass
        else:
            raise AssertionError("missing pins must be rejected")

    # Offline structural check of the real repo: every pinned source must
    # contain exactly one parseable pin so header reformats surface here
    # instead of only in the weekly networked run.
    pins = local_pins(DEFAULT_REPO_ROOT)
    assert len(pins) == len(FIXTURE_FILES) + 1, pins
    print("protocol-sync: self-test passed")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=DEFAULT_REPO_ROOT)
    parser.add_argument("--self-test", action="store_true", help="offline self-test")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    return check(args.repo_root)


if __name__ == "__main__":
    sys.exit(main())
