[CmdletBinding()]
param(
    # Skip the staged-files dirty check. Useful in CI where there is no index.
    [switch]$SkipStagedCheck,
    [switch]$VerboseOutput
)

# Single source of truth for the pre-commit / CI LLM harness flow.
#
# Responsibilities:
#   1. Regenerate `.llm/index.md` and the generated section of
#      `.llm/context.md`.
#   2. Run the linter.
#   3. Detect any change to generated files that is not staged for commit,
#      including untracked files (which `git diff` ignores).
#
# Exits non-zero if any step fails or the generated files are not staged.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptsDir = $PSScriptRoot
$RepoRoot = Split-Path -Parent $ScriptsDir
$Generator = Join-Path $ScriptsDir 'generate-llm-index.ps1'
$Linter = Join-Path $ScriptsDir 'lint-llm.ps1'
$GeneratedFiles = @('.llm/index.md', '.llm/context.md')

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

Push-Location $RepoRoot
try {
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
        Write-HookLine 'Generated LLM files are out of sync with the index.' 'Red'
        foreach ($entry in $dirty) {
            Write-HookLine " - $entry" 'Red'
        }
        Write-HookLine 'Stage them with: git add .llm/index.md .llm/context.md' 'Yellow'
        exit 1
    }

    Write-HookLine 'LLM harness OK.' 'Green'
    exit 0
} finally {
    Pop-Location
}
