# PowerShell-native pre-commit hook for environments without a POSIX sh
# (e.g., pure Windows installs without Git for Windows' bundled sh.exe).
# Mirrors `.githooks/pre-commit` so logic stays single-sourced in
# `scripts/run-llm-hooks.ps1`.
#
# Git invokes hook files by their exact name (`pre-commit`), so on Windows
# without sh, install this with:
#   git config core.hooksPath .githooks
#   Copy-Item .githooks/pre-commit.ps1 .githooks/pre-commit -Force
# `scripts/install-git-hooks.ps1` handles this automatically.

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$hookDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $hookDir
$entry = Join-Path $repoRoot 'scripts/run-llm-hooks.ps1'

if (-not (Test-Path -LiteralPath $entry -PathType Leaf)) {
    Write-Host "[llm-hook] ERROR: missing $entry" -ForegroundColor Red
    exit 1
}

& pwsh -NoProfile -File $entry
exit $LASTEXITCODE
