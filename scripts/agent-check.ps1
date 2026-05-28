[CmdletBinding()]
param(
    [switch]$VerboseOutput
)

# Fast pre-commit / post-edit validation entry point intended for AI agents
# and humans iterating locally. Wraps `run-llm-hooks.ps1` with the flags that
# make sense outside an actual `git commit`:
#
#   * `-SkipStagedCheck`  – the working tree may legitimately differ from
#                            the index while you are editing.
#   * `-NoAutoFix`        – we want loud failure surfaces, not silent edits,
#                            so the caller learns what is wrong.
#
# Run this after editing any `.ps1`, `.psm1`, `.psd1`, or `.llm/**` file.
# It is a no-network, no-mutation check. If it passes, the pre-commit hook
# will also pass (modulo staging).
#
# Usage:
#   pwsh -NoProfile -File scripts/agent-check.ps1
#   pwsh -NoProfile -File scripts/agent-check.ps1 -VerboseOutput

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$entry = Join-Path $PSScriptRoot 'run-llm-hooks.ps1'
if (-not (Test-Path -LiteralPath $entry -PathType Leaf)) {
    Write-Host "[agent-check] Missing $entry" -ForegroundColor Red
    exit 1
}

$argsList = @('-NoProfile', '-File', $entry, '-SkipStagedCheck', '-NoAutoFix')
if ($VerboseOutput) { $argsList += '-VerboseOutput' }

& pwsh @argsList
exit $LASTEXITCODE
