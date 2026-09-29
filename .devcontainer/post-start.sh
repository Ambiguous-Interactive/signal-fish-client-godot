#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
echo "==> Configuring git safe.directory"
if git config --global --get-all safe.directory 2>/dev/null | grep -qxF "${repo_root}"; then
    :
else
    git config --global --add safe.directory "${repo_root}" || true
fi

if [ "${SF_DEVCONTAINER_MAINTENANCE:-0}" != "1" ]; then
    echo "==> Container ready. Rebuild to update tools."
    exit 0
fi

exec python3 "${repo_root}/.devcontainer/post-start.py"
