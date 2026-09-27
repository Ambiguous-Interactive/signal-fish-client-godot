#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
shellcheck_bin="${SHELLCHECK_BIN:-shellcheck}"
command -v "$shellcheck_bin" >/dev/null || {
    echo 'ShellCheck is required.' >&2
    exit 1
}
[[ -x node_modules/.bin/eslint ]] || {
    echo 'Run npm ci first.' >&2
    exit 1
}
command -v pwsh >/dev/null || {
    echo 'PowerShell is required.' >&2
    exit 1
}

mapfile -d '' -t shell_files < <(git ls-files -z -- '*.sh')
mapfile -d '' -t javascript_files < <(git ls-files -z -- '*.js' '*.cjs' '*.mjs')
"$shellcheck_bin" --severity=style "${shell_files[@]}"
node_modules/.bin/eslint --max-warnings 0 "${javascript_files[@]}"
pwsh -NoProfile -File scripts/check-powershell-quality.ps1
