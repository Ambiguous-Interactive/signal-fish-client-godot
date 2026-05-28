[CmdletBinding()]
param(
    [switch]$VerboseOutput,
    # Skip the subprocess-spawning behavioral test subset (~8 tests that
    # fork `pwsh -File ...` for sandbox / end-to-end checks). Drops the
    # wall time from ~10-15s to under 3s, suitable for tight inner-loop
    # post-edit feedback. The pre-commit hook does NOT pass this flag,
    # so the full suite still gates real commits. (MIN-2)
    [switch]$SkipBehavioralTests
)

# Comprehensive pre-commit / post-edit validation entry point for AI
# agents and humans iterating locally. Wall time ~10-15s for the full
# suite; pass `-SkipBehavioralTests` to drop sub-3s for tight feedback
# loops. Runs the two halves of the pre-commit flow with the flags that
# make sense outside an actual `git commit`:
#
#   1. `preflight.ps1 -NoAutoFix`              -> parse-checks toolkit
#      sources first; corruption surfaces loudly before any other tool
#      attempts to execute a broken script.
#   2. `run-llm-hooks.ps1 -SkipStagedCheck -NoAutoFix` -> regenerate /
#      lint / self-test pipeline. `-SkipStagedCheck` because the working
#      tree may legitimately differ from the index while you are editing.
#      `-NoAutoFix` because we want loud failure surfaces, not silent edits.
#
# Run this after editing any `.ps1`, `.psm1`, `.psd1`, or `.llm/**` file.
# It is a no-network, no-mutation check. If it passes, the pre-commit hook
# will also pass (modulo staging).
#
# Usage:
#   pwsh -NoProfile -File scripts/agent-check.ps1
#   pwsh -NoProfile -File scripts/agent-check.ps1 -VerboseOutput
#   pwsh -NoProfile -File scripts/agent-check.ps1 -SkipBehavioralTests

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$preflight = Join-Path $PSScriptRoot 'preflight.ps1'
$entry = Join-Path $PSScriptRoot 'run-llm-hooks.ps1'

if (-not (Test-Path -LiteralPath $preflight -PathType Leaf)) {
    Write-Host "[agent-check] Missing $preflight" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path -LiteralPath $entry -PathType Leaf)) {
    Write-Host "[agent-check] Missing $entry" -ForegroundColor Red
    exit 1
}

# Step 1: preflight first (parse-check toolkit sources). Bail on non-zero
# so a corrupted source cannot bleed into the harness step.
$preArgs = @('-NoProfile', '-File', $preflight, '-NoAutoFix')
if ($VerboseOutput) { $preArgs += '-VerboseOutput' }
& pwsh @preArgs
if ($LASTEXITCODE -ne 0) {
    Write-Host "[agent-check] Preflight failed (exit $LASTEXITCODE); aborting before harness." -ForegroundColor Red
    exit $LASTEXITCODE
}

# Step 2: the regenerate / lint / self-test pipeline.
#
# Set LLM_HARNESS_PREFLIGHT_DONE=1 so `run-llm-hooks.ps1` skips its own
# preflight pass (we just paid for it above). Saves ~0.9s wall time.
# (NIT-5)
#
# Propagate -SkipBehavioralTests to run-llm-hooks via the same env-var
# pattern so the self-test stage skips behavioral tests without a wire
# protocol change. The flag is `LLM_HARNESS_SKIP_BEHAVIORAL_TESTS=1`.
# (MIN-2)
$envBackup = @{
    Preflight  = $env:LLM_HARNESS_PREFLIGHT_DONE
    Behavioral = $env:LLM_HARNESS_SKIP_BEHAVIORAL_TESTS
}
$env:LLM_HARNESS_PREFLIGHT_DONE = '1'
if ($SkipBehavioralTests) {
    $env:LLM_HARNESS_SKIP_BEHAVIORAL_TESTS = '1'
}
try {
    $hookArgs = @('-NoProfile', '-File', $entry, '-SkipStagedCheck', '-NoAutoFix')
    if ($VerboseOutput) { $hookArgs += '-VerboseOutput' }
    & pwsh @hookArgs
    exit $LASTEXITCODE
} finally {
    # Restore the parent env so callers do not inherit our state.
    $env:LLM_HARNESS_PREFLIGHT_DONE = $envBackup.Preflight
    $env:LLM_HARNESS_SKIP_BEHAVIORAL_TESTS = $envBackup.Behavioral
}
