#!/usr/bin/env python3
"""Install and verify the dev container terminal agent CLIs."""

import concurrent.futures
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

BINARIES = ("codex", "opencode", "nanocoder", "claude")
SPECS = (
    os.environ.get("CODEX_NPM_SPEC") or "@openai/codex@latest",
    os.environ.get("OPENCODE_NPM_SPEC") or "@opencode/cli@latest",
    os.environ.get("NANOCODER_NPM_SPEC") or "@nanocollective/nanocoder@latest",
    os.environ.get("CLAUDE_NPM_SPEC") or "@anthropic-ai/claude-code@latest",
)
ALLOW_SCRIPTS = "@opencode/cli,@nanocollective/nanocoder,@anthropic-ai/claude-code,@openai/codex,@github/keytar,node-pty,opencode-ai"
V1 = "opencode-ai"
V2 = "@opencode/cli"
SECRETS = (
    "GITHUB_TOKEN",
    "GH_TOKEN",
    "GITHUB_MCP_PAT",
    "Z_AI_API_KEY",
    "Z_AI_MODE",
    "CONTEXT7_API_KEY",
)


def milliseconds(name: str, default: int) -> int:
    value = os.environ.get(name, str(default))
    return int(value) if value.isascii() and value.isdecimal() else default


def package_name(spec: str) -> str:
    return spec.rsplit("@", 1)[0] or spec


def major(version: str) -> int | None:
    match = re.match(r"^(?:opencode )?v?=?([0-9]+)(?:\.|\s|$)", version)
    return int(match.group(1)) if match else None


def first_line(value: str) -> str:
    return value.splitlines()[0] if value.splitlines() else ""


def run(*args: str) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(args, text=True, capture_output=True, check=False)  # noqa: S603
        if (
            len(args) > 1
            and args[0] == "npm"
            and args[1] in ("install", "uninstall")
            and result.returncode != 0
        ):
            print(result.stderr or result.stdout, end="", file=sys.stderr)
        return result
    except OSError as exc:
        return subprocess.CompletedProcess(args, 127, "", str(exc))


class Installer:
    def __init__(self, mode: str) -> None:
        self.mode = mode
        self.prefix = Path()
        self.bin_dir = Path()
        self.versions: dict[str, str] = {}
        self.allow_scripts: list[str] = []

    def warn_or_fail(self, message: str) -> None:
        if self.mode == "--update":
            print(
                f"agent-tools: WARNING: {message}; continuing with the installed toolchain",
                file=sys.stderr,
            )
            return
        print(f"agent-tools: ERROR: {message}", file=sys.stderr)
        raise RuntimeError(message)

    def sweep_dangling_bins(self) -> None:
        for name in (*BINARIES, "opencode2"):
            link = self.bin_dir / name
            if link.is_symlink() and not link.exists():
                try:
                    link.unlink()
                    print(f"agent-tools: removed dangling bin link: {link}")
                except OSError:
                    self.warn_or_fail(f"could not remove dangling bin link: {link}")

    def refresh_versions(self) -> None:
        result = run("npm", "list", "--global", "--depth=0", "--json")
        try:
            dependencies = json.loads(result.stdout).get("dependencies", {})
        except (ValueError, AttributeError):
            dependencies = {}
        self.versions = {
            name: value["version"]
            for name, value in dependencies.items()
            if isinstance(value, dict) and isinstance(value.get("version"), str)
        }

    def version(self, name: str) -> str:
        return self.versions.get(name, "")

    def binary_version(self, binary: str | Path) -> tuple[subprocess.CompletedProcess[str], str]:
        result = run(str(binary), "--version")
        return result, first_line(result.stdout) or first_line(result.stderr)

    def owned_v2(self, binary: Path, prefix: Path, require_record: bool = False) -> bool:
        package_root = prefix / "lib/node_modules/@opencode/cli"
        if not binary.is_symlink() or not (package_root / "package.json").is_file():
            return False
        try:
            binary.resolve(strict=True).relative_to(package_root.resolve(strict=True))
        except (OSError, ValueError):
            return False
        if require_record and not self.version(V2):
            return False
        result, version = self.binary_version(binary)
        return result.returncode == 0 and major(version) == 2

    def active_v2(self) -> bool:
        return self.owned_v2(self.bin_dir / "opencode", self.prefix, True)

    def save_v2_bins(self, backup: Path) -> bool:
        backup.mkdir()
        for alias, fallback in (("opencode", "opencode2"), ("opencode2", "opencode")):
            source = self.bin_dir / alias
            if not source.exists() and not source.is_symlink():
                source = self.bin_dir / fallback
            if not source.exists() and not source.is_symlink():
                return False
            shutil.copy2(source, backup / alias, follow_symlinks=False)
        return True

    def restore_v2_bins(self, backup: Path) -> bool:
        ok = True
        for alias in ("opencode", "opencode2"):
            source = backup / alias
            if source.exists() or source.is_symlink():
                try:
                    (self.bin_dir / alias).unlink(missing_ok=True)
                    shutil.copy2(source, self.bin_dir / alias, follow_symlinks=False)
                except OSError:
                    ok = False
        return ok

    def remove_v1_after_v2(self, scratch: Path) -> bool:
        backup = scratch / "active-opencode-v2-bins"
        try:
            if not self.save_v2_bins(backup):
                return False
            status = run("npm", "uninstall", "--global", V1).returncode
            return self.restore_v2_bins(backup) and self.active_v2() and status == 0
        except OSError:
            return False

    def remove_opencode_aliases(self) -> None:
        for alias in ("opencode", "opencode2"):
            (self.bin_dir / alias).unlink(missing_ok=True)

    def install_args(self, spec: str, prefix: Path | None = None) -> list[str]:
        args = ["npm", "install", "--global"]
        if prefix is not None:
            args += ["--prefix", str(prefix)]
        return [*args, "--no-audit", "--no-fund", *self.allow_scripts, spec]

    def restore_v1(self, version: str) -> bool:
        run("npm", "uninstall", "--global", V2)
        self.sweep_dangling_bins()
        if run(*self.install_args(f"{V1}@{version}")).returncode != 0:
            self.remove_opencode_aliases()
            return False
        result, actual = self.binary_version(self.bin_dir / "opencode")
        if result.returncode != 0 or major(actual) != 1:
            self.remove_opencode_aliases()
            return False
        return True

    def promote_v2(self, spec: str, version: str, scratch: Path) -> int:
        candidate = scratch / "opencode-v2-prefix"
        if run(*self.install_args(spec, candidate)).returncode != 0:
            return 1
        if not self.owned_v2(candidate / "bin/opencode", candidate):
            return 1
        if run("npm", "uninstall", "--global", V1).returncode != 0:
            return 1 if self.restore_v1(version) else 2
        if run(*self.install_args(spec)).returncode != 0:
            self.sweep_dangling_bins()
            return 1 if self.restore_v1(version) else 2
        self.refresh_versions()
        if not self.active_v2():
            return 1 if self.restore_v1(version) else 2
        return 0

    def initialize(self) -> bool:
        node = run("node", "--version")
        node_match = re.match(r"^v([0-9]+)", node.stdout)
        if node_match is None or int(node_match.group(1)) < 22:
            self.warn_or_fail(
                f"Node.js 22 or newer is required (found: {first_line(node.stdout) or 'none'})"
            )
            return False
        npm = run("npm", "--version")
        npm_match = re.match(r"^([0-9]+)", npm.stdout)
        if npm_match and int(npm_match.group(1)) >= 11:
            self.allow_scripts = [f"--allow-scripts={ALLOW_SCRIPTS}"]
        prefix = run("npm", "config", "get", "prefix").stdout.strip()
        if not prefix:
            self.warn_or_fail("npm config get prefix returned empty")
            return False
        self.prefix = Path(prefix)
        self.bin_dir = self.prefix / "bin"
        os.environ["PATH"] = f"{self.bin_dir}:{os.environ.get('PATH', '')}"
        if not self.prefix.is_dir():
            if not os.access(self.prefix.parent, os.W_OK):
                self.warn_or_fail(
                    f"npm global prefix parent is not writable: {self.prefix.parent}; rebuild the container instead of repairing with elevated npm"
                )
                return False
        elif not os.access(self.prefix, os.W_OK):
            self.warn_or_fail(
                f"npm global prefix is not writable: {self.prefix}; rebuild the container instead of repairing with elevated npm"
            )
            return False
        self.sweep_dangling_bins()
        return True

    def probe(self, spec: str, timeout: int) -> subprocess.CompletedProcess[str]:
        return run(
            "npm", "view", spec, "version", f"--fetch-timeout={timeout}", "--fetch-retries=0"
        )

    def provision(self, scratch: Path) -> bool:
        timeout = milliseconds("AGENT_TOOLS_NPM_FETCH_TIMEOUT_MS", 5000)
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            futures = [pool.submit(self.probe, spec, timeout) for spec in SPECS]
            probes = [future.result() for future in futures]
        for spec, probe in zip(SPECS, probes, strict=True):
            if probe.returncode != 0:
                print(
                    f"agent-tools: WARNING: npm registry probe failed for {spec}", file=sys.stderr
                )
        self.refresh_versions()
        v1_installed = self.version(V1)
        migration_blocked = False
        if v1_installed:
            if self.active_v2():
                print(
                    f"agent-tools: removing OpenCode v1 package {v1_installed} after proving the active binary is v2"
                )
                if self.remove_v1_after_v2(scratch):
                    v1_installed = ""
                    self.refresh_versions()
                else:
                    self.warn_or_fail("could not remove OpenCode v1 after activating v2")
                    return False
            elif probes[1].returncode == 0:
                print(f"agent-tools: staging OpenCode v2 before replacing v1 {v1_installed}")
                status = self.promote_v2(SPECS[1], v1_installed, scratch)
                if status:
                    migration_blocked = True
                    detail = (
                        "OpenCode v1 could not be restored"
                        if status == 2
                        else "retaining OpenCode v1"
                    )
                    self.warn_or_fail(f"could not prove and activate OpenCode v2; {detail}")
                else:
                    v1_installed = ""
            else:
                migration_blocked = True
                print(
                    "agent-tools: WARNING: retaining OpenCode v1 because the v2 package is unavailable",
                    file=sys.stderr,
                )
        install_specs = []
        for index, (spec, binary) in enumerate(zip(SPECS, BINARIES, strict=True)):
            probe = probes[index]
            latest = "".join(probe.stdout.split()) if probe.returncode == 0 else ""
            installed = self.version(package_name(spec))
            if index == 1 and v1_installed and (migration_blocked or probe.returncode != 0):
                print(
                    f"agent-tools: deferring OpenCode v2 install for {binary} while retaining v1",
                    file=sys.stderr,
                )
                continue
            if (
                self.mode == "--update"
                and probe.returncode != 0
                and not installed
                and not os.access(self.bin_dir / binary, os.X_OK)
            ):
                print(
                    f"agent-tools: skipping {binary}: registry unreachable and not installed (rerun post-create when online)",
                    file=sys.stderr,
                )
                continue
            if (
                not os.access(self.bin_dir / binary, os.X_OK)
                or not installed
                or (index == 1 and not self.active_v2())
                or (latest and installed != latest)
            ):
                install_specs.append(spec)
        if not install_specs:
            print("agent-tools: all agent CLIs are current; skipped npm install")
            return True
        print(f"agent-tools: installing {len(install_specs)} package(s) into {self.prefix}")
        failed = []
        delay = milliseconds("AGENT_TOOLS_RETRY_SLEEP_MS", 2000) / 1000
        attempts = 1 if self.mode == "--update" else 3
        for spec in install_specs:
            for attempt in range(1, attempts + 1):
                if run(*self.install_args(spec)).returncode == 0:
                    self.refresh_versions()
                    break
                self.sweep_dangling_bins()
                if attempt < attempts:
                    print(
                        f"agent-tools: npm install of {spec} failed (attempt {attempt}/{attempts}); retrying",
                        file=sys.stderr,
                    )
                    if delay:
                        time.sleep(delay)
            else:
                failed.append(spec)
        if failed:
            self.warn_or_fail(f"npm could not install: {' '.join(failed)}")
            return False
        return True

    def verify(self) -> None:
        ready, missing = [], []
        for binary in BINARIES:
            path = shutil.which(binary)
            if path is None:
                missing.append(binary)
                continue
            result, version = self.binary_version(path)
            if result.returncode != 0:
                missing.append(binary)
                if version:
                    print(
                        f"agent-tools: {binary} --version exited {result.returncode}: {version}",
                        file=sys.stderr,
                    )
                continue
            if not version:
                missing.append(binary)
                continue
            if binary == "opencode" and not self.active_v2():
                missing.append(
                    "opencode (active binary is not an owned @opencode/cli package or is not major 2)"
                )
                continue
            ready.append(f"{binary}@{version}")
        if missing:
            self.warn_or_fail(
                f"agent CLIs missing or silent after provisioning: {' '.join(missing)} (npm prefix: {self.prefix})"
            )
            return
        print(f"agent-tools: ready: {' '.join(ready)}")


def main() -> int:
    mode = sys.argv[1] if len(sys.argv) > 1 else "install"
    if mode not in ("install", "--verify", "--update"):
        print(
            f"agent-tools: ERROR: unknown mode '{mode}' (expected 'install', '--verify', or '--update')",
            file=sys.stderr,
        )
        return 2
    for name in SECRETS:
        os.environ.pop(name, None)
    installer = Installer(mode)
    try:
        if not installer.initialize():
            return 0
        with tempfile.TemporaryDirectory() as directory:
            if mode == "--verify":
                installer.refresh_versions()
            elif not installer.provision(Path(directory)):
                return 0
            installer.verify()
    except RuntimeError:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
