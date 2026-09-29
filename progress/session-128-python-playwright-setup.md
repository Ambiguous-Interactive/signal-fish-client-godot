# Session 128: Python Playwright browser setup

Branch: `codex/session-128-python-playwright-setup` from `origin/main` at
`7f66044`.

- Used the pinned Python Playwright in Docs Validation and Web Export Smoke to
  install Chromium and its system packages (#168).
- Removed the duplicate npm install and Node cache from the shared action.
- Checked that each workflow installs Python Playwright before the action.

Checks: GitHub config self-tests, Python lint, format and types, full LLM
harness, and docs style. PR CI verifies the docs browser path; the web smoke
workflow remains a separate scheduled or manual check.
