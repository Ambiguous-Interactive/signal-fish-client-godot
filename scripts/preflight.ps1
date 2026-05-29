[CmdletBinding()]
param(
    # Attempt to auto-recover corrupted PowerShell sources by checking out the
    # index/staged copy first, then the tracked HEAD copy. Default OFF for
    # direct invocation (loud failure).
    [switch]$AutoFix,
    # -NoAutoFix wins over -AutoFix so CI / scripted callers can force loud
    # failure even when a wrapper enabled -AutoFix.
    [switch]$NoAutoFix,
    # Parse-check ONLY this script first, then exit. Used by the bootstrap
    # path so the preflight cannot mask its own corruption.
    [switch]$SelfCheck,
    [switch]$VerboseOutput
)

# Self-healing preflight for the LLM harness toolkit.
#
# Usage:
#   pwsh -NoProfile -File scripts/preflight.ps1
#     Default. Parse-check every tracked .ps1/.psm1/.psd1 plus .claude/hooks/*.ps1.
#     Exit 0 if all clean, 1 if any are corrupt.
#   pwsh -NoProfile -File scripts/preflight.ps1 -AutoFix
#     On corruption: back up the corrupt file under the directory resolved by
#     `git rev-parse --git-path preflight-recovery`
#     (<recovery-parent>/<timestamp>-<pid>-<rand>/<encoded-path>), then `git
#     checkout -- <path>` to restore from the index/staged copy first. If the
#     index copy is unavailable or still corrupt, it falls back to `git checkout
#     HEAD -- <path>`. Re-parses; if HEAD is also corrupt the working-tree
#     backup is restored and exit is 1. Exit 2 on successful recovery (caller
#     may continue but should warn).
#   pwsh -NoProfile -File scripts/preflight.ps1 -NoAutoFix
#     Force loud-failure mode regardless of a wrapper setting -AutoFix.
#     -NoAutoFix wins over -AutoFix.
#   pwsh -NoProfile -File scripts/preflight.ps1 -SelfCheck
#     Parse-check ONLY this script; used by the bootstrap path so the
#     preflight cannot mask its own corruption.
#   pwsh -NoProfile -File scripts/preflight.ps1 -VerboseOutput
#     Emit per-file `parse OK` lines and trace messages.
#
# Why this script exists (bootstrap reasoning):
#
# The linter (`lint-llm.ps1`) and the test harness (`test-llm-harness.ps1`)
# each parse the toolkit's PowerShell sources to catch structural
# regressions. But if one of those tools itself becomes corrupted (e.g. a
# stale editor buffer re-merges old code on top of new code), pwsh refuses
# to even start the script, and the corrupted-tool-checking-itself loop
# never runs. This preflight is the single-file bootstrap that closes that
# blind spot:
#
#   1. The TOP-LEVEL invocation (no -SelfCheck) first spawns a child
#      `pwsh -NoProfile -File <self> -SelfCheck -NoAutoFix`. The child
#      process has FRESH pwsh parsing, so if THIS script is corrupted
#      the user sees a structured `[preflight] Self-parse failed for ...`
#      rather than an opaque pwsh parse error. NOTE: this is belt-and-
#      suspenders only. If preflight.ps1 itself has a parse error pwsh
#      refuses to start it and we never get here; the PRIMARY defense
#      lives upstream in `run-llm-hooks.ps1` (and in the installed git hook
#      shim), each of which parse-checks its callee before invoking.
#   2. -SelfCheck runs ONLY the per-file parse check on $PSCommandPath and
#      exits; it does NOT recurse into a third invocation.
#   3. After the child self-check passes, the top-level parent parse-checks
#      every tracked PowerShell source plus `.claude/hooks/*.ps1` via the
#      .NET Parser API (no script execution required).
#   4. In -AutoFix mode, if a file is corrupt, it BACKS UP the corrupt content
#      to the directory returned by
#      `git rev-parse --git-path preflight-recovery`
#      (`<recovery-parent>/<ts>-<pid>-<rand>/<encoded-path>`)
#      (the encoded path replaces `/` and `\` with `__` so two files with
#      the same basename do not overwrite each other), then tries the
#      index/staged copy first and HEAD second. This recovers from the common
#      failure mode where the staged version is clean but a stale editor buffer
#      corrupted the working tree.
#   5. If the HEAD copy ALSO fails to parse, AutoFix RESTORES the working-tree
#      backup back to the file (so we never leave a "broken from HEAD" file
#      masquerading as success) and exits 1 with the recovery-backup path so
#      the user can fix it manually.
#
# Backup directory layout:
#   <git-path:preflight-recovery>/<unixMs>-<pid>-<guid>/
#     <encoded-path>     (e.g. scripts__lib__LlmHarness.psm1)
#     <encoded-path>.index     (staged/index copy, when present)
# Use `git rev-parse --git-path preflight-recovery` to print the parent
# directory for the current clone, worktree, or submodule.
# Backups are pruned at preflight startup to the most-recent 20 dirs so a
# debugging loop does not accrue hundreds.
#
# Exit codes:
#   0 - all parse-clean
#   1 - unrecoverable corruption (HEAD copy also broken, or autofix off)
#   2 - corruption was auto-recovered; caller may continue but should warn

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptPath = $PSCommandPath

function Get-PreflightRepoRoot {
    <#
    .SYNOPSIS
    Resolve the repository root for preflight. Prefers `git rev-parse
    --show-toplevel` for worktree / submodule correctness; falls back to
    `Split-Path -Parent $ScriptDir` if git is unavailable.

    .DESCRIPTION
    LAYOUT ASSUMPTION: the fallback branch assumes the on-disk layout
    `<repoRoot>/scripts/preflight.ps1`. If this script is ever moved to
    a deeper or sibling directory (for example, `tools/llm/preflight.ps1`),
    the fallback will return the WRONG directory. Adjust the
    `Split-Path -Parent` chain or add a layout-specific marker check.
    A self-test in `test-llm-harness.ps1` exercises this branch with a
    synthetic `$ScriptDir` to catch silent regressions. (MIN-7)
    #>
    param([string]$ScriptDir)
    if (Get-Command git -ErrorAction SilentlyContinue) {
        Push-Location $ScriptDir
        try {
            $top = & git rev-parse --show-toplevel 2>$null
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($top)) {
                return ([System.IO.Path]::GetFullPath(($top | Select-Object -First 1))).TrimEnd(
                    [System.IO.Path]::DirectorySeparatorChar,
                    [System.IO.Path]::AltDirectorySeparatorChar)
            }
        } finally {
            Pop-Location
        }
    }
    return (Split-Path -Parent $ScriptDir)
}

$RepoRoot = Get-PreflightRepoRoot -ScriptDir $PSScriptRoot

function Resolve-PreflightGitPath {
    param(
        [Parameter(Mandatory)][string]$GitPath
    )

    if (Get-Command git -ErrorAction SilentlyContinue) {
        Push-Location $RepoRoot
        try {
            $raw = @(& git rev-parse --git-path $GitPath 2>$null) | Select-Object -First 1
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($raw)) {
                if ([System.IO.Path]::IsPathRooted($raw)) {
                    return [System.IO.Path]::GetFullPath($raw)
                }
                return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $raw))
            }
        } finally {
            Pop-Location
        }
    }

    return [System.IO.Path]::GetFullPath((Join-Path (Join-Path $RepoRoot '.git') $GitPath))
}

# -NoAutoFix overrides -AutoFix (CI / scripted callers force loud failure).
$autoFixEnabled = [bool]$AutoFix -and -not $NoAutoFix

function Write-PreLine {
    param([string]$Message, [string]$Color = 'Gray')
    Write-Host "[preflight] $Message" -ForegroundColor $Color
}

function Test-PowerShellFileParse {
    param([Parameter(Mandatory)][string]$Path)
    $tokens = $null
    $parseErrors = $null
    try {
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $Path, [ref]$tokens, [ref]$parseErrors)
    } catch {
        return [pscustomobject]@{
            Ok       = $false
            Errors   = @("parse threw: $($_.Exception.Message)")
            ParseAst = $null
        }
    }
    if ($null -ne $parseErrors -and $parseErrors.Count -gt 0) {
        $messages = foreach ($err in $parseErrors) {
            "$($err.Extent.StartLineNumber):$($err.Extent.StartColumnNumber): $($err.Message)"
        }
        return [pscustomobject]@{ Ok = $false; Errors = @($messages) }
    }
    return [pscustomobject]@{ Ok = $true; Errors = @() }
}

# In -SelfCheck mode: validate ONLY this script and exit. The parent
# invocation spawned us in a child pwsh so we are not relying on the
# fact that THIS process already parsed us; a corrupted source will
# fail before pwsh even reaches this comment because pwsh -File refuses
# unparseable scripts, surfacing a clear error.
if ($SelfCheck) {
    $result = Test-PowerShellFileParse -Path $ScriptPath
    if (-not $result.Ok) {
        Write-PreLine "Self-parse failed for $ScriptPath" 'Red'
        foreach ($msg in $result.Errors) { Write-PreLine "  $msg" 'Red' }
        exit 1
    }
    if ($VerboseOutput) { Write-PreLine "Self-check OK." 'Green' }
    exit 0
}

# Bootstrap: spawn a child pwsh that parses THIS script. If the user
# corrupted preflight.ps1, the child crashes with a clear preflight-
# branded error instead of leaving us in an unknown state. This is
# belt-and-suspenders: if the corruption is severe enough that the
# parent pwsh refused to start this script, we never reach this line.
# The PRIMARY defense lives upstream in `run-llm-hooks.ps1` which
# parse-checks `preflight.ps1` before invoking it, and in the installed
# pre-commit shim which parse-checks `run-llm-hooks.ps1`.
if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
    Write-PreLine 'pwsh not found on PATH; cannot bootstrap self-check.' 'Red'
    exit 1
}
$childArgs = @('-NoProfile', '-File', $ScriptPath, '-SelfCheck', '-NoAutoFix')
if ($VerboseOutput) { $childArgs += '-VerboseOutput' }
& pwsh @childArgs
$selfExit = $LASTEXITCODE
if ($selfExit -ne 0) {
    Write-PreLine "Self-check child process failed with exit $selfExit; aborting." 'Red'
    exit 1
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-PreLine 'git not found on PATH; cannot enumerate sources.' 'Red'
    exit 1
}

# Prune old recovery dirs to keep at most $RecoveryRetainCount of them.
# Runs at startup so a debugging loop does not accrue hundreds. Cleanup
# failures are NEVER fatal; they cannot block recovery.
$RecoveryRetainCount = 20
$recoveryParent = Resolve-PreflightGitPath -GitPath 'preflight-recovery'
if (Test-Path -LiteralPath $recoveryParent -PathType Container) {
    try {
        # Sort by LastWriteTimeUtc, not CreationTimeUtc, because some
        # filesystems (FAT, certain NFS configurations) do not preserve
        # creation time portably; mtime is the lowest-common-denominator
        # ordering. We write to each recovery dir exactly once at
        # creation, so mtime == creation time in practice anyway. (NIT-2)
        $existing = @(Get-ChildItem -LiteralPath $recoveryParent -Directory -ErrorAction SilentlyContinue |
            Sort-Object -Property LastWriteTimeUtc -Descending)
        if ($existing.Count -gt $RecoveryRetainCount) {
            $stale = $existing | Select-Object -Skip $RecoveryRetainCount
            foreach ($d in $stale) {
                try {
                    Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction Stop
                    if ($VerboseOutput) { Write-PreLine "Pruned stale recovery dir: $($d.Name)" }
                } catch {
                    # Swallow per-dir errors; cleanup is best-effort. We
                    # do NOT log loudly because cleanup must never look
                    # like a failure to the caller.
                    if ($VerboseOutput) { Write-PreLine "Skip prune of $($d.Name): $($_.Exception.Message)" }
                }
            }
        }
    } catch {
        if ($VerboseOutput) { Write-PreLine "Recovery prune skipped: $($_.Exception.Message)" }
    }
}

Push-Location $RepoRoot
try {
    $sources = @(& git ls-files -- '*.ps1' '*.psm1' '*.psd1')
    if ($LASTEXITCODE -ne 0) {
        Write-PreLine "git ls-files (PowerShell sources) failed with exit $LASTEXITCODE." 'Red'
        exit 1
    }
} finally {
    Pop-Location
}

$sources = @($sources | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

# Also scan `.claude/hooks/*.ps1` directly so untracked or gitignored
# hooks are still parse-checked. Get-ChildItem is null-safe when the
# directory does not exist.
$hooksDir = Join-Path $RepoRoot '.claude/hooks'
if (Test-Path -LiteralPath $hooksDir -PathType Container) {
    $hookFiles = @(Get-ChildItem -LiteralPath $hooksDir -Filter '*.ps1' -File -ErrorAction SilentlyContinue)
    foreach ($hook in $hookFiles) {
        $rel = ".claude/hooks/$($hook.Name)"
        if ($sources -notcontains $rel) {
            $sources += $rel
        }
    }
}

$corruptedRecovered = $false
$corruptedFatal = New-Object System.Collections.Generic.List[string]
# Single recovery directory for this preflight invocation. Cached so we
# only attempt the New-Item once per run.
$script:recoveryRoot = $null
$script:recoveryRootFailed = $false
function Get-RecoveryDir {
    if (-not [string]::IsNullOrWhiteSpace($script:recoveryRoot)) {
        return $script:recoveryRoot
    }
    if ($script:recoveryRootFailed) {
        return $null
    }
    # A GUID makes same-timestamp/PID collisions practically irrelevant, and
    # the final New-Item deliberately omits -Force so any real collision is
    # loud instead of silently reusing another recovery directory.
    $stamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $token = "$stamp-$PID-$([Guid]::NewGuid().ToString('N'))"
    $dir = Join-Path $recoveryParent $token
    try {
        if (-not (Test-Path -LiteralPath $recoveryParent -PathType Container)) {
            New-Item -ItemType Directory -Path $recoveryParent -Force -ErrorAction Stop | Out-Null
        }
        New-Item -ItemType Directory -Path $dir -ErrorAction Stop | Out-Null
        $script:recoveryRoot = $dir
        return $dir
    } catch {
        # Recovery dir cannot be created (read-only fs, EACCES, etc).
        # The backup is the safety contract: we REFUSE to restore from
        # HEAD if we cannot first preserve the working-tree WIP. Caller
        # treats $null as "no backup possible".
        Write-PreLine "Failed to create recovery directory $dir`: $($_.Exception.Message). Refusing to overwrite working-tree WIP without a safety backup." 'Red'
        $script:recoveryRootFailed = $true
        return $null
    }
}

# Encode a repo-relative path for use as a backup filename. Replaces both
# `/` and `\` with `__` so two backed-up files with the same basename
# (`scripts/foo.ps1` and `lib/foo.ps1`) do not overwrite each other.
function ConvertTo-RecoveryFileName {
    param([Parameter(Mandatory)][string]$RelativePath)
    return ($RelativePath -replace '[\\/]', '__')
}

function Copy-GitBlobToFile {
    param(
        [Parameter(Mandatory)][string]$Blob,
        [Parameter(Mandatory)][string]$Destination
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'git'
    [void]$psi.ArgumentList.Add('cat-file')
    [void]$psi.ArgumentList.Add('blob')
    [void]$psi.ArgumentList.Add($Blob)
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false

    Push-Location $RepoRoot
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $stream = [System.IO.File]::Open($Destination, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $proc.StandardOutput.BaseStream.CopyTo($stream)
        } finally {
            $stream.Dispose()
        }
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        if ($proc.ExitCode -ne 0) {
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            throw "git cat-file blob $Blob failed with exit $($proc.ExitCode): $stderr"
        }
    } finally {
        Pop-Location
    }
}

function New-IndexRecoveryBackup {
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$RecoveryDir
    )

    Push-Location $RepoRoot
    try {
        $stageLine = @(& git ls-files --stage -- $RelativePath 2>&1) | Select-Object -First 1
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($stageLine)) {
            return $null
        }
    } finally {
        Pop-Location
    }

    if ($stageLine -notmatch '^(?<Mode>\d+)\s+(?<Sha>[0-9a-f]{40,64})\s+\d+\s+') {
        throw "Could not parse index entry for $RelativePath`: $stageLine"
    }

    $indexBackupPath = Join-Path $RecoveryDir "$(ConvertTo-RecoveryFileName -RelativePath $RelativePath).index"
    Copy-GitBlobToFile -Blob $Matches['Sha'] -Destination $indexBackupPath
    return [pscustomobject]@{
        Path = $indexBackupPath
        Mode = $Matches['Mode']
    }
}

function Restore-IndexRecoveryBackup {
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)]$IndexBackup
    )

    Push-Location $RepoRoot
    try {
        $hashOutput = @(& git hash-object -w -- $IndexBackup.Path 2>&1)
        if ($LASTEXITCODE -ne 0 -or $hashOutput.Count -eq 0) {
            Write-PreLine "AutoFix: failed to hash index backup for $RelativePath (exit $LASTEXITCODE): $($hashOutput -join '; ')" 'Red'
            return
        }
        $blobSha = "$($hashOutput[0])".Trim()
        $updateOutput = @(& git update-index --add --cacheinfo $IndexBackup.Mode $blobSha $RelativePath 2>&1)
        if ($LASTEXITCODE -ne 0) {
            Write-PreLine "AutoFix: failed to restore index backup for $RelativePath (exit $LASTEXITCODE): $($updateOutput -join '; ')" 'Red'
        }
    } finally {
        Pop-Location
    }
}

foreach ($rel in $sources) {
    $full = Join-Path $RepoRoot $rel
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        # Tracked but deleted in working tree; nothing to parse.
        continue
    }
    $result = Test-PowerShellFileParse -Path $full
    if ($result.Ok) {
        if ($VerboseOutput) { Write-PreLine "parse OK: $rel" }
        continue
    }
    Write-PreLine "Parse error in ${rel}:" 'Red'
    foreach ($msg in $result.Errors) { Write-PreLine "  ${rel}:$msg" 'Red' }
    if (-not $autoFixEnabled) {
        $corruptedFatal.Add($rel)
        continue
    }

    # AutoFix flow:
    #   1. BACKUP corrupt working-tree content (so user can reclaim WIP).
    #   2. Try `git checkout -- <path>` (restore from INDEX/staged version)
    #      first. This preserves user's staged WIP — the common pre-commit
    #      case where the user staged clean code and the working-tree
    #      copy was corrupted after staging by a stale editor buffer.
    #   3. Parse-check; if good, done.
    #   4. Fallback: `git checkout HEAD -- <path>` (restore from HEAD).
    #      This loses any staged WIP that was itself corrupt or unrecoverable,
    #      but at least gets the toolkit running again.
    #   5. If HEAD is ALSO broken, RESTORE the working-tree backup so we
    #      never leave a half-repaired tree masquerading as success.
    $recoveryDir = Get-RecoveryDir
    if ($null -eq $recoveryDir) {
        # No safety backup possible; refuse to restore.
        Write-PreLine "AutoFix: cannot create recovery directory; refusing to restore $rel without a backup." 'Red'
        $corruptedFatal.Add($rel)
        continue
    }
    $backupPath = Join-Path $recoveryDir (ConvertTo-RecoveryFileName -RelativePath $rel)
    try {
        $corruptBytes = [System.IO.File]::ReadAllBytes($full)
        [System.IO.File]::WriteAllBytes($backupPath, $corruptBytes)
        Write-PreLine "AutoFix: backed up corrupt $rel to $backupPath" 'Yellow'
    } catch {
        Write-PreLine "AutoFix: failed to write recovery backup for $rel`: $($_.Exception.Message). Refusing to overwrite WIP." 'Red'
        $corruptedFatal.Add($rel)
        continue
    }

    $indexBackup = $null
    try {
        $indexBackup = New-IndexRecoveryBackup -RelativePath $rel -RecoveryDir $recoveryDir
        if ($null -ne $indexBackup) {
            Write-PreLine "AutoFix: backed up index copy of $rel to $($indexBackup.Path)" 'Yellow'
        }
    } catch {
        Write-PreLine "AutoFix: failed to write index recovery backup for $rel`: $($_.Exception.Message). Refusing to overwrite staged WIP." 'Red'
        $corruptedFatal.Add($rel)
        continue
    }

    $restoredFrom = $null
    Push-Location $RepoRoot
    try {
        # Step 2: try index/staged first.
        Write-PreLine "AutoFix: restoring $rel from index (staged version)." 'Yellow'
        $checkoutOutput = @(& git checkout -- $rel 2>&1)
        $indexExit = $LASTEXITCODE
        if ($indexExit -eq 0) {
            $recheck = Test-PowerShellFileParse -Path $full
            if ($recheck.Ok) {
                $restoredFrom = 'index'
            } else {
                Write-PreLine "AutoFix: index copy of $rel also has parse errors; falling back to HEAD." 'Yellow'
            }
        } else {
            # File may not be in the index (e.g., never staged); fall through.
            Write-PreLine "AutoFix: git checkout from index failed for $rel (exit $indexExit): $($checkoutOutput -join '; '). Falling back to HEAD." 'Yellow'
        }
        # Step 4: fallback to HEAD.
        if ($null -eq $restoredFrom) {
            if ($null -eq $indexBackup) {
                Write-PreLine "AutoFix: cannot fall back to HEAD for $rel without an index backup. Restoring working-tree backup and aborting." 'Red'
                [System.IO.File]::WriteAllBytes($full, $corruptBytes)
                $corruptedFatal.Add($rel)
                continue
            }
            $checkoutOutput = @(& git checkout HEAD -- $rel 2>&1)
            if ($LASTEXITCODE -ne 0) {
                Write-PreLine "AutoFix: git checkout HEAD failed for $rel (exit $LASTEXITCODE): $($checkoutOutput -join '; '). Recovery backup at $backupPath." 'Red'
                Restore-IndexRecoveryBackup -RelativePath $rel -IndexBackup $indexBackup
                $corruptedFatal.Add($rel)
                continue
            }
            $recheck = Test-PowerShellFileParse -Path $full
            if ($recheck.Ok) {
                $restoredFrom = 'HEAD'
            }
        }
    } finally {
        Pop-Location
    }
    if ($null -eq $restoredFrom) {
        Write-PreLine "AutoFix: HEAD copy of $rel is ALSO corrupt; restoring working-tree backup so we do not leave a broken-from-HEAD file masquerading as success." 'Red'
        foreach ($msg in $recheck.Errors) { Write-PreLine "  HEAD ${rel}:$msg" 'Red' }
        try {
            [System.IO.File]::WriteAllBytes($full, $corruptBytes)
        } catch {
            Write-PreLine "AutoFix: failed to restore working-tree copy of $rel from backup ($($_.Exception.Message)). Recover from $backupPath." 'Red'
        }
        if ($null -ne $indexBackup) {
            Restore-IndexRecoveryBackup -RelativePath $rel -IndexBackup $indexBackup
        }
        Write-PreLine "Both working tree and HEAD copy of $rel have parse errors. The repo's HEAD is in a corrupt state; escalate manually. Recovery backup at $backupPath." 'Red'
        $corruptedFatal.Add($rel)
        continue
    }
    if ($restoredFrom -eq 'HEAD') {
        $indexNote = if ($null -ne $indexBackup) { "; staged/index WIP is preserved in $($indexBackup.Path)" } else { '' }
        Write-PreLine "AutoFix: recovered $rel from HEAD. NOTE: working-tree WIP is preserved in $backupPath$indexNote." 'Yellow'
    } else {
        Write-PreLine "AutoFix: recovered $rel from index (staged version)." 'Yellow'
    }
    $corruptedRecovered = $true
}

if ($corruptedFatal.Count -gt 0) {
    Write-PreLine "Unrecoverable corruption in: $($corruptedFatal -join ', ')" 'Red'
    exit 1
}
if ($corruptedRecovered) {
    Write-PreLine "AutoFix recovered one or more PowerShell sources (from index where possible, HEAD as fallback). Review with git status; corrupt originals are preserved in $recoveryParent." 'Yellow'
    exit 2
}
Write-PreLine 'Preflight OK.' 'Green'
exit 0
