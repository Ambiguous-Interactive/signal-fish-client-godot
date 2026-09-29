# Session 140: Python web export smoke setup

Branch: `codex/session-140-python-web-export-smoke` from `origin/main` at
`5b9bebe`.

- Moved the Web Export Smoke import, export, artifact check, and TLS setup into
  one Python command for #168.
- Kept the Godot export target and certificate settings unchanged.

Local checks: real Godot 4.3 web export, HTTPS and WSS browser smoke, Ruff,
mypy, GitHub config validation, full runtime checks, and the full LLM harness
passed.
