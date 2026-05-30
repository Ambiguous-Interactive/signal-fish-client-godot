#!/usr/bin/env python3
"""Fail on GDScript helpers and references that are fragile in CI.

The check uses gdtoolkit's GDScript parser, then treats public methods,
Godot lifecycle callbacks, signal-style `_on_*` handlers, and constructors as
reachability roots. Private methods that cannot be reached from those roots in
their own script or nested class scope are reported as likely dead scaffolding.

It also rejects references to a script's own `class_name` through `ClassName.`
because those depend on Godot's ignored global class cache and can compile in a
warm local checkout while failing from a fresh CI clone.

Intentional reflection-only helpers can be suppressed by placing this comment
on the helper definition line or the immediately preceding line:

    # gdscript-private-helper: allow _helper_name

Group dispatch (`call_group`, `call_group_flags`) is not treated as local
reachability because the analyzer cannot prove the current script is in the
target group. Use the local allow comment for intentional group-only handlers.
"""

from __future__ import annotations

import argparse
import ast
import os
import re
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable

try:
    from gdtoolkit.parser import parser as gd_parser
    from lark import Token, Tree
except ImportError as exc:  # pragma: no cover - exercised by humans without tooling.
    print(
        "error: gdtoolkit is required. Install it with `python3 -m pip install gdtoolkit`.",
        file=sys.stderr,
    )
    raise SystemExit(2) from exc


DEFAULT_PATHS = ("addons/signal_fish", "tests")
EXCLUDED_PARTS = {".git", ".godot", ".import", "__pycache__", "gdUnit4", "gut"}
ALLOW_COMMENT = re.compile(
    r"#\s*gdscript-private-helper:\s*allow\s+([A-Za-z_][A-Za-z0-9_]*)"
)

GODOT_PRIVATE_ROOTS = {
    "_apply_changes",
    "_build",
    "_can_drop_data",
    "_can_handle",
    "_can_import_threaded",
    "_can_make_function",
    "_can_use_render_priority",
    "_clips_input",
    "_disable_plugin",
    "_draw",
    "_drop_data",
    "_edit",
    "_enable_plugin",
    "_enter_tree",
    "_exit_tree",
    "_export_begin",
    "_export_end",
    "_export_file",
    "_forward_3d_draw_over_viewport",
    "_forward_3d_force_draw_over_viewport",
    "_forward_3d_gui_input",
    "_forward_canvas_draw_over_viewport",
    "_forward_canvas_force_draw_over_viewport",
    "_forward_canvas_gui_input",
    "_get",
    "_get_android_dependencies",
    "_get_android_dependencies_maven_repos",
    "_get_android_libraries",
    "_get_android_manifest_activity_element_contents",
    "_get_android_manifest_application_element_contents",
    "_get_android_manifest_element_contents",
    "_get_configuration_warnings",
    "_get_drag_data",
    "_get_export_options",
    "_get_export_option_warning",
    "_get_global_class_name",
    "_get_import_options",
    "_get_import_order",
    "_get_importer_name",
    "_get_option_visibility",
    "_get_plugin_icon",
    "_get_plugin_name",
    "_get_preset_count",
    "_get_preset_name",
    "_get_property_list",
    "_get_recognized_extensions",
    "_get_resource_type",
    "_get_save_extension",
    "_get_state",
    "_get_tooltip",
    "_gui_input",
    "_handles",
    "_handles_global_class_type",
    "_handles_type",
    "_has_main_screen",
    "_has_point",
    "_init",
    "_input",
    "_input_event",
    "_integrate_forces",
    "_import",
    "_import_post",
    "_make_custom_tooltip",
    "_make_visible",
    "_notification",
    "_parse_begin",
    "_parse_category",
    "_parse_end",
    "_parse_group",
    "_parse_property",
    "_physics_process",
    "_post_import",
    "_process",
    "_property_can_revert",
    "_property_get_revert",
    "_ready",
    "_set",
    "_shortcut_input",
    "_structured_text_parser",
    "_tile_data_runtime_update",
    "_to_string",
    "_unhandled_input",
    "_unhandled_key_input",
    "_use_tile_data_runtime_update",
    "_validate_property",
}

DYNAMIC_SELF_METHOD_STRING_ARGUMENTS = {
    "call": {0},
    "call_deferred": {0},
    "callv": {0},
    "rpc": {0},
    "rpc_id": {1},
}

DYNAMIC_TARGET_METHOD_STRING_ARGUMENTS = {
    "Callable": (0, 1),
    "connect": (1, 2),
    "disconnect": (1, 2),
    "funcref": (0, 1),
}

CALLABLE_ARGUMENT_CALLS = {
    "Callable",
    "connect",
    "disconnect",
    "start",
}

TREE_WALK_SKIP = {
    "class_def",
    "func_def",
    "func_header",
    "static_func_def",
}

CLASS_BODY_SKIP = {
    "class_def",
    "func_def",
    "static_func_def",
}

# Keep this as an executable invariant: helper-ish names should not become roots
# just because Godot has many underscore-prefixed virtual methods.
NON_ROOT_SELF_TEST_NAMES = {
    "_has_number",
    "_is_number",
    "_local_players_from_array",
}


@dataclass
class FunctionDef:
    name: str
    node: Tree
    line: int


@dataclass
class Scope:
    name: str
    node: Tree
    functions: dict[str, FunctionDef] = field(default_factory=dict)
    children: list["Scope"] = field(default_factory=list)


@dataclass(frozen=True)
class Problem:
    path: str
    line: int
    scope: str
    name: str
    kind: str = "private-helper"

    def format(self) -> str:
        if self.scope == "<parse>":
            return f"{self.path}:{self.line}: {self.name}"
        if self.kind == "self-class-reference":
            return (
                f"{self.path}:{self.line}: self class reference {self.name} depends on "
                "Godot's global class cache; use local helpers/constants or a preload alias"
            )
        return f"{self.path}:{self.line}: private helper {self.scope}.{self.name} is unreachable"


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    configure_gdtoolkit_cache()

    if args.self_test:
        run_self_tests()

    paths = [Path(path) for path in (args.paths or DEFAULT_PATHS)]
    missing_paths = [path for path in paths if not path.exists()]
    if missing_paths:
        for path in missing_paths:
            print(f"error: path does not exist: {path}", file=sys.stderr)
        return 2

    files_by_path = {path: gdscript_files_for_path(path) for path in paths}
    empty_paths = [path for path, files in files_by_path.items() if not files]
    if empty_paths:
        for path in empty_paths:
            print(f"error: no GDScript files found under: {path.as_posix()}", file=sys.stderr)
        return 2

    gdscript_files = sorted({file for files in files_by_path.values() for file in files})
    problems: list[Problem] = []
    for path in gdscript_files:
        problems.extend(analyze_file(path))

    for problem in problems:
        print(problem.format(), file=sys.stderr)
    if problems:
        parse_count = sum(1 for problem in problems if problem.scope == "<parse>")
        self_class_count = sum(1 for problem in problems if problem.kind == "self-class-reference")
        helper_count = len(problems) - parse_count - self_class_count
        summaries: list[str] = []
        if parse_count:
            summaries.append(f"{parse_count} GDScript parse failure(s)")
        if self_class_count:
            summaries.append(f"{self_class_count} cold-cache GDScript self-reference(s)")
        if helper_count:
            summaries.append(f"{helper_count} unreachable private GDScript helper(s)")
        print(f"error: found {' and '.join(summaries)}", file=sys.stderr)
        return 1
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "paths",
        nargs="*",
        help="GDScript files or directories to inspect. Defaults to addon and test code.",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="Run parser/reachability self-tests before checking repository files.",
    )
    return parser.parse_args(argv)


def configure_gdtoolkit_cache() -> None:
    cache_root = os.environ.get("GDTOOLKIT_CACHE_DIR")
    if not cache_root:
        cache_root = os.path.join(tempfile.gettempdir(), "gdtoolkit-cache")
    gd_parser._cache_dirpath = cache_root


def iter_gdscript_files(paths: Iterable[Path]) -> list[Path]:
    return sorted({file for path in paths for file in gdscript_files_for_path(path)})


def gdscript_files_for_path(path: Path) -> list[Path]:
    if path.is_file():
        if path.suffix == ".gd" and not is_excluded(path):
            return [path]
        return []
    if path.is_dir():
        return sorted(
            child for child in path.rglob("*.gd") if child.is_file() and not is_excluded(child)
        )
    return []


def is_excluded(path: Path) -> bool:
    return any(part in EXCLUDED_PARTS for part in path.parts)


def analyze_file(path: Path) -> list[Problem]:
    return analyze_source(path.read_text(encoding="utf-8"), path.as_posix())


def analyze_source(source: str, path: str) -> list[Problem]:
    try:
        tree = gd_parser.parse(source, gather_metadata=True)
    except Exception as exc:  # pragma: no cover - depends on parser internals.
        return [Problem(path, parse_error_line(exc), "<parse>", f"parse failed: {exc}")]

    allowlisted = collect_allowlisted_lines(source)
    root_scope = build_scope(path, tree)
    problems = self_class_reference_problems(tree, path)
    problems.extend(analyze_scope(root_scope, path, allowlisted))
    return problems


def parse_error_line(exc: Exception) -> int:
    line = getattr(exc, "line", 1)
    return line if isinstance(line, int) and line > 0 else 1


def collect_allowlisted_lines(source: str) -> dict[int, set[str]]:
    names_by_line: dict[int, set[str]] = {}
    for line_number, line in enumerate(source.splitlines(), start=1):
        match = ALLOW_COMMENT.search(line)
        if match:
            names_by_line.setdefault(line_number, set()).add(match.group(1))
    return names_by_line


def self_class_reference_problems(tree: Tree, path: str) -> list[Problem]:
    class_name = script_class_name(tree)
    if not class_name:
        return []
    problems: list[Problem] = []
    for node in walk_tree_nodes(tree):
        if node.data != "getattr":
            continue
        names = [str(child) for child in node.children if is_name_token(child)]
        if len(names) < 2 or names[0] != class_name:
            continue
        problems.append(
            Problem(
                path=path,
                line=getattr(node.meta, "line", 1),
                scope="<cold-cache>",
                name=f"{class_name}.{names[1]}",
                kind="self-class-reference",
            )
        )
    return problems


def script_class_name(tree: Tree) -> str:
    for child in tree_children(tree):
        if child.data == "classname_stmt":
            return first_token_value(child)
    return ""


def walk_tree_nodes(node: Tree | Token) -> Iterable[Tree]:
    if isinstance(node, Token):
        return
    yield node
    for child in tree_children(node):
        yield from walk_tree_nodes(child)


def build_scope(name: str, node: Tree) -> Scope:
    scope = Scope(name=name, node=node)
    for child in tree_children(node):
        if child.data == "class_def":
            class_name = first_token_value(child)
            scope.children.append(build_scope(f"{name}.{class_name}", child))
        elif child.data == "func_def":
            add_function(scope, child)
        elif child.data == "static_func_def":
            func_node = first_child_tree(child, "func_def")
            if func_node is not None:
                add_function(scope, func_node)
    return scope


def add_function(scope: Scope, func_node: Tree) -> None:
    name = function_name(func_node)
    if not name:
        return
    scope.functions[name] = FunctionDef(
        name=name,
        node=func_node,
        line=getattr(func_node.meta, "line", 1),
    )


def analyze_scope(
    scope: Scope, path: str, allowlisted: dict[int, set[str]]
) -> list[Problem]:
    problems: list[Problem] = []
    names = set(scope.functions)
    private_names = {name for name in names if name.startswith("_")}
    roots = {name for name in names if is_reachability_root(name)}
    roots.update(class_body_references(scope.node, names))

    graph = {
        name: call_references_in_function(function.node, names)
        for name, function in scope.functions.items()
    }
    reachable = traverse_reachable(roots, graph)

    for name in sorted(private_names):
        if name not in reachable:
            function = scope.functions[name]
            if is_allowlisted(function, allowlisted):
                continue
            problems.append(Problem(path, function.line, scope.name, name))

    for child in scope.children:
        problems.extend(analyze_scope(child, path, allowlisted))
    return problems


def is_reachability_root(name: str) -> bool:
    return (
        not name.startswith("_")
        or name in GODOT_PRIVATE_ROOTS
        or name.startswith("_on_")
    )


def is_allowlisted(function: FunctionDef, allowlisted: dict[int, set[str]]) -> bool:
    lines = {function.line, function.line - 1}
    return any(function.name in allowlisted.get(line, set()) for line in lines)


def class_body_references(node: Tree, names: set[str]) -> set[str]:
    references: set[str] = set()
    for child in tree_children(node):
        if child.data in CLASS_BODY_SKIP:
            continue
        references.update(call_references(child, names))
    return references


def call_references_in_function(func_node: Tree, names: set[str]) -> set[str]:
    references: set[str] = set()
    for child in tree_children(func_node):
        if child.data == "func_header":
            continue
        references.update(call_references(child, names))
    return references


def call_references(node: Tree | Token, names: set[str]) -> set[str]:
    references: set[str] = set()
    for call in walk_call_nodes(node):
        call_name = called_name(call)
        if call_name in names:
            references.add(call_name)
        references.update(dynamic_method_string_references(call, names))
        if api_call_name(call) in CALLABLE_ARGUMENT_CALLS:
            references.update(callable_argument_references(call, names))
    return references


def walk_call_nodes(node: Tree | Token) -> Iterable[Tree]:
    if isinstance(node, Token):
        return
    if node.data in {"standalone_call", "getattr_call"}:
        yield node
    for child in tree_children(node):
        if child.data in TREE_WALK_SKIP:
            continue
        yield from walk_call_nodes(child)


def called_name(call: Tree) -> str:
    if call.data == "standalone_call":
        return first_token_value(call)
    if call.data == "getattr_call":
        getattr_node = first_child_tree(call, "getattr")
        if getattr_node is not None and is_direct_self_getattr(getattr_node):
            return last_token_value(getattr_node)
    return ""


def api_call_name(call: Tree) -> str:
    if call.data == "standalone_call":
        return first_token_value(call)
    if call.data == "getattr_call":
        getattr_node = first_child_tree(call, "getattr")
        if getattr_node is not None:
            return last_token_value(getattr_node)
    return ""


def is_direct_self_getattr(getattr_node: Tree) -> bool:
    names = [str(child) for child in getattr_node.children if is_name_token(child)]
    return len(names) == 2 and names[0] == "self"


def dynamic_method_string_references(call: Tree, names: set[str]) -> set[str]:
    call_name = api_call_name(call)
    references: set[str] = set()
    arguments = call_arguments(call)
    if is_self_or_standalone_call(call):
        for argument_index in DYNAMIC_SELF_METHOD_STRING_ARGUMENTS.get(call_name, set()):
            add_method_string_reference(references, arguments, argument_index, names)
    target_indexes = DYNAMIC_TARGET_METHOD_STRING_ARGUMENTS.get(call_name)
    if target_indexes is not None:
        target_index, method_index = target_indexes
        if target_index < len(arguments) and argument_is_self(arguments[target_index]):
            add_method_string_reference(references, arguments, method_index, names)
    return references


def add_method_string_reference(
    references: set[str],
    arguments: list[Tree | Token],
    argument_index: int,
    names: set[str],
) -> None:
    if argument_index >= len(arguments):
        return
    value = string_literal_value(arguments[argument_index])
    if value in names:
        references.add(value)


def is_self_or_standalone_call(call: Tree) -> bool:
    if call.data == "standalone_call":
        return True
    if call.data == "getattr_call":
        getattr_node = first_child_tree(call, "getattr")
        return getattr_node is not None and is_direct_self_getattr(getattr_node)
    return False


def argument_is_self(argument: Tree | Token) -> bool:
    return is_name_token(argument) and str(argument) == "self"


def traverse_reachable(roots: set[str], graph: dict[str, set[str]]) -> set[str]:
    reachable: set[str] = set()
    stack = list(roots)
    while stack:
        name = stack.pop()
        if name in reachable or name not in graph:
            continue
        reachable.add(name)
        stack.extend(sorted(graph[name] - reachable))
    return reachable


def callable_argument_references(call: Tree, names: set[str]) -> set[str]:
    references: set[str] = set()
    for child in call_arguments(call):
        if is_name_token(child) and str(child) in names:
            references.add(str(child))
        elif (
            isinstance(child, Tree)
            and child.data == "getattr"
            and is_direct_self_getattr(child)
        ):
            attribute = last_token_value(child)
            if attribute in names:
                references.add(attribute)
    return references


def call_arguments(call: Tree) -> list[Tree | Token]:
    if call.data == "standalone_call":
        return list(call.children[1:])
    if call.data == "getattr_call":
        return list(call.children[1:])
    return []


def string_literal_value(node: Tree | Token) -> str:
    if isinstance(node, Tree) and node.data == "string":
        for child in node.children:
            if isinstance(child, Token) and child.type.endswith("STRING"):
                return parse_string_token(str(child))
    if isinstance(node, Tree) and node.data == "string_name":
        for child in tree_children(node):
            value = string_literal_value(child)
            if value:
                return value
    if isinstance(node, Tree) and called_name(node) == "StringName":
        arguments = call_arguments(node)
        if arguments:
            return string_literal_value(arguments[0])
    if isinstance(node, Token) and node.type.endswith("STRING"):
        return parse_string_token(str(node))
    return ""


def parse_string_token(value: str) -> str:
    try:
        parsed = ast.literal_eval(value)
    except (SyntaxError, ValueError):
        return ""
    return parsed if isinstance(parsed, str) else ""


def function_name(func_node: Tree) -> str:
    header = first_child_tree(func_node, "func_header")
    if header is None:
        return ""
    return first_token_value(header)


def first_token_value(node: Tree) -> str:
    for child in node.children:
        if isinstance(child, Token):
            return str(child)
    return ""


def last_token_value(node: Tree) -> str:
    for child in reversed(node.children):
        if isinstance(child, Token):
            return str(child)
    return ""


def is_name_token(node: Tree | Token) -> bool:
    return isinstance(node, Token) and node.type == "NAME"


def first_child_tree(node: Tree, data: str) -> Tree | None:
    for child in tree_children(node):
        if child.data == data:
            return child
    return None


def tree_children(node: Tree) -> list[Tree]:
    return [child for child in node.children if isinstance(child, Tree)]


def walk_tokens(node: Tree | Token) -> Iterable[Token]:
    if isinstance(node, Token):
        yield node
        return
    for child in node.children:
        if isinstance(child, Token):
            yield child
        elif isinstance(child, Tree):
            yield from walk_tokens(child)


def run_self_tests() -> None:
    accidental_roots = sorted(
        name for name in NON_ROOT_SELF_TEST_NAMES if is_reachability_root(name)
    )
    if accidental_roots:
        raise SystemExit(f"self-test failed: helper names became roots: {accidental_roots}")

    cases = [
        (
            "public reaches private",
            "func public():\n\t_helper()\n\nfunc _helper():\n\tpass\n",
            set(),
        ),
        (
            "self reaches private",
            "func public():\n\tself._helper()\n\nfunc _helper():\n\tpass\n",
            set(),
        ),
        (
            "arbitrary receiver is not local",
            "func public(other):\n\tother._dead()\n\nfunc _dead():\n\tpass\n",
            {"_dead"},
        ),
        (
            "private chain remains dead",
            "func public():\n\tpass\n\nfunc _dead():\n\t_leaf()\n\nfunc _leaf():\n\tpass\n",
            {"_dead", "_leaf"},
        ),
        (
            "constructor root reaches private",
            "func _init():\n\t_setup()\n\nfunc _setup():\n\tpass\n",
            set(),
        ),
        (
            "custom _run is not a root",
            "func public():\n\tpass\n\nfunc _run():\n\tpass\n",
            {"_run"},
        ),
        (
            "dynamic call edge",
            "func _ready():\n\tcall(\"_late\")\n\nfunc _late():\n\tpass\n",
            set(),
        ),
        (
            "string name dynamic call edge",
            "func _ready():\n\tcall(&\"_late\")\n\nfunc _late():\n\tpass\n",
            set(),
        ),
        (
            "constructed string name dynamic call edge",
            (
                "func _ready():\n"
                "\tcall(StringName(\"_late\"))\n\n"
                "func _late():\n"
                "\tpass\n"
            ),
            set(),
        ),
        (
            "callv dynamic call edge",
            "func _ready():\n\tcallv(\"_late\", [])\n\nfunc _late():\n\tpass\n",
            set(),
        ),
        (
            "callv string name dynamic call edge",
            "func _ready():\n\tcallv(&\"_late\", [])\n\nfunc _late():\n\tpass\n",
            set(),
        ),
        (
            "call group method argument is not local",
            "func _ready():\n\tcall_group(\"group\", \"_late\")\n\nfunc _late():\n\tpass\n",
            {"_late"},
        ),
        (
            "call group name is not a method edge",
            (
                "func public():\n"
                "\tcall_group(\"_dead\", \"_handler\")\n\n"
                "func _handler():\n"
                "\tpass\n"
                "func _dead():\n"
                "\tpass\n"
            ),
            {"_dead", "_handler"},
        ),
        (
            "other call string is not local",
            "func public(other):\n\tother.call(\"_dead\")\n\nfunc _dead():\n\tpass\n",
            {"_dead"},
        ),
        (
            "self call string is local",
            "func public():\n\tself.call(\"_helper\")\n\nfunc _helper():\n\tpass\n",
            set(),
        ),
        (
            "callable target must be self",
            "func public(other):\n\tCallable(other, \"_dead\")\n\nfunc _dead():\n\tpass\n",
            {"_dead"},
        ),
        (
            "rpc payload is not a method edge",
            (
                "func public():\n"
                "\trpc(\"_handler\", \"_dead\")\n\n"
                "func _handler():\n"
                "\tpass\n"
                "func _dead():\n"
                "\tpass\n"
            ),
            {"_dead"},
        ),
        (
            "rpc receiver must be self",
            "func public(other):\n\tother.rpc(\"_dead\")\n\nfunc _dead():\n\tpass\n",
            {"_dead"},
        ),
        (
            "callable edge",
            "func _ready():\n\tbutton.pressed.connect(_pressed)\n\nfunc _pressed():\n\tpass\n",
            set(),
        ),
        (
            "self callable edge",
            (
                "func _ready():\n"
                "\tbutton.pressed.connect(self._pressed)\n\n"
                "func _pressed():\n"
                "\tpass\n"
            ),
            set(),
        ),
        (
            "other receiver can connect self target",
            (
                "func _ready(other):\n"
                "\tother.connect(\"pressed\", self, \"_pressed\")\n\n"
                "func _pressed():\n"
                "\tpass\n"
            ),
            set(),
        ),
        (
            "other receiver connect needs self target",
            (
                "func public(other):\n"
                "\tother.connect(\"pressed\", other, \"_dead\")\n\n"
                "func _dead():\n"
                "\tpass\n"
            ),
            {"_dead"},
        ),
        (
            "legacy connect target edge",
            (
                "func _ready():\n"
                "\tconnect(\"pressed\", self, \"_pressed\")\n\n"
                "func _pressed():\n"
                "\tpass\n"
            ),
            set(),
        ),
        (
            "legacy connect string name target edge",
            (
                "func _ready():\n"
                "\tconnect(&\"pressed\", self, &\"_pressed\")\n\n"
                "func _pressed():\n"
                "\tpass\n"
            ),
            set(),
        ),
        (
            "legacy connect constructed string name target edge",
            (
                "func _ready():\n"
                "\tconnect(StringName(\"pressed\"), self, StringName(\"_pressed\"))\n\n"
                "func _pressed():\n"
                "\tpass\n"
            ),
            set(),
        ),
        (
            "string name callable target edge",
            (
                "func _ready():\n"
                "\tCallable(self, &\"_pressed\")\n\n"
                "func _pressed():\n"
                "\tpass\n"
            ),
            set(),
        ),
        (
            "constructed string name callable target edge",
            (
                "func _ready():\n"
                "\tCallable(self, StringName(\"_pressed\"))\n\n"
                "func _pressed():\n"
                "\tpass\n"
            ),
            set(),
        ),
        (
            "legacy connect signal name is not a method edge",
            (
                "func public():\n"
                "\tconnect(\"_dead\", self, \"_handler\")\n\n"
                "func _handler():\n"
                "\tpass\n"
                "func _dead():\n"
                "\tpass\n"
            ),
            {"_dead"},
        ),
        (
            "comment is not a reference",
            "func public():\n\tpass\n\n# _dead\nfunc _dead():\n\tpass\n",
            {"_dead"},
        ),
        (
            "identifier variable is not a call edge",
            "func public():\n\tvar _dead = 1\n\nfunc _dead():\n\tpass\n",
            {"_dead"},
        ),
        (
            "dictionary key string is not a call edge",
            "func public(data):\n\tdata.get(\"_dead\")\n\nfunc _dead():\n\tpass\n",
            {"_dead"},
        ),
        (
            "signal name string is not a call edge",
            "func public():\n\temit_signal(\"_dead\")\n\nfunc _dead():\n\tpass\n",
            {"_dead"},
        ),
        (
            "drag callback root",
            "func _can_drop_data(_pos, _data):\n\treturn _ok()\n\nfunc _ok():\n\treturn true\n",
            set(),
        ),
        (
            "local allow comment",
            (
                "func public():\n"
                "\tpass\n\n"
                "# gdscript-private-helper: allow _dead\n"
                "func _dead():\n"
                "\tpass\n"
            ),
            set(),
        ),
        (
            "allow comment is not file-global",
            (
                "class A:\n"
                "\t# gdscript-private-helper: allow _helper\n"
                "\tfunc _helper():\n"
                "\t\tpass\n"
                "class B:\n"
                "\tfunc _helper():\n"
                "\t\tpass\n"
            ),
            {"_helper"},
            1,
        ),
        (
            "nested classes are independent scopes",
            (
                "class A:\n"
                "\tfunc _init():\n"
                "\t\t_helper()\n"
                "\tfunc _helper():\n"
                "\t\tpass\n"
                "class B:\n"
                "\tfunc public():\n"
                "\t\tpass\n"
                "\tfunc _helper():\n"
                "\t\tpass\n"
            ),
            {"_helper"},
            1,
        ),
    ]

    for case in cases:
        name, source, expected = case[:3]
        expected_count = case[3] if len(case) > 3 else len(expected)
        problems = analyze_source(source, f"<self-test {name}>")
        actual = {problem.name for problem in problems}
        if actual != expected or len(problems) != expected_count:
            raise SystemExit(
                "self-test failed: %s: expected %s (%d problems), got %s (%d problems)"
                % (name, sorted(expected), expected_count, sorted(actual), len(problems))
            )

    parse_problems = analyze_source("func ok():\n\tpass\nfunc broken(\n", "<self-test parse>")
    if len(parse_problems) != 1 or parse_problems[0].scope != "<parse>":
        raise SystemExit("self-test failed: parse error must be reported as one parse problem")
    if parse_problems[0].line != 3:
        raise SystemExit(
            "self-test failed: parse error line should be 3, got %d" % parse_problems[0].line
        )

    self_class_problems = analyze_source(
        (
            "class_name LocalScript\n"
            "const OtherScript = preload(\"res://other.gd\")\n"
            "func public():\n"
            "\tLocalScript.make_value()\n"
            "\tOtherScript.make_value()\n"
        ),
        "<self-test self class reference>",
    )
    self_class_refs = [
        problem for problem in self_class_problems if problem.kind == "self-class-reference"
    ]
    if len(self_class_refs) != 1 or self_class_refs[0].name != "LocalScript.make_value":
        raise SystemExit(
            "self-test failed: self class references should be reported once, got %s"
            % [problem.name for problem in self_class_refs]
        )

    with tempfile.TemporaryDirectory() as temp_dir:
        temp_path = Path(temp_dir)
        script_path = temp_path / "ok.gd"
        script_path.write_text("func public():\n\tpass\n", encoding="utf-8")
        nested_path = temp_path / "nested"
        nested_path.mkdir()
        if gdscript_files_for_path(script_path) != [script_path]:
            raise SystemExit("self-test failed: single .gd file path was not detected")
        if gdscript_files_for_path(nested_path):
            raise SystemExit("self-test failed: empty path should not report GDScript files")


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
