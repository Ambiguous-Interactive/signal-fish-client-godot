[CmdletBinding()]
param(
    [switch]$VerboseOutput,
    # Run the exhaustive validation path, including behavioral sandbox tests.
    [switch]$Full,
    # Compatibility switch for older invocations. AgentFast skips behavioral
    # subprocess tests by design; in Full mode only this explicit switch keeps
    # them skipped.
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
$runnerArgs = @{
    Mode            = $mode
    SkipStagedCheck = $true
    NoAutoFix       = $true
}
if ($VerboseOutput) { $runnerArgs.VerboseOutput = $true }

# Invoke the shared runner in this PowerShell process. The runner owns
# preflight gating, fast-path scoping, and exit codes, so agent-check stays
# a tiny non-mutating convenience wrapper.
$hadSkipBehavioralEnv = Test-Path Env:LLM_HARNESS_SKIP_BEHAVIORAL_TESTS
$skipBehavioralBackup = if ($hadSkipBehavioralEnv) { $env:LLM_HARNESS_SKIP_BEHAVIORAL_TESTS } else { $null }
$exitCode = 1
try {
    if ($SkipBehavioralTests -or -not $Full) {
        $env:LLM_HARNESS_SKIP_BEHAVIORAL_TESTS = '1'
    } else {
        Remove-Item Env:LLM_HARNESS_SKIP_BEHAVIORAL_TESTS -ErrorAction SilentlyContinue
    }
    & $entry @runnerArgs
    $exitCode = $LASTEXITCODE
} finally {
    if ($hadSkipBehavioralEnv) {
        $env:LLM_HARNESS_SKIP_BEHAVIORAL_TESTS = $skipBehavioralBackup
    } else {
        Remove-Item Env:LLM_HARNESS_SKIP_BEHAVIORAL_TESTS -ErrorAction SilentlyContinue
    }
}
exit $exitCode
