#!/usr/bin/env python3
"""Report storage and manage registered experiment scratch on Linux."""

from __future__ import annotations

import argparse
import contextlib
import json
import math
import os
import shutil
import stat
import sys
import tempfile
import time
from collections.abc import Callable, Iterator
from datetime import datetime, timezone
from pathlib import Path
from typing import TypedDict, cast

GIB = 1024**3
DEFAULT_ROOT = Path("/tmp/signal-fish-scratch")  # noqa: S108
SCHEMA = "signal-fish-scratch-v1"


class RunRecord(TypedDict):
    schema: str
    state: str
    updated: float


class CleanReport(TypedDict):
    root: str
    total_bytes: int
    remaining_bytes: int
    reclaimed_bytes: int
    candidates: list[str]
    protected: list[str]
    errors: list[str]
    over_budget: bool
    apply: bool
    projected_bytes: int
    protected_bytes: int


class PathEntry(TypedDict, total=False):
    path: str
    allocated_bytes: int
    filesystem_total: int
    filesystem_free: int
    error: str
    owner_uid: int
    device: int
    errors: list[str]


class PathsReport(TypedDict):
    paths: list[PathEntry]
    duration_seconds: float
    measured_utc: str
    accounting: str
    policy: str


class CacheReport(TypedDict):
    total_bytes: int
    candidates: list[str]
    apply: bool
    projected_bytes: int


def root_path(path: Path, *, create: bool = False) -> Path:
    path = path.absolute()
    if path.resolve() != path:
        raise ValueError(f"Symlinked scratch path refused: {path}")
    if create:
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.exists() and (not path.is_dir() or path.stat().st_uid != os.getuid()):
        raise ValueError(f"Scratch root must be a directory owned by this user: {path}")
    if path.exists() and path.stat().st_mode & 0o022:
        raise ValueError(f"Scratch root must not be writable by other users: {path}")
    return path


@contextlib.contextmanager
def lock(path: Path) -> Iterator[bool]:
    import fcntl

    descriptor = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise ValueError(f"Lock must be a regular file: {path}")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            yield False
        else:
            yield True
    finally:
        os.close(descriptor)


def allocated(path: Path, *, errors: list[str] | None = None) -> int:
    device = path.lstat().st_dev
    seen: set[tuple[int, int]] = set()
    mounts: set[str] = set()
    mountinfo = Path("/proc/self/mountinfo")
    if mountinfo.is_file():
        for line in mountinfo.read_text().splitlines():
            value = line.split()[4]
            for encoded, decoded in (
                (r"\040", " "),
                (r"\011", "\t"),
                (r"\012", "\n"),
                (r"\134", "\\"),
            ):
                value = value.replace(encoded, decoded)
            mounts.add(value)

    def visit(name: str, info: os.stat_result, *, root: bool = False) -> int:
        try:
            if not root and (info.st_dev != device or name in mounts):
                raise ValueError(f"Nested mount refused: {name}")
            if info.st_nlink > 1:
                identity = (info.st_dev, info.st_ino)
                if identity in seen:
                    return 0
                seen.add(identity)
            size = info.st_blocks * 512
            if stat.S_ISDIR(info.st_mode):
                with os.scandir(name) as children:
                    for child in children:
                        try:
                            size += visit(child.path, child.stat(follow_symlinks=False))
                        except OSError as exc:
                            if errors is None:
                                raise
                            errors.append(f"{child.path}: {exc}")
            return size
        except (OSError, ValueError) as exc:
            if errors is None:
                raise
            errors.append(f"{name}: {exc}")
            return 0

    return visit(str(path.absolute()), path.lstat(), root=True)


def record(path: Path) -> RunRecord:
    marker = path / ".run.json"
    descriptor = os.open(marker, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor) as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError("Run marker must be a regular file")
        data = json.load(stream)
    if not isinstance(data, dict) or data.get("schema") != SCHEMA:
        raise ValueError("Unregistered scratch directory")
    updated = data.get("updated")
    if not isinstance(updated, (float, int)) or not math.isfinite(updated):
        raise ValueError("Run timestamp missing or invalid")
    if data.get("state") not in {"active", "completed", "failed", "compacted"}:
        raise ValueError("Run state missing or invalid")
    return cast(RunRecord, data)


def write_record(path: Path, data: RunRecord) -> None:
    with tempfile.NamedTemporaryFile(mode="w", dir=path, delete=False) as output:
        temporary = Path(output.name)
        json.dump(data, output)
    try:
        os.replace(temporary, path / ".run.json")
    finally:
        temporary.unlink(missing_ok=True)


def compact(path: Path) -> None:
    evidence = path / "evidence"
    if evidence.is_symlink():
        raise ValueError("Symlinked evidence refused")
    if not evidence.exists():
        with tempfile.TemporaryDirectory(prefix=".evidence-", dir=path) as folder:
            staging = Path(folder)
            remaining = 1024 * 1024
            for base, directories, files in os.walk(path, followlinks=False):
                directories[:] = sorted(
                    name
                    for name in directories
                    if name
                    not in {"project", "node_modules", ".godot", "build", "server", "evidence"}
                    and not name.startswith(".evidence-")
                    and not (Path(base) / name).is_symlink()
                )
                for name in sorted(files):
                    source = Path(base) / name
                    if source.is_symlink() or not source.is_file():
                        continue
                    if name not in {
                        "summary.json",
                        "assessment.json",
                        "seats.json",
                    } and not name.endswith(".log"):
                        continue
                    limit = min(remaining, 65536 if name.endswith(".json") else 16384)
                    if limit <= 0:
                        break
                    size = source.stat().st_size
                    with source.open("rb") as stream:
                        stream.seek(max(0, size - limit))
                        content = stream.read(limit)
                    target = staging / source.relative_to(path)
                    if size > limit and name.endswith(".json"):
                        target = target.with_suffix(".json.tail.txt")
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(content)
                    remaining -= len(content)
            os.replace(staging, evidence)
    for child in path.iterdir():
        if child.name in {".run.json", ".active", ".keep", "evidence"}:
            continue
        if child.is_dir() and not child.is_symlink():
            shutil.rmtree(child)
        else:
            child.unlink()


def clean(
    root: Path = DEFAULT_ROOT,
    *,
    apply: bool = False,
    budget: int = 10 * GIB,
    now: float | None = None,
    days: float = 7,
) -> CleanReport:
    root = root_path(root)
    now = time.time() if now is None else now
    result: CleanReport = {
        "root": str(root),
        "total_bytes": 0,
        "remaining_bytes": 0,
        "reclaimed_bytes": 0,
        "candidates": [],
        "protected": [],
        "errors": [],
        "over_budget": False,
        "apply": apply,
        "projected_bytes": 0,
        "protected_bytes": 0,
    }
    if not root.exists():
        return result
    with lock(root / ".sweep") as acquired:
        if not acquired:
            result["errors"].append("Another storage sweep is active")
            return result
        entries: list[tuple[float, Path, int, RunRecord]] = []
        for path in sorted(root.iterdir()):
            if path.is_symlink() or not path.is_dir() or path.is_mount():
                continue
            try:
                data = record(path)
                size = allocated(path)
                entries.append((data["updated"], path, size, data))
            except (OSError, ValueError) as exc:
                result["errors"].append(f"Skipped {path}: {exc}")
        total = sum(entry[2] for entry in entries)
        result["total_bytes"] = total
        for _updated, path, size, data in sorted(entries):
            try:
                if path.is_symlink() or path.is_mount() or path.resolve().parent != root:
                    raise ValueError("Run path changed during sweep")
                with lock(path / ".active") as acquired:
                    if not acquired or (path / ".keep").exists() or (path / ".keep").is_symlink():
                        result["protected"].append(str(path))
                        result["protected_bytes"] += size
                        continue
                    # Re-read after locking: a run can finish during the scan.
                    data = record(path)
                    if now - data["updated"] < days * 86400 and total <= budget:
                        continue
                    result["candidates"].append(str(path))
                    if apply:
                        if data.get("state") == "compacted":
                            shutil.rmtree(path)
                            new_size = 0
                        else:
                            compact(path)
                            write_record(path, {**data, "state": "compacted", "updated": now})
                            new_size = allocated(path)
                        total += new_size - size
                    else:
                        total -= size
            except (OSError, ValueError) as exc:
                result["errors"].append(f"Skipped {path}: {exc}")
        if apply and total > budget:
            for _, path, _, _ in sorted(entries):
                if not path.exists():
                    continue
                try:
                    if path.is_symlink() or path.is_mount() or path.resolve().parent != root:
                        raise ValueError("Run path changed during sweep")
                    with lock(path / ".active") as acquired:
                        if (
                            acquired
                            and not (path / ".keep").exists()
                            and not (path / ".keep").is_symlink()
                            and record(path).get("state") == "compacted"
                        ):
                            size = allocated(path)
                            shutil.rmtree(path)
                            total -= size
                            if total <= budget:
                                break
                except (OSError, ValueError) as exc:
                    result["errors"].append(f"Skipped {path}: {exc}")
        result["remaining_bytes"] = total if apply else result["total_bytes"]
        result["projected_bytes"] = total
        result["reclaimed_bytes"] = result["total_bytes"] - result["remaining_bytes"]
        result["over_budget"] = total > budget
    return result


@contextlib.contextmanager
def managed_output(
    output: Path | None,
    *,
    keep: bool = False,
    root: Path | None = None,
    now: Callable[[], float] = time.time,
) -> Iterator[Path]:
    if output is not None:
        output.mkdir(parents=True, exist_ok=True)
        yield output
        return
    root = root_path(
        root or Path(os.environ.get("SF_SCRATCH_ROOT", str(DEFAULT_ROOT))), create=True
    )
    clean(root, apply=True, now=now())
    path = Path(tempfile.mkdtemp(prefix="run-", dir=root))
    try:
        with lock(path / ".active") as acquired:
            if not acquired:
                raise RuntimeError("New experiment lock unavailable")
            data: RunRecord = {"schema": SCHEMA, "state": "active", "updated": now()}
            write_record(path, data)
            if keep:
                (path / ".keep").touch()
            state = "failed"
            try:
                yield path
                state = "completed"
            finally:
                write_record(path, {**data, "state": state, "updated": now()})
    finally:
        result = clean(root, apply=True, now=now())
        if result["over_budget"] or result["errors"]:
            print(f"WARN: scratch maintenance: {json.dumps(result)}", file=sys.stderr)


def set_pin(root: Path, name: str, pin: bool) -> None:
    root = root_path(root)
    if name in {"", ".", ".."} or Path(name).name != name:
        raise ValueError("Expected one run directory name")
    path = root / name
    if path.is_symlink():
        raise ValueError("Symlinked run refused")
    with lock(root / ".sweep") as acquired:
        if not acquired:
            raise RuntimeError("Another storage sweep is active")
        record(path)
        if (path / ".keep").is_symlink():
            raise ValueError("Symlinked pin refused")
        if pin:
            (path / ".keep").touch(exist_ok=True)
        else:
            (path / ".keep").unlink(missing_ok=True)


def report_paths(paths: list[Path]) -> PathsReport:
    start = time.monotonic()
    results: list[PathEntry] = []
    for path in paths:
        try:
            usage = shutil.disk_usage(path)
            errors: list[str] = []
            size = allocated(path, errors=errors)
            results.append(
                {
                    "path": str(path),
                    "allocated_bytes": size,
                    "owner_uid": path.lstat().st_uid,
                    "device": path.lstat().st_dev,
                    "errors": errors,
                    "filesystem_total": usage.total,
                    "filesystem_free": usage.free,
                }
            )
        except (OSError, ValueError) as exc:
            results.append({"path": str(path), "error": str(exc)})
    return {
        "paths": results,
        "duration_seconds": time.monotonic() - start,
        "measured_utc": datetime.now(timezone.utc).isoformat(),
        "accounting": "Paths can overlap or share image layers. Do not sum them.",
        "policy": "Report only",
    }


def extension_cache(path: Path, *, budget: int = 2 * GIB, apply: bool = False) -> CacheReport:
    if path.is_symlink() or path.resolve() != path.absolute():
        raise ValueError("Symlinked extension cache refused")
    files = sorted(
        (p for p in path.iterdir() if p.is_file() and not p.is_symlink()),
        key=lambda p: (p.stat().st_mtime, p.name),
    )
    total = sum(allocated(p) for p in files)
    result: CacheReport = {
        "total_bytes": total,
        "candidates": [],
        "apply": apply,
        "projected_bytes": total,
    }
    for item in files:
        if total <= budget:
            break
        size = allocated(item)
        result["candidates"].append(str(item))
        if apply:
            item.unlink()
        total -= size
    result["projected_bytes"] = total
    return result


def server_cache(path: Path, references: Path | None = None) -> dict[str, object]:
    references = references or Path.home() / ".vscode-server/bin"
    linked = {p.resolve() for p in references.glob("*") if p.is_symlink()}
    versions: list[dict[str, object]] = []
    for architecture in sorted(path.iterdir()):
        if not architecture.is_dir() or architecture.is_symlink():
            continue
        servers = sorted(
            (p for p in architecture.iterdir() if p.is_dir() and not p.is_symlink()),
            key=lambda p: (p.stat().st_mtime, p.name),
            reverse=True,
        )
        for index, server in enumerate(servers):
            local_reference = server.resolve() in linked
            versions.append(
                {
                    "path": str(server),
                    "allocated_bytes": allocated(server),
                    "local_reference": local_reference,
                    "retain_under_local_policy": local_reference or index < 2,
                }
            )
    return {
        "versions": versions,
        "other_container_references_verified": False,
        "policy": "Report only. Review other containers before removing any server.",
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true")
    commands = parser.add_subparsers(dest="command", required=True)
    report = commands.add_parser("report")
    report.add_argument("paths", nargs="*", type=Path)
    cleanup = commands.add_parser("clean")
    configured_root = Path(os.environ.get("SF_SCRATCH_ROOT", str(DEFAULT_ROOT)))
    cleanup.add_argument("--root", type=Path, default=configured_root)
    cleanup.add_argument("--budget-gib", type=float, default=10)
    cleanup.add_argument("--days", type=float, default=7)
    mode = cleanup.add_mutually_exclusive_group()
    mode.add_argument("--apply", action="store_true")
    mode.add_argument("--dry-run", action="store_true")
    for name in ("pin", "unpin"):
        pin = commands.add_parser(name)
        pin.add_argument("run")
        pin.add_argument("--root", type=Path, default=configured_root)
    shared = commands.add_parser("extension-cache")
    shared.add_argument("--path", type=Path, default=Path("/vscode/vscode-server/extensionsCache"))
    shared.add_argument("--budget-gib", type=float, default=2)
    shared.add_argument("--apply", action="store_true")
    shared.add_argument("--sessions-closed", action="store_true")
    servers = commands.add_parser("server-cache")
    servers.add_argument("--path", type=Path, default=Path("/vscode/vscode-server/bin"))
    legacy = commands.add_parser("legacy")
    legacy.add_argument("--path", type=Path, default=Path("/tmp"))  # noqa: S108
    args = parser.parse_args()
    if hasattr(args, "budget_gib") and (not 0 <= args.budget_gib <= 1024):
        parser.error("budget must be between 0 and 1024 GiB")
    result: object
    if args.command == "clean":
        if not 0 <= args.days <= 3650:
            parser.error("days must be between 0 and 3650")
        result = clean(
            args.root, apply=args.apply, budget=int(args.budget_gib * GIB), days=args.days
        )
    elif args.command in {"pin", "unpin"}:
        set_pin(args.root, args.run, args.command == "pin")
        result = {"run": args.run, "pinned": args.command == "pin"}
    elif args.command == "extension-cache":
        if args.apply and not args.sessions_closed:
            parser.error("shared cache cleanup requires --sessions-closed")
        result = extension_cache(args.path, budget=int(args.budget_gib * GIB), apply=args.apply)
    elif args.command == "server-cache":
        result = server_cache(args.path)
    elif args.command == "legacy":
        paths = [
            p
            for p in args.path.iterdir()
            if p.name.startswith(("session", "sf-session")) and p.is_dir() and not p.is_symlink()
        ]
        result = report_paths(paths)
        result["policy"] = (
            "Report only. Review paths and worktree registrations before explicit deletion."
        )
    else:
        result = report_paths(
            args.paths or [Path(tempfile.gettempdir()), Path.home(), Path("/vscode"), Path.cwd()]
        )
    print(("" if args.json else "Storage report (bytes):\n") + json.dumps(result, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError) as exc:
        raise SystemExit(f"storage: {exc}") from exc
