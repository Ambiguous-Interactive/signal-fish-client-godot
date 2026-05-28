[CmdletBinding()]
param(
    # Skip the staged-files dirty check. Used by wrappers such as CI and the
    # pre-commit framework when they validate content outside a local staging flow.
    [switch]$SkipStagedCheck,
    # Auto-recover from the two most common, deterministic failure modes:
    #   * Generated `.llm/index.md` / `.llm/context.md` regenerated but not
    #     staged -> `git add` them.
    #   * Stray staging artifacts (`*.new`, `*.bak`, `*.orig`, `*.old`,
    #     `*.rej`) in the working tree -> delete them.
    # Default OFF for direct script invocation (loud failure surface). The
    # pre-commit hook ENABLES this so commits do not fail for mechanical
    # reasons. CI passes `-NoAutoFix` to keep failures loud.
    [switch]$AutoFix,
    [switch]$NoAutoFix,
    [switch]$VerboseOutput
)

# Single source of truth for the pre-commit / CI LLM harness flow.
#
# Responsibilities:
#   1. Regenerate `.llm/index.md` and the generated section of
#      `.llm/context.md`.
#   2. Run the linter.
#   3. Run the harness self-tests.
#   4. Detect any change to generated files that is not staged for commit,
#      including untracked files (which `git diff` ignores).
#
# Exits non-zero if any step fails or the generated files are not staged.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptsDir = $PSScriptRoot
$RepoRoot = Split-Path -Parent $ScriptsDir
$ModulePath = Join-Path $ScriptsDir 'lib/LlmHarness.psm1'
$Generator = Join-Path $ScriptsDir 'generate-llm-index.ps1'
$Linter = Join-Path $ScriptsDir 'lint-llm.ps1'
$SelfTests = Join-Path $ScriptsDir 'test-llm-harness.ps1'
$Preflight = Join-Path $ScriptsDir 'preflight.ps1'
$GeneratedFiles = @('.llm/index.md', '.llm/context.md')
$StagingArtifactPatterns = @('*.new', '*.bak', '*.orig', '*.old', '*.rej')
# Broader cleanup set used in AutoFix. Sourced from the shared module
# (Get-LlmDefaultStrayPatterns) so the linter, hook runner, and helper
# defaults never drift apart (MIN-1). The assignment happens AFTER
# `Import-Module` below; until then this is $null and unused.
$WorkingTreeJunkPatterns = $null

# -NoAutoFix wins over -AutoFix so CI / scripted callers can force loud
# failure regardless of any wrapper that flipped -AutoFix on.
$autoFixEnabled = [bool]$AutoFix -and -not $NoAutoFix

function Write-HookLine {
    param([string]$Message, [string]$Color = 'Gray')
    Write-Host "[llm-hook] $Message" -ForegroundColor $Color
}

function ConvertFrom-GeneratedFileStatusLine {
    param([AllowEmptyString()][string]$Line)

    if ($null -eq $Line) { $Line = '' }
    $index = if ($Line.Length -ge 1) { $Line[0] } else { ' ' }
    $worktree = if ($Line.Length -ge 2) { $Line[1] } else { ' ' }
    $path = if ($Line.Length -ge 4) { $Line.Substring(3) } else { $Line }
    $needsStaging = -not [string]::IsNullOrWhiteSpace($Line) -and
    (($index -eq '?' -and $worktree -eq '?') -or $worktree -ne ' ')

    return [pscustomobject]@{
        Raw          = $Line
        Index        = $index
        Worktree     = $worktree
        Path         = $path
        NeedsStaging = $needsStaging
    }
}

if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
    Write-HookLine 'pwsh is required but was not found on PATH.' 'Red'
    exit 1
}
if (-not (Test-Path -LiteralPath $Generator -PathType Leaf)) {
    Write-HookLine "Missing generator script: $Generator" 'Red'
    exit 1
}
if (-not (Test-Path -LiteralPath $ModulePath -PathType Leaf)) {
    Write-HookLine "Missing shared harness module: $ModulePath" 'Red'
    exit 1
}
if (-not (Test-Path -LiteralPath $Linter -PathType Leaf)) {
    Write-HookLine "Missing linter script: $Linter" 'Red'
    exit 1
}
if (-not (Test-Path -LiteralPath $SelfTests -PathType Leaf)) {
    Write-HookLine "Missing self-tests script: $SelfTests" 'Red'
    exit 1
}
if (-not (Test-Path -LiteralPath $Preflight -PathType Leaf)) {
    Write-HookLine "Missing preflight script: $Preflight" 'Red'
    exit 1
}

# Skip the parse-check + preflight invocation if an outer wrapper
# already ran preflight in this process tree (NIT-5). `agent-check.ps1`
# sets `LLM_HARNESS_PREFLIGHT_DONE=1` before invoking us so the shared
# preflight is not paid twice (~0.9s saved per invocation). We require
# the env var to equal the exact string '1' to avoid false-positive
# matches against any user-provided value.
$skipPreflight = ($env:LLM_HARNESS_PREFLIGHT_DONE -eq '1')

if ($skipPreflight) {
    Write-HookLine 'Skipping preflight (LLM_HARNESS_PREFLIGHT_DONE=1; already run by outer wrapper).'
} else {
    # Parse-check preflight.ps1 BEFORE invoking it. If preflight itself has
    # a parse error, pwsh refuses to start it and preflight's own self-check
    # branch never runs. This is the n-level recovery shape: the shim parse-
    # checks `run-llm-hooks.ps1`; `run-llm-hooks.ps1` parse-checks
    # `preflight.ps1`; `preflight.ps1` parse-checks every other PS file.
    # Each layer is the LAST line of defense for the layer below.
    $preflightTokens = $null
    $preflightErrors = $null
    try {
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $Preflight, [ref]$preflightTokens, [ref]$preflightErrors)
    } catch {
        Write-HookLine "Failed to parse-check preflight.ps1: $($_.Exception.Message)" 'Red'
        exit 1
    }
    if ($null -ne $preflightErrors -and $preflightErrors.Count -gt 0) {
        Write-HookLine "preflight.ps1 has parse errors:" 'Red'
        foreach ($e in $preflightErrors) {
            Write-HookLine "  preflight.ps1:$($e.Extent.StartLineNumber): $($e.Message)" 'Red'
        }
        if ($autoFixEnabled -and (Get-Command git -ErrorAction SilentlyContinue)) {
            Write-HookLine 'AutoFix: restoring scripts/preflight.ps1 from index (staged version), HEAD as fallback.' 'Yellow'
            # Index-first restore mirrors preflight.ps1's policy: a
            # user mid-commit usually has the clean WIP staged and a
            # corrupt working-tree copy. Restoring from the index
            # preserves that WIP. Fall back to HEAD only when the
            # index copy is also corrupt or there is no index entry.
            $restoredFrom = $null
            Push-Location $RepoRoot
            try {
                $indexOut = @(& git checkout -- 'scripts/preflight.ps1' 2>&1)
                if ($LASTEXITCODE -eq 0) {
                    $iTokens = $null
                    $iErrors = $null
                    [void][System.Management.Automation.Language.Parser]::ParseFile(
                        $Preflight, [ref]$iTokens, [ref]$iErrors)
                    if ($null -eq $iErrors -or $iErrors.Count -eq 0) {
                        $restoredFrom = 'index'
                    }
                }
                if ($null -eq $restoredFrom) {
                    $headOut = @(& git checkout HEAD -- 'scripts/preflight.ps1' 2>&1)
                    if ($LASTEXITCODE -ne 0) {
                        Write-HookLine "AutoFix: git checkout HEAD failed for scripts/preflight.ps1 (exit $LASTEXITCODE): $($headOut -join '; ')" 'Red'
                        exit 1
                    }
                    $hTokens = $null
                    $hErrors = $null
                    [void][System.Management.Automation.Language.Parser]::ParseFile(
                        $Preflight, [ref]$hTokens, [ref]$hErrors)
                    if ($null -eq $hErrors -or $hErrors.Count -eq 0) {
                        $restoredFrom = 'HEAD'
                    }
                }
            } finally {
                Pop-Location
            }
            if ($null -eq $restoredFrom) {
                Write-HookLine 'Both index and HEAD copies of scripts/preflight.ps1 are corrupt; escalate manually.' 'Red'
                exit 1
            }
            Write-HookLine "AutoFix: recovered scripts/preflight.ps1 from $restoredFrom; continuing." 'Yellow'
        } else {
            Write-HookLine 'Re-run with -AutoFix (or restore HEAD manually) to recover.' 'Yellow'
            exit 1
        }
    }

    # Preflight runs BEFORE anything else so a corrupted toolkit script is
    # diagnosed (and, in -AutoFix mode, recovered from HEAD) before pwsh tries
    # to execute it. Exit 2 from preflight means it auto-recovered something:
    # we surface a warning and continue.
    Write-HookLine 'Running preflight (parse-check toolkit sources)...'
    $preArgs = @('-NoProfile', '-File', $Preflight)
    if ($autoFixEnabled) { $preArgs += '-AutoFix' } else { $preArgs += '-NoAutoFix' }
    if ($VerboseOutput) { $preArgs += '-VerboseOutput' }
    & pwsh @preArgs
    $preExit = $LASTEXITCODE
    if ($preExit -eq 1) {
        Write-HookLine 'Preflight reported unrecoverable corruption; aborting.' 'Red'
        exit 1
    }
    if ($preExit -eq 2) {
        Write-HookLine 'Preflight auto-recovered one or more sources (index/HEAD); corrupt originals preserved in .git/preflight-recovery/. Continuing.' 'Yellow'
    } elseif ($preExit -ne 0) {
        Write-HookLine "Preflight failed with unexpected exit $preExit." 'Red'
        exit $preExit
    }
}

Import-Module $ModulePath -Force
# Now that the shared module is loaded, source the canonical stray-
# artifact pattern list from it (MIN-1).
$WorkingTreeJunkPatterns = @(Get-LlmDefaultStrayPatterns)

Push-Location $RepoRoot
try {
    # Stray artifact handling. The broader pattern set (Get-LlmStray...)
    # closes the gitignored `*.tmp` / `*.swp` blind spot the linter's
    # tracked-only check cannot see. We ALWAYS run this scan; the only
    # difference between AutoFix and NoAutoFix is whether we delete the
    # in-scope ones or just report-and-fail.
    if (Get-Command git -ErrorAction SilentlyContinue) {
        try {
            $strayArtifacts = @(Get-LlmStrayWorkingTreeArtifacts -RepoRoot $RepoRoot -Patterns $WorkingTreeJunkPatterns)
        } catch {
            Write-HookLine $_.Exception.Message 'Red'
            exit 1
        }
        $trackedSet = Get-LlmTrackedFileSet -RepoRoot $RepoRoot
        $autoFixFailed = $false
        $strayReportable = New-Object System.Collections.Generic.List[string]
        $repoRootFull = [System.IO.Path]::GetFullPath($RepoRoot)
        $repoRootPrefix = $repoRootFull.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) +
        [System.IO.Path]::DirectorySeparatorChar
        # Filesystem case sensitivity is platform-dependent: Linux is
        # case-sensitive; Windows/macOS default to case-insensitive. Using
        # OrdinalIgnoreCase everywhere would false-allow `/repo/x` to match
        # a repo root of `/Repo/` on Linux (a different directory), defeating
        # the traversal guard. Pick the comparison mode to match the OS.
        $pathComparison = if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Linux)) {
            [System.StringComparison]::Ordinal
        } else {
            [System.StringComparison]::OrdinalIgnoreCase
        }
        foreach ($artifact in $strayArtifacts) {
            $stray = $artifact.Path
            $full = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $stray))
            # Defensive: never let a path that escapes the repo root reach
            # Remove-Item. `git ls-files` already returns repo-relative paths,
            # but belt-and-suspenders is cheap here.
            if (-not ($full.StartsWith($repoRootPrefix, $pathComparison) -or
                    $full.Equals($repoRootFull, $pathComparison))) {
                Write-HookLine "Stray: refusing to touch suspicious path outside repo: $stray" 'Red'
                $autoFixFailed = $true
                continue
            }
            # Skip if it does not exist OR if it is a directory (defensive
            # against a future git behavior change; `git ls-files` returns
            # only files today but we never want to recurse-delete a dir).
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
            # Scope check: only auto-delete artifacts inside controlled
            # directories or those that look like backups of tracked
            # sources. Anything else is reported as a warning.
            $deletable = Test-LlmDeletableArtifact -RepoRoot $RepoRoot -RelativePath $stray -TrackedFiles $trackedSet
            if (-not $deletable) {
                if ($autoFixEnabled) {
                    Write-HookLine "AutoFix: found stray $stray but it's outside controlled directories; leaving for manual review." 'Yellow'
                } else {
                    # NoAutoFix mode: even out-of-scope strays must surface
                    # as a failure so CI / agents notice them.
                    $strayReportable.Add($stray)
                }
                continue
            }
            if (-not $autoFixEnabled) {
                # NoAutoFix mode: report the in-scope stray; we will fail
                # at the end of the scan with the aggregated list.
                $strayReportable.Add($stray)
                continue
            }
            $removed = $false
            try {
                Remove-Item -LiteralPath $full -Force -ErrorAction Stop
                $removed = $true
                Write-HookLine "AutoFix: removed stray staging artifact: $stray" 'Yellow'
            } catch {
                Write-HookLine "AutoFix: failed to remove $stray`: $($_.Exception.Message)" 'Red'
            }
            if ($artifact.IsTracked) {
                if (-not $removed) {
                    # Tracked file still on disk -> repo would stay broken.
                    # Fail loudly rather than silently continuing.
                    $autoFixFailed = $true
                    continue
                }
                $rmOutput = @(& git rm -f --quiet -- $stray 2>&1)
                if ($LASTEXITCODE -ne 0) {
                    Write-HookLine "AutoFix: git rm failed for $stray (exit $LASTEXITCODE): $($rmOutput -join '; ')" 'Red'
                    $autoFixFailed = $true
                }
            }
        }
        if ($autoFixFailed) {
            Write-HookLine 'AutoFix could not clean up stray artifacts; aborting before commit.' 'Red'
            exit 1
        }
        if ($strayReportable.Count -gt 0) {
            Write-HookLine 'Stray working-tree artifacts found (NoAutoFix mode):' 'Red'
            foreach ($s in $strayReportable) {
                Write-HookLine "  - $s" 'Red'
            }
            Write-HookLine 'Remove them manually or re-run with -AutoFix.' 'Yellow'
            exit 1
        }
    }

    Write-HookLine 'Regenerating LLM index and context section...'
    $genArgs = @('-NoProfile', '-File', $Generator)
    if ($VerboseOutput) { $genArgs += '-VerboseOutput' }
    & pwsh @genArgs
    if ($LASTEXITCODE -ne 0) {
        Write-HookLine "Generator failed (exit $LASTEXITCODE)." 'Red'
        exit $LASTEXITCODE
    }

    Write-HookLine 'Running LLM harness linter...'
    $lintArgs = @('-NoProfile', '-File', $Linter)
    if ($VerboseOutput) { $lintArgs += '-VerboseOutput' }
    & pwsh @lintArgs
    if ($LASTEXITCODE -ne 0) {
        Write-HookLine "Linter failed (exit $LASTEXITCODE)." 'Red'
        exit $LASTEXITCODE
    }

    Write-HookLine 'Running LLM harness self-tests...'
    $testArgs = @('-NoProfile', '-File', $SelfTests)
    if ($VerboseOutput) { $testArgs += '-VerboseOutput' }
    & pwsh @testArgs
    if ($LASTEXITCODE -ne 0) {
        Write-HookLine "Self-tests failed (exit $LASTEXITCODE)." 'Red'
        exit $LASTEXITCODE
    }

    if ($SkipStagedCheck) {
        Write-HookLine 'Skipping staged-files check (SkipStagedCheck).'
        Write-HookLine 'LLM harness OK.' 'Green'
        exit 0
    }

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-HookLine 'git not found; cannot verify staged generated files.' 'Red'
        exit 1
    }

    # `git status --porcelain` reports BOTH staged and unstaged changes and
    # also lists untracked files (`??`). This catches the case the previous
    # `git diff` approach missed: a freshly generated file that has never
    # been added. We pass the path filter as a plain array so PowerShell
    # auto-unrolls it for the native git command (equivalent to splatting,
    # but more conventional and less surprising to readers).
    $statusOutput = @(& git status --porcelain -- $GeneratedFiles)
    if ($LASTEXITCODE -ne 0) {
        Write-HookLine "git status failed (exit $LASTEXITCODE)." 'Red'
        exit $LASTEXITCODE
    }

    $dirty = New-Object System.Collections.Generic.List[string]
    foreach ($line in $statusOutput) {
        $statusEntry = ConvertFrom-GeneratedFileStatusLine -Line $line
        if (-not $statusEntry.NeedsStaging) { continue }
        if ($statusEntry.Index -eq '?' -and $statusEntry.Worktree -eq '?') {
            $dirty.Add("untracked: $($statusEntry.Path)")
        } else {
            $dirty.Add("unstaged: $($statusEntry.Path)")
        }
    }

    if ($dirty.Count -gt 0) {
        if ($autoFixEnabled) {
            Write-HookLine 'AutoFix: staging regenerated LLM files.' 'Yellow'
            foreach ($entry in $dirty) {
                Write-HookLine " - $entry" 'Yellow'
            }
            & git add -- @GeneratedFiles
            if ($LASTEXITCODE -ne 0) {
                Write-HookLine "AutoFix: git add failed (exit $LASTEXITCODE)." 'Red'
                exit $LASTEXITCODE
            }
            # Re-check after staging to confirm nothing remains.
            $recheckStatusOutput = @(& git status --porcelain -- $GeneratedFiles)
            if ($LASTEXITCODE -ne 0) {
                Write-HookLine "AutoFix: git status failed after staging (exit $LASTEXITCODE)." 'Red'
                exit $LASTEXITCODE
            }
            $recheck = @($recheckStatusOutput |
                ForEach-Object { ConvertFrom-GeneratedFileStatusLine -Line $_ } |
                Where-Object { $_.NeedsStaging })
            if ($recheck.Count -gt 0) {
                Write-HookLine 'AutoFix: generated files still dirty after staging:' 'Red'
                foreach ($entry in $recheck) { Write-HookLine " - $($entry.Raw)" 'Red' }
                exit 1
            }
        } else {
            Write-HookLine 'Generated LLM files are out of sync with the index.' 'Red'
            foreach ($entry in $dirty) {
                Write-HookLine " - $entry" 'Red'
            }
            Write-HookLine 'Stage them with: git add .llm/index.md .llm/context.md' 'Yellow'
            Write-HookLine 'Or re-run with -AutoFix to stage them automatically.' 'Yellow'
            exit 1
        }
    }

    Write-HookLine 'LLM harness OK.' 'Green'
    exit 0
} finally {
    Pop-Location
}
