[CmdletBinding()]
param(
    [switch]$VerboseOutput,
    # Run the exhaustive validation path, including behavioral sandbox tests.
    [switch]$Full,
    # Compatibility switch for older invocations. AgentFast skips behavioral
    # subprocess tests by design; in Full mode this env var keeps them skipped.
    [switch]$SkipBehavioralTests
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$entry = Join-Path $PSScriptRoot 'run-llm-hooks.ps1'
if (-not (Test-Path -LiteralPath $entry -PathType Leaf)) {
    Write-Host "[agent-check] Missing $entry" -ForegroundColor Red
    exit 1
}

$mode = if ($Full) { 'Full' } else { 'AgentFast' }
if ($SkipBehavioralTests -or -not $Full) {
    $env:LLM_HARNESS_SKIP_BEHAVIORAL_TESTS = '1'
}

$runnerArgs = @{
    Mode            = $mode
    SkipStagedCheck = $true
    NoAutoFix       = $true
}
if ($VerboseOutput) { $runnerArgs.VerboseOutput = $true }

# Invoke the shared runner in this PowerShell process. The runner owns
# preflight gating, fast-path scoping, and exit codes, so agent-check stays
# a tiny non-mutating convenience wrapper.
& $entry @runnerArgs
exit $LASTEXITCODE
