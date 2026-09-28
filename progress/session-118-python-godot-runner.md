# Session 118: move the Godot runner to Python

Branch: `refactor/python-runtime-godot` from `origin/main` at `2a1705b`.

- Moved suite selection, cold project copies, archive preparation, warm cache
  snapshots, and output checks into `scripts/run-runtime-godot.py` for #168.
- Kept the `run-runtime-checks.sh` entry point and the warm single-suite,
  isolated multi-suite, forced-cold, and opt-in smoke commands.
- Kept deleted files out of the tar manifest and failed runs with a
  `SCRIPT ERROR` diagnostic, even when Godot exits zero.

Local checks: Python types, full and changed runtime gates, forced-cold
protocol suite, socket smoke check, malformed Godot output, archive fallback,
and LLM context validation. #168 remains open for other suitable scripts.
