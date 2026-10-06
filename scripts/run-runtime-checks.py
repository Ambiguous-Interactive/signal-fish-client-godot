#!/usr/bin/env python3
"""Select and run the local and CI runtime checks."""

import argparse
import contextlib
import importlib.util
import io
import os
import re
import shutil
import site
import subprocess
import sys
import tempfile
import unittest
from collections import deque
from collections.abc import Sequence
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from functools import cache
from pathlib import Path
from unittest.mock import call, patch

ROOT = Path(__file__).resolve().parents[1]
RUNNERS = (
    ("protocol", "tests/protocol/run_protocol_tests.gd"),
    ("transport", "tests/transport/run_transport_tests.gd"),
    ("client", "tests/client/run_client_tests.gd"),
    ("binary", "tests/client/run_binary_tests.gd"),
    ("reconnect", "tests/client/run_reconnect_tests.gd"),
)
REFERENCE = re.compile(r"\"(res://tests/(?:\\.|[^\"\\])*)\"|'(res://tests/(?:\\.|[^'\\])*)'")
BOOTSTRAP_MARKER = "SF_RUNTIME_BOOTSTRAPPED"


def bootstrap_environment() -> None:
    if os.environ.pop(BOOTSTRAP_MARKER, None):
        return
    venv = ROOT / ".venv-ci"
    activate = venv / "bin" / "activate"
    user_site = site.getusersitepackages() if not activate.is_file() else ""
    home = Path(
        os.environ.get("GDSCRIPT_TOOL_HOME")
        or Path(os.environ.get("RUNNER_TEMP") or "/tmp") / "signal-fish-runtime-home"  # noqa: S108
    )
    home.mkdir(parents=True, exist_ok=True)
    os.environ["HOME"] = str(home)
    os.environ["GDTOOLKIT_CACHE_DIR"] = os.environ.get("GDTOOLKIT_CACHE_DIR") or str(
        home / "gdtoolkit-cache"
    )
    if activate.is_file():
        os.environ["VIRTUAL_ENV"] = str(venv)
        venv_bin = str(venv / "bin")
        if os.environ.get("PATH", "").split(os.pathsep)[0] != venv_bin:
            os.environ["PATH"] = f"{venv_bin}{os.pathsep}{os.environ.get('PATH', '')}"
        os.environ.pop("PYTHONHOME", None)
        command = os.environ.get("PYTHON") or "python3"
        os.environ[BOOTSTRAP_MARKER] = "1"
        try:
            os.execvpe(command, [command, *sys.argv], os.environ)  # noqa: S606
        except OSError as exc:
            print(f"{command}: {exc}", file=sys.stderr)
            raise SystemExit(1) from exc
    if venv.is_dir():
        print(
            "::warning::.venv-ci is missing bin/activate; using user site-packages", file=sys.stderr
        )
    if venv.is_dir() or Path(user_site).is_dir():
        os.environ["PYTHONPATH"] = (
            f"{user_site}{os.pathsep}{os.environ['PYTHONPATH']}"
            if os.environ.get("PYTHONPATH")
            else user_site
        )


@dataclass(frozen=True)
class Selection:
    mode: str
    docs: bool = False
    python: bool = False
    pins: bool = False
    prettier: bool = False
    markdownlint: bool = False
    suites: tuple[str, ...] = ()
    static_files: tuple[str, ...] = ()


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


@cache
def prettier_suffixes() -> tuple[str, ...]:
    path = ROOT / "scripts" / "check-source.py"
    spec = importlib.util.spec_from_file_location("check-source", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return tuple(pattern.removeprefix("*") for pattern in sorted(module.PRETTIER_SUFFIXES))


def is_prettier(path: str) -> bool:
    return path.endswith(prettier_suffixes())


def is_markdownlint(path: str) -> bool:
    return path.endswith(".md") or path.startswith(".markdownlint")


def is_python(path: str) -> bool:
    return path.endswith(".py") or path in ("ruff.toml", "requirements-python-quality.txt")


def select(paths: list[str], root: Path) -> Selection:
    if not paths:
        return Selection("clean")
    docs = any(map(is_docs, paths))
    prettier = any(map(is_prettier, paths))
    markdownlint = any(map(is_markdownlint, paths))
    docs_only = all(map(is_docs, paths))
    if docs_only:
        return Selection("docs", docs=True, prettier=prettier, markdownlint=markdownlint)
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
        return Selection(
            "full",
            docs,
            python,
            pins,
            prettier=prettier,
            markdownlint=markdownlint,
            static_files=static_files,
        )
    if python and python_only:
        return Selection("python", docs, python, prettier=prettier, markdownlint=markdownlint)
    if prettier and all(map(is_prettier, paths)):
        return Selection("prettier", docs=docs, prettier=True, markdownlint=markdownlint)
    suites = suites_for(tests, root)
    if suites is None:
        return Selection("uncertain", docs, python, prettier=prettier, markdownlint=markdownlint)
    if not suites:
        return Selection("unreferenced", docs, python, prettier=prettier, markdownlint=markdownlint)
    return Selection(
        "suites",
        docs,
        python,
        prettier=prettier,
        markdownlint=markdownlint,
        suites=suites,
        static_files=static_files,
    )


class SelectionTests(unittest.TestCase):
    def test_bootstrap_uses_venv_and_preserves_override(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            activate = root / ".venv-ci/bin/activate"
            activate.parent.mkdir(parents=True)
            activate.touch()
            environment = {
                "RUNNER_TEMP": folder,
                "PATH": "/usr/bin",
                "PYTHON": "/custom/python",
                "PYTHONHOME": "/old/home",
                "GDTOOLKIT_CACHE_DIR": "/custom/cache",
            }
            with (
                patch.dict(os.environ, environment, clear=True),
                patch(f"{__name__}.ROOT", root),
                patch("os.execvpe", side_effect=RuntimeError("exec intercepted")) as execute,
            ):
                with self.assertRaisesRegex(RuntimeError, "exec intercepted"):
                    bootstrap_environment()
                command, argv, actual = execute.call_args.args
                self.assertEqual(command, "/custom/python")
                self.assertEqual(argv[0], "/custom/python")
                self.assertEqual(actual["VIRTUAL_ENV"], str(root / ".venv-ci"))
                self.assertTrue(actual["PATH"].startswith(f"{root / '.venv-ci/bin'}:"))
                self.assertEqual(actual["HOME"], f"{folder}/signal-fish-runtime-home")
                self.assertEqual(actual["GDTOOLKIT_CACHE_DIR"], "/custom/cache")
                self.assertNotIn("PYTHONHOME", actual)

    def test_bootstrap_falls_back_to_original_user_site(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            user_site = root / "original-site"
            user_site.mkdir()
            for broken in (False, True):
                with self.subTest(broken=broken):
                    if broken:
                        (root / ".venv-ci").mkdir()
                    with (
                        patch.dict(
                            os.environ,
                            {
                                "GDSCRIPT_TOOL_HOME": str(root / "cache"),
                                "GDTOOLKIT_CACHE_DIR": "",
                                "PYTHONPATH": "/existing",
                            },
                            clear=True,
                        ),
                        patch(f"{__name__}.ROOT", root),
                        patch("site.getusersitepackages", return_value=str(user_site)),
                        contextlib.redirect_stderr(io.StringIO()) as errors,
                    ):
                        bootstrap_environment()
                        self.assertEqual(os.environ["PYTHONPATH"], f"{user_site}:/existing")
                        self.assertEqual(os.environ["HOME"], str(root / "cache"))
                        self.assertEqual(
                            os.environ["GDTOOLKIT_CACHE_DIR"], str(root / "cache/gdtoolkit-cache")
                        )
                        self.assertTrue(Path(os.environ["HOME"]).is_dir())
                    self.assertEqual("missing bin/activate" in errors.getvalue(), broken)

    def test_classification(self) -> None:
        root = ROOT
        cases: tuple[tuple[list[str], str], ...] = (
            ([], "clean"),
            (["README.md"], "docs"),
            (["scripts/tool.py"], "full"),
            (["ruff.toml", "README.md"], "python"),
            (["requirements-ci.txt"], "full"),
            (["tests/unreferenced.gd"], "unreferenced"),
            ([".github/workflows/ci.yml"], "prettier"),
            (["PLAN.md", ".github/workflows/ci.yml"], "prettier"),
        )
        for paths, mode in cases:
            with self.subTest(paths=paths):
                self.assertEqual(select(paths, root).mode, mode)
        self.assertTrue(select(["README.md"], root).prettier)
        self.assertFalse(select(["llms.txt"], root).prettier)
        markdownlint_cases: tuple[tuple[list[str], bool], ...] = (
            (["README.md"], True),
            ([".markdownlint.json"], True),
            ([".markdownlint-cli2.jsonc"], True),
            (["llms.txt"], False),
            (["LICENSE"], False),
            ([".github/workflows/ci.yml"], False),
        )
        for paths, wanted in markdownlint_cases:
            with self.subTest(paths=paths):
                self.assertEqual(select(paths, root).markdownlint, wanted)
        mixed = select(["PLAN.md", "tests/client/run_client_tests.gd"], root)
        self.assertEqual(mixed.mode, "suites")
        self.assertTrue(mixed.prettier)
        self.assertTrue(mixed.markdownlint)

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

    def test_full_dispatch_keeps_empty_scope_and_pin_gate(self) -> None:
        cases = (
            (
                Selection("full", python=True),
                [
                    script("run-runtime-static.py", "scoped"),
                    script("run-runtime-static.py", "python-types"),
                ],
            ),
            (
                Selection("full", python=True, pins=True),
                [script("run-runtime-static.py", "static")],
            ),
        )
        for selection, background in cases:
            with self.subTest(selection=selection):
                with (
                    patch(f"{__name__}.concurrent", return_value=0) as dispatch,
                    contextlib.redirect_stdout(io.StringIO()),
                ):
                    self.assertEqual(run_changed(selection), 0)
                dispatch.assert_called_once_with(
                    script("run-runtime-godot.py", "godot"), background
                )

    def test_all_dispatch_runs_static_and_node_checks_beside_the_suites(self) -> None:
        with (
            patch(f"{__name__}.concurrent", return_value=0) as dispatch,
            contextlib.redirect_stdout(io.StringIO()),
        ):
            self.assertEqual(run_all(), 0)
        dispatch.assert_called_once_with(
            script("run-runtime-godot.py", "godot"),
            [
                script("run-runtime-static.py", "static"),
                script("run-runtime-static.py", "prettier"),
                script("run-runtime-static.py", "markdownlint"),
            ],
        )

    def test_docs_and_node_dispatch_runs_style_and_node_checks(self) -> None:
        style = script("check-docs-style.py", "--changed")
        prettier = script("run-runtime-static.py", "prettier")
        markdownlint = script("run-runtime-static.py", "markdownlint")
        cases: tuple[tuple[Selection, list[object], list[object]], ...] = (
            (Selection("docs", docs=True), [], [call(style)]),
            (Selection("docs", docs=True, prettier=True), [call(style, [prettier])], []),
            (
                Selection("docs", docs=True, prettier=True, markdownlint=True),
                [call(style, [prettier, markdownlint])],
                [],
            ),
            (
                Selection("prettier", docs=True, prettier=True, markdownlint=True),
                [call(style, [prettier, markdownlint])],
                [],
            ),
            (Selection("prettier", prettier=True), [], [call(prettier)]),
            (
                Selection("suites", prettier=True, suites=("protocol",)),
                [
                    call(
                        script("run-runtime-godot.py", "godot", "protocol"),
                        [script("run-runtime-static.py", "scoped")],
                    )
                ],
                [call(prettier)],
            ),
            (
                Selection("suites", markdownlint=True, suites=("protocol",)),
                [
                    call(
                        script("run-runtime-godot.py", "godot", "protocol"),
                        [script("run-runtime-static.py", "scoped")],
                    )
                ],
                [call(markdownlint)],
            ),
        )
        for selection, fanout, direct_calls in cases:
            with self.subTest(selection=selection):
                with (
                    patch(f"{__name__}.concurrent", return_value=0) as concurrent_mock,
                    patch(f"{__name__}.direct", return_value=0) as direct_mock,
                    contextlib.redirect_stdout(io.StringIO()),
                ):
                    self.assertEqual(run_changed(selection), 0)
                self.assertEqual(concurrent_mock.call_args_list, fanout)
                self.assertEqual(direct_mock.call_args_list, direct_calls)


def script(name: str, *args: str) -> list[str]:
    return [sys.executable, str(ROOT / "scripts" / name), *args]


def direct(command: Sequence[str]) -> int:
    try:
        return subprocess.run(command, cwd=ROOT, check=False).returncode  # noqa: S603
    except OSError as exc:
        print(f"{command[0]}: {exc}", file=sys.stderr)
        return 1


def captured(command: Sequence[str]) -> tuple[int, str]:
    try:
        result = subprocess.run(  # noqa: S603
            command,
            cwd=ROOT,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            errors="replace",
        )
    except OSError as exc:
        return 1, f"{command[0]}: {exc}\n"
    return result.returncode, result.stdout


def concurrent(primary: Sequence[str], background: Sequence[Sequence[str]]) -> int:
    with ThreadPoolExecutor(max_workers=len(background)) as pool:
        futures = [pool.submit(captured, command) for command in background]
        primary_status = direct(primary)
        results = [future.result() for future in futures]
    for _, output in results:
        print(output, end="")
    return int(primary_status != 0 or any(status != 0 for status, _ in results))


def run_all() -> int:
    return concurrent(
        script("run-runtime-godot.py", "godot"),
        [
            script("run-runtime-static.py", "static"),
            script("run-runtime-static.py", "prettier"),
            script("run-runtime-static.py", "markdownlint"),
        ],
    )


def run_changed(selection: Selection) -> int:
    if selection.mode == "clean":
        print("working tree clean; nothing to check")
        return 0
    docs = script("check-docs-style.py", "--changed")
    node_checks = [
        script("run-runtime-static.py", name)
        for name, wanted in (
            ("prettier", selection.prettier),
            ("markdownlint", selection.markdownlint),
        )
        if wanted
    ]
    if selection.mode == "docs":
        if not node_checks:
            print(
                "=== changed: docs-only edit -> style check (runtime suites unaffected) ===",
                flush=True,
            )
            return direct(docs)
        names = " and ".join(check[-1] for check in node_checks)
        print(f"=== changed: docs-only edit -> style and {names} checks ===", flush=True)
        return concurrent(docs, node_checks)
    if selection.mode == "prettier":
        if selection.docs:
            print(
                "=== changed: docs and prettier-covered edits -> style and node checks ===",
                flush=True,
            )
            return concurrent(docs, node_checks)
        print("=== changed: prettier-covered edit -> node checks ===", flush=True)
        for check in node_checks:
            status = direct(check)
            if status != 0:
                return status
        return 0
    if selection.docs:
        status = direct(docs)
        if status != 0:
            return status
    for check in node_checks:
        status = direct(check)
        if status != 0:
            return status
    python_types = script("run-runtime-static.py", "python-types")
    if selection.mode == "python":
        print("=== changed: Python-only edit -> types, lint, format ===", flush=True)
        return direct(python_types)
    if selection.python and selection.mode != "full":
        status = direct(python_types)
        if status != 0:
            return status

    static = script("run-runtime-static.py", "static")
    godot = script("run-runtime-godot.py", "godot")
    if selection.mode == "full":
        if selection.pins:
            print("=== changed: tooling edit -> all suites and full static checks ===", flush=True)
            background = [static]
        else:
            print(
                "=== changed: production-side edit -> all suites, static scoped to the edit ===",
                flush=True,
            )
            background = [script("run-runtime-static.py", "scoped", *selection.static_files)]
            if selection.python:
                background.append(python_types)
        return concurrent(godot, background)

    if selection.mode in ("unreferenced", "uncertain"):
        if selection.mode == "uncertain":
            print("=== changed: uncertain test preload -> full gate ===", flush=True)
        else:
            print("=== changed: unreferenced test file -> full gate ===", flush=True)
        status = direct(static)
        return status if status != 0 else direct(godot)

    if selection.mode == "suites":
        print(f"=== changed: suites {' '.join(selection.suites)} ===", flush=True)
        return concurrent(
            script("run-runtime-godot.py", "godot", *selection.suites),
            [script("run-runtime-static.py", "scoped", *selection.static_files)],
        )
    print(f"unknown selection mode: {selection.mode}", file=sys.stderr)
    return 2


def main() -> int:
    bootstrap_environment()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("command", nargs="?", default="all")
    parser.add_argument("suites", nargs="*")
    args = parser.parse_args()
    if args.self_test:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(SelectionTests)
        return 0 if unittest.TextTestRunner().run(suite).wasSuccessful() else 1
    if args.command == "all":
        return run_all()
    if args.command in (
        "static",
        "gdscript-static",
        "python-types",
        "private-helpers",
        "warning-pins",
        "format",
        "lint",
        "prettier",
        "markdownlint",
    ):
        return direct(script("run-runtime-static.py", args.command))
    if args.command == "godot":
        return direct(script("run-runtime-godot.py", "godot", *args.suites))
    if args.command == "smoke":
        return direct(script("run-runtime-godot.py", "smoke"))
    if args.command == "steam-drill":
        return direct(script("run-runtime-godot.py", "steam-drill"))
    if args.command == "steam-ext":
        return direct(script("run-runtime-godot.py", "steam-ext"))
    if args.command == "changed":
        return run_changed(select(dirty_files(ROOT), ROOT))
    parser.print_help(sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
