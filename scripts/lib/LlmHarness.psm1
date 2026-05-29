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
# than hardcode its own copy. Git pathspec expansion is derived from this
# list by `ConvertTo-LlmStrayArtifactPathspecs`. A self-test asserts the
# three call sites do not redeclare the list literally.
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

function ConvertTo-LlmStrayArtifactPathspecs {
    <#
    .SYNOPSIS
    Converts stray-artifact filename globs into Git pathspecs.

    .DESCRIPTION
    Basename-style artifacts include literal names and filename globs.
    Literal names only match the repository root when passed directly to
    `git ls-files`, so this helper preserves each source pattern and adds a
    recursive glob pathspec for patterns that do not already name a directory.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string[]]$Patterns = $null
    )

    $pathspecs = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($pattern in @($Patterns)) {
        $normalized = "$pattern".Trim() -replace '\\', '/'
        if ([string]::IsNullOrWhiteSpace($normalized)) { continue }

        $candidates = @($normalized)
        if ($normalized -notmatch '/') {
            $candidates += ":(glob)**/$normalized"
        }
        foreach ($candidate in $candidates) {
            if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
            if ($seen.Add($candidate)) {
                $pathspecs.Add($candidate)
            }
        }
    }

    return @($pathspecs)
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

function Resolve-LlmGitPath {
    <#
    .SYNOPSIS
    Resolves a path relative to Git's actual metadata directory.

    .DESCRIPTION
    `Join-Path $RepoRoot .git/...` is wrong in linked worktrees and some
    submodule layouts because `.git` can be a file that points at the real git
    dir. This helper wraps `git rev-parse --git-path <path>` and normalizes the
    returned path to an absolute filesystem path. If git is unavailable or the
    command fails, it falls back to the ordinary clone layout so diagnostics can
    still name the intended location.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
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

function Read-LlmFileLines {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    return @([System.IO.File]::ReadAllLines($Path))
}

function Read-LlmFileText {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    return [System.IO.File]::ReadAllText($Path)
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

    $lines = @(Read-LlmFileLines -Path $Path)
    return (ConvertFrom-LlmFrontmatterLines -Lines $lines)
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
    if ((Test-Path -LiteralPath $Path -PathType Leaf) -and
        (ConvertTo-LlmNormalizedNewlines (Read-LlmFileText -Path $Path)) -eq
        (ConvertTo-LlmNormalizedNewlines $Content)) {
        return $false
    }
    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
    return $true
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
        [string[]]$Patterns = (Get-LlmDefaultStrayPatterns)
    )

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'git not available; cannot inspect staging artifacts.'
    }

    $activePathspecs = @(ConvertTo-LlmStrayArtifactPathspecs -Patterns $Patterns)
    if ($activePathspecs.Count -eq 0) {
        return @()
    }

    $trackedErrorPath = [System.IO.Path]::GetTempFileName()
    $untrackedErrorPath = [System.IO.Path]::GetTempFileName()

    Push-Location $RepoRoot
    try {
        $tracked = @(& git ls-files -- @activePathspecs 2> $trackedErrorPath)
        $trackedExitCode = $LASTEXITCODE
        if ($trackedExitCode -ne 0) {
            $trackedError = (Get-Content -LiteralPath $trackedErrorPath -Raw -ErrorAction SilentlyContinue).Trim()
            if ([string]::IsNullOrWhiteSpace($trackedError)) {
                throw "git ls-files (tracked) failed with exit $trackedExitCode."
            }
            throw "git ls-files (tracked) failed with exit $trackedExitCode`: $trackedError"
        }

        $untracked = @(& git ls-files --others --exclude-standard -- @activePathspecs 2> $untrackedErrorPath)
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

    $activePathspecs = @(ConvertTo-LlmStrayArtifactPathspecs -Patterns $Patterns)
    if ($activePathspecs.Count -eq 0) {
        return @()
    }

    $trackedErrorPath = [System.IO.Path]::GetTempFileName()
    $untrackedErrorPath = [System.IO.Path]::GetTempFileName()
    $ignoredErrorPath = [System.IO.Path]::GetTempFileName()

    Push-Location $RepoRoot
    try {
        $tracked = @(& git ls-files -- @activePathspecs 2> $trackedErrorPath)
        if ($LASTEXITCODE -ne 0) {
            $err = (Get-Content -LiteralPath $trackedErrorPath -Raw -ErrorAction SilentlyContinue).Trim()
            throw "git ls-files (tracked) failed with exit $LASTEXITCODE`: $err"
        }
        $untracked = @(& git ls-files --others --exclude-standard -- @activePathspecs 2> $untrackedErrorPath)
        if ($LASTEXITCODE -ne 0) {
            $err = (Get-Content -LiteralPath $untrackedErrorPath -Raw -ErrorAction SilentlyContinue).Trim()
            throw "git ls-files (untracked) failed with exit $LASTEXITCODE`: $err"
        }
        # `--others --ignored --exclude-standard` is the canonical
        # incantation for "untracked files that match a .gitignore rule".
        # Without --others, --ignored will error out on modern git.
        $ignored = @(& git ls-files --others --ignored --exclude-standard -- @activePathspecs 2> $ignoredErrorPath)
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

function ConvertFrom-LlmFrontmatterLines {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines)

    $metadata = [ordered]@{}
    if ($Lines.Count -lt 3 -or $Lines[0] -ne '---') {
        return $metadata
    }

    $closed = $false
    for ($i = 1; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -eq '---') {
            $closed = $true
            break
        }
        if ($Lines[$i] -match '^\s*([A-Za-z0-9_-]+):\s*(.*?)\s*$') {
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

function Get-LlmMarkdownTitleFromLines {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory)][string]$Path
    )
    foreach ($line in $Lines) {
        if ($line -match '^#\s+(.+)$') {
            return $Matches[1].Trim()
        }
    }
    return [System.IO.Path]::GetFileNameWithoutExtension($Path)
}

function Get-LlmRelativeMarkdownPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LlmDir,
        [Parameter(Mandatory)][string]$Path
    )
    return ([System.IO.Path]::GetRelativePath($LlmDir, $Path)).Replace('\', '/')
}

function Get-LlmMarkdownInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot)

    $llmDir = Join-Path $RepoRoot '.llm'
    if (-not (Test-Path -LiteralPath $llmDir -PathType Container)) {
        throw "Missing .llm directory at $llmDir"
    }

    $files = @(Get-ChildItem -LiteralPath $llmDir -Filter '*.md' -Recurse -File | Sort-Object FullName)
    $records = foreach ($file in $files) {
        $lines = @(Read-LlmFileLines -Path $file.FullName)
        $metadata = ConvertFrom-LlmFrontmatterLines -Lines $lines
        $relative = Get-LlmRelativeMarkdownPath -LlmDir $llmDir -Path $file.FullName
        [pscustomobject]@{
            FullName     = $file.FullName
            RelativePath = $relative
            Lines        = $lines
            Text         = ($lines -join "`n") + $(if ($lines.Count -gt 0) { "`n" } else { '' })
            Metadata     = $metadata
            Title        = Get-LlmMarkdownTitleFromLines -Lines $lines -Path $file.FullName
        }
    }
    return @($records)
}

function New-LlmIndexLines {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Inventory)

    $skillFiles = @($Inventory | Where-Object { $_.RelativePath.StartsWith('skills/') } | Sort-Object RelativePath)
    $otherFiles = @($Inventory | Where-Object {
            $_.RelativePath -ne 'context.md' -and
            $_.RelativePath -ne 'index.md' -and
            -not $_.RelativePath.StartsWith('skills/')
        } | Sort-Object RelativePath)

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# LLM Context Index')
    $lines.Add('')
    $lines.Add('Generated Markdown inventory by `scripts/generate-llm-index.ps1`; do not edit by hand.')
    $lines.Add('')
    $lines.Add('## Skills')
    $lines.Add('')

    if ($skillFiles.Count -eq 0) {
        $lines.Add('- No skill files found.')
    } else {
        foreach ($file in $skillFiles) {
            $category = Get-LlmFrontmatterValue -Metadata $file.Metadata -Key 'category' -Fallback 'Uncategorized'
            $description = Get-LlmFrontmatterValue -Metadata $file.Metadata -Key 'description' -Fallback 'No description.'
            $triggers = Get-LlmFrontmatterValue -Metadata $file.Metadata -Key 'triggers' -Fallback 'No triggers.'
            $lines.Add("- [$($file.Title)]($($file.RelativePath)) (``$category``) - $description")
            $lines.Add("  Triggers: $triggers")
        }
    }

    $lines.Add('')
    $lines.Add('## Other LLM Files')
    $lines.Add('')

    if ($otherFiles.Count -eq 0) {
        $lines.Add('- No additional LLM files found.')
    } else {
        foreach ($file in $otherFiles) {
            $description = Get-LlmFrontmatterValue -Metadata $file.Metadata -Key 'description' -Fallback 'No description.'
            $lines.Add("- [$($file.Title)]($($file.RelativePath)) - $description")
        }
    }

    return @($lines)
}

function Join-LlmLines {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines)
    return (($Lines -join "`n") + "`n")
}

function Get-LlmGeneratedContentState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot)

    $llmDir = Join-Path $RepoRoot '.llm'
    $contextPath = Join-Path $llmDir 'context.md'
    $indexPath = Join-Path $llmDir 'index.md'
    $startMarker = '<!-- LLM-INDEX:START -->'
    $endMarker = '<!-- LLM-INDEX:END -->'

    if (-not (Test-Path -LiteralPath $contextPath -PathType Leaf)) {
        throw "Missing context file at $contextPath"
    }

    $inventory = @(Get-LlmMarkdownInventory -RepoRoot $RepoRoot)
    $indexLines = @(New-LlmIndexLines -Inventory $inventory)
    $expectedIndex = Join-LlmLines -Lines $indexLines

    $skillsIndex = [Array]::IndexOf($indexLines, '## Skills')
    $embeddedLines = if ($skillsIndex -lt 0) {
        $indexLines
    } else {
        @($indexLines[$skillsIndex..($indexLines.Count - 1)])
    }
    $embedded = (Join-LlmLines -Lines $embeddedLines).TrimEnd()

    $context = Read-LlmFileText -Path $contextPath
    $start = $context.IndexOf($startMarker)
    $end = $context.IndexOf($endMarker)
    if ($start -lt 0 -or $end -lt 0 -or $end -lt $start) {
        throw "context.md must contain $startMarker and $endMarker markers"
    }
    $prefix = $context.Substring(0, $start)
    $suffix = $context.Substring($end + $endMarker.Length)
    $expectedContext = "$prefix$startMarker`n$embedded`n$endMarker$suffix"

    $changes = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf) -or
        (ConvertTo-LlmNormalizedNewlines (Read-LlmFileText -Path $indexPath)) -ne
        (ConvertTo-LlmNormalizedNewlines $expectedIndex)) {
        $changes.Add('.llm/index.md')
    }
    if ((ConvertTo-LlmNormalizedNewlines $context) -ne
        (ConvertTo-LlmNormalizedNewlines $expectedContext)) {
        $changes.Add('.llm/context.md')
    }

    return [pscustomobject]@{
        RepoRoot        = $RepoRoot
        LlmDir          = $llmDir
        ContextPath     = $contextPath
        IndexPath       = $indexPath
        ExpectedIndex   = $expectedIndex
        ExpectedContext = $expectedContext
        Changes         = @($changes)
        Inventory       = $inventory
    }
}

function Invoke-LlmIndexGenerator {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [switch]$Check,
        [switch]$VerboseOutput,
        [switch]$PassThru
    )

    $state = Get-LlmGeneratedContentState -RepoRoot $RepoRoot
    if ($Check) {
        if ($state.Changes.Count -gt 0) {
            Write-Host '[llm-index] Generated LLM index is stale:' -ForegroundColor Red
            $state.Changes | ForEach-Object { Write-Host " - $_" -ForegroundColor Red }
            Write-Host 'Run: pwsh -NoProfile -File scripts/generate-llm-index.ps1' -ForegroundColor Yellow
            if ($PassThru) {
                return [pscustomobject]@{
                    Success      = $false
                    Check        = $true
                    ChangedPaths = @($state.Changes)
                    WrittenPaths = @()
                    WroteIndex   = $false
                    WroteContext = $false
                }
            }
            return $false
        }
        if ($VerboseOutput) {
            Write-Host '[llm-index] Generated files are up to date.'
        }
        if ($PassThru) {
            return [pscustomobject]@{
                Success      = $true
                Check        = $true
                ChangedPaths = @()
                WrittenPaths = @()
                WroteIndex   = $false
                WroteContext = $false
            }
        }
        return $true
    }

    $wroteIndex = Write-LlmTextFile -Path $state.IndexPath -Content $state.ExpectedIndex
    $wroteContext = Write-LlmTextFile -Path $state.ContextPath -Content $state.ExpectedContext
    $writtenPaths = [System.Collections.Generic.List[string]]::new()
    if ($wroteIndex) { $writtenPaths.Add('.llm/index.md') }
    if ($wroteContext) { $writtenPaths.Add('.llm/context.md') }
    if ($wroteIndex -or $wroteContext) {
        Write-Host '[llm-index] Generated .llm/index.md and updated .llm/context.md'
    } elseif ($VerboseOutput) {
        Write-Host '[llm-index] Generated files already up to date.'
    }
    if ($PassThru) {
        return [pscustomobject]@{
            Success      = $true
            Check        = $false
            ChangedPaths = @($state.Changes)
            WrittenPaths = @($writtenPaths)
            WroteIndex   = [bool]$wroteIndex
            WroteContext = [bool]$wroteContext
        }
    }
    return $true
}

function Invoke-LlmLint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [int]$MaxLines = 300,
        [switch]$VerboseOutput,
        [switch]$SkipGeneratedIndexCheck,
        [switch]$SkipStagingArtifactCheck,
        [switch]$SkipPowerShellParseCheck
    )

    $llmDir = Join-Path $RepoRoot '.llm'
    $errors = [System.Collections.Generic.List[string]]::new()
    $pointerChecks = @(
        [pscustomobject]@{ Path = 'AGENTS.md'; Required = $true; RequiredPattern = '\.llm/context\.md' },
        [pscustomobject]@{ Path = 'CLAUDE.md'; Required = $true; RequiredPattern = '\.llm/context\.md' },
        [pscustomobject]@{ Path = 'GEMINI.md'; Required = $true; RequiredPattern = '\.llm/context\.md' },
        [pscustomobject]@{ Path = 'CHATGPT.md'; Required = $true; RequiredPattern = '\.llm/context\.md' },
        [pscustomobject]@{ Path = 'CODEX.md'; Required = $true; RequiredPattern = '\.llm/context\.md' },
        [pscustomobject]@{ Path = 'llms.txt'; Required = $true; RequiredPattern = '\.llm/context\.md' },
        [pscustomobject]@{ Path = '.cursorrules'; Required = $true; RequiredPattern = '\.llm/context\.md' },
        [pscustomobject]@{ Path = '.windsurfrules'; Required = $true; RequiredPattern = '\.llm/context\.md' },
        [pscustomobject]@{ Path = '.github/copilot-instructions.md'; Required = $true; RequiredPattern = '\.llm/context\.md' },
        [pscustomobject]@{ Path = '.cursor/rules/signal-fish-llm-context.mdc'; Required = $true; RequiredPattern = '\.llm/context\.md' }
    )

    function Add-LlmLintError {
        param([string]$Message)
        $errors.Add($Message)
        Write-Host "[llm-lint] ERROR: $Message" -ForegroundColor Red
    }
    function Write-LlmLintDiagnostic {
        param([string]$Message)
        if ($VerboseOutput) {
            Write-Host "[llm-lint] DIAG: $Message" -ForegroundColor DarkGray
        }
    }
    function Get-LlmLintRelPath {
        param([string]$Path)
        return (Get-LlmRepoRelativePath -RepoRoot $RepoRoot -Path $Path)
    }
    function Resolve-LlmLintFile {
        param([string]$Path)
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            return $null
        }
        try {
            $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop | Select-Object -First 1
            if ($null -eq $resolved) { return $null }
            return [System.IO.Path]::GetFullPath($resolved.ProviderPath)
        } catch {
            Add-LlmLintError "Failed to resolve file path '$Path': $($_.Exception.Message)"
            return $null
        }
    }
    function Add-LlmLintTrackedFile {
        param(
            [System.Collections.Generic.Dictionary[string, string]]$Files,
            [string]$Path
        )
        $fullPath = Resolve-LlmLintFile -Path $Path
        if ([string]::IsNullOrWhiteSpace($fullPath)) { return }
        if (-not $Files.ContainsKey($fullPath)) {
            $Files[$fullPath] = $fullPath
        }
    }

    Write-LlmLintDiagnostic "Repo root: $RepoRoot"
    Write-LlmLintDiagnostic "Working directory: $((Get-Location).Path)"
    Write-LlmLintDiagnostic "PowerShell version: $($PSVersionTable.PSVersion)"

    if (-not (Test-Path -LiteralPath $llmDir -PathType Container)) {
        Add-LlmLintError 'Missing .llm directory.'
    }

    $files = [System.Collections.Generic.Dictionary[string, string]]::new()
    if (Test-Path -LiteralPath $llmDir -PathType Container) {
        try {
            Get-ChildItem -LiteralPath $llmDir -Recurse -File | Where-Object {
                $_.Extension -eq '.md'
            } | ForEach-Object {
                Add-LlmLintTrackedFile -Files $files -Path $_.FullName
            }
        } catch {
            Add-LlmLintError "Failed to enumerate markdown files in .llm: $($_.Exception.Message)"
        }
    }

    foreach ($pointerCheck in $pointerChecks) {
        Add-LlmLintTrackedFile -Files $files -Path (Join-Path $RepoRoot $pointerCheck.Path)
    }

    foreach ($path in ($files.Keys | Sort-Object)) {
        try {
            $lineCount = @(Read-LlmFileLines -Path $path).Count
            if ($lineCount -gt $MaxLines) {
                Add-LlmLintError "$(Get-LlmLintRelPath $path): $lineCount lines exceeds max $MaxLines"
            } elseif ($VerboseOutput) {
                Write-Host "[llm-lint] OK: $(Get-LlmLintRelPath $path) ($lineCount lines)"
            }
        } catch {
            Add-LlmLintError "Failed to read $(Get-LlmLintRelPath $path): $($_.Exception.Message)"
        }
    }

    $requiredKeys = @('description', 'triggers', 'category')
    if (Test-Path -LiteralPath $llmDir -PathType Container) {
        try {
            $inventory = @(Get-LlmMarkdownInventory -RepoRoot $RepoRoot)
            foreach ($file in $inventory) {
                if ((Get-LlmRepoRelativePath -RepoRoot $RepoRoot -Path $file.FullName) -eq '.llm/index.md') {
                    continue
                }
                foreach ($key in $requiredKeys) {
                    if (-not $file.Metadata.Contains($key) -or [string]::IsNullOrWhiteSpace($file.Metadata[$key])) {
                        Add-LlmLintError "$(Get-LlmRepoRelativePath -RepoRoot $RepoRoot -Path $file.FullName) missing frontmatter key: $key"
                    }
                }
            }
        } catch {
            Add-LlmLintError "Failed while validating frontmatter metadata: $($_.Exception.Message)"
        }
    }

    foreach ($pointerCheck in $pointerChecks) {
        $path = Join-Path $RepoRoot $pointerCheck.Path
        $exists = Test-Path -LiteralPath $path -PathType Leaf
        Write-LlmLintDiagnostic "pointer '$($pointerCheck.Path)' exists=$exists"
        if (-not $exists) {
            if ($pointerCheck.Required) {
                Add-LlmLintError "Missing pointer file: $($pointerCheck.Path)"
            }
            continue
        }
        try {
            $content = Read-LlmFileText -Path $path
            if (-not [string]::IsNullOrWhiteSpace($pointerCheck.RequiredPattern) -and
                $content -notmatch $pointerCheck.RequiredPattern) {
                $message = "$($pointerCheck.Path) must point to .llm/context.md"
                if ($pointerCheck.Required) {
                    Add-LlmLintError $message
                } else {
                    Write-Host "[llm-lint] WARNING: $message" -ForegroundColor Yellow
                }
            }
        } catch {
            Add-LlmLintError "Failed to read pointer file $($pointerCheck.Path): $($_.Exception.Message)"
        }
    }

    if (-not $SkipGeneratedIndexCheck) {
        try {
            $state = Get-LlmGeneratedContentState -RepoRoot $RepoRoot
            if ($state.Changes.Count -gt 0) {
                Add-LlmLintError "Generated LLM index validation failed (stale: $($state.Changes -join ', '))."
            }
        } catch {
            Add-LlmLintError "Generated LLM index validation failed: $($_.Exception.Message)"
        }
    }

    if (-not $SkipStagingArtifactCheck) {
        if (Get-Command git -ErrorAction SilentlyContinue) {
            $patterns = @(Get-LlmDefaultStrayPatterns)
            try {
                $offenders = @(Get-LlmStrayWorkingTreeArtifacts -RepoRoot $RepoRoot -Patterns $patterns)
                foreach ($artifact in $offenders) {
                    Add-LlmLintError "Stray staging artifact: $($artifact.Path) (patterns: $($patterns -join ', '))"
                }
            } catch {
                Add-LlmLintError $_.Exception.Message
            }
        } else {
            Write-LlmLintDiagnostic 'git not available; skipping staging-artifact check.'
        }
    }

    if (-not $SkipPowerShellParseCheck) {
        if (Get-Command git -ErrorAction SilentlyContinue) {
            Push-Location $RepoRoot
            try {
                $psFiles = @(& git ls-files -- '*.ps1' '*.psm1' '*.psd1')
                if ($LASTEXITCODE -ne 0) {
                    Add-LlmLintError "git ls-files (powershell sources) failed with exit $LASTEXITCODE."
                    $psFiles = @()
                }
            } finally {
                Pop-Location
            }

            foreach ($rel in ($psFiles | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
                $full = Join-Path $RepoRoot $rel
                if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
                $tokens = $null
                $parseErrors = $null
                try {
                    [void][System.Management.Automation.Language.Parser]::ParseFile(
                        $full, [ref]$tokens, [ref]$parseErrors)
                } catch {
                    Add-LlmLintError "PowerShell parse threw for $rel`: $($_.Exception.Message)"
                    continue
                }
                if ($null -ne $parseErrors -and $parseErrors.Count -gt 0) {
                    foreach ($err in $parseErrors) {
                        Add-LlmLintError "PowerShell parse error in $rel`:$($err.Extent.StartLineNumber): $($err.Message)"
                    }
                } else {
                    Write-LlmLintDiagnostic "parse OK: $rel"
                }
            }
        } else {
            Write-LlmLintDiagnostic 'git not available; skipping PowerShell parse check.'
        }
    }

    if ($errors.Count -gt 0) {
        Write-Host "[llm-lint] Diagnostics: repoRoot=$RepoRoot cwd=$((Get-Location).Path)" -ForegroundColor Yellow
        foreach ($pointerCheck in $pointerChecks) {
            $path = Join-Path $RepoRoot $pointerCheck.Path
            $exists = Test-Path -LiteralPath $path -PathType Leaf
            Write-Host "[llm-lint] Pointer status: $($pointerCheck.Path) => $exists" -ForegroundColor Yellow
        }
        Write-Host "[llm-lint] Failed with $($errors.Count) error(s)." -ForegroundColor Red
        return $false
    }

    Write-Host '[llm-lint] All LLM harness checks passed.' -ForegroundColor Green
    return $true
}

Export-ModuleMember -Function `
    Get-LlmRepoRoot, `
    Get-LlmRepoRelativePath, `
    Resolve-LlmGitPath, `
    Read-LlmFileLines, `
    Read-LlmFileText, `
    Read-LlmFrontmatter, `
    Get-LlmFrontmatterValue, `
    Get-LlmMarkdownTitle, `
    Write-LlmTextFile, `
    ConvertTo-LlmNormalizedNewlines, `
    ConvertTo-LlmStrayArtifactPathspecs, `
    Get-LlmStagingArtifacts, `
    Get-LlmStrayWorkingTreeArtifacts, `
    Get-LlmDefaultStrayPatterns, `
    Test-LlmDeletableArtifact, `
    Get-LlmTrackedFileSet, `
    Get-LlmGeneratedContentState, `
    Invoke-LlmIndexGenerator, `
    Invoke-LlmLint `
    -Variable LlmDefaultStrayPatterns
