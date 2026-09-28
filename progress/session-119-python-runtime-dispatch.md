# Session 119: dispatch runtime checks from Python

Branch: `refactor/python-runtime-dispatch` from `origin/main` at `88c4299`.

- Moved runtime check selection and orchestration from Bash into
  `scripts/run-runtime-checks.py` for #168. The shell entry point still sets
  the tool environment before starting Python.
- Kept the `all`, `changed`, standalone static, Godot, and smoke commands.
  Removed the NUL plan handoff between the old selector and Bash.
- Pinned the full-mode empty scoped file list and tooling-pin path in the
  selector self-tests.

Local checks: selector self-tests, full and changed runtime gates, Python
quality, GitHub config, LLM fast gate, and an invalid GDScript case that made
`changed` fail. #168 remains open for other suitable scripts.
