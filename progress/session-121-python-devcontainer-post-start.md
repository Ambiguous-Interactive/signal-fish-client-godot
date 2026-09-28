# Session 121: run devcontainer maintenance from Python

Branch: `refactor/python-devcontainer-post-start` from `origin/main` at
`20f8e62`.

- Moved optional tool refresh and Python dependency repair into
  `.devcontainer/post-start.py` for #168. The shell entry point keeps PATH,
  git trust, and the no-maintenance path so startup works in the offline
  base-image test before Python is installed.
- Kept ordinary starts offline and optional maintenance warn-only.
- Updated portability and harness checks to cover the Python path, including
  idempotent git trust and a broken venv that does not block attach.
- CI exposed a repeatable docs accessibility timing failure: drawer state
  changed before its animation-frame focus move. The browser check now waits
  for that visible modal focus before continuing.

Local checks: portability tests, Ruff, mypy, a real maintenance run with
tool updates disabled, LLM harness, runtime gate, docs style, and the browser
accessibility check.
