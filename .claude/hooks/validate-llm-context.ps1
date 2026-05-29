#!/usr/bin/env pwsh
# PostToolUse hook: when the agent writes / edits a `.llm/**/*.md` file,
# run a FAST per-file structural check so any regression is surfaced
# immediately as tool_result JSON. The agent self-corrects on the next
# turn. This avoids the slow loop of "edit -> commit -> hook fails".
#
# Performance budget: under 1 second cold-start. This hook MUST NOT
# regenerate the LLM index or run the full harness self-tests; those run
# in the slower Stop hook / commit path.
#
# Contract:
#   - Reads tool_input JSON from stdin.
#   - If tool_input.file_path is inside this repo, under `.llm/`, and ends
#     with `.md`, validate it: required frontmatter keys present, line
#     count <= 300, file is parseable as UTF-8 text.
#   - On failure: emit stdout JSON {"decision":"block","reason":...} and
#     exit 2 so the model sees structured tool_result and self-corrects.
#   - Otherwise: exit 0 silently.
#
# Cross-platform pwsh-only.

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Self-parse guard so a corrupted hook does not silently disable itself.
$selfTokens = $null
$selfErrors = $null
try {
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $PSCommandPath, [ref]$selfTokens, [ref]$selfErrors)
} catch { exit 0 }
if ($null -ne $selfErrors -and $selfErrors.Count -gt 0) { exit 0 }

function Get-RepoRoot {
    # Prefer $env:CLAUDE_PROJECT_DIR (Claude Code sets this to the absolute
    # project root). Fall back to walking up from this script until we find
    # a `.git` entry.
    if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_PROJECT_DIR) -and
        (Test-Path -LiteralPath $env:CLAUDE_PROJECT_DIR -PathType Container)) {
        return ([System.IO.Path]::GetFullPath($env:CLAUDE_PROJECT_DIR)).TrimEnd(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar)
    }
    $dir = Split-Path -Parent $PSCommandPath
    while (-not [string]::IsNullOrWhiteSpace($dir)) {
        if (Test-Path -LiteralPath (Join-Path $dir '.git')) {
            return ([System.IO.Path]::GetFullPath($dir)).TrimEnd(
                [System.IO.Path]::DirectorySeparatorChar,
                [System.IO.Path]::AltDirectorySeparatorChar)
        }
        $parent = Split-Path -Parent $dir
        if ($parent -eq $dir) { break }
        $dir = $parent
    }
    return $null
}

function Send-BlockReason {
    param([string]$Reason)
    # Intentionally duplicated from `.claude/hooks/parse-check-powershell.ps1`.
    # Hook scripts MUST be self-contained to avoid a bootstrap circular
    # dependency: if a shared helper module were corrupted, the very
    # hooks meant to diagnose corruption would themselves fail to load.
    # Keep these two copies in sync by convention.
    $blockResponse = [pscustomobject]@{
        decision = 'block'
        reason   = $Reason
    }
    [System.Console]::Out.WriteLine(($blockResponse | ConvertTo-Json -Compress))
    exit 2
}

$raw = [System.Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }

$hookInput = $null
try { $hookInput = $raw | ConvertFrom-Json -ErrorAction Stop } catch { exit 0 }
if ($null -eq $hookInput -or -not ($hookInput.PSObject.Properties.Name -contains 'tool_input')) {
    exit 0
}
# Defensive matcher: trust but verify the upstream matcher. Same shape
# as parse-check-powershell.ps1 so a misconfigured settings.json cannot
# route an unexpected tool here.
if ($hookInput.PSObject.Properties.Name -contains 'tool_name' -and
    $hookInput.tool_name -notin @('Write', 'Edit', 'MultiEdit')) {
    exit 0
}
$filePath = $hookInput.tool_input.file_path
if ([string]::IsNullOrWhiteSpace($filePath)) { exit 0 }

# Normalize separators for the per-segment check.
$normalized = ($filePath -replace '\\', '/')
if ($normalized -notmatch '(^|/)\.llm/.*\.md$') { exit 0 }

# Gate on $CLAUDE_PROJECT_DIR (or auto-resolved repo root): a path that
# does not live inside THIS repo is not our business.
$repoRoot = Get-RepoRoot
if ([string]::IsNullOrWhiteSpace($repoRoot)) { exit 0 }
try {
    $fullPath = [System.IO.Path]::GetFullPath($filePath)
} catch {
    exit 0
}
$repoPrefix = $repoRoot + [System.IO.Path]::DirectorySeparatorChar
$pathComparison = if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
        [System.Runtime.InteropServices.OSPlatform]::Windows)) {
    [System.StringComparison]::OrdinalIgnoreCase
} else {
    [System.StringComparison]::Ordinal
}
if (-not ($fullPath.StartsWith($repoPrefix, $pathComparison) -or
        $fullPath.Equals($repoRoot, $pathComparison))) {
    # Path is not inside this repo; exit silently.
    exit 0
}

if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { exit 0 }

# Fast structural validation. Avoid the full harness self-test suite to
# keep cold-start under 1s.
$modulePath = Join-Path $repoRoot 'scripts/lib/LlmHarness.psm1'
if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
    # No shared module in this checkout; do not block.
    exit 0
}
try {
    Import-Module $modulePath -Force -ErrorAction Stop
} catch {
    # Module failed to import; do not block on a harness bug.
    exit 0
}

$relative = ($fullPath.Substring($repoRoot.Length).TrimStart(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar) -replace '\\', '/')

# The generated index file is exempt from frontmatter requirements but
# still must respect the line limit.
$isGeneratedIndex = ($relative -eq '.llm/index.md')

try {
    $lines = @(Get-Content -LiteralPath $fullPath -ErrorAction Stop)
} catch {
    Send-BlockReason "${relative}: failed to read file: $($_.Exception.Message)"
}

$maxLines = 300
if ($lines.Count -gt $maxLines) {
    Send-BlockReason "${relative}: $($lines.Count) lines exceeds max $maxLines. Split the file into focused skills or move detail to .llm/research."
}

if (-not $isGeneratedIndex) {
    try {
        $metadata = Read-LlmFrontmatter -Path $fullPath
    } catch {
        Send-BlockReason "${relative}: frontmatter parse failed: $($_.Exception.Message)"
    }
    $required = @('description', 'triggers', 'category')
    $missing = @()
    foreach ($key in $required) {
        if (-not $metadata.Contains($key) -or [string]::IsNullOrWhiteSpace($metadata[$key])) {
            $missing += $key
        }
    }
    if ($missing.Count -gt 0) {
        Send-BlockReason "${relative}: missing required frontmatter keys: $($missing -join ', '). Add a YAML --- block at the top with description/triggers/category."
    }
}

exit 0
