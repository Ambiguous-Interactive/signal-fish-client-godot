Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Shared helpers used by generate-llm-index.ps1, lint-llm.ps1, and
# run-llm-hooks.ps1. Centralizing them keeps the generator and linter from
# drifting on frontmatter parsing, path handling, or repo-root discovery.

# Canonical list of editor/backup/staging artifact glob patterns. Single
# source of truth shared by lint-llm.ps1, run-llm-hooks.ps1, and the
# `Get-LlmStrayWorkingTreeArtifacts` helper default. Anything that wants
# the harness's idea of "junk in the working tree" must consume this
# variable (or the `Get-LlmDefaultStrayPatterns` accessor below) rather
# than hardcode its own copy. A self-test asserts the three call sites
# do not redeclare the list literally.
$script:LlmDefaultStrayPatterns = @(
    '*.tmp', '*.swp', '*.swo', '*~', '.#*', '#*#',
    '*.bak', '*.orig', '*.old', '*.new', '*.rej',
    '.DS_Store', 'Thumbs.db'
)

function Get-LlmDefaultStrayPatterns {
    <#
    .SYNOPSIS
    Returns the canonical stray-artifact glob list. Callers must use this
    accessor (or `$script:LlmDefaultStrayPatterns`) instead of hardcoding
    their own copy so the linter, hook runner, and helper defaults never
    drift apart.

    .OUTPUTS
    A fresh `string[]` clone so callers cannot mutate the module-private
    backing array by accident.
    #>
    [CmdletBinding()]
    param()
    return @($script:LlmDefaultStrayPatterns)
}

function Get-LlmRepoRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ScriptRoot
    )
    return (Split-Path -Parent $ScriptRoot)
}

function Get-LlmRepoRelativePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Path
    )
    try {
        return ([System.IO.Path]::GetRelativePath($RepoRoot, $Path)).Replace('\', '/')
    } catch {
        return $Path
    }
}

function Read-LlmFileLines {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    return @(Get-Content -LiteralPath $Path -ErrorAction Stop)
}

function Read-LlmFileText {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    return (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop)
}

function Read-LlmFrontmatter {
    <#
    .SYNOPSIS
    Parses YAML-ish frontmatter from a Markdown file.

    .DESCRIPTION
    Returns an ordered hashtable of lowercase keys to trimmed values. If the
    file does not start with a '---' fence or the closing fence is missing,
    returns an empty hashtable. Only simple `key: value` lines are supported,
    matching the harness conventions documented in .llm/skills/agent-harness.md.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $metadata = [ordered]@{}
    $lines = @(Read-LlmFileLines -Path $Path)
    if ($lines.Count -lt 3 -or $lines[0] -ne '---') {
        return $metadata
    }

    $closed = $false
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -eq '---') {
            $closed = $true
            break
        }
        if ($lines[$i] -match '^\s*([A-Za-z0-9_-]+):\s*(.*?)\s*$') {
            $key = $Matches[1].Trim().ToLowerInvariant()
            $value = $Matches[2].Trim().Trim('"').Trim("'")
            $metadata[$key] = $value
        }
    }

    if (-not $closed) {
        return [ordered]@{}
    }
    return $metadata
}

function Get-LlmFrontmatterValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Metadata,
        [Parameter(Mandatory)][string]$Key,
        [string]$Fallback = ''
    )
    if ($Metadata.Contains($Key) -and -not [string]::IsNullOrWhiteSpace($Metadata[$Key])) {
        return [string]$Metadata[$Key]
    }
    return $Fallback
}

function Get-LlmMarkdownTitle {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    foreach ($line in @(Read-LlmFileLines -Path $Path)) {
        if ($line -match '^#\s+(.+)$') {
            return $Matches[1].Trim()
        }
    }
    return [System.IO.Path]::GetFileNameWithoutExtension($Path)
}

function Write-LlmTextFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content
    )
    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function ConvertTo-LlmNormalizedNewlines {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)
    return $Content.Replace("`r`n", "`n")
}

function Get-LlmStagingArtifacts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string[]]$Patterns = @('*.new', '*.bak', '*.orig', '*.old', '*.rej')
    )

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'git not available; cannot inspect staging artifacts.'
    }

    $activePatterns = @($Patterns | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($activePatterns.Count -eq 0) {
        return @()
    }

    $trackedErrorPath = [System.IO.Path]::GetTempFileName()
    $untrackedErrorPath = [System.IO.Path]::GetTempFileName()

    Push-Location $RepoRoot
    try {
        $tracked = @(& git ls-files -- @activePatterns 2> $trackedErrorPath)
        $trackedExitCode = $LASTEXITCODE
        if ($trackedExitCode -ne 0) {
            $trackedError = (Get-Content -LiteralPath $trackedErrorPath -Raw -ErrorAction SilentlyContinue).Trim()
            if ([string]::IsNullOrWhiteSpace($trackedError)) {
                throw "git ls-files (tracked) failed with exit $trackedExitCode."
            }
            throw "git ls-files (tracked) failed with exit $trackedExitCode`: $trackedError"
        }

        $untracked = @(& git ls-files --others --exclude-standard -- @activePatterns 2> $untrackedErrorPath)
        $untrackedExitCode = $LASTEXITCODE
        if ($untrackedExitCode -ne 0) {
            $untrackedError = (Get-Content -LiteralPath $untrackedErrorPath -Raw -ErrorAction SilentlyContinue).Trim()
            if ([string]::IsNullOrWhiteSpace($untrackedError)) {
                throw "git ls-files (untracked) failed with exit $untrackedExitCode."
            }
            throw "git ls-files (untracked) failed with exit $untrackedExitCode`: $untrackedError"
        }

        $artifacts = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
        foreach ($path in $tracked) {
            $artifactPath = "$path"
            if ([string]::IsNullOrWhiteSpace($artifactPath)) { continue }
            $artifacts[$artifactPath] = [pscustomobject]@{ Path = $artifactPath; IsTracked = $true }
        }
        foreach ($path in $untracked) {
            $artifactPath = "$path"
            if ([string]::IsNullOrWhiteSpace($artifactPath)) { continue }
            if (-not $artifacts.ContainsKey($artifactPath)) {
                $artifacts[$artifactPath] = [pscustomobject]@{ Path = $artifactPath; IsTracked = $false }
            }
        }

        return @($artifacts.Values | Sort-Object -Property Path)
    } finally {
        Pop-Location
        Remove-Item -LiteralPath $trackedErrorPath, $untrackedErrorPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-LlmStrayWorkingTreeArtifacts {
    <#
    .SYNOPSIS
    Finds stray editor / backup / staging artifacts anywhere in the working
    tree, INCLUDING gitignored files.

    .DESCRIPTION
    `Get-LlmStagingArtifacts` calls `git ls-files --others --exclude-standard`,
    which honors `.gitignore`. That is correct for catching tracked or
    accidentally-untracked artifacts, but it has a blind spot: patterns like
    `*.tmp` are already gitignored in this repo, so a stale
    `scripts/install-git-hooks.ps1.tmp` left by an editor will be invisible
    to the linter while still corrupting the working tree (and possibly
    being mistaken for the real file by a confused agent).

    This helper closes that blind spot by passing `--ignored` to
    `git ls-files`, then unions the result with the tracked + non-ignored
    set so we cover every case in a single sorted, deduplicated list.

    Returns pscustomobjects with Path, IsTracked, IsIgnored properties.
    Skips `.git/` defensively (git itself does not list those, but we
    belt-and-suspender it).

    Note: `git ls-files` returns files only, never directories. A path
    like `cache.tmp/` (a directory matching one of the artifact glob
    patterns) is NOT returned. Callers that delete entries from the
    result set MUST still confirm with `Test-Path -PathType Leaf` before
    `Remove-Item -Force` to defend against future git changes or
    pathological symlink targets. `run-llm-hooks.ps1` does this.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [string[]]$Patterns = (Get-LlmDefaultStrayPatterns)
    )

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'git not available; cannot inspect stray working tree artifacts.'
    }

    $activePatterns = @($Patterns | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($activePatterns.Count -eq 0) {
        return @()
    }

    $trackedErrorPath = [System.IO.Path]::GetTempFileName()
    $untrackedErrorPath = [System.IO.Path]::GetTempFileName()
    $ignoredErrorPath = [System.IO.Path]::GetTempFileName()

    Push-Location $RepoRoot
    try {
        $tracked = @(& git ls-files -- @activePatterns 2> $trackedErrorPath)
        if ($LASTEXITCODE -ne 0) {
            $err = (Get-Content -LiteralPath $trackedErrorPath -Raw -ErrorAction SilentlyContinue).Trim()
            throw "git ls-files (tracked) failed with exit $LASTEXITCODE`: $err"
        }
        $untracked = @(& git ls-files --others --exclude-standard -- @activePatterns 2> $untrackedErrorPath)
        if ($LASTEXITCODE -ne 0) {
            $err = (Get-Content -LiteralPath $untrackedErrorPath -Raw -ErrorAction SilentlyContinue).Trim()
            throw "git ls-files (untracked) failed with exit $LASTEXITCODE`: $err"
        }
        # `--others --ignored --exclude-standard` is the canonical
        # incantation for "untracked files that match a .gitignore rule".
        # Without --others, --ignored will error out on modern git.
        $ignored = @(& git ls-files --others --ignored --exclude-standard -- @activePatterns 2> $ignoredErrorPath)
        if ($LASTEXITCODE -ne 0) {
            $err = (Get-Content -LiteralPath $ignoredErrorPath -Raw -ErrorAction SilentlyContinue).Trim()
            throw "git ls-files (ignored) failed with exit $LASTEXITCODE`: $err"
        }

        $artifacts = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
        foreach ($path in $tracked) {
            $p = "$path"
            if ([string]::IsNullOrWhiteSpace($p)) { continue }
            if ($p.StartsWith('.git/') -or $p -eq '.git') { continue }
            $artifacts[$p] = [pscustomobject]@{ Path = $p; IsTracked = $true; IsIgnored = $false }
        }
        foreach ($path in $untracked) {
            $p = "$path"
            if ([string]::IsNullOrWhiteSpace($p)) { continue }
            if ($p.StartsWith('.git/') -or $p -eq '.git') { continue }
            if (-not $artifacts.ContainsKey($p)) {
                $artifacts[$p] = [pscustomobject]@{ Path = $p; IsTracked = $false; IsIgnored = $false }
            }
        }
        foreach ($path in $ignored) {
            $p = "$path"
            if ([string]::IsNullOrWhiteSpace($p)) { continue }
            if ($p.StartsWith('.git/') -or $p -eq '.git') { continue }
            if (-not $artifacts.ContainsKey($p)) {
                $artifacts[$p] = [pscustomobject]@{ Path = $p; IsTracked = $false; IsIgnored = $true }
            }
        }

        return @($artifacts.Values | Sort-Object -Property Path)
    } finally {
        Pop-Location
        Remove-Item -LiteralPath $trackedErrorPath, $untrackedErrorPath, $ignoredErrorPath -Force -ErrorAction SilentlyContinue
    }
}

function Test-LlmDeletableArtifact {
    <#
    .SYNOPSIS
    Scope an AutoFix delete to "known harness-controlled" paths so a stray
    edit-buffer artifact outside the harness directories is REPORTED rather
    than silently destroyed.

    .DESCRIPTION
    Returns $true iff the artifact's first path segment is one of the
    controlled directories (`scripts`, `.llm`, `.githooks`, `.claude`), OR
    the artifact looks like a sibling backup of a tracked source file
    (`foo.ps1.tmp` is deletable when `foo.ps1` is tracked, where the
    "stripped" name is computed by removing one well-known extension).

    Why: the broad `*.tmp` / `*.swp` cleanup patterns will match a user's
    vim swap file (`.notes.md.swp`) or a build artifact (`build.tmp`) that
    has nothing to do with the harness. Auto-deleting those would silently
    destroy user data. This helper is the single decision point so the
    behavior is testable and reviewable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        # Repo-relative path (`/` separators). Empty/whitespace returns $false.
        [Parameter(Mandatory)][AllowEmptyString()][string]$RelativePath,
        # Tracked-file lookup set. Keys are repo-relative `/`-separated paths.
        # An empty hashset is valid and yields the controlled-dir branch only.
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.HashSet[string]]$TrackedFiles
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath)) { return $false }

    $normalized = $RelativePath -replace '\\', '/'
    # Collapse repeated `/` so an input like `scripts//foo.ps1.tmp` or
    # `.//scripts/foo.ps1.tmp` normalizes to `scripts/foo.ps1.tmp`. Run
    # this BEFORE the leading-`./` strip so `././/scripts/...` reduces
    # cleanly across both passes. We use a while-loop to handle three
    # or more consecutive slashes (`///`) which a single replace would
    # leave behind. (NIT-1)
    while ($normalized.Contains('//')) {
        $normalized = $normalized -replace '/{2,}', '/'
    }
    if ($normalized.StartsWith('/')) {
        $normalized = $normalized.TrimStart('/')
    }
    # Strip leading `./` segments (and any further `./` after them) so an
    # input like `./scripts/foo.ps1.tmp` is treated the same as
    # `scripts/foo.ps1.tmp`. Without this, the first split segment would
    # be `.` and every membership check below would silently miss.
    while ($normalized.StartsWith('./')) {
        $normalized = $normalized.Substring(2)
    }
    # Defensive: never claim a path with `..` traversal is harness-owned.
    if ($normalized.Contains('..')) { return $false }

    $first = $normalized.Split('/', 2)[0]
    $controlled = @('scripts', '.llm', '.githooks', '.claude')
    if ($controlled -contains $first) {
        return $true
    }

    # Sibling-of-tracked-source case: `foo.ps1.tmp` is deletable iff
    # `foo.ps1` is tracked. Try stripping one trailing artifact suffix.
    $artifactSuffixes = @(
        '.tmp', '.swp', '.swo', '.bak', '.orig', '.old', '.new', '.rej', '~'
    )
    foreach ($suffix in $artifactSuffixes) {
        if ($normalized.EndsWith($suffix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $sibling = $normalized.Substring(0, $normalized.Length - $suffix.Length)
            if (-not [string]::IsNullOrWhiteSpace($sibling) -and $TrackedFiles.Contains($sibling)) {
                return $true
            }
        }
    }

    # Editor-style backups: `.#name` and `#name#` are emacs lock / autosave
    # files. Treat as deletable iff the base name corresponds to a tracked
    # file in the same directory.
    $leaf = [System.IO.Path]::GetFileName($normalized)
    $dir = [System.IO.Path]::GetDirectoryName($normalized) -replace '\\', '/'
    if ($leaf -match '^\.#(.+)$') {
        $base = if ([string]::IsNullOrWhiteSpace($dir)) { $Matches[1] } else { "$dir/$($Matches[1])" }
        if ($TrackedFiles.Contains($base)) { return $true }
    } elseif ($leaf -match '^#(.+)#$') {
        $base = if ([string]::IsNullOrWhiteSpace($dir)) { $Matches[1] } else { "$dir/$($Matches[1])" }
        if ($TrackedFiles.Contains($base)) { return $true }
    }

    return $false
}

function Get-LlmTrackedFileSet {
    <#
    .SYNOPSIS
    Build a HashSet of repo-relative tracked file paths for fast membership
    queries used by `Test-LlmDeletableArtifact`.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot)

    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        return $set
    }
    Push-Location $RepoRoot
    try {
        $files = @(& git ls-files)
        if ($LASTEXITCODE -ne 0) {
            return $set
        }
        foreach ($f in $files) {
            $p = "$f"
            if ([string]::IsNullOrWhiteSpace($p)) { continue }
            [void]$set.Add(($p -replace '\\', '/'))
        }
    } finally {
        Pop-Location
    }
    return $set
}

Export-ModuleMember -Function `
    Get-LlmRepoRoot, `
    Get-LlmRepoRelativePath, `
    Read-LlmFileLines, `
    Read-LlmFileText, `
    Read-LlmFrontmatter, `
    Get-LlmFrontmatterValue, `
    Get-LlmMarkdownTitle, `
    Write-LlmTextFile, `
    ConvertTo-LlmNormalizedNewlines, `
    Get-LlmStagingArtifacts, `
    Get-LlmStrayWorkingTreeArtifacts, `
    Get-LlmDefaultStrayPatterns, `
    Test-LlmDeletableArtifact, `
    Get-LlmTrackedFileSet `
    -Variable LlmDefaultStrayPatterns
