#!/usr/bin/env python3
"""Enforce the docs style policy: ASCII-only Markdown, no LLM-isms.

Scope: every tracked ``*.md`` file plus ``llms.txt``. The policy keeps the
documentation surface copy-paste safe for any editor and tool chain and
bans the contrast constructions ("not X, but Y") that read as generated
prose. Pattern checks skip fenced code blocks; code samples are not prose.
An inline ``<!-- sf-allow:non-ascii -->`` marker suppresses every check on
its own line; use it for intentional non-ASCII (a multi-byte string shown
in a protocol example) or a legit prose overlap.
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile
import unicodedata

ALLOW_MARKER = "<!-- sf-allow:non-ascii -->"

# Name -> pattern. Case-insensitive; each hit is one finding.
PATTERNS = {
    "contrast 'not X, but Y'": re.compile(r"\bnot [^.;?!\n]{1,60}, but (?:rather |simply |just )?\b", re.I),
    "contrast 'it's not X, it's Y'": re.compile(r"\bit'?s not [^.;?!\n]{1,60}, (?:but )?it'?s\b", re.I),
    "filler 'not just'": re.compile(r"\b(?:not|isn't|aren't|wasn't|weren't) just\b", re.I),
    "filler 'it's worth noting'": re.compile(r"\bit'?s worth noting (that )?\b", re.I),
}

FENCE = re.compile(r"^\s*(?:```|~~~)")

EXTRA_FILES = ("llms.txt",)


def git_toplevel():
    return subprocess.run(
        ["git", "rev-parse", "--show-toplevel"], capture_output=True, check=True
    ).stdout.decode("utf-8").strip()


def is_scoped_doc(root_relative):
    return root_relative.endswith(".md") or root_relative in EXTRA_FILES


def scoped_existing_docs(entries, top):
    """Filter raw root-relative paths to this checker's scope, existing only.

    Single source of truth for "which files does the policy cover": callers
    that re-encode the scope themselves drift from CI (the llms.txt and
    markdownlint-config misses this file fixed both came from that drift).
    """
    out = []
    for rel in sorted({e for e in entries if e}):
        if not is_scoped_doc(rel):
            continue
        path = os.path.join(top, rel)
        if os.path.isfile(path):
            out.append(path)
    return out


def tracked_doc_files():
    top = git_toplevel()
    # --full-name + cwd=top: paths come back root-relative no matter where
    # the checker was invoked from.
    result = subprocess.run(
        ["git", "ls-files", "-z", "--full-name", "--", "*.md", *EXTRA_FILES],
        capture_output=True,
        check=True,
        cwd=top,
    )
    return sorted(
        f"{top}/{p.decode('utf-8')}" for p in result.stdout.split(b"\0") if p
    )


def dirty_doc_files():
    top = git_toplevel()
    entries = []
    for args in (
        ["diff", "--name-only", "-z", "HEAD"],
        ["ls-files", "-z", "--others", "--exclude-standard"],
    ):
        result = subprocess.run(["git", *args], capture_output=True, check=True, cwd=top)
        entries.extend(result.stdout.decode("utf-8").split("\0"))
    return scoped_existing_docs(entries, top)


def find_violations(text):
    """Yield (line_number, column, message) for one file's text."""
    in_fence = False
    for index, line in enumerate(text.splitlines(), 1):
        if FENCE.match(line):
            in_fence = not in_fence
        allowed = ALLOW_MARKER in line
        for col, char in enumerate(line, 1):
            if ord(char) > 127:
                if allowed:
                    continue
                name = unicodedata.name(char, f"U+{ord(char):04X}")
                yield index, col, f"non-ASCII character U+{ord(char):04X} {name}"
        if allowed or in_fence:
            continue
        for name, pattern in PATTERNS.items():
            match = pattern.search(line)
            if match:
                yield index, match.start() + 1, name


def run_check(paths, skip_missing=False):
    findings = []
    scanned = 0
    files = paths if paths else tracked_doc_files()
    for path in files:
        try:
            text = open(path, encoding="utf-8").read()
        except FileNotFoundError:
            # A deleted doc is a legitimate edit (the caller filters those
            # out up front); an explicitly named missing path is a typo and
            # stays an error.
            if not skip_missing and paths:
                findings.append((path, 0, 0, "not found"))
            continue
        except (OSError, UnicodeDecodeError) as exc:
            findings.append((path, 0, 0, f"unreadable: {exc}"))
            continue
        scanned += 1
        for line, col, message in find_violations(text):
            findings.append((path, line, col, message))
    return findings, scanned


def self_test():
    failures = []

    def expect(message, text, count):
        got = len(list(find_violations(text)))
        if got != count:
            failures.append(f"{message}: expected {count} violations, got {got}")

    def allow(message, text, needle):
        got = [v for v in find_violations(text) if needle in v[2]]
        if got:
            failures.append(f"{message}: marker did not suppress {got}")

    expect("em dash", "a \u2014 b\n", 1)
    expect("en dash", "a \u2013 b\n", 1)
    expect("arrow", "a \u2192 b\n", 1)
    expect("ellipsis", "a\u2026\n", 1)
    expect("section sign", "\u00a74.1\n", 1)
    expect("middle dot", "a \u00b7 b\n", 1)
    expect("curly quote", "\u2018x\u2019\n", 2)
    expect("contrast not-x-but-y", "it is not fast, but robust.\n", 1)
    expect("contrast not-x-but-y is case-insensitive", "It is NOT slow, BUT sturdy.\n", 1)
    expect("contrast its-not-x-its-y", "it's not a bug, it's a feature.\n", 1)
    expect("not just", "not just fast.\n", 1)
    expect("isn't just", "isn't just fast.\n", 1)
    expect("worth noting", "It's worth noting that it works.\n", 1)
    expect("plain ascii passes", "a - b -> c, 100% done.\n", 0)
    expect("sentence without the shape is fine", "The file is not found; nothing else happens.\n", 0)
    expect("patterns skip fenced code", "```gdscript\nnot fast, but strict\n```\n", 0)
    expect("fence state tracks toggles", "```\nx\n```\nnot slow, but sure.\n", 1)
    expect("non-ASCII inside a fence still counts", "```\na \u2014 b\n```\n", 1)
    allow("marker suppresses non-ASCII", "h\u00e9llo " + ALLOW_MARKER + "\n", "non-ASCII")
    allow("marker suppresses patterns", "not just " + ALLOW_MARKER + "\n", "filler")
    expect("marker only covers its line", "h\u00e9llo\nplain\n", 1)

    with tempfile.TemporaryDirectory() as top:
        for rel in ("docs/keep.md", "keep2.md", "out-of-scope.gd"):
            full = os.path.join(top, rel)
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, "w", encoding="utf-8"):
                pass
        got = scoped_existing_docs(
            [
                "docs/keep.md",
                "keep2.md",
                "gone.md",
                "out-of-scope.gd",
                ".markdownlint.json",
                "LICENSE",
                "",
            ],
            top,
        )
        want = sorted([os.path.join(top, "docs/keep.md"), os.path.join(top, "keep2.md")])
        if got != want:
            failures.append(f"dirty-doc filter: expected {want}, got {got}")

    if failures:
        for failure in failures:
            print(f"self-test FAIL: {failure}", file=sys.stderr)
        return 1
    print("check-docs-style self-test OK")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="*", help="files to check (default: all tracked docs)")
    parser.add_argument(
        "--changed",
        action="store_true",
        help="check the dirty docs (HEAD diff + untracked, this checker's scope) instead of the whole tree",
    )
    parser.add_argument("--self-test", action="store_true", help="run internal checks and exit")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if args.changed and args.paths:
        parser.error("--changed cannot be combined with explicit paths")
    if args.changed:
        findings, scanned = run_check(dirty_doc_files(), skip_missing=True)
    else:
        findings, scanned = run_check(args.paths)
    top = ""
    if not args.paths:
        top = git_toplevel()
    for path, line, col, message in findings:
        shown = path[len(top) + 1:] if top and path.startswith(top + "/") else path
        print(f"::error file={shown},line={line},col={col}::{message}")
    if findings:
        print(
            f"check-docs-style: {len(findings)} violation(s). "
            "Docs must be ASCII with no LLM-isms; a line needing an escape "
            f"carries an inline '{ALLOW_MARKER}' marker.",
            file=sys.stderr,
        )
        return 1
    print(f"check-docs-style OK ({scanned} file(s) scanned)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
