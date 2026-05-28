#!/usr/bin/env pwsh
# PostToolUse hook: parse-check PowerShell sources immediately after the
# agent writes / edits them, so a corrupt save surfaces as tool_result
# JSON on the NEXT turn (the agent self-corrects) rather than at hook /
# commit time.
#
# Contract:
#   - Reads tool_input JSON from stdin (Claude Code's hook protocol).
#   - If tool_input.file_path ends with .ps1 / .psm1 / .psd1, parse-check it.
#   - On parse failure: emit stdout JSON {"decision":"block","reason":...}
#     and exit 2 so the model sees a structured tool_result and self-
#     corrects. Exit 2 is kept as the secondary mechanism for hosts that
#     do not parse stdout JSON.
#   - On success or non-PowerShell files: exit 0 silently. Cold-start cost
#     is what matters here (target: under 1s).
#
# Cross-platform: pwsh-only, no bash, no `find`, no `sed`. Works on
# Linux / macOS / Windows native pwsh.

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Self-parse guard. The hook file itself MUST parse before it can validate
# anything else; if a future edit corrupts this hook, the corruption
# surfaces here rather than silently disabling the safety net.
$selfTokens = $null
$selfErrors = $null
try {
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $PSCommandPath, [ref]$selfTokens, [ref]$selfErrors)
} catch {
    # Keep stderr clean (Write-Host is captured but not stderr-noisy).
    # Do not block the agent on a hook bug; preflight will catch it.
    Write-Host "[parse-check-hook] self-parse threw: $($_.Exception.Message)" -ForegroundColor Yellow
    exit 0
}
if ($null -ne $selfErrors -and $selfErrors.Count -gt 0) {
    Write-Host "[parse-check-hook] self-parse failed; ignoring this turn." -ForegroundColor Yellow
    exit 0
}

function Send-BlockReason {
    param([string]$Reason)
    # Per Claude Code docs, the canonical structured-output form is stdout
    # JSON with `decision = "block"`. Exit 2 stays as the secondary
    # signal for hosts that key off exit codes.
    #
    # NOTE: this helper is intentionally duplicated in
    # `.claude/hooks/validate-llm-context.ps1`. Hook scripts MUST be
    # self-contained: a shared helper would create a bootstrap circular
    # dependency (the parse-check hook helping diagnose corruption in
    # the very module it depends on). Keep these two copies in sync by
    # convention; the duplication is small (~10 lines) and the safety
    # property is more valuable than the DRY win.
    $obj = [pscustomobject]@{
        decision = 'block'
        reason   = $Reason
    }
    [System.Console]::Out.WriteLine(($obj | ConvertTo-Json -Compress))
    exit 2
}

# Read the hook input. Claude Code sends a JSON envelope on stdin.
$raw = [System.Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }

$payload = $null
try {
    $payload = $raw | ConvertFrom-Json -ErrorAction Stop
} catch {
    # Malformed input is not the agent's fault; bail out silently.
    exit 0
}

if ($null -eq $payload -or -not ($payload.PSObject.Properties.Name -contains 'tool_input')) {
    exit 0
}
# Defensive matcher: trust but verify the upstream matcher. If a future
# Claude Code version routes an unexpected tool here (or a misconfigured
# settings.json forgets the matcher), exit silently rather than running
# the parse check against a non-write tool's payload.
if ($payload.PSObject.Properties.Name -contains 'tool_name' -and
    $payload.tool_name -notin @('Write', 'Edit', 'MultiEdit')) {
    exit 0
}
$filePath = $payload.tool_input.file_path
if ([string]::IsNullOrWhiteSpace($filePath)) { exit 0 }
if ($filePath -notmatch '\.(ps1|psm1|psd1)$') { exit 0 }
if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) { exit 0 }

$tokens = $null
$parseErrors = $null
try {
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $filePath, [ref]$tokens, [ref]$parseErrors)
} catch {
    Send-BlockReason "${filePath}: PowerShell parser threw '$($_.Exception.Message)'. Re-read the file and fix any duplicate / orphan code blocks. Do NOT commit until the file parses cleanly."
}
if ($null -ne $parseErrors -and $parseErrors.Count -gt 0) {
    $first = $parseErrors[0]
    Send-BlockReason "${filePath}: parse error on line $($first.Extent.StartLineNumber) col $($first.Extent.StartColumnNumber): $($first.Message). Re-read the file and fix any duplicate / orphan code blocks left over from a stale editor buffer. Do NOT commit until the file parses cleanly."
}
exit 0
