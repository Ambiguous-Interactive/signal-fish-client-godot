#!/usr/bin/env python3
"""Deterministic allow-list check for the Godot Asset Library archive."""

from __future__ import annotations

import argparse
import io
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

# The Asset Library generates the user download from the release tag ref and
# `git archive` applies `.gitattributes` export-ignore. Per the pinned
# surface (issue #139), users get the addon, the runnable demo
# (+ project.godot), and LICENSE/README/CHANGELOG - anything else in the
# archive is a leak that ships to every user (issue #158).
REQUIRED_ARCHIVE_ENTRIES = (
    "CHANGELOG.md",
    "LICENSE",
    "README.md",
    "addons",
    "demo",
    "project.godot",
)
ALLOWED_ARCHIVE_ENTRIES = frozenset(REQUIRED_ARCHIVE_ENTRIES)
TAR_BOOKKEEPING_ENTRIES = frozenset({"pax_global_header"})


class ArchiveError(Exception):
    pass


def run_git(repo_root: Path, *args: str) -> bytes:
    result = subprocess.run(
        ["git", "-C", str(repo_root), *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        raise ArchiveError(
            "git {} failed (exit {}): {}".format(
                " ".join(args), result.returncode, result.stderr.decode(errors="replace").strip()
            )
        )
    return result.stdout


def archive_top_level_entries(repo_root: Path) -> list[str]:
    """Top-level entries `git archive HEAD` ships, exactly what Asset
    Library users download."""
    blob = run_git(repo_root, "archive", "HEAD")
    entries: set[str] = set()
    with tarfile.open(fileobj=io.BytesIO(blob)) as archive:
        for member in archive.getmembers():
            name = member.name.split("/", 1)[0]
            # Kept as insurance: Python's tarfile normally consumes the
            # pax global header, but a future format change must never
            # surface it as a phantom repo entry.
            if name and name not in TAR_BOOKKEEPING_ENTRIES:
                entries.add(name)
    return sorted(entries)


def duplicate_gitattributes_patterns(path: Path) -> list[str]:
    attributes = path.read_text(encoding="utf-8").splitlines()
    seen: set[str] = set()
    duplicates: list[str] = []
    for line in attributes:
        pattern = line.strip()
        if not pattern or pattern.startswith("#"):
            continue
        if pattern in seen and pattern not in duplicates:
            duplicates.append(pattern)
        seen.add(pattern)
    return duplicates


def check_archive(repo_root: Path) -> list[str]:
    errors: list[str] = []
    entries = archive_top_level_entries(repo_root)
    attributes = repo_root / ".gitattributes"
    if not attributes.is_file():
        errors.append(".gitattributes is missing; the export-ignore contract cannot be checked")
    else:
        for pattern in duplicate_gitattributes_patterns(attributes):
            errors.append(f".gitattributes repeats the pattern {pattern!r}; keep one rule per path")
    leaks = [entry for entry in entries if entry not in ALLOWED_ARCHIVE_ENTRIES]
    for entry in leaks:
        errors.append(
            f"'{entry}' ships in the Asset Library archive but is not allow-listed; "
            f"add '/{entry} export-ignore' to .gitattributes (issue #158)"
        )
    shipped = set(entries)
    for entry in REQUIRED_ARCHIVE_ENTRIES:
        if entry not in shipped:
            errors.append(
                f"required asset entry '{entry}' is missing from the archive; "
                "fix or remove its export-ignore rule in .gitattributes"
            )
    return errors


def write_self_test_repo(root: Path, files: dict[str, str], attributes: str = "") -> None:
    for name, content in files.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
    if attributes:
        (root / ".gitattributes").write_text(attributes, encoding="utf-8")
    run_git(root, "init", "-q")
    run_git(root, "add", "-A")
    run_git(
        root,
        "-c",
        "user.name=asset-check",
        "-c",
        "user.email=asset-check@example.com",
        "commit",
        "-q",
        "--no-gpg-sign",
        "--no-verify",
        "-m",
        "fixture",
    )


ASSET_FILES = {
    "addons/signal_fish/plugin.cfg": "[plugin]\n",
    "demo/main.tscn": "[node]\n",
    "CHANGELOG.md": "# Changelog\n",
    "LICENSE": "MIT\n",
    "README.md": "# Signal Fish\n",
    "project.godot": "config_version=5\n",
}
GOOD_ATTRIBUTES = "/.gitattributes export-ignore\n/scripts export-ignore\n"


def self_test() -> int:
    failures: list[str] = []

    def expect(case: str, condition: bool, detail: str) -> None:
        if not condition:
            failures.append(f"{case}: {detail}")

    with tempfile.TemporaryDirectory() as tmp:
        # Pinned surface: clean archive passes.
        root = Path(tmp) / "ok"
        root.mkdir()
        write_self_test_repo(root, ASSET_FILES, GOOD_ATTRIBUTES)
        expect("clean archive", check_archive(root) == [], f"unexpected errors: {check_archive(root)}")

        # Leak: a tracked top-level path without export-ignore must be named.
        leaky = Path(tmp) / "leak"
        leaky.mkdir()
        write_self_test_repo(leaky, {**ASSET_FILES, "tools/build.py": "x = 1\n"}, GOOD_ATTRIBUTES)
        errors = check_archive(leaky)
        expect("leak", any("'tools' ships" in error for error in errors), f"errors: {errors}")

        # Over-ignore: excluding a required entry must fail loudly.
        over = Path(tmp) / "over"
        over.mkdir()
        write_self_test_repo(over, ASSET_FILES, GOOD_ATTRIBUTES + "/README.md export-ignore\n")
        errors = check_archive(over)
        expect("over-ignore", any("'README.md' is missing" in error for error in errors), f"errors: {errors}")

        # Hygiene: a repeated pattern is a maintenance hazard.
        dup = Path(tmp) / "dup"
        dup.mkdir()
        write_self_test_repo(dup, ASSET_FILES, GOOD_ATTRIBUTES + "/scripts export-ignore\n")
        errors = check_archive(dup)
        expect("duplicate", any("repeats the pattern" in error for error in errors), f"errors: {errors}")

        # Missing contract: no .gitattributes at all must fail with a clean,
        # actionable message instead of a traceback or a mangled warning.
        bare = Path(tmp) / "bare"
        bare.mkdir()
        write_self_test_repo(bare, ASSET_FILES)
        errors = check_archive(bare)
        expect(
            "missing attributes",
            any(".gitattributes is missing" in error for error in errors),
            f"errors: {errors}",
        )

    if failures:
        for failure in failures:
            print(f"SELF-TEST FAIL: {failure}", file=sys.stderr)
        return 1
    print("check-asset-archive: self-test passed")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", default=".", help="repository root to check (default: .)")
    parser.add_argument("--self-test", action="store_true", help="run the self-test and exit")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    repo_root = Path(args.repo_root).resolve()
    try:
        errors = check_archive(repo_root)
    except ArchiveError as exc:
        print(f"check-asset-archive: {exc}", file=sys.stderr)
        return 2
    if errors:
        for error in errors:
            print(f"check-asset-archive: {error}", file=sys.stderr)
        return 1
    print("check-asset-archive: archive surface matches the allow-list")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
