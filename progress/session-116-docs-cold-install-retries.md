# Session 116: retry cold docs installs

Branch: `fix/docs-cold-install-retries` from `origin/main` at `6139e37`.

- Issue #236: two cold-cache Docs Validation jobs timed out fetching
  `python-dateutil` from PyPI after uv's default retry window.
- Extended pip and uv request timeouts for cold docs installs, with five uv
  retries. Persistent fetch or dependency errors still fail the job.
- Updated the docs venv cache key so PR CI exercises a fresh install.

Local GitHub config validation passed. Cold-cache CI evidence: pending.
