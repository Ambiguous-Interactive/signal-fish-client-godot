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
import re
import subprocess
import sys
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


def tracked_doc_files():
    top = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"], capture_output=True, check=True
    ).stdout.decode("utf-8").strip()
    result = subprocess.run(
        ["git", "ls-files", "-z", "--", "*.md", *EXTRA_FILES],
        capture_output=True,
        check=True,
    )
    return sorted(
        f"{top}/{p.decode('utf-8')}" for p in result.stdout.split(b"\0") if p
    )


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


def run_check(paths):
    findings = []
    explicit = bool(paths)
    files = paths if explicit else tracked_doc_files()
    for path in files:
        try:
            text = open(path, encoding="utf-8").read()
        except FileNotFoundError:
            # A deleted tracked doc is a legitimate edit; an explicitly
            # named missing path is a typo and stays an error.
            if explicit:
                findings.append((path, 0, 0, "not found"))
            continue
        except (OSError, UnicodeDecodeError) as exc:
            findings.append((path, 0, 0, f"unreadable: {exc}"))
            continue
        for line, col, message in find_violations(text):
            findings.append((path, line, col, message))
    return findings


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

    if failures:
        for failure in failures:
            print(f"self-test FAIL: {failure}", file=sys.stderr)
        return 1
    print("check-docs-style self-test OK")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="*", help="files to check (default: all tracked docs)")
    parser.add_argument("--self-test", action="store_true", help="run internal checks and exit")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    findings = run_check(args.paths)
    top = ""
    if not args.paths:
        top = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"], capture_output=True, check=True
        ).stdout.decode("utf-8").strip()
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
    files = args.paths if args.paths else tracked_doc_files()
    print(f"check-docs-style OK ({len(files)} file(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main())
