# Session 110: check web exports with Python

Branch: `codex/session-110-python-web-browser-smoke` from `origin/main` at
`30ee8d7`.

- Moved the browser export smoke check to Python. It still checks HTTPS boot,
  WSS authentication and ping, browser Origin, and `ws://` refusal.
- Aligned Node and Python Playwright on `1.61.0` and added a check that rejects
  pin drift.
- Verified the exported Godot 4.3 demo in Chromium. Runtime, Python, source,
  and GitHub config checks passed locally.

#168 stays open for other automation work.
