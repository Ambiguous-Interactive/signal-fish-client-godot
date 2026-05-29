#!/usr/bin/env pwsh
# Stop hook: final preflight safety net before the agent ends a turn.
# Runs `scripts/preflight.ps1 -NoAutoFix` so corrupted toolkit scripts
# (the failure mode that prompted this whole infrastructure) cannot
# silently survive until commit time. If preflight fails, emit stdout
# JSON {"decision":"block","reason":...} and exit 2 so the agent
# retries with a fix.
#
# Workflow note: agents whose flow involves many intermediate Stops can
# disable this hook via the standard Claude Code mechanism (e.g. a user
# settings override). Behavior is intentionally kept here so the default
# is safe; preflight is fast (sub-second on this repo) so the per-turn
# cost is negligible.

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Self-parse guard.
$selfTokens = $null
$selfErrors = $null
try {
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $PSCommandPath, [ref]$selfTokens, [ref]$selfErrors)
} catch { exit 0 }
if ($null -ne $selfErrors -and $selfErrors.Count -gt 0) { exit 0 }

function Get-RepoRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_PROJECT_DIR) -and
        (Test-Path -LiteralPath $env:CLAUDE_PROJECT_DIR -PathType Container)) {
        return ([System.IO.Path]::GetFullPath($env:CLAUDE_PROJECT_DIR)).TrimEnd(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar)
    }
    $dir = Split-Path -Parent $PSCommandPath
    while (-not [string]::IsNullOrWhiteSpace($dir)) {
        if (Test-Path -LiteralPath (Join-Path $dir '.git')) {
            return ([System.IO.Path]::GetFullPath($dir)).TrimEnd(
                [System.IO.Path]::DirectorySeparatorChar,
                [System.IO.Path]::AltDirectorySeparatorChar)
        }
        $parent = Split-Path -Parent $dir
        if ($parent -eq $dir) { break }
        $dir = $parent
    }
    return $null
}

$repoRoot = Get-RepoRoot
if ([string]::IsNullOrWhiteSpace($repoRoot)) { exit 0 }
$preflight = Join-Path $repoRoot 'scripts/preflight.ps1'
if (-not (Test-Path -LiteralPath $preflight -PathType Leaf)) {
    exit 0
}

$output = & pwsh -NoProfile -File $preflight -NoAutoFix 2>&1
$exitCode = $LASTEXITCODE
if ($exitCode -ne 0) {
    $reason = "Preflight failed (exit $exitCode) before turn end. A toolkit script may be corrupted. Output:`n$($output -join "`n")`nRun: pwsh -NoProfile -File scripts/preflight.ps1 -AutoFix to recover from the index first, then HEAD fallback; backups are preserved."
    $blockResponse = [pscustomobject]@{
        decision = 'block'
        reason   = $reason
    }
    [System.Console]::Out.WriteLine(($blockResponse | ConvertTo-Json -Compress))
    exit 2
}
exit 0
