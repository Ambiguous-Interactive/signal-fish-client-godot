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

# Filesystem case sensitivity is platform-dependent. Linux is case-sensitive;
# Windows and macOS default to case-insensitive. Pick the StringComparison
# that matches the OS so a legacy hook path like '.GitHooks' is normalized
# the way the underlying filesystem would interpret it.
function Get-InstallPathComparison {
    if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
            [System.Runtime.InteropServices.OSPlatform]::Linux)) {
        return [System.StringComparison]::Ordinal
    }
    return [System.StringComparison]::OrdinalIgnoreCase
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
    # shim's parse-check + `git checkout HEAD` is the only thing that
    # can recover from that. The check uses pwsh's parser API (not a
    # naive `pwsh -NoProfile -Command "exit 0"`) so it does not actually
    # execute the script.
    #
    # The escaped `\` before `$null` / `$errors` and the doubled `` `` `
    # in front of variable references inside the here-string keep PowerShell
    # from interpolating them at install time; they must reach the emitted
    # shim verbatim.
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

# Parse-check the harness entry script BEFORE invoking it. If it has
# a parse error pwsh -File refuses to start it and the downstream self-
# heal (preflight -> everything) never runs. Restore from HEAD if
# corrupt. Portable to Git for Windows' bundled sh.exe.
#
# We materialise the parse-check into a temp .ps1 file and run
# `pwsh -NoProfile -File <file>` to avoid the terminal-init ANSI bytes
# `pwsh -Command -` writes to stdout on some hosts (those bytes
# pollute command substitution). The temp file is cleaned up after.
#
# Cross-platform mktemp note (NIT-4): `mktemp -t <template>` has subtly
# different semantics across implementations (BSD vs GNU vs Git for
# Windows' MSYS bundle). GNU mktemp interprets the argument as a template,
# Git-for-Windows' MSYS mktemp historically used `-t` to mean "use TMPDIR
# as a prefix", and BSD differs again. The fallback path
# `/tmp/llm-parse-check-\$\$.ps1` is the cross-platform safe one: every
# supported shell creates /tmp at boot and `\$\$` is the current PID so
# concurrent hook runs cannot collide on the same file. The `||` keeps
# the fallback purely a backstop — the mktemp branch is preferred when
# it works because mktemp's atomicity defeats TOCTOU races that `/tmp/PID`
# is theoretically vulnerable to. Either path produces a usable temp file.
LLM_HARNESS_TARGET="`$REPO_ROOT/$EntryScript"
export LLM_HARNESS_TARGET
PARSE_CHECK_SCRIPT="`$(mktemp -t llm-parse-check-XXXXXX.ps1 2>/dev/null || echo "/tmp/llm-parse-check-`$`$.ps1")"
cat >"`$PARSE_CHECK_SCRIPT" <<'SHIM_PARSE_CHECK'
Set-StrictMode -Version Latest
`$ParseErrors = `$null
try {
    [void][System.Management.Automation.Language.Parser]::ParseFile(`$env:LLM_HARNESS_TARGET, [ref]`$null, [ref]`$ParseErrors)
} catch {
    Write-Output 'BAD'
    exit 0
}
if (`$ParseErrors -and `$ParseErrors.Count -gt 0) { Write-Output 'BAD' } else { Write-Output 'OK' }
SHIM_PARSE_CHECK
PARSE_RESULT="`$(pwsh -NoProfile -File "`$PARSE_CHECK_SCRIPT" 2>/dev/null | tr -d '\r' | tail -n 1)"
rm -f "`$PARSE_CHECK_SCRIPT" 2>/dev/null || true
if [ "`$PARSE_RESULT" != "OK" ]; then
    echo "[llm-hook] WARNING: $EntryScript has parse errors; restoring from HEAD..." >&2
    (cd "`$REPO_ROOT" && git checkout HEAD -- "$EntryScript") || {
        echo "[llm-hook] ERROR: failed to restore $EntryScript from HEAD." >&2
        exit 1
    }
fi

exec pwsh -NoProfile -File "`$REPO_ROOT/$EntryScript" -AutoFix
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
            Write-Install "WARNING: core.hooksPath is set to '$existingHooksPath'; the installed .git/hooks/pre-commit will be ignored. Re-run with -Force to clear it." 'Yellow'
        }
    }

    Write-Install "Installed pre-commit hook at $installedHook" 'Green'
} finally {
    Pop-Location
}
