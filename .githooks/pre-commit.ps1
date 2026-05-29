#!/usr/bin/env pwsh
# Optional PowerShell-native pre-commit reference for environments where
# the user wants to invoke the harness directly from pwsh instead of via
# the materialised POSIX shim.
#
# This file is NOT the live hook. Production installs run
# `pwsh -NoProfile -File scripts/install-git-hooks.ps1`, which materialises
# a `#!/usr/bin/env sh` shim into the path from `git rev-parse --git-path
# hooks`. The sh shim works on Linux, macOS, and Windows because Git for
# Windows always bundles `sh.exe`. A pwsh shebang on the extensionless live
# hook would break on Windows: `pwsh -File` refuses files without a `.ps1`
# extension.

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

& pwsh -NoProfile -File $entry -Mode PreCommit -AutoFix
exit $LASTEXITCODE
