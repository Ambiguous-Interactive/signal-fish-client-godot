#!/usr/bin/env pwsh
# SessionStart hook: emit a one-shot reminder so the agent knows its
# writes are auto-validated. Kept short (<200 chars) to minimize per-session
# context overhead.

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$selfTokens = $null
$selfErrors = $null
try {
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $PSCommandPath, [ref]$selfTokens, [ref]$selfErrors)
} catch { exit 0 }
if ($null -ne $selfErrors -and $selfErrors.Count -gt 0) { exit 0 }

$reminder = 'Harness: hooks validate PowerShell and .llm edits. Recovery: pwsh -NoProfile -File scripts/preflight.ps1 -AutoFix'
$sessionStartResponse = [pscustomobject]@{
    hookSpecificOutput = [pscustomobject]@{
        hookEventName     = 'SessionStart'
        additionalContext = $reminder
    }
}
[System.Console]::Out.WriteLine(($sessionStartResponse | ConvertTo-Json -Depth 4 -Compress))
exit 0
