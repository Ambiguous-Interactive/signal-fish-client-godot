#!/usr/bin/env bash
# Install the official OpenAI Codex CLI for the dev container.
set -euo pipefail

CODEX_CLI_VERSION="${CODEX_CLI_VERSION:-0.135.0}"
CODEX_NPM_PACKAGE="@openai/codex"

if ! command -v node >/dev/null 2>&1; then
    echo "ERROR: node is required before installing Codex CLI." >&2
    exit 1
fi

if ! command -v npm >/dev/null 2>&1; then
    echo "ERROR: npm is required before installing Codex CLI." >&2
    exit 1
fi

npm_prefix="$(npm config get prefix 2>/dev/null || true)"
if [ -z "${npm_prefix}" ]; then
    echo "ERROR: npm config get prefix returned empty." >&2
    exit 1
fi

npm_bin_dir="${npm_prefix}/bin"
if [[ ":${PATH}:" != *":${npm_bin_dir}:"* ]]; then
    export PATH="${npm_bin_dir}:${PATH}"
fi

get_installed_codex_version() {
    local npm_json
    local parsed_version

    npm_json="$(npm list --global --depth=0 --json "${CODEX_NPM_PACKAGE}" 2>/dev/null || true)"
    if [ -z "${npm_json}" ]; then
        echo "WARN: npm list returned no package metadata; will attempt Codex install." >&2
        return 0
    fi

    if ! parsed_version="$(printf '%s' "${npm_json}" | node -e '
const fs = require("fs");
const input = fs.readFileSync(0, "utf8");
if (!input.trim()) process.exit(0);
try {
  const data = JSON.parse(input);
  const pkg = data.dependencies && data.dependencies["@openai/codex"];
  if (pkg && pkg.version) process.stdout.write(pkg.version);
} catch (error) {
  console.error(error.message);
  process.exit(2);
}
')"; then
        echo "WARN: could not parse npm package metadata; will attempt Codex install." >&2
        return 0
    fi

    printf '%s' "${parsed_version}"
}

installed_version="$(get_installed_codex_version)"
if [ "${installed_version}" = "${CODEX_CLI_VERSION}" ] && command -v codex >/dev/null 2>&1; then
    echo "==> Codex CLI ${CODEX_CLI_VERSION} already installed"
else
    echo "==> Installing Codex CLI ${CODEX_CLI_VERSION}"
    npm install --global --no-audit --no-fund "${CODEX_NPM_PACKAGE}@${CODEX_CLI_VERSION}"
fi

hash -r
if ! command -v codex >/dev/null 2>&1; then
    echo "ERROR: codex was installed but is not on PATH." >&2
    echo "       npm prefix: ${npm_prefix}" >&2
    echo "       expected bin: ${npm_bin_dir}" >&2
    exit 1
fi

codex_version_output="$(codex --version 2>&1)"
if [[ "${codex_version_output}" != *"${CODEX_CLI_VERSION}"* ]]; then
    echo "ERROR: codex --version did not report ${CODEX_CLI_VERSION}: ${codex_version_output}" >&2
    exit 1
fi

echo "==> Codex CLI ready: ${codex_version_output}"
