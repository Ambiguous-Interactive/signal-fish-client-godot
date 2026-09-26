#!/usr/bin/env bash
# Post-create lifecycle: install repo git hooks and verify
# that the toolchain matches the repo's expectations.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${REPO_ROOT}"
DEVCONTAINER_DIR="${REPO_ROOT}/.devcontainer"

echo "==> Configuring git safe.directory"
git config --global --add safe.directory "${REPO_ROOT}" || true

export PATH="/usr/local/bin:${HOME}/.local/bin:${PATH}"

ensure_writable_dir() {
    local path="$1"

    mkdir -p "${path}" 2>/dev/null || true
    if [ ! -d "${path}" ] && command -v sudo >/dev/null 2>&1; then
        sudo mkdir -p "${path}"
    fi

    if [ -d "${path}" ] && [ ! -w "${path}" ] && command -v sudo >/dev/null 2>&1; then
        sudo chown -R "$(id -u):$(id -g)" "${path}"
    fi

    if [ ! -d "${path}" ] || [ ! -w "${path}" ]; then
        echo "WARN: ${path} is not writable; related tooling may fall back or fail." >&2
        return 1
    fi
}

echo "==> Preparing writable mounted directories"
ensure_writable_dir "/commandhistory" || true
# Docker creates parent directories of volume mount points as root. The
# pre-commit cache volume targets ~/.cache/pre-commit, so every freshly
# created container starts with a root-owned ~/.cache. Anything that lazily
# mkdirs under ~/.cache then dies with EACCES: opencode's postinstall verify
# step crashes there (which fails the whole agent CLI install and leaves
# dangling npm bin symlinks behind), and so does VS Code's agent host
# (mkdir ~/.cache/Microsoft). Repair before anything runs.
ensure_writable_dir "${HOME}/.cache" || true

echo "==> Installing direct git hooks"
pwsh -NoProfile -File scripts/install-git-hooks.ps1 -Force

echo "==> Verifying image agent CLIs (codex, opencode, nanocoder, claude)"
# Invoke via bash: repo scripts are committed non-executable (Windows-authored,
# core.filemode=false), so direct execution fails on Linux-native checkouts.
bash "${DEVCONTAINER_DIR}/install-agent-tools.sh" --verify
for cli in codex opencode nanocoder claude; do
    if ! command -v "${cli}" >/dev/null 2>&1; then
        echo "ERROR: agent CLI '${cli}' is missing after post-create install." >&2
        exit 1
    fi
done

echo "==> Checking npm-based MCP servers"
SF_MCP_SKIP_PLAYWRIGHT_BROWSER=1 bash "${DEVCONTAINER_DIR}/install-mcp-servers.sh"

echo "==> Seeding agent MCP configurations (doctor prints names and set/unset state, never values)"
bash "${DEVCONTAINER_DIR}/seed-mcp-config.sh"

echo "==> Installing PowerShell user profile (persists pwsh history)"
# PowerShell on Linux reads CurrentUserAllHosts from
# $HOME/.config/powershell/profile.ps1. Installing here (instead of in the
# Dockerfile) is required because the PowerShell devcontainer feature lays
# down pwsh AFTER the image is built.
PWSH_PROFILE_DIR="${HOME}/.config/powershell"
PWSH_PROFILE_SRC="${DEVCONTAINER_DIR}/pwsh-profile.ps1"
if command -v pwsh >/dev/null 2>&1 && [ -f "${PWSH_PROFILE_SRC}" ]; then
    ensure_writable_dir "${PWSH_PROFILE_DIR}" || {
        echo "ERROR: Failed to prepare ${PWSH_PROFILE_DIR}." >&2
        exit 1
    }
    install -m 0644 "${PWSH_PROFILE_SRC}" "${PWSH_PROFILE_DIR}/profile.ps1" || {
        echo "ERROR: Failed to install PowerShell profile to ${PWSH_PROFILE_DIR}/profile.ps1." >&2
        exit 1
    }
else
    echo "WARN: pwsh or profile source not found; skipping PowerShell profile." >&2
fi

echo "==> Toolchain summary"
TOOLCHAIN_SUMMARY="$(mktemp "${TMPDIR:-/tmp}/sf-toolchain.XXXXXX")"
{
    printf '  bash    : %s\n' "$(bash --version | head -n1)"
    printf '  git     : %s\n' "$(git --version)"
    printf '  pwsh    : %s\n' "$(pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null || echo 'NOT FOUND')"
    printf '  python  : %s\n' "$(python3 --version 2>&1)"
    printf '  node    : %s\n' "$(node --version 2>/dev/null || echo 'NOT FOUND')"
    printf '  gh      : %s\n' "$(gh --version 2>/dev/null | head -n1 || echo 'NOT FOUND')"
    printf '  godot   : %s\n' "$(godot --version 2>/dev/null || echo 'NOT FOUND')"
    printf '  codex   : %s\n' "$(codex --version 2>/dev/null | head -n 1 || echo 'NOT FOUND')"
    printf '  opencode: %s\n' "$(opencode --version 2>/dev/null | head -n 1 || echo 'NOT FOUND')"
    printf '  nanocoder: %s\n' "$(nanocoder --version 2>/dev/null | head -n 1 || echo 'NOT FOUND')"
    printf '  claude  : %s\n' "$(claude --version 2>/dev/null | head -n 1 || echo 'NOT FOUND')"
    printf '  github-mcp-server: %s\n' "$(github-mcp-server --version 2>/dev/null | head -n 1 || echo 'NOT FOUND')"
    printf '  pre-commit (optional): %s\n' "$(pre-commit --version 2>/dev/null || echo 'NOT FOUND')"
} | tee "${TOOLCHAIN_SUMMARY}"
echo "==> Toolchain summary saved to ${TOOLCHAIN_SUMMARY}"

SF_DEVCONTAINER_MAINTENANCE=1 SF_DEVCONTAINER_SKIP_TOOL_UPDATES=1 \
    bash "${DEVCONTAINER_DIR}/post-start.sh"

echo "==> Dev container ready."
