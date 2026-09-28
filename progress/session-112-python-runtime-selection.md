# Session 112: select runtime checks with Python

Branch: `codex/session-112-python-runtime-selection` from `origin/main` at
`3ef53b7`.

- Moved the dirty-file classification and test preload graph traversal from
  Bash to Python for issue #168. The runtime gate still runs the selected
  checks through its existing command interface.
- Kept NUL-delimited Git paths and selector output, so names with newlines
  reach the right checks. Deleted test files still select their suites and
  stay out of file-based static checks.
- Added CI self-tests for classification, transitive selection, and Git paths.
- Local checks: selector self-tests, Ruff, mypy, shellcheck, shfmt, GitHub
  config validation, LLM harness fast check, full runtime gate, and a live
  single-suite fast-loop check passed.
- PR #227 delivers this milestone. The independent review found and fixed
  unsafe path matching for spaces, apostrophes, and escaped characters.

#168 stays open for more automation work.
