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

Local checks: portability tests, Ruff, mypy, a real maintenance run with
tool updates disabled, LLM harness, runtime gate, and docs style.
