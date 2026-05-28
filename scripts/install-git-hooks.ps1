[CmdletBinding()]
param(
    # Replace foreign / unrecognised hooks and clear unexpected core.hooksPath.
    [switch]$Force
)

# Installs the LLM harness pre-commit hook into this checkout.
#
# Cross-platform design notes:
#   * Git invokes hooks via the bundled POSIX shell on every supported OS,
#     including Windows (Git for Windows ships sh.exe). PowerShell's `-File`
#     parameter REFUSES files without a `.ps1` extension, so a
#     `#!/usr/bin/env pwsh` shebang on the extensionless hook breaks on
#     Windows. The materialised hook is therefore a POSIX shell shim that
#     itself invokes `pwsh -File scripts/run-llm-hooks.ps1`. See
#     `.githooks/pre-commit` for the reference template; this script writes
#     an equivalent shim with an idempotency marker so re-installs are
#     safe.
#   * We materialise into `.git/hooks/pre-commit` (resolved via
#     `git rev-parse --git-path hooks`, which is worktree- and
#     submodule-aware) rather than relying on `core.hooksPath = .githooks`.
#   * Any prior `core.hooksPath` pointing at the legacy `.githooks/`
#     directory is cleared automatically; other values warn unless -Force.
#   * Hooks owned by other tooling (no marker line) are NEVER clobbered
#     without -Force.
#
# DO NOT REINTRODUCE legacy patterns from prior versions of this script:
#   * Setting `core.hooksPath` to point at the in-repo `.githooks/`
#     directory (replaced by per-checkout install into `.git/hooks/`).
#   * A second `Push-Location` / `try` block (the script must have
#     EXACTLY ONE such block).
#   * A separate "shim target" variable distinct from `$installedHook`.
# Self-tests in `scripts/test-llm-harness.ps1` assert these invariants so
# accidental re-merges of stale buffers fail loudly before commit.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$EntryScript = 'scripts/run-llm-hooks.ps1'
$Marker = '# llm-harness-installed-hook v1'

function Write-Install {
    param([string]$Message, [string]$Color = 'Gray')
    Write-Host "[llm-hooks] $Message" -ForegroundColor $Color
}

if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot $EntryScript) -PathType Leaf)) {
    throw "Missing entry script: $EntryScript"
}

Push-Location $RepoRoot
try {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'git is required to install the pre-commit hook.'
    }

    $hooksDirRaw = @(& git rev-parse --git-path hooks 2>$null) | Select-Object -First 1
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($hooksDirRaw)) {
        throw "git rev-parse --git-path hooks failed (exit $LASTEXITCODE); is this a git repository?"
    }
    if ([System.IO.Path]::IsPathRooted($hooksDirRaw)) {
        $hooksDir = [System.IO.Path]::GetFullPath($hooksDirRaw)
    } else {
        $hooksDir = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $hooksDirRaw))
    }
    if (-not (Test-Path -LiteralPath $hooksDir)) {
        New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null
    }

    $installedHook = Join-Path $hooksDir 'pre-commit'

    $hookBody = @"
#!/usr/bin/env sh
$Marker
# Auto-installed by scripts/install-git-hooks.ps1. Do not edit by hand;
# re-run the installer to regenerate. All real logic lives in
# $EntryScript.
set -eu

if ! command -v pwsh >/dev/null 2>&1; then
  echo "[llm-hook] ERROR: pwsh (PowerShell 7+) is required to run the LLM harness hooks." >&2
  echo "[llm-hook] Install from https://aka.ms/powershell and re-run the commit." >&2
  exit 1
fi

REPO_ROOT="`$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "`$REPO_ROOT" ]; then
  echo "[llm-hook] ERROR: git rev-parse --show-toplevel failed; cannot locate repo root." >&2
  exit 1
fi

exec pwsh -NoProfile -File "`$REPO_ROOT/$EntryScript" -AutoFix
"@

    if (Test-Path -LiteralPath $installedHook -PathType Leaf) {
        $existing = Get-Content -LiteralPath $installedHook -Raw -ErrorAction SilentlyContinue
        if ($null -ne $existing -and $existing -notmatch [regex]::Escape($Marker) -and -not $Force) {
            throw "Refusing to overwrite foreign pre-commit hook at $installedHook. Re-run with -Force to replace it."
        }
    }

    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($hookBody.Replace("`r`n", "`n"))
    [System.IO.File]::WriteAllBytes($installedHook, $bytes)

    $chmod = Get-Command chmod -ErrorAction SilentlyContinue
    if ($null -ne $chmod) {
        $chmodOutput = & chmod +x -- $installedHook 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Install "WARNING: chmod +x failed for $installedHook ($chmodOutput). Hook may not be executable." 'Yellow'
        }
    }

    $existingHooksPath = (@(& git config --get core.hooksPath 2>$null) | Select-Object -First 1)
    if (-not [string]::IsNullOrWhiteSpace($existingHooksPath)) {
        if ($existingHooksPath -eq '.githooks' -or $Force) {
            & git config --unset core.hooksPath 2>$null | Out-Null
            Write-Install "Cleared previous core.hooksPath '$existingHooksPath'."
        } else {
            Write-Install "WARNING: core.hooksPath is set to '$existingHooksPath'; the installed .git/hooks/pre-commit will be ignored. Re-run with -Force to clear it." 'Yellow'
        }
    }

    Write-Install "Installed pre-commit hook at $installedHook" 'Green'
} finally {
    Pop-Location
}
