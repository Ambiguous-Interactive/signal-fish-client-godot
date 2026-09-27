#!/usr/bin/env python3
"""Deterministic allow-list check for the Godot Asset Library archive."""

from __future__ import annotations

import argparse
import io
import os
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

# The Asset Library builds its download from the release ref. The addon alone
# belongs in that archive; its local README and LICENSE travel with it.
REQUIRED_ARCHIVE_ENTRIES = ("addons",)
ALLOWED_ARCHIVE_ENTRIES = frozenset(REQUIRED_ARCHIVE_ENTRIES)
TAR_BOOKKEEPING_ENTRIES = frozenset({"pax_global_header"})
# Update this list when intentionally adding or removing a shipped file.
# CI then checks the release tag's exact download, not just its directories.
REQUIRED_ARCHIVE_FILES = frozenset(
    {
        "addons/signal_fish/LICENSE",
        "addons/signal_fish/README.md",
        "addons/signal_fish/icon.png",
        "addons/signal_fish/icon.png.import",
        "addons/signal_fish/plugin.cfg",
        "addons/signal_fish/plugin.gd",
        "addons/signal_fish/protocol/sf_binary_codec.gd",
        "addons/signal_fish/protocol/sf_binary_frames.gd",
        "addons/signal_fish/protocol/sf_envelope.gd",
        "addons/signal_fish/protocol/sf_error_codes.gd",
        "addons/signal_fish/protocol/sf_events.gd",
        "addons/signal_fish/protocol/sf_game_data_format.gd",
        "addons/signal_fish/protocol/sf_json_guard.gd",
        "addons/signal_fish/protocol/sf_log.gd",
        "addons/signal_fish/protocol/sf_messages.gd",
        "addons/signal_fish/protocol/sf_msgpack.gd",
        "addons/signal_fish/protocol/sf_session_types.gd",
        "addons/signal_fish/protocol/sf_type_utils.gd",
        "addons/signal_fish/protocol/sf_types.gd",
        "addons/signal_fish/signal_fish_client.gd",
        "addons/signal_fish/signal_fish_config.gd",
        "addons/signal_fish/transport/sf_transport.gd",
        "addons/signal_fish/transport/sf_websocket_peer_adapter.gd",
        "addons/signal_fish/transport/sf_websocket_transport.gd",
        "addons/signal_fish/webrtc/sf_webrtc_mesh.gd",
    }
)


class ArchiveError(Exception):
    pass


def run_git(repo_root: Path, *args: str, env: dict[str, str] | None = None) -> bytes:
    result = subprocess.run(
        ["git", "-C", str(repo_root), *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    )
    if result.returncode != 0:
        raise ArchiveError(
            "git {} failed (exit {}): {}".format(
                " ".join(args), result.returncode, result.stderr.decode(errors="replace").strip()
            )
        )
    return result.stdout


def worktree_ref(repo_root: Path) -> str:
    """Write a temporary tree without changing the checkout's shared index."""
    with tempfile.TemporaryDirectory() as tmp:
        index = Path(tmp) / "index"
        env = {**os.environ, "GIT_INDEX_FILE": str(index)}
        run_git(repo_root, "read-tree", "HEAD", env=env)
        run_git(repo_root, "add", "--all", env=env)
        return run_git(repo_root, "write-tree", env=env).decode().strip()


def archive_entries(repo_root: Path, ref: str = "HEAD") -> tuple[list[str], list[str]]:
    """Directory and file entries the Asset Library download contains."""
    blob = run_git(repo_root, "archive", "--worktree-attributes", ref)
    top_level: set[str] = set()
    files: set[str] = set()
    with tarfile.open(fileobj=io.BytesIO(blob)) as archive:
        for member in archive.getmembers():
            name = member.name.split("/", 1)[0]
            # Kept as insurance: Python's tarfile normally consumes the
            # pax global header, but a future format change must never
            # surface it as a phantom repo entry.
            if name and name not in TAR_BOOKKEEPING_ENTRIES:
                top_level.add(name)
                if member.isfile():
                    files.add(member.name)
    return sorted(top_level), sorted(files)


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


def check_archive(
    repo_root: Path,
    expected_files: frozenset[str] = REQUIRED_ARCHIVE_FILES,
    ref: str = "HEAD",
) -> list[str]:
    errors: list[str] = []
    entries, files = archive_entries(repo_root, ref)
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
            "keep only addons/ unignored in .gitattributes"
        )
    shipped = set(entries)
    for entry in REQUIRED_ARCHIVE_ENTRIES:
        if entry not in shipped:
            errors.append(
                f"required asset entry '{entry}' is missing from the archive; "
                "fix or remove its export-ignore rule in .gitattributes"
            )
    for entry in sorted(set(files) - expected_files):
        errors.append(f"'{entry}' ships in the Asset Library archive but is not in the file manifest")
    for entry in sorted(expected_files - set(files)):
        errors.append(f"required asset file '{entry}' is missing from the archive")
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
    "addons/signal_fish/README.md": "# Signal Fish\n",
    "addons/signal_fish/LICENSE": "MIT\n",
    "demo/main.tscn": "[node]\n",
    "CHANGELOG.md": "# Changelog\n",
    "LICENSE": "MIT\n",
    "README.md": "# Signal Fish\n",
    "project.godot": "config_version=5\n",
}
GOOD_ATTRIBUTES = "/* export-ignore\n/addons !export-ignore\n/addons/** !export-ignore\n"


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
        expected = frozenset(name for name in ASSET_FILES if name.startswith("addons/"))
        expect(
            "clean archive",
            check_archive(root, expected) == [],
            f"unexpected errors: {check_archive(root, expected)}",
        )

        # Leak: a stray unignore rule cannot ship another top-level path.
        leaky = Path(tmp) / "leak"
        leaky.mkdir()
        write_self_test_repo(
            leaky,
            {**ASSET_FILES, "tools/build.py": "x = 1\n"},
            GOOD_ATTRIBUTES + "/tools !export-ignore\n/tools/** !export-ignore\n",
        )
        errors = check_archive(leaky, expected)
        expect("leak", any("'tools' ships" in error for error in errors), f"errors: {errors}")

        # Over-ignore: excluding a required entry must fail loudly.
        over = Path(tmp) / "over"
        over.mkdir()
        write_self_test_repo(
            over, ASSET_FILES, GOOD_ATTRIBUTES + "/addons/signal_fish/README.md export-ignore\n"
        )
        errors = check_archive(over, expected)
        expect(
            "over-ignore",
            any("'addons/signal_fish/README.md' is missing" in error for error in errors),
            f"errors: {errors}",
        )

        # Hygiene: a repeated pattern is a maintenance hazard.
        dup = Path(tmp) / "dup"
        dup.mkdir()
        write_self_test_repo(dup, ASSET_FILES, GOOD_ATTRIBUTES + "/addons !export-ignore\n")
        errors = check_archive(dup, expected)
        expect("duplicate", any("repeats the pattern" in error for error in errors), f"errors: {errors}")

        # Missing contract: no .gitattributes at all must fail with a clean,
        # actionable message instead of a traceback or a mangled warning.
        bare = Path(tmp) / "bare"
        bare.mkdir()
        write_self_test_repo(bare, ASSET_FILES)
        errors = check_archive(bare, expected)
        expect(
            "missing attributes",
            any(".gitattributes is missing" in error for error in errors),
            f"errors: {errors}",
        )

        # A test fixture hidden inside an allowed addon directory is still
        # not part of the user download.
        nested = Path(tmp) / "nested"
        nested.mkdir()
        write_self_test_repo(
            nested,
            {**ASSET_FILES, "addons/signal_fish/transport/sf_fake_transport.gd": "class_name Fake\n"},
            GOOD_ATTRIBUTES,
        )
        errors = check_archive(nested, expected)
        expect(
            "nested fixture",
            any("'addons/signal_fish/transport/sf_fake_transport.gd' ships" in error for error in errors),
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
    parser.add_argument(
        "--worktree", action="store_true", help="check current files using an isolated temporary index"
    )
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    repo_root = Path(args.repo_root).resolve()
    try:
        ref = worktree_ref(repo_root) if args.worktree else "HEAD"
        errors = check_archive(repo_root, ref=ref)
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
