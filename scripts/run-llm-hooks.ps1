[CmdletBinding()]
param(
    # Skip the staged-files dirty check. Useful in CI where there is no index.
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
$Generator = Join-Path $ScriptsDir 'generate-llm-index.ps1'
$Linter = Join-Path $ScriptsDir 'lint-llm.ps1'
$SelfTests = Join-Path $ScriptsDir 'test-llm-harness.ps1'
$GeneratedFiles = @('.llm/index.md', '.llm/context.md')
$StagingArtifactPatterns = @('*.new', '*.bak', '*.orig', '*.old', '*.rej')

# -NoAutoFix wins over -AutoFix so CI / scripted callers can force loud
# failure regardless of any wrapper that flipped -AutoFix on.
$autoFixEnabled = [bool]$AutoFix -and -not $NoAutoFix

function Write-HookLine {
    param([string]$Message, [string]$Color = 'Gray')
    Write-Host "[llm-hook] $Message" -ForegroundColor $Color
}

if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
    Write-HookLine 'pwsh is required but was not found on PATH.' 'Red'
    exit 1
}
if (-not (Test-Path -LiteralPath $Generator -PathType Leaf)) {
    Write-HookLine "Missing generator script: $Generator" 'Red'
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

Push-Location $RepoRoot
try {
    if ($autoFixEnabled -and (Get-Command git -ErrorAction SilentlyContinue)) {
        # Delete stray staging artifacts BEFORE the linter sees them so the
        # commit can proceed without manual cleanup. We only touch files that
        # match the well-known artifact patterns, never anything else.
        $strayTracked = @(& git ls-files -- @StagingArtifactPatterns) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        $strayUntracked = @(& git ls-files --others --exclude-standard -- @StagingArtifactPatterns) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        $autoFixFailed = $false
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
        foreach ($stray in (@($strayTracked + $strayUntracked) | Sort-Object -Unique)) {
            $full = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $stray))
            # Defensive: never let a path that escapes the repo root reach
            # Remove-Item. `git ls-files` already returns repo-relative paths,
            # but belt-and-suspenders is cheap here.
            if (-not ($full.StartsWith($repoRootPrefix, $pathComparison) -or
                    $full.Equals($repoRootFull, $pathComparison))) {
                Write-HookLine "AutoFix: refusing to touch suspicious path outside repo: $stray" 'Red'
                $autoFixFailed = $true
                continue
            }
            if (-not (Test-Path -LiteralPath $full)) { continue }
            $removed = $false
            try {
                Remove-Item -LiteralPath $full -Force -ErrorAction Stop
                $removed = $true
                Write-HookLine "AutoFix: removed stray staging artifact: $stray" 'Yellow'
            } catch {
                Write-HookLine "AutoFix: failed to remove $stray`: $($_.Exception.Message)" 'Red'
            }
            if ($strayTracked -contains $stray) {
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
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        # Porcelain format: "XY path" where X = index status, Y = worktree.
        # Anything where Y is not ' ' (worktree change) OR the entry is '??'
        # (untracked) means the file is not fully staged.
        $index = if ($line.Length -ge 1) { $line[0] } else { ' ' }
        $worktree = if ($line.Length -ge 2) { $line[1] } else { ' ' }
        $path = if ($line.Length -ge 4) { $line.Substring(3) } else { $line }
        if ($index -eq '?' -and $worktree -eq '?') {
            $dirty.Add("untracked: $path")
        } elseif ($worktree -ne ' ') {
            $dirty.Add("unstaged: $path")
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
            $recheck = @(@(& git status --porcelain -- $GeneratedFiles) |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and ($_[1] -ne ' ' -or ($_[0] -eq '?' -and $_[1] -eq '?')) })
            if ($recheck.Count -gt 0) {
                Write-HookLine 'AutoFix: generated files still dirty after staging:' 'Red'
                foreach ($entry in $recheck) { Write-HookLine " - $entry" 'Red' }
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
