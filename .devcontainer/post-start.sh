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

echo "==> Ensuring Python automation dependencies (warn-only)"
# CI provides these two things; heal them locally so the local gate matches
# CI. PyYAML must be importable by bare python3 because harness sandbox
# tests strip .venv-ci, and runner images ship it globally. One local
# .venv-ci serves both gates: gdtoolkit for run-runtime-checks.sh (ci.yml)
# and PyYAML for the harness (llm-harness.yml).
cd "${REPO_ROOT}"
venv_ok() {
    . .venv-ci/bin/activate \
        && python -c 'import yaml' >/dev/null 2>&1 \
        && gdformat --version >/dev/null 2>&1
}
if ! python3 -c 'import yaml' >/dev/null 2>&1; then
    if python3 -m pip install --user -r "${REPO_ROOT}/requirements-automation.txt" >/dev/null 2>&1 \
        && python3 -c 'import yaml' >/dev/null 2>&1; then
        echo "==> Installed PyYAML into user site-packages"
    else
        echo "WARN: python3 cannot import PyYAML; GitHub config validation fails until it is installed" \
            "(python3 -m pip install --user -r requirements-automation.txt)." >&2
        if [ -f /usr/lib/python3*/EXTERNALLY-MANAGED ] 2>/dev/null; then
            echo "WARN: this interpreter enforces PEP 668 (EXTERNALLY-MANAGED); install with" \
                "'python3 -m pip install --user --break-system-packages -r requirements-automation.txt' or fix PATH." >&2
        fi
    fi
fi
# Verify, not just existence: a venv whose pip install died halfway must be
# re-provisioned on the next start instead of silently poisoning every
# later run.
if [ ! -f ".venv-ci/bin/activate" ] || ! venv_ok; then
    # Re-provisioning an existing venv is safe: `venv` upgrades in place and
    # pip install is idempotent, so a halfway-failed install heals here.
    if python3 -m venv .venv-ci \
        && . .venv-ci/bin/activate \
        && python -m pip install -r "${REPO_ROOT}/requirements-ci.txt" -r "${REPO_ROOT}/requirements-automation.txt" >/dev/null 2>&1 \
        && venv_ok; then
        echo "==> .venv-ci ready with runtime and automation dependencies"
    else
        echo "WARN: could not provision .venv-ci; runtime checks fall back to user site-packages." >&2
    fi
fi

echo "==> Container ready."
