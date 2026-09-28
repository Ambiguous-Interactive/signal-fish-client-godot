#!/usr/bin/env python3
"""Validate a release and prepare its notes and addon ZIP."""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path


class ReleaseError(Exception):
    pass


def release_notes(changelog: str, version: str) -> str:
    heading = f"## [{version}]"
    lines = changelog.splitlines(keepends=True)
    start = next(
        (
            index + 1
            for index, line in enumerate(lines)
            if line.rstrip("\r\n") == heading or line.startswith(f"{heading} ")
        ),
        None,
    )
    if start is None:
        raise ReleaseError(
            f"no CHANGELOG.md section starting with {heading}; cut the changelog first"
        )
    end = next(
        (index for index in range(start, len(lines)) if lines[index].startswith("## ")), len(lines)
    )
    notes = "".join(lines[start:end])
    if not notes.strip():
        raise ReleaseError(f"CHANGELOG.md section {heading} has no release notes")
    return notes


def plugin_version(config: str) -> str:
    values: list[str] = re.findall(r"^\s*version\s*=\s*(.+?)\s*$", config, flags=re.MULTILINE)
    if len(values) != 1:
        raise ReleaseError("addons/signal_fish/plugin.cfg must define one version")
    return values[0].strip("\"'")


def prepare(repo_root: Path, version: str, github_env: Path) -> Path:
    if re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", version) is None:
        raise ReleaseError("version must be a single vMAJOR.MINOR.PATCH token (e.g. v0.1.0)")
    notes = release_notes((repo_root / "CHANGELOG.md").read_text(encoding="utf-8"), version)
    config_path = repo_root / "addons/signal_fish/plugin.cfg"
    if not config_path.is_file():
        raise ReleaseError(
            f"{config_path.relative_to(repo_root)} is missing; the Asset Library requires it"
        )
    actual = plugin_version(config_path.read_text(encoding="utf-8"))
    expected = version[1:]
    if actual != expected:
        raise ReleaseError(
            f"addons/signal_fish/plugin.cfg version '{actual}' != release {expected}"
        )

    archive = repo_root / f"signal-fish-godot-{version}.zip"
    result = subprocess.run(  # noqa: S603
        ["git", "archive", "--format=zip", f"--output={archive}", "HEAD", "addons"],  # noqa: S607
        cwd=repo_root,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise ReleaseError(f"git archive failed: {result.stderr.strip()}")
    (repo_root / "release-notes.md").write_text(notes, encoding="utf-8")
    with github_env.open("a", encoding="utf-8") as output:
        output.write(f"VERSION={version}\n")
    return archive


class PrepareReleaseTests(unittest.TestCase):
    def test_release_content_and_archive(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            git = shutil.which("git")
            if git is None:
                self.fail("git is required for the release test")
            (root / "addons/signal_fish").mkdir(parents=True)
            (root / "addons/signal_fish/plugin.cfg").write_text(
                '[plugin]\nversion="1.2.3"\n', encoding="utf-8"
            )
            (root / "addons/signal_fish/plugin.gd").write_text(
                "extends EditorPlugin\n", encoding="utf-8"
            )
            (root / "CHANGELOG.md").write_text(
                "## [v1.2.3] - today\n\n### Fixed\n\n- A bug.\n\n## [v1.2.2] - before\n- Old.\n",
                encoding="utf-8",
            )
            subprocess.run([git, "init", "-q"], cwd=root, check=True)  # noqa: S603
            subprocess.run([git, "add", "-A"], cwd=root, check=True)  # noqa: S603
            subprocess.run(  # noqa: S603
                [
                    git,
                    "-c",
                    "user.name=test",
                    "-c",
                    "user.email=test@example.com",
                    "commit",
                    "-qm",
                    "fixture",
                ],
                cwd=root,
                check=True,
            )
            github_env = root / "github-env"
            archive = prepare(root, "v1.2.3", github_env)
            self.assertEqual(github_env.read_text(encoding="utf-8"), "VERSION=v1.2.3\n")
            self.assertEqual(
                (root / "release-notes.md").read_text(encoding="utf-8"),
                "\n### Fixed\n\n- A bug.\n\n",
            )
            with zipfile.ZipFile(archive) as package:
                self.assertEqual(
                    set(package.namelist()),
                    {
                        "addons/",
                        "addons/signal_fish/",
                        "addons/signal_fish/plugin.cfg",
                        "addons/signal_fish/plugin.gd",
                    },
                )
            for bad in ("v1.2.3\nBAD=1", "v1.2.3-extra", "../v1.2.3"):
                with self.subTest(bad=bad), self.assertRaises(ReleaseError):
                    prepare(root, bad, github_env)
            (root / "addons/signal_fish/plugin.cfg").write_text(
                'version="1.2.2"\n', encoding="utf-8"
            )
            with self.assertRaisesRegex(ReleaseError, "version '1.2.2'"):
                prepare(root, "v1.2.3", github_env)

    def test_empty_or_missing_notes(self) -> None:
        for changelog in ("## [v1.2.3]\n\n## [v1.2.2]\n- Old\n", "## [v1.2.2]\n- Old\n"):
            with self.subTest(changelog=changelog), self.assertRaises(ReleaseError):
                release_notes(changelog, "v1.2.3")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=Path("."))
    parser.add_argument("--version")
    parser.add_argument("--github-env", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(PrepareReleaseTests)
        return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1
    if args.version is None or args.github_env is None:
        parser.error("--version and --github-env are required")
    try:
        archive = prepare(args.repo_root.resolve(), args.version, args.github_env)
    except (OSError, ReleaseError) as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 1
    print((args.repo_root / "release-notes.md").read_text(encoding="utf-8"))
    print(f"Prepared {archive.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
