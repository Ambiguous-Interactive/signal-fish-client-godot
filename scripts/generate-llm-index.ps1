[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$VerboseOutput
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$LlmDir = Join-Path $RepoRoot '.llm'
$ContextPath = Join-Path $LlmDir 'context.md'
$IndexPath = Join-Path $LlmDir 'index.md'
$StartMarker = '<!-- LLM-INDEX:START -->'
$EndMarker = '<!-- LLM-INDEX:END -->'

function Write-Info {
    param([string]$Message)
    if ($VerboseOutput) {
        Write-Host "[llm-index] $Message"
    }
}

function ConvertTo-LlmRelativePath {
    param([string]$Path)
    $relative = [System.IO.Path]::GetRelativePath($LlmDir, $Path)
    return $relative.Replace('\', '/')
}

function Read-Frontmatter {
    param([string]$Path)
    $metadata = [ordered]@{}
    $lines = @(Get-Content -LiteralPath $Path)
    if ($lines.Count -lt 3 -or $lines[0] -ne '---') {
        return $metadata
    }

    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -eq '---') {
            break
        }
        if ($lines[$i] -match '^\s*([A-Za-z0-9_-]+):\s*(.*?)\s*$') {
            $key = $Matches[1].Trim().ToLowerInvariant()
            $value = $Matches[2].Trim().Trim('"').Trim("'")
            $metadata[$key] = $value
        }
    }
    return $metadata
}

function Get-Title {
    param([string]$Path)
    foreach ($line in @(Get-Content -LiteralPath $Path)) {
        if ($line -match '^#\s+(.+)$') {
            return $Matches[1].Trim()
        }
    }
    return [System.IO.Path]::GetFileNameWithoutExtension($Path)
}

function Get-MetadataValue {
    param(
        [hashtable]$Metadata,
        [string]$Key,
        [string]$Fallback
    )
    if ($Metadata.Contains($Key) -and -not [string]::IsNullOrWhiteSpace($Metadata[$Key])) {
        return $Metadata[$Key]
    }
    return $Fallback
}

function New-IndexLines {
    $skillRoot = Join-Path $LlmDir 'skills'
    $skillFiles = @()
    if (Test-Path $skillRoot) {
        $skillFiles = @(Get-ChildItem -LiteralPath $skillRoot -Filter '*.md' -Recurse -File | Sort-Object FullName)
    }

    $llmMarkdownFiles = @(Get-ChildItem -LiteralPath $LlmDir -Filter '*.md' -Recurse -File | Sort-Object FullName)
    $otherFiles = @($llmMarkdownFiles | Where-Object {
        $relative = ConvertTo-LlmRelativePath $_.FullName
        $relative -ne 'context.md' -and
        $relative -ne 'index.md' -and
        -not $relative.StartsWith('skills/')
    })

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# LLM Context Index')
    $lines.Add('')
    $lines.Add('Generated Markdown inventory by `scripts/generate-llm-index.ps1`; do not edit by hand.')
    $lines.Add('')
    $lines.Add('## Skills')
    $lines.Add('')

    if ($skillFiles.Count -eq 0) {
        $lines.Add('- No skill files found.')
    }
    else {
        foreach ($file in $skillFiles) {
            $metadata = Read-Frontmatter $file.FullName
            $relative = ConvertTo-LlmRelativePath $file.FullName
            $title = Get-Title $file.FullName
            $category = Get-MetadataValue $metadata 'category' 'Uncategorized'
            $description = Get-MetadataValue $metadata 'description' 'No description.'
            $triggers = Get-MetadataValue $metadata 'triggers' 'No triggers.'
            $lines.Add("- [$title]($relative) (``$category``) - $description")
            $lines.Add("  Triggers: $triggers")
        }
    }

    $lines.Add('')
    $lines.Add('## Other LLM Files')
    $lines.Add('')

    if ($otherFiles.Count -eq 0) {
        $lines.Add('- No additional LLM files found.')
    }
    else {
        foreach ($file in $otherFiles) {
            $metadata = Read-Frontmatter $file.FullName
            $relative = ConvertTo-LlmRelativePath $file.FullName
            $title = Get-Title $file.FullName
            $description = Get-MetadataValue $metadata 'description' 'No description.'
            $lines.Add("- [$title]($relative) - $description")
        }
    }

    return $lines
}

function New-EmbeddedLines {
    $indexLines = @(New-IndexLines)
    $skillsIndex = [Array]::IndexOf($indexLines, '## Skills')
    if ($skillsIndex -lt 0) {
        return $indexLines
    }
    return @($indexLines[$skillsIndex..($indexLines.Count - 1)])
}

function Join-Lines {
    param([string[]]$Lines)
    return (($Lines -join "`n") + "`n")
}

function Write-TextFile {
    param(
        [string]$Path,
        [string]$Content
    )
    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Normalize-Newlines {
    param([string]$Content)
    return $Content.Replace("`r`n", "`n")
}

if (-not (Test-Path $LlmDir)) {
    throw "Missing .llm directory at $LlmDir"
}
if (-not (Test-Path $ContextPath)) {
    throw "Missing context file at $ContextPath"
}

$expectedIndex = Join-Lines (New-IndexLines)
$embedded = (Join-Lines (New-EmbeddedLines)).TrimEnd()
$context = Get-Content -LiteralPath $ContextPath -Raw
$start = $context.IndexOf($StartMarker)
$end = $context.IndexOf($EndMarker)
if ($start -lt 0 -or $end -lt 0 -or $end -lt $start) {
    throw "context.md must contain $StartMarker and $EndMarker markers"
}
$prefix = $context.Substring(0, $start)
$suffix = $context.Substring($end + $EndMarker.Length)
$expectedContext = "$prefix$StartMarker`n$embedded`n$EndMarker$suffix"

$changes = New-Object System.Collections.Generic.List[string]
if (-not (Test-Path $IndexPath) -or
    (Normalize-Newlines (Get-Content -LiteralPath $IndexPath -Raw)) -ne (Normalize-Newlines $expectedIndex)) {
    $changes.Add('.llm/index.md')
}
if ((Normalize-Newlines $context) -ne (Normalize-Newlines $expectedContext)) {
    $changes.Add('.llm/context.md')
}

if ($Check) {
    if ($changes.Count -gt 0) {
        Write-Host '[llm-index] Generated LLM index is stale:' -ForegroundColor Red
        $changes | ForEach-Object { Write-Host " - $_" -ForegroundColor Red }
        Write-Host 'Run: pwsh -NoProfile -File scripts/generate-llm-index.ps1' -ForegroundColor Yellow
        exit 1
    }
    Write-Info 'Generated files are up to date.'
    exit 0
}

Write-TextFile $IndexPath $expectedIndex
Write-TextFile $ContextPath $expectedContext
Write-Host '[llm-index] Generated .llm/index.md and updated .llm/context.md'

