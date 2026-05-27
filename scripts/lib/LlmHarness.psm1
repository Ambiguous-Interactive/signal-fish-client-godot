Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Shared helpers used by generate-llm-index.ps1, lint-llm.ps1, and
# run-llm-hooks.ps1. Centralizing them keeps the generator and linter from
# drifting on frontmatter parsing, path handling, or repo-root discovery.

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

Export-ModuleMember -Function `
    Get-LlmRepoRoot, `
    Get-LlmRepoRelativePath, `
    Read-LlmFileLines, `
    Read-LlmFileText, `
    Read-LlmFrontmatter, `
    Get-LlmFrontmatterValue, `
    Get-LlmMarkdownTitle, `
    Write-LlmTextFile, `
    ConvertTo-LlmNormalizedNewlines
