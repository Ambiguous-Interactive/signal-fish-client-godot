#!/usr/bin/env python3
"""Install the npm MCP servers after the devcontainer Node feature is ready."""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

PACKAGES = (
    ("GODOT_MCP_NPM_SPEC", "@coding-solo/godot-mcp@0.1.1", "godot-mcp"),
    ("PLAYWRIGHT_MCP_NPM_SPEC", "@playwright/mcp@0.0.82", "playwright-mcp"),
    ("CONTEXT7_MCP_NPM_SPEC", "@upstash/context7-mcp@4.0.4", "context7-mcp"),
)
ALLOW_SCRIPTS = (
    "@coding-solo/godot-mcp,@playwright/mcp,@upstash/context7-mcp,playwright,playwright-core"
)
SECRET_NAMES = (
    "GITHUB_TOKEN",
    "GH_TOKEN",
    "GITHUB_MCP_PAT",
    "GITHUB_PERSONAL_ACCESS_TOKEN",
    "Z_AI_API_KEY",
    "Z_AI_MODE",
    "CONTEXT7_API_KEY",
)
VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.]+)?\Z")


def run(
    args: list[str], env: dict[str, str], *, capture: bool = True
) -> subprocess.CompletedProcess[str] | None:
    try:
        return subprocess.run(  # noqa: S603
            args, env=env, text=True, capture_output=capture, check=False
        )
    except OSError:
        return None


def output(args: list[str], env: dict[str, str]) -> str:
    result = run(args, env)
    return result.stdout.strip() if result else ""


def warn_or_fail(message: str, update: bool) -> int:
    if update:
        print(
            f"mcp-servers: WARNING: {message}; continuing with the installed toolchain",
            file=sys.stderr,
        )
        return 0
    print(f"mcp-servers: ERROR: {message}", file=sys.stderr)
    return 1


def installed_versions(env: dict[str, str]) -> dict[str, str]:
    # npm list may fail for unrelated global packages while still returning useful JSON.
    try:
        data = json.loads(output(["npm", "list", "--global", "--depth=0", "--json"], env))
        dependencies = data.get("dependencies", {})
        if isinstance(dependencies, dict):
            return {
                name: entry.get("version", "")
                for name, entry in dependencies.items()
                if isinstance(entry, dict)
            }
    except (json.JSONDecodeError, AttributeError, TypeError):
        pass
    return {}


def sweep_dangling_bins(bin_dir: Path, update: bool) -> bool:
    for _, _, binary in PACKAGES:
        link = bin_dir / binary
        if link.is_symlink() and not link.exists():
            try:
                link.unlink()
            except OSError:
                if warn_or_fail(f"could not remove dangling bin link: {link}", update):
                    return False
            else:
                print(f"mcp-servers: removed dangling bin link: {link}")
    return True


def install_browser(prefix: Path, env: dict[str, str]) -> None:
    if env.get("SF_MCP_SKIP_PLAYWRIGHT_BROWSER") == "1":
        print("mcp-servers: SF_MCP_SKIP_PLAYWRIGHT_BROWSER=1; skipped Chromium install")
        return
    # Resolve the CLI from @playwright/mcp's bundled dependency, not the repo pin.
    browser_env = {**env, "MCP_PKG_DIR": str(prefix / "lib/node_modules/@playwright/mcp")}
    cli = output(
        [
            "node",
            "-p",
            "const path = require('path'); path.join(path.dirname(require.resolve('playwright/package.json', { paths: [process.env.MCP_PKG_DIR] })), 'cli.js')",
        ],
        browser_env,
    )
    if not cli or not Path(cli).is_file():
        print(
            "mcp-servers: WARNING: could not locate @playwright/mcp's bundled playwright CLI; skipping Chromium install",
            file=sys.stderr,
        )
        return
    print("==> Installing Chromium for playwright-mcp (best-effort; may take a few minutes)")
    result = run(["node", cli, "install", "--with-deps", "chromium"], env, capture=False)
    if result and result.returncode == 0:
        print("==> Chromium installed for playwright-mcp")
    else:
        print(
            f'mcp-servers: WARNING: Chromium install failed; playwright-mcp tools will not run until it succeeds (rerun: node "{cli}" install --with-deps chromium)',
            file=sys.stderr,
        )


def main(argv: list[str]) -> int:
    if len(argv) > 1 or (argv and argv[0] not in ("install", "--update")):
        print("mcp-servers: ERROR: expected 'install' or '--update'", file=sys.stderr)
        return 2
    update = bool(argv and argv[0] == "--update")
    env = os.environ.copy()
    for name in SECRET_NAMES:
        env.pop(name, None)

    specs: list[tuple[str, str, str]] = []
    for name, default, binary in PACKAGES:
        spec = env.get(name, default)
        package, separator, version = spec.rpartition("@")
        if not separator or not package or not VERSION.fullmatch(version):
            print(
                f"mcp-servers: ERROR: npm spec '{spec}' must pin a concrete x.y.z version (set a concrete override or unset it).",
                file=sys.stderr,
            )
            return 1
        specs.append((package, version, binary))

    node_version = output(["node", "--version"], env)
    node_match = re.match(r"v([0-9]+)", node_version)
    if not node_match or int(node_match.group(1)) < 22:
        return warn_or_fail(
            f"Node.js 22 or newer is required (found: {node_version or 'none'})", update
        )
    npm_version = output(["npm", "--version"], env)
    npm_match = re.match(r"([0-9]+)", npm_version)
    npm_args = (
        [f"--allow-scripts={ALLOW_SCRIPTS}"] if npm_match and int(npm_match.group(1)) >= 11 else []
    )
    prefix_text = output(["npm", "config", "get", "prefix"], env)
    if not prefix_text:
        return warn_or_fail("npm config get prefix returned empty", update)
    prefix = Path(prefix_text)
    bin_dir = prefix / "bin"
    env["PATH"] = f"{bin_dir}{os.pathsep}{env.get('PATH', '')}"

    failed: list[str] = []
    for package, version, _ in specs:
        spec = f"{package}@{version}"
        if installed_versions(env).get(package) == version:
            print(f"mcp-servers: {spec} is current; skipped")
            continue
        if not sweep_dangling_bins(bin_dir, update):
            return 1
        result = run(
            ["npm", "install", "--global", "--no-audit", "--no-fund", *npm_args, spec],
            env,
            capture=False,
        )
        if result and result.returncode == 0:
            print(f"mcp-servers: installed {spec}")
        else:
            if not sweep_dangling_bins(bin_dir, update):
                return 1
            failed.append(spec)
    if failed:
        return warn_or_fail(f"npm could not install: {' '.join(failed)}", update)

    versions = installed_versions(env)
    missing: list[str] = []
    for package, version, binary in specs:
        path = shutil.which(binary, path=env["PATH"])
        if not path or not os.access(path, os.X_OK):
            missing.append(binary)
        elif versions.get(package) != version:
            missing.append(f"{binary} (npm global state does not match {package}@{version})")
    if missing:
        return warn_or_fail(
            f"MCP servers missing or mismatched after provisioning: {' '.join(missing)} (npm prefix: {prefix})",
            update,
        )

    if update:
        print(
            "mcp-servers: --update skipped the Chromium install (heal via post-create or rerun the installer in install mode)"
        )
    else:
        install_browser(prefix, env)
    print("mcp-servers: ready: " + " ".join(binary for _, _, binary in PACKAGES))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
