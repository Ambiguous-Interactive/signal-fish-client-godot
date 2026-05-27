#!/usr/bin/env bash
# Post-create lifecycle: install Python tooling, pre-commit hooks, and verify
# that the toolchain matches the repo's expectations.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${REPO_ROOT}"

echo "==> Configuring git safe.directory"
git config --global --add safe.directory "${REPO_ROOT}" || true

export PATH="/usr/local/bin:${HOME}/.local/bin:${PATH}"

# pre-commit is installed system-wide by the image (see Dockerfile). Fall back
# to a per-user pipx install if the image was customized to remove it.
if ! command -v pre-commit >/dev/null 2>&1; then
    echo "==> Installing pre-commit via pipx (fallback)"
    pipx ensurepath >/dev/null 2>&1 || true
    pipx install pre-commit
fi

if [ -f ".pre-commit-config.yaml" ]; then
    echo "==> Installing pre-commit git hooks"
    pre-commit install --install-hooks || {
        echo "WARN: pre-commit install failed; continuing." >&2
    }
fi

echo "==> Installing PowerShell user profile (persists pwsh history)"
# PowerShell on Linux reads CurrentUserAllHosts from
# $HOME/.config/powershell/profile.ps1. Installing here (instead of in the
# Dockerfile) is required because the PowerShell devcontainer feature lays
# down pwsh AFTER the image is built.
PWSH_PROFILE_DIR="${HOME}/.config/powershell"
PWSH_PROFILE_SRC="${REPO_ROOT}/.devcontainer/pwsh-profile.ps1"
if command -v pwsh >/dev/null 2>&1 && [ -f "${PWSH_PROFILE_SRC}" ]; then
    mkdir -p "${PWSH_PROFILE_DIR}"
    install -m 0644 "${PWSH_PROFILE_SRC}" "${PWSH_PROFILE_DIR}/profile.ps1"
else
    echo "WARN: pwsh or profile source not found; skipping PowerShell profile." >&2
fi

echo "==> Toolchain summary"
{
    printf '  bash    : %s\n' "$(bash --version | head -n1)"
    printf '  git     : %s\n' "$(git --version)"
    printf '  pwsh    : %s\n' "$(pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null || echo 'NOT FOUND')"
    printf '  python  : %s\n' "$(python3 --version 2>&1)"
    printf '  node    : %s\n' "$(node --version 2>/dev/null || echo 'NOT FOUND')"
    printf '  gh      : %s\n' "$(gh --version 2>/dev/null | head -n1 || echo 'NOT FOUND')"
    printf '  godot   : %s\n' "$(godot --version 2>/dev/null || echo 'NOT FOUND')"
    printf '  precmt  : %s\n' "$(pre-commit --version 2>/dev/null || echo 'NOT FOUND')"
} | tee /tmp/sf-toolchain.txt

echo "==> Dev container ready."
