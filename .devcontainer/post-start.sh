#!/usr/bin/env bash
# Post-start lifecycle: runs after every successful container start.
#   1. Keep the workspace trusted for git (cheap, idempotent).
#   2. Refresh the agent CLIs warn-only via `install-agent-tools.sh --update`;
#      a registry outage must never block VS Code from attaching.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/usr/local/bin:${HOME}/.local/bin:${PATH}"

echo "==> Configuring git safe.directory"
# --add is append-only; check first so every attach does not grow ~/.gitconfig.
if git config --global --get-all safe.directory 2>/dev/null | grep -qxF "${REPO_ROOT}"; then
    :
else
    git config --global --add safe.directory "${REPO_ROOT}" || true
fi

echo "==> Checking agent CLI versions (best-effort refresh)"
if bash "${REPO_ROOT}/.devcontainer/install-agent-tools.sh" --update; then
    echo "==> Agent CLI refresh attempted"
else
    echo "WARN: agent CLI refresh failed; using installed versions." >&2
fi

echo "==> Container ready."
