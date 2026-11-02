#!/usr/bin/env python3
"""Check the pinned master WebSocket repair against upstream Godot master.

The master pin in ``scripts/repair-websocket-stable.py`` freezes the upstream
submission godotengine/godot#125066 at one revision. This script reads the
current upstream master ref, mirrors the patched files at that revision, and
checks that the bundled patch still applies, so receive-path drift or upstream
adoption surfaces as a scheduled CI failure instead of a stale pin.

Network is only used by the default mode; ``--self-test`` is offline.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from collections.abc import Callable
from pathlib import Path

DEFAULT_REPO_ROOT = Path(__file__).resolve().parent.parent

MASTER_REF_URL = "https://github.com/godotengine/godot.git"
RAW_BASE_URL = "https://raw.githubusercontent.com/godotengine/godot"
PR_API_URL = "https://api.github.com/repos/godotengine/godot/pulls/125066"
PR_NUMBER = 125066
REPAIR_SCRIPT = Path("scripts/repair-websocket-stable.py")

REVISION_RE = r"[0-9a-f]{40}"
MASTER_PIN_RE = re.compile(r'"(' + REVISION_RE + r')":\s*"(godot-master-[^"]+)"')
PATCH_HEADER_RE = re.compile(r"^diff --git a/(\S+) b/(\S+)$", re.M)
GIT_REF_RE = re.compile(r"^(" + REVISION_RE + r")\trefs/heads/master$", re.M)
ADOPTION_MARKER = "frame_is_data"

# The bundled patch must keep applying to upstream master. A still-applying
# patch after master moved stays green: the pin itself is unchanged. Adoption
# and receive-path drift both demand action, so both fail the check.
OK_STATUSES = ("current", "applies")


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise RuntimeError(f"cannot read {path}: {exc}") from exc


def extract_unique(pattern: re.Pattern[str], text: str, source: str) -> tuple[str, str]:
    matches = pattern.findall(text)
    if not matches:
        raise RuntimeError(f"no master pin found in {source}")
    unique = sorted(set(matches))
    if len(unique) != 1:
        raise RuntimeError(f"conflicting master pins in {source}: {', '.join(map(str, unique))}")
    value = unique[0]
    if not isinstance(value, tuple) or len(value) != 2:
        raise RuntimeError(f"master pin in {source} is not a revision and patch pair")
    return value


def local_pin(repo_root: Path) -> tuple[str, Path]:
    source = REPAIR_SCRIPT
    revision, patch_name = extract_unique(MASTER_PIN_RE, read_text(repo_root / source), str(source))
    patch = repo_root / "scripts" / "patches" / patch_name
    if not patch.is_file():
        raise RuntimeError(f"bundled master patch is missing: {patch}")
    return revision, patch


def patch_paths(patch_text: str) -> list[str]:
    paths = sorted({match.group(1) for match in PATCH_HEADER_RE.finditer(patch_text)})
    for path in paths:
        if path.startswith("/") or ".." in Path(path).parts or not path.strip():
            raise RuntimeError(f"unsafe path in patch header: {path!r}")
    if not paths:
        raise RuntimeError("patch carries no file headers")
    return paths


def remote_master() -> str:
    result = subprocess.run(  # noqa: S603
        ["git", "ls-remote", MASTER_REF_URL, "refs/heads/master"],  # noqa: S607
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(f"git ls-remote failed: {result.stderr.strip()}")
    match = GIT_REF_RE.search(result.stdout)
    if match is None:
        raise RuntimeError("git ls-remote returned no parsable master ref")
    revision = match.group(1)
    if revision is None:
        raise RuntimeError("git ls-remote master ref has no revision")
    return revision


def fetch_file(revision: str, path: str) -> str:
    url = f"{RAW_BASE_URL}/{revision}/{path}"
    request = urllib.request.Request(  # noqa: S310
        url, headers={"User-Agent": "signal-fish-master-pin-watch"}
    )
    with urllib.request.urlopen(request, timeout=60) as response:  # noqa: S310
        raw: bytes = response.read()
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise RuntimeError(f"{url} is not valid UTF-8: {exc}") from exc


def evaluate(
    revision: str,
    patch: Path,
    master: str,
    fetch_file_fn: Callable[[str, str], str] = fetch_file,
) -> dict[str, object]:
    if master == revision:
        return {"status": "current"}
    patch_text = read_text(patch)
    paths = patch_paths(patch_text)
    mirrored: dict[str, str] = {}
    for path in paths:
        mirrored[path] = fetch_file_fn(master, path)
    applies = True
    with tempfile.TemporaryDirectory(prefix="master-pin-") as tmp:
        root = Path(tmp)
        for path, content in mirrored.items():
            target = root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content, encoding="utf-8")
        subprocess.run(["git", "init", "-q", str(root)], check=True, timeout=60)  # noqa: S603, S607
        apply = subprocess.run(  # noqa: S603
            ["git", "apply", "--check", str(patch)],  # noqa: S607
            cwd=root,
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        applies = apply.returncode == 0
    status = "applies"
    if not applies:
        status = (
            "adopted" if any(ADOPTION_MARKER in body for body in mirrored.values()) else "drifted"
        )
    return {"status": status, "master": master, "files": paths}


def parse_pr(payload: object) -> dict[str, object]:
    if not isinstance(payload, dict):
        return {"error": "upstream PR response is not an object"}
    return {
        "number": PR_NUMBER,
        "state": payload.get("state"),
        "draft": payload.get("draft"),
        "mergeable_state": payload.get("mergeable_state"),
        "review_comments": payload.get("review_comments"),
        "updated_at": payload.get("updated_at"),
    }


def pr_state() -> dict[str, object]:
    request = urllib.request.Request(
        PR_API_URL,
        headers={
            "User-Agent": "signal-fish-master-pin-watch",
            "Accept": "application/vnd.github+json",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:  # noqa: S310
            raw: bytes = response.read()
        payload = json.loads(raw.decode("utf-8"))
    except (urllib.error.URLError, OSError, ValueError) as exc:
        return {"error": str(exc)}
    return parse_pr(payload)


def report(result: dict[str, object], pin: str, patch_name: str) -> None:
    status = str(result["status"])
    master = str(result.get("master", pin))
    print(f"master-pin: pin {pin[:12]} ({patch_name}) against upstream master {master[:12]}")
    if status in OK_STATUSES:
        detail = "matches the pin" if status == "current" else "moved; the patch still applies"
        print(f"master-pin: OK (master {detail})")
    else:
        if status == "adopted":
            print(
                f"master-pin: ADOPTED: master contains the repair. Requalify the adopted "
                f"revision, then retire the pin ({PR_NUMBER})."
            )
        else:
            print(
                f"master-pin: DRIFTED: master changed the receive path. Rebase the bundled "
                f"patch and refresh the upstream submission ({PR_NUMBER})."
            )
    upstream = result.get("upstream_pr")
    if isinstance(upstream, dict) and "error" not in upstream:
        print(f"master-pin: upstream PR #{PR_NUMBER}: {json.dumps(upstream, sort_keys=True)}")
    else:
        error = upstream.get("error") if isinstance(upstream, dict) else "unknown"
        print(f"master-pin: upstream PR #{PR_NUMBER}: unavailable ({error})")


def check(repo_root: Path) -> int:
    try:
        revision, patch = local_pin(repo_root)
        master = remote_master()
        result = evaluate(revision, patch, master)
    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError) as exc:
        print(f"master-pin: FAILED: {exc}", file=sys.stderr)
        return 1
    result["upstream_pr"] = pr_state()
    report(result, revision, patch.name)
    return 0 if result["status"] in OK_STATUSES else 1


def self_test() -> int:
    revision, patch = local_pin(DEFAULT_REPO_ROOT)
    assert re.fullmatch(REVISION_RE, revision), revision
    patch_text = read_text(patch)
    paths = patch_paths(patch_text)
    assert paths == sorted(
        [
            "modules/websocket/wsl_peer.cpp",
            "modules/websocket/wsl_peer.h",
            "thirdparty/wslay/wslay_event.c",
        ]
    ), paths
    added = [line for line in patch_text.splitlines() if line.startswith("+")]
    assert any(ADOPTION_MARKER in line for line in added), "adoption marker left the patch"

    for unsafe in ("/etc/passwd", "../escape", "ok/../../up"):
        patch_text_unsafe = patch_text.replace("modules/websocket/wsl_peer.cpp", unsafe)
        try:
            patch_paths(patch_text_unsafe)
        except RuntimeError:
            pass
        else:
            raise AssertionError(f"unsafe patch path must be rejected: {unsafe}")

    try:
        extract_unique(MASTER_PIN_RE, '{"no": "pins"}', "empty.txt")
    except RuntimeError:
        pass
    else:
        raise AssertionError("missing master pins must be rejected")

    conflicting = (
        '"95c0fa5fe8a019adc29d074c16b64469b04571f7": "godot-master-websocket-assembly.patch"\n'
        '"ed1daf0bf001b61586d9930840f2f1394092c079": "godot-master-websocket-assembly.patch"\n'
    )
    try:
        extract_unique(MASTER_PIN_RE, conflicting, "conflict.txt")
    except RuntimeError:
        pass
    else:
        raise AssertionError("conflicting master pins must be rejected")

    # Offline structural check of the real repo: the applicator must still
    # select the bundled patch so a rename or regen surfaces here instead of
    # only in the weekly networked run.
    repair_text = read_text(DEFAULT_REPO_ROOT / REPAIR_SCRIPT)
    assert patch.name in repair_text, patch.name
    print("master-pin: self-test passed")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=DEFAULT_REPO_ROOT)
    parser.add_argument("--self-test", action="store_true", help="offline self-test")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    return check(args.repo_root)


if __name__ == "__main__":
    sys.exit(main())
