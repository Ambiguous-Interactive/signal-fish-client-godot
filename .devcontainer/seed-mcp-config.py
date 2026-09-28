#!/usr/bin/env python3
"""Seed Codex MCP configuration and check the committed client configs."""

from __future__ import annotations

import json
import os
import re
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SERVERS = ("godot", "github", "context7", "deepwiki", "git", "fetch", "playwright")
# This marker stays stable so existing Codex configs migrate in place.
CODEX_MARKER_BEGIN = "# >>> signal-fish-mcp >>> managed by .devcontainer/seed-mcp-config.sh (regenerated; edit outside the markers)"
CODEX_MARKER_END = "# <<< signal-fish-mcp <<<"
CODEX_MANAGED_BLOCK = f"""{CODEX_MARKER_BEGIN}
[mcp_servers.godot]
command = "godot-mcp"
args = []

[mcp_servers.godot.env]
GODOT_PATH = "/usr/local/bin/godot"

[mcp_servers.github]
command = "sf-github-mcp"
args = []
# Codex forwards a sanitized environment by default.
env_vars = ["GITHUB_MCP_PAT", "GITHUB_PERSONAL_ACCESS_TOKEN", "GITHUB_READ_ONLY", "GITHUB_TOOLSETS"]

[mcp_servers.context7]
command = "context7-mcp"
args = []
env_vars = ["CONTEXT7_API_KEY"]

[mcp_servers.deepwiki]
url = "https://mcp.deepwiki.com/mcp"

[mcp_servers.git]
command = "mcp-server-git"
args = []

[mcp_servers.fetch]
command = "mcp-server-fetch"
args = []

[mcp_servers.playwright]
command = "playwright-mcp"
args = ["--browser", "chromium", "--headless", "--no-sandbox"]
{CODEX_MARKER_END}
"""
TABLE = re.compile(r"^\[mcp_servers\.([A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*)\]$")


def report(message: str, update: bool) -> None:
    level = "WARNING" if update else "ERROR"
    print(f"seed-mcp-config: {level}: {message}", file=sys.stderr)


def check_json_configs(update: bool) -> tuple[dict[str, set[str]], bool]:
    found: dict[str, set[str]] = {}
    failed = False
    for label, path, keys in (
        (".mcp.json", REPO_ROOT / ".mcp.json", ("mcpServers",)),
        ("opencode.json", REPO_ROOT / "opencode.json", ("mcp", "servers")),
    ):
        if not path.is_file():
            report(f"missing {label} ({path})", update)
            found[label] = set()
            failed = True
            continue
        try:
            node = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, ValueError):
            report(f"{label} is not valid JSON: {path}", update)
            found[label] = set()
            failed = True
            continue
        for key in keys:
            node = node.get(key) if isinstance(node, dict) else None
        present = set(node) if isinstance(node, dict) else set()
        found[label] = present
        for server in SERVERS:
            if server not in present:
                report(f"{label} does not declare the '{server}' MCP server", update)
                failed = True
    return found, failed


def lines_and_tables(content: str) -> tuple[list[str], str | tuple[int, int] | None]:
    lines = content.splitlines(keepends=True)
    outside: set[str] = set()
    markers: list[tuple[int, int]] = []
    begin: int | None = None
    for index, line in enumerate(lines):
        stripped = line.rstrip("\r\n")
        if stripped == CODEX_MARKER_BEGIN:
            if begin is not None or markers:
                return lines, "corrupted"
            begin = index
            continue
        if stripped == CODEX_MARKER_END:
            if begin is None:
                return lines, "corrupted"
            markers.append((begin, index))
            begin = None
            continue
        if begin is None:
            match = TABLE.fullmatch(stripped)
            if match:
                outside.add(match.group(1))
    if begin is not None:
        return lines, "corrupted"
    for table in outside:
        if table.split(".", 1)[0] in SERVERS:
            return lines, "conflict"
    if markers:
        start, end = markers[0]
        return lines, (start, end)
    return lines, None


def write_atomic(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        newline="",
        dir=path.parent,
        prefix=".config.toml.",
        delete=False,
    ) as handle:
        temporary = Path(handle.name)
        try:
            handle.write(content)
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise
    temporary.replace(path)


def seed_codex_config(path: Path, update: bool) -> bool:
    try:
        if path.is_file():
            with path.open(encoding="utf-8", newline="") as handle:
                original = handle.read()
        else:
            original = None
    except (OSError, UnicodeError):
        report(f"could not read {path}", update)
        return False
    if original is None:
        replacement = CODEX_MANAGED_BLOCK
    else:
        lines, state = lines_and_tables(original)
        if state == "conflict":
            report(
                f"{path} defines signal-fish MCP server tables outside the managed block; remove them (or the managed block) and rerun",
                update,
            )
            return False
        if state == "corrupted":
            report(f"{path} has a corrupted managed block; fix or delete it and rerun", update)
            return False
        if state is None:
            replacement = original + "\n" + CODEX_MANAGED_BLOCK
        elif isinstance(state, tuple):
            start, end = state
            replacement = "".join(lines[:start]) + CODEX_MANAGED_BLOCK + "".join(lines[end + 1 :])
        else:
            report(f"{path} has a corrupted managed block; fix or delete it and rerun", update)
            return False
        if replacement == original:
            print("seed-mcp-config: codex managed block is current; skipped")
            return True
    try:
        write_atomic(path, replacement)
    except OSError:
        report(f"could not write {path}", update)
        return False
    print(f"seed-mcp-config: wrote codex managed block to {path}")
    return True


def doctor(found: dict[str, set[str]], path: Path, update: bool) -> bool:
    try:
        content = path.read_text(encoding="utf-8")
        tables = {
            match.group(1)
            for line in content.splitlines()
            if (match := TABLE.fullmatch(line.strip()))
        }
    except (OSError, UnicodeError):
        tables = set()
    print("==> MCP doctor (values are never printed; only names and state)")
    missing = False
    for server in SERVERS:
        mcp_ok = server in found.get(".mcp.json", set())
        open_ok = server in found.get("opencode.json", set())
        codex_ok = any(table == server or table.startswith(server + ".") for table in tables)
        print(
            f"  {server:<9} mcp.json:{'ok' if mcp_ok else 'MISSING'} opencode:{'ok' if open_ok else 'MISSING'} codex:{'ok' if codex_ok else 'MISSING'}"
        )
        missing |= not (mcp_ok and codex_ok)
    for name in ("GITHUB_MCP_PAT", "CONTEXT7_API_KEY", "GITHUB_READ_ONLY"):
        print(f"  env {name:<18} {'set' if os.environ.get(name) else 'UNSET'}")
    if missing:
        report("doctor found MISSING MCP servers (see above)", update)
    return not missing


def main(argv: list[str]) -> int:
    if len(argv) > 1 or (argv and argv[0] not in ("install", "--update")):
        print("seed-mcp-config: ERROR: expected 'install' or '--update'", file=sys.stderr)
        return 2
    update = bool(argv and argv[0] == "--update")
    path = Path.home() / ".codex/config.toml"
    found, json_failed = check_json_configs(update)
    seed_ok = seed_codex_config(path, update)
    doctor_ok = doctor(found, path, update)
    if json_failed or not seed_ok or not doctor_ok:
        report("MCP configuration seeding reported problems above", update)
        return 0 if update else 1
    print("==> MCP configurations seeded.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
