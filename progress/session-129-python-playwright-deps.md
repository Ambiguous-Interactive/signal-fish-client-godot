# Session 129: Python Playwright system setup

Branch: `codex/session-129-python-playwright-deps` from `origin/main` at
`68ccc2f`.

- Moved shared Chromium system dependency setup into Python for #168.
- Used Playwright's own apt simulation result to skip installs when the runner
  already has the packages.
- Kept the runner image and Playwright version stamp, Chrome apt source cleanup,
  and install retries.

Checks: helper tests, live local Playwright probe, GitHub config validation,
runtime changed gate, Python lint and format, docs style, and LLM harness.
