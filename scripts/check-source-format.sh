#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
mode="${1:-check}"
if [[ "$mode" != check && "$mode" != write ]]; then
    echo 'usage: check-source-format.sh [check|write]' >&2
    exit 2
fi
shfmt_bin="${SHFMT_BIN:-shfmt}"
command -v "$shfmt_bin" >/dev/null || {
    echo 'shfmt is required.' >&2
    exit 1
}
[[ -x node_modules/.bin/prettier ]] || {
    echo 'Run npm ci first.' >&2
    exit 1
}
command -v pwsh >/dev/null || {
    echo 'PowerShell is required.' >&2
    exit 1
}

mapfile -d '' -t shell_files < <(git ls-files -z -- '*.sh')
mapfile -d '' -t prettier_files < <(git ls-files -z -- '*.js' '*.cjs' '*.mjs' '*.json' '*.jsonc' '*.yml' '*.yaml' '*.toml' '*.md' '*.css' '*.html')
if [[ "$mode" == write ]]; then
    for path in "${shell_files[@]}"; do
        case "$path" in
        scripts/run-runtime-checks.sh) indent=0 ;;
        scripts/dependabot-auto-merge.sh) indent=2 ;;
        *) indent=4 ;;
        esac
        "$shfmt_bin" -i "$indent" -w "$path"
    done
    node_modules/.bin/prettier --write "${prettier_files[@]}"
    pwsh -NoProfile -File scripts/format-powershell.ps1 -Write
else
    for path in "${shell_files[@]}"; do
        case "$path" in
        scripts/run-runtime-checks.sh) indent=0 ;;
        scripts/dependabot-auto-merge.sh) indent=2 ;;
        *) indent=4 ;;
        esac
        "$shfmt_bin" -i "$indent" -d "$path"
    done
    node_modules/.bin/prettier --check "${prettier_files[@]}"
    pwsh -NoProfile -File scripts/format-powershell.ps1
fi
