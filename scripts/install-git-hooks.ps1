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
#     `.githooks/pre-commit` for the committed reference shim; this script
#     writes the same bootstrap behavior with an idempotency marker so
#     re-installs are safe.
#   * We materialise into the path from `git rev-parse --git-path hooks`
#     (usually `.git/hooks/pre-commit`, but worktree- and submodule-aware)
#     rather than relying on `core.hooksPath = .githooks`.
#   * Any prior `core.hooksPath` pointing at the legacy `.githooks/`
#     directory is cleared automatically; other values warn unless -Force.
#   * Hooks owned by other tooling (no marker line) are NEVER clobbered
#     without -Force.
#
# DO NOT REINTRODUCE legacy patterns from prior versions of this script:
#   * Setting `core.hooksPath` to point at the in-repo `.githooks/`
#     directory (replaced by per-checkout install into the resolved git hooks
#     path).
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

# Filesystem case sensitivity is volume-dependent on Unix-like systems. Keep
# hook path normalization case-insensitive only on Windows, where path casing is
# case-preserving but not case-sensitive for normal local paths.
function Get-InstallPathComparison {
    if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
            [System.Runtime.InteropServices.OSPlatform]::Windows)) {
        return [System.StringComparison]::OrdinalIgnoreCase
    }
    return [System.StringComparison]::Ordinal
}

# Normalize a user-supplied core.hooksPath value to a fully resolved
# absolute path. Returns an empty string for whitespace input. Relative
# paths are resolved against the repo root, trailing separators are
# stripped, and forward / backslash variants are unified by GetFullPath.
function ConvertTo-NormalizedHooksPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }
    if ([System.IO.Path]::IsPathRooted($Path)) {
        $full = [System.IO.Path]::GetFullPath($Path)
    } else {
        $full = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $Path))
    }
    return $full.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
}

# Returns $true iff a configured core.hooksPath value resolves to the
# in-repo `.githooks/` directory once trailing separators and relative
# path variants are normalized. The legacy installer set
# core.hooksPath=.githooks; we clear that automatically. Foreign paths
# return $false so they require -Force to clobber.
function Test-LegacyHooksPath {
    param([string]$ConfiguredPath)
    if ([string]::IsNullOrWhiteSpace($ConfiguredPath)) {
        return $false
    }
    $configuredFull = ConvertTo-NormalizedHooksPath $ConfiguredPath
    $legacyFull = ConvertTo-NormalizedHooksPath '.githooks'
    if ([string]::IsNullOrWhiteSpace($configuredFull) -or [string]::IsNullOrWhiteSpace($legacyFull)) {
        return $false
    }
    return [string]::Equals($configuredFull, $legacyFull, (Get-InstallPathComparison))
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

    # The hook body is a POSIX-sh shim. It is the FIRST layer of the
    # n-level self-heal chain documented in `.llm/skills/agent-harness.md`:
    #
    #   shim (sh)  ->  parse-checks scripts/run-llm-hooks.ps1
    #   run-llm-hooks.ps1  ->  parse-checks scripts/preflight.ps1
    #   preflight.ps1  ->  parse-checks all other tracked .ps1/.psm1/.psd1
    #
    # If `run-llm-hooks.ps1` itself has a parse error, pwsh `-File`
    # refuses to start it and EVERY downstream self-heal never runs. The
    # shim's parse-check plus index-first / HEAD-fallback recovery is the
    # only thing that can recover from that. The check uses pwsh's parser
    # API (not a naive `pwsh -NoProfile -Command "exit 0"`) so it does not
    # actually execute the script.
    #
    # The doubled `` `` ` in front of variable references inside the
    # here-string keeps PowerShell from interpolating them at install time;
    # they must reach the emitted shim verbatim. The shim starts exactly one
    # pwsh process: a generated bootstrap script parse-checks / recovers the
    # runner, then invokes it in the same PowerShell process.
    $hookBody = @"
#!/usr/bin/env sh
$Marker
# Auto-installed by scripts/install-git-hooks.ps1. Do not edit by hand;
# re-run the installer to regenerate. All real logic lives in
# $EntryScript.
set -eu

# Defensive env-var hygiene: a parent shell that left
# LLM_HARNESS_PREFLIGHT_DONE or LLM_HARNESS_SKIP_BEHAVIORAL_TESTS set
# would cause the harness to skip its preflight or behavioral checks
# inside the commit, defeating the n-level recovery chain. Unset both
# before any pwsh invocation so commit-time behavior matches a clean
# session every time.
unset LLM_HARNESS_PREFLIGHT_DONE 2>/dev/null || true
unset LLM_HARNESS_SKIP_BEHAVIORAL_TESTS 2>/dev/null || true

if ! command -v pwsh >/dev/null 2>&1; then
  echo "[llm-hook] ERROR: pwsh (PowerShell 7+) is required to run the LLM harness hooks." >&2
  if command -v powershell.exe >/dev/null 2>&1; then
    echo "[llm-hook] Detected legacy powershell.exe (Windows PowerShell 5.x). It is NOT supported." >&2
  fi
  echo "[llm-hook] Install PowerShell 7+ from https://aka.ms/powershell and re-run the commit." >&2
  exit 1
fi

REPO_ROOT="`$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "`$REPO_ROOT" ]; then
  echo "[llm-hook] ERROR: git rev-parse --show-toplevel failed; cannot locate repo root." >&2
  exit 1
fi

if ! command -v mktemp >/dev/null 2>&1; then
  echo "[llm-hook] ERROR: mktemp is required to create a secure temporary bootstrap script." >&2
  exit 1
fi

# Create a private temp directory, then put a fixed .ps1 file inside it.
# This keeps pwsh -File happy on macOS/BSD mktemp and avoids predictable
# fallback filenames or symlinkable /tmp paths.
BOOTSTRAP_ROOT="`${TMPDIR:-/tmp}"
BOOTSTRAP_ROOT="`${BOOTSTRAP_ROOT%/}"
if [ -z "`$BOOTSTRAP_ROOT" ]; then
  BOOTSTRAP_ROOT="/"
fi
if ! BOOTSTRAP_DIR="`$(mktemp -d "`$BOOTSTRAP_ROOT/llm-hook-bootstrap.XXXXXX" 2>/dev/null)"; then
  echo "[llm-hook] ERROR: mktemp failed; cannot create a secure temporary bootstrap directory." >&2
  exit 1
fi
cleanup_bootstrap() {
  rm -rf "`$BOOTSTRAP_DIR" 2>/dev/null || true
}
trap cleanup_bootstrap EXIT
BOOTSTRAP_SCRIPT="`$BOOTSTRAP_DIR/bootstrap.ps1"
cat >"`$BOOTSTRAP_SCRIPT" <<'SHIM_BOOTSTRAP'
Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'
`$repoRoot = `$env:LLM_HARNESS_REPO_ROOT
`$entryScript = `$env:LLM_HARNESS_ENTRY_SCRIPT
`$target = Join-Path `$repoRoot `$entryScript
function Resolve-HookGitPath {
    param([Parameter(Mandatory)][string]`$GitPath)

    if (Get-Command git -ErrorAction SilentlyContinue) {
        Push-Location `$repoRoot
        try {
            `$raw = @(& git rev-parse --git-path `$GitPath 2>`$null) | Select-Object -First 1
            if (`$LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(`$raw)) {
                if ([System.IO.Path]::IsPathRooted(`$raw)) {
                    return [System.IO.Path]::GetFullPath(`$raw)
                }
                return [System.IO.Path]::GetFullPath((Join-Path `$repoRoot `$raw))
            }
        } finally {
            Pop-Location
        }
    }

    return [System.IO.Path]::GetFullPath((Join-Path (Join-Path `$repoRoot '.git') `$GitPath))
}
function Copy-GitBlobToFile {
    param(
        [Parameter(Mandatory)][string]`$Blob,
        [Parameter(Mandatory)][string]`$Destination
    )

    `$psi = [System.Diagnostics.ProcessStartInfo]::new()
    `$psi.FileName = 'git'
    [void]`$psi.ArgumentList.Add('cat-file')
    [void]`$psi.ArgumentList.Add('blob')
    [void]`$psi.ArgumentList.Add(`$Blob)
    `$psi.RedirectStandardOutput = `$true
    `$psi.RedirectStandardError = `$true
    `$psi.UseShellExecute = `$false

    Push-Location `$repoRoot
    try {
        `$proc = [System.Diagnostics.Process]::Start(`$psi)
        `$stream = [System.IO.File]::Open(`$Destination, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            `$proc.StandardOutput.BaseStream.CopyTo(`$stream)
        } finally {
            `$stream.Dispose()
        }
        `$stderr = `$proc.StandardError.ReadToEnd()
        `$proc.WaitForExit()
        if (`$proc.ExitCode -ne 0) {
            Remove-Item -LiteralPath `$Destination -Force -ErrorAction SilentlyContinue
            throw "git cat-file blob `$Blob failed with exit `$(`$proc.ExitCode): `$stderr"
        }
    } finally {
        Pop-Location
    }
}
`$tokens = `$null
`$parseErrors = `$null
try {
    [void][System.Management.Automation.Language.Parser]::ParseFile(`$target, [ref]`$tokens, [ref]`$parseErrors)
} catch {
    `$parseErrors = @(`$_)
}
function Test-TargetParsesClean {
    `$targetTokens = `$null
    `$targetErrors = `$null
    try {
        [void][System.Management.Automation.Language.Parser]::ParseFile(`$target, [ref]`$targetTokens, [ref]`$targetErrors)
    } catch {
        return `$false
    }
    return (-not `$targetErrors -or `$targetErrors.Count -eq 0)
}
if (`$parseErrors -and `$parseErrors.Count -gt 0) {
    Write-Host "[llm-hook] WARNING: `$entryScript has parse errors; restoring from index or HEAD..." -ForegroundColor Yellow
    `$stamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    `$recoveryParent = Resolve-HookGitPath -GitPath 'preflight-recovery'
    `$backupDir = Join-Path `$recoveryParent "`$stamp-`$PID-`$([Guid]::NewGuid().ToString('N'))"
    try {
        if (-not (Test-Path -LiteralPath `$recoveryParent -PathType Container)) {
            New-Item -ItemType Directory -Path `$recoveryParent -Force -ErrorAction Stop | Out-Null
        }
        New-Item -ItemType Directory -Path `$backupDir -ErrorAction Stop | Out-Null
        `$backupPath = Join-Path `$backupDir (`$entryScript -replace '[\\/]', '__')
        [System.IO.File]::Copy(`$target, `$backupPath, `$true)
    } catch {
        Write-Host "[llm-hook] ERROR: failed to back up `$entryScript before restore: `$(`$_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
    `$indexBackupPath = "`$backupPath.index"
    `$indexMode = `$null
    Push-Location `$repoRoot
    try {
        `$stageLine = @(& git ls-files --stage -- `$entryScript 2>&1) | Select-Object -First 1
        if (`$LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(`$stageLine) -or
            `$stageLine -notmatch '^(?<Mode>\d+)\s+(?<Sha>[0-9a-f]{40,64})\s+\d+\s+') {
            Write-Host "[llm-hook] ERROR: failed to read index entry for `$entryScript; refusing to overwrite staged WIP." -ForegroundColor Red
            exit 1
        }
        `$indexMode = `$Matches['Mode']
        Copy-GitBlobToFile -Blob `$Matches['Sha'] -Destination `$indexBackupPath
    } finally {
        Pop-Location
    }
    `$restoredFrom = `$null
    Push-Location `$repoRoot
    try {
        & git checkout -- `$entryScript
        if (`$LASTEXITCODE -eq 0) {
            if (Test-TargetParsesClean) {
                `$restoredFrom = 'index'
            } else {
                Write-Host "[llm-hook] WARNING: index copy of `$entryScript still has parse errors; falling back to HEAD." -ForegroundColor Yellow
            }
        } else {
            Write-Host "[llm-hook] WARNING: failed to restore `$entryScript from index; falling back to HEAD." -ForegroundColor Yellow
        }
        if (`$null -eq `$restoredFrom) {
            & git checkout HEAD -- `$entryScript
            if (`$LASTEXITCODE -ne 0) {
                Write-Host "[llm-hook] ERROR: failed to restore `$entryScript from HEAD." -ForegroundColor Red
                exit 1
            }
            if (Test-TargetParsesClean) {
                `$restoredFrom = 'HEAD'
            }
        }
    } finally {
        Pop-Location
    }
    if (`$null -eq `$restoredFrom) {
        Write-Host "[llm-hook] ERROR: `$entryScript still has parse errors after restore; restoring backed-up WIP." -ForegroundColor Red
        try {
            Copy-Item -LiteralPath `$backupPath -Destination `$target -Force
            Push-Location `$repoRoot
            try {
                `$indexBlob = (@(& git hash-object -w -- `$indexBackupPath 2>&1) | Select-Object -First 1)
                if (`$LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(`$indexBlob)) {
                    `$indexBlob = "`$indexBlob".Trim()
                    & git update-index --add --cacheinfo `$indexMode `$indexBlob `$entryScript 2>&1 | Out-Null
                }
            } finally {
                Pop-Location
            }
        } catch {
            Write-Host "[llm-hook] ERROR: failed to restore `$entryScript from `${backupPath}: `$(`$_.Exception.Message)" -ForegroundColor Red
        }
        exit 1
    }
    Write-Host "[llm-hook] Recovered `$entryScript from `$restoredFrom; backed up corrupt WIP to `$backupPath and index WIP to `$indexBackupPath" -ForegroundColor Yellow
}

& `$target -Mode PreCommit -AutoFix
exit `$LASTEXITCODE
SHIM_BOOTSTRAP

LLM_HARNESS_REPO_ROOT="`$REPO_ROOT"
LLM_HARNESS_ENTRY_SCRIPT="$EntryScript"
export LLM_HARNESS_REPO_ROOT LLM_HARNESS_ENTRY_SCRIPT
set +e
pwsh -NoProfile -File "`$BOOTSTRAP_SCRIPT"
HOOK_STATUS="`$?"
set -e
unset LLM_HARNESS_REPO_ROOT LLM_HARNESS_ENTRY_SCRIPT
exit "`$HOOK_STATUS"
"@

    if (Test-Path -LiteralPath $installedHook -PathType Leaf) {
        $existing = Get-Content -LiteralPath $installedHook -Raw -ErrorAction SilentlyContinue
        # Plain `Contains` is simpler than `-notmatch [regex]::Escape($Marker)`
        # and immune to accidental regex meta-characters in $Marker (NIT-6).
        if ($null -ne $existing -and -not $existing.Contains($Marker) -and -not $Force) {
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
        $isLegacy = Test-LegacyHooksPath $existingHooksPath
        if ($isLegacy -or $Force) {
            & git config --unset core.hooksPath 2>$null | Out-Null
            Write-Install "Cleared previous core.hooksPath '$existingHooksPath'."
        } else {
            Write-Install "WARNING: core.hooksPath is set to '$existingHooksPath'; the installed git hooks-path pre-commit shim will be ignored. Re-run with -Force to clear it." 'Yellow'
        }
    }

    Write-Install "Installed pre-commit hook at $installedHook" 'Green'
} finally {
    Pop-Location
}
