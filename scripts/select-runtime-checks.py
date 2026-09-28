#!/usr/bin/env python3
"""Select fast runtime checks from the dirty tree and test preload graph."""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from collections import deque
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RUNNERS = (
    ("protocol", "tests/protocol/run_protocol_tests.gd"),
    ("transport", "tests/transport/run_transport_tests.gd"),
    ("client", "tests/client/run_client_tests.gd"),
    ("binary", "tests/client/run_binary_tests.gd"),
    ("reconnect", "tests/client/run_reconnect_tests.gd"),
)
REFERENCE = re.compile(r"\"(res://tests/(?:\\.|[^\"\\])*)\"|'(res://tests/(?:\\.|[^'\\])*)'")


@dataclass(frozen=True)
class Selection:
    mode: str
    docs: bool = False
    python: bool = False
    pins: bool = False
    suites: tuple[str, ...] = ()
    static_files: tuple[str, ...] = ()

    def encode(self) -> bytes:
        fields = [
            self.mode,
            str(int(self.docs)),
            str(int(self.python)),
            str(int(self.pins)),
            str(len(self.suites)),
            *self.suites,
            str(len(self.static_files)),
            *self.static_files,
        ]
        return b"\0".join(os.fsencode(field) for field in fields) + b"\0"


def dirty_files(root: Path) -> list[str]:
    commands = (
        ("git", "diff", "--name-only", "-z", "HEAD"),
        ("git", "ls-files", "-z", "--full-name", "--others", "--exclude-standard"),
    )
    paths: set[str] = set()
    for command in commands:
        output = subprocess.check_output(command, cwd=root)  # noqa: S603
        paths.update(os.fsdecode(path) for path in output.split(b"\0") if path)
    return sorted(paths)


def suites_for(files: list[str], root: Path) -> tuple[str, ...] | None:
    targets = set(files)
    selected: list[str] = []
    for name, runner in RUNNERS:
        queue = deque([runner])
        seen: set[str] = set()
        while queue:
            current = queue.popleft()
            if current in seen:
                continue
            seen.add(current)
            if current in targets:
                selected.append(name)
                break
            path = root / current
            if not path.is_file():
                continue
            for double, single in REFERENCE.findall(path.read_text()):
                ref = double or single
                if "\\" in ref:
                    return None
                dependency = ref.removeprefix("res://")
                if dependency not in seen:
                    queue.append(dependency)
    return tuple(selected)


def is_docs(path: str) -> bool:
    return (
        path.endswith(".md")
        or path == "llms.txt"
        or path.startswith(".markdownlint")
        or path == "LICENSE"
    )


def is_python(path: str) -> bool:
    return path.endswith(".py") or path in ("ruff.toml", "requirements-python-quality.txt")


def select(paths: list[str], root: Path) -> Selection:
    if not paths:
        return Selection("clean")
    docs = any(map(is_docs, paths))
    docs_only = all(map(is_docs, paths))
    if docs_only:
        return Selection("docs", docs=True)
    python = any(map(is_python, paths))
    python_only = all(is_python(path) or is_docs(path) for path in paths)
    pins = "requirements-ci.txt" in paths
    full = any(
        path.startswith(("addons/", "demo/", "scripts/", "tests/fixtures/"))
        or path in ("project.godot", "export_presets.cfg", "requirements-ci.txt")
        for path in paths
    )
    tests = [path for path in paths if path.startswith("tests/") and path.endswith(".gd")]
    static_files = tuple(
        path
        for path in paths
        if path.endswith(".gd")
        and (path.startswith(("addons/signal_fish/", "demo/", "scripts/")) or path in tests)
        and (root / path).is_file()
    )
    if full:
        return Selection("full", docs, python, pins, static_files=static_files)
    if python and python_only:
        return Selection("python", docs, python)
    suites = suites_for(tests, root)
    if suites is None:
        return Selection("uncertain", docs, python)
    if not suites:
        return Selection("unreferenced", docs, python)
    return Selection("suites", docs, python, suites=suites, static_files=static_files)


class SelectionTests(unittest.TestCase):
    def test_classification(self) -> None:
        root = ROOT
        cases: tuple[tuple[list[str], str], ...] = (
            ([], "clean"),
            (["README.md"], "docs"),
            (["scripts/tool.py"], "full"),
            (["ruff.toml", "README.md"], "python"),
            (["requirements-ci.txt"], "full"),
            (["tests/unreferenced.gd"], "unreferenced"),
        )
        for paths, mode in cases:
            with self.subTest(paths=paths):
                self.assertEqual(select(paths, root).mode, mode)

    def test_transitive_and_deleted_files(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            runner = root / RUNNERS[0][1]
            runner.parent.mkdir(parents=True)
            runner.write_text('preload("res://tests/shared/helper.gd")')
            helper = root / "tests/shared/helper.gd"
            helper.parent.mkdir(parents=True)
            helper.write_text('preload("res://tests/shared/deleted.gd")')
            picked = select(["tests/shared/deleted.gd"], root)
            self.assertEqual(picked.suites, ("protocol",))
            self.assertEqual(picked.static_files, ())
            helper.write_text('preload("res://tests/shared/odd file.gd")')
            client = root / RUNNERS[2][1]
            client.parent.mkdir(parents=True, exist_ok=True)
            client.write_text("extends SceneTree")
            picked = select(["tests/shared/odd file.gd", RUNNERS[2][1]], root)
            self.assertEqual(picked.suites, ("protocol", "client"))
            helper.write_text('preload("res://tests/shared/owner\'s_case.gd")')
            picked = select(["tests/shared/owner's_case.gd", RUNNERS[2][1]], root)
            self.assertEqual(picked.suites, ("protocol", "client"))
            helper.write_text("preload('res://tests/shared/owner\\'s.gd')")
            picked = select(["tests/shared/owner's.gd", RUNNERS[2][1]], root)
            self.assertEqual(picked.mode, "uncertain")

    def test_dirty_paths_preserve_newlines(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            git = shutil.which("git")
            if git is None:
                self.fail("git is required")
            subprocess.run((git, "init", "-q"), cwd=root, check=True)  # noqa: S603
            tracked = root / "README.md"
            tracked.write_text("initial\n")
            subprocess.run((git, "add", "README.md"), cwd=root, check=True)  # noqa: S603
            subprocess.run(  # noqa: S603
                (
                    git,
                    "-c",
                    "user.name=Test",
                    "-c",
                    "user.email=test@example.com",
                    "commit",
                    "-qm",
                    "init",
                ),
                cwd=root,
                check=True,
            )
            tracked.write_text("updated\n")
            (root / "odd\nname.md").write_text("new\n")
            self.assertEqual(dirty_files(root), ["README.md", "odd\nname.md"])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(SelectionTests)
        return 0 if unittest.TextTestRunner().run(suite).wasSuccessful() else 1
    sys.stdout.buffer.write(select(dirty_files(ROOT), ROOT).encode())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
