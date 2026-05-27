[CmdletBinding()]
param(
    [int]$MaxLines = 300,
    [switch]$VerboseOutput
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$LlmDir = Join-Path $RepoRoot '.llm'
$errors = New-Object System.Collections.Generic.List[string]

function Add-Error {
    param([string]$Message)
    $errors.Add($Message)
    Write-Host "[llm-lint] ERROR: $Message" -ForegroundColor Red
}

function Add-TrackedFile {
    param(
        [System.Collections.Generic.Dictionary[string, string]]$Files,
        [string]$Path
    )
    if (Test-Path -LiteralPath $Path) {
        $fullPath = (Get-Item -LiteralPath $Path).FullName
        if (-not $Files.ContainsKey($fullPath)) {
            $Files[$fullPath] = $fullPath
        }
    }
}

function Get-RepoRelativePath {
    param([string]$Path)
    return ([System.IO.Path]::GetRelativePath($RepoRoot, $Path)).Replace('\', '/')
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
            $metadata[$Matches[1].Trim().ToLowerInvariant()] = $Matches[2].Trim().Trim('"').Trim("'")
        }
    }
    return $metadata
}

if (-not (Test-Path $LlmDir)) {
    Add-Error 'Missing .llm directory.'
}

$files = [System.Collections.Generic.Dictionary[string, string]]::new()
if (Test-Path $LlmDir) {
    Get-ChildItem -LiteralPath $LlmDir -Recurse -File | Where-Object {
        $_.Extension -eq '.md'
    } | ForEach-Object {
        Add-TrackedFile $files $_.FullName
    }
}

$pointerFiles = @(
    'AGENTS.md',
    'CLAUDE.md',
    'GEMINI.md',
    'CHATGPT.md',
    'CODEX.md',
    'llms.txt',
    '.cursorrules',
    '.windsurfrules',
    '.github/copilot-instructions.md',
    '.cursor/rules/signal-fish-llm-context.mdc'
)

foreach ($pointer in $pointerFiles) {
    Add-TrackedFile $files (Join-Path $RepoRoot $pointer)
}

foreach ($path in $files.Keys) {
    $lineCount = @(Get-Content -LiteralPath $path).Count
    if ($lineCount -gt $MaxLines) {
        Add-Error "$(Get-RepoRelativePath $path): $lineCount lines exceeds max $MaxLines"
    }
    elseif ($VerboseOutput) {
        Write-Host "[llm-lint] OK: $(Get-RepoRelativePath $path) ($lineCount lines)"
    }
}

$requiredKeys = @('description', 'triggers', 'category')
if (Test-Path $LlmDir) {
    Get-ChildItem -LiteralPath $LlmDir -Filter '*.md' -Recurse -File | Where-Object {
        (Get-RepoRelativePath $_.FullName) -ne '.llm/index.md'
    } | ForEach-Object {
        $metadata = Read-Frontmatter $_.FullName
        foreach ($key in $requiredKeys) {
            if (-not $metadata.Contains($key) -or [string]::IsNullOrWhiteSpace($metadata[$key])) {
                Add-Error "$(Get-RepoRelativePath $_.FullName) missing frontmatter key: $key"
            }
        }
    }
}

foreach ($pointer in $pointerFiles) {
    $path = Join-Path $RepoRoot $pointer
    if (-not (Test-Path -LiteralPath $path)) {
        Add-Error "Missing pointer file: $pointer"
        continue
    }
    $content = Get-Content -LiteralPath $path -Raw
    if ($content -notmatch '\.llm/context\.md') {
        Add-Error "$pointer must point to .llm/context.md"
    }
}

& (Join-Path $PSScriptRoot 'generate-llm-index.ps1') -Check
if ($LASTEXITCODE -ne 0) {
    Add-Error 'Generated LLM index is stale.'
}

if ($errors.Count -gt 0) {
    Write-Host "[llm-lint] Failed with $($errors.Count) error(s)." -ForegroundColor Red
    exit 1
}

Write-Host '[llm-lint] All LLM harness checks passed.' -ForegroundColor Green

