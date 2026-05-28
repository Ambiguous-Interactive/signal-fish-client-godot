[CmdletBinding()]
param(
    [int]$MaxLines = 300,
    [switch]$VerboseOutput
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'lib/LlmHarness.psm1') -Force

$RepoRoot = Get-LlmRepoRoot -ScriptRoot $PSScriptRoot
$LlmDir = Join-Path $RepoRoot '.llm'
$errors = New-Object System.Collections.Generic.List[string]

$pointerChecks = @(
    [PSCustomObject]@{ Path = 'AGENTS.md'; Required = $true; RequiredPattern = '\.llm/context\.md' },
    [PSCustomObject]@{ Path = 'CLAUDE.md'; Required = $true; RequiredPattern = '\.llm/context\.md' },
    [PSCustomObject]@{ Path = 'GEMINI.md'; Required = $true; RequiredPattern = '\.llm/context\.md' },
    [PSCustomObject]@{ Path = 'CHATGPT.md'; Required = $true; RequiredPattern = '\.llm/context\.md' },
    [PSCustomObject]@{ Path = 'CODEX.md'; Required = $true; RequiredPattern = '\.llm/context\.md' },
    [PSCustomObject]@{ Path = 'llms.txt'; Required = $true; RequiredPattern = '\.llm/context\.md' },
    [PSCustomObject]@{ Path = '.cursorrules'; Required = $true; RequiredPattern = '\.llm/context\.md' },
    [PSCustomObject]@{ Path = '.windsurfrules'; Required = $true; RequiredPattern = '\.llm/context\.md' },
    [PSCustomObject]@{ Path = '.github/copilot-instructions.md'; Required = $true; RequiredPattern = '\.llm/context\.md' },
    [PSCustomObject]@{ Path = '.cursor/rules/signal-fish-llm-context.mdc'; Required = $true; RequiredPattern = '\.llm/context\.md' }
)

function Add-Error {
    param([string]$Message)
    $errors.Add($Message)
    Write-Host "[llm-lint] ERROR: $Message" -ForegroundColor Red
}

function Write-Diagnostic {
    param([string]$Message)
    if ($VerboseOutput) {
        Write-Host "[llm-lint] DIAG: $Message" -ForegroundColor DarkGray
    }
}

function Get-RelPath {
    param([string]$Path)
    return (Get-LlmRepoRelativePath -RepoRoot $RepoRoot -Path $Path)
}

function Try-ResolveFilePath {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    try {
        $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop | Select-Object -First 1
        if ($null -eq $resolved) {
            return $null
        }
        return [System.IO.Path]::GetFullPath($resolved.ProviderPath)
    }
    catch {
        Add-Error "Failed to resolve file path '$Path': $($_.Exception.Message)"
        return $null
    }
}

function Add-TrackedFile {
    param(
        [System.Collections.Generic.Dictionary[string, string]]$Files,
        [string]$Path
    )
    $fullPath = Try-ResolveFilePath -Path $Path
    if ([string]::IsNullOrWhiteSpace($fullPath)) {
        return
    }
    if (-not $Files.ContainsKey($fullPath)) {
        $Files[$fullPath] = $fullPath
    }
}

function Test-PointerFile {
    param([PSCustomObject]$PointerCheck)

    $path = Join-Path $RepoRoot $PointerCheck.Path
    $exists = Test-Path -LiteralPath $path -PathType Leaf
    Write-Diagnostic "pointer '$($PointerCheck.Path)' exists=$exists"

    if (-not $exists) {
        if ($PointerCheck.Required) {
            Add-Error "Missing pointer file: $($PointerCheck.Path)"
        }
        return
    }

    try {
        $content = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
    }
    catch {
        Add-Error "Failed to read pointer file $($PointerCheck.Path): $($_.Exception.Message)"
        return
    }

    if (-not [string]::IsNullOrWhiteSpace($PointerCheck.RequiredPattern) -and $content -notmatch $PointerCheck.RequiredPattern) {
        $message = "$($PointerCheck.Path) must point to .llm/context.md"
        if ($PointerCheck.Required) {
            Add-Error $message
        }
        else {
            Write-Host "[llm-lint] WARNING: $message" -ForegroundColor Yellow
        }
    }
}

function Invoke-GeneratedIndexCheck {
    $generateScriptPath = Join-Path $PSScriptRoot 'generate-llm-index.ps1'
    if (-not (Test-Path -LiteralPath $generateScriptPath -PathType Leaf)) {
        Add-Error 'Missing generator script: scripts/generate-llm-index.ps1'
        return
    }

    $output = @()
    try {
        $output = @(& pwsh -NoProfile -File "$generateScriptPath" -Check 2>&1)
    }
    catch {
        Add-Error "Failed to execute generated index check: $($_.Exception.Message)"
        return
    }

    if ($LASTEXITCODE -ne 0) {
        Add-Error "Generated LLM index validation failed (exit code: $LASTEXITCODE)."
        foreach ($line in $output) {
            if (-not [string]::IsNullOrWhiteSpace("$line")) {
                Write-Host "[llm-lint] INDEX-CHECK: $line" -ForegroundColor Yellow
            }
        }
    }
}

# Stray staging artifacts (e.g. `*.new`, `*.bak`, `*.orig`, `*.old`) are a
# recurring source of confusion and silent drift: contributors commit a
# `script.ps1.new` alongside a broken `script.ps1`, or leave a `.bak` from a
# manual edit. Fail the lint if any tracked file matches these patterns.
function Invoke-StagingArtifactCheck {
    $patterns = @('*.new', '*.bak', '*.orig', '*.old', '*.rej')
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Diagnostic 'git not available; skipping staging-artifact check.'
        return
    }
    Push-Location $RepoRoot
    try {
        $tracked = @(& git ls-files -- @patterns)
        if ($LASTEXITCODE -ne 0) {
            Add-Error "git ls-files (tracked) failed with exit $LASTEXITCODE."
            return
        }
        $untracked = @(& git ls-files --others --exclude-standard -- @patterns)
        if ($LASTEXITCODE -ne 0) {
            Add-Error "git ls-files (untracked) failed with exit $LASTEXITCODE."
            return
        }
        $offenders = @($tracked + $untracked) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
        foreach ($path in $offenders) {
            Add-Error "Stray staging artifact: $path (patterns: $($patterns -join ', '))"
        }
    }
    finally {
        Pop-Location
    }
}

# Parse every committed PowerShell source file. This catches structural
# regressions like the orphaned-code / undefined-variable failure in
# `install-git-hooks.ps1` *before* a contributor runs the hook for real.
function Invoke-PowerShellParseCheck {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Diagnostic 'git not available; skipping PowerShell parse check.'
        return
    }
    Push-Location $RepoRoot
    try {
        $files = @(& git ls-files -- '*.ps1' '*.psm1' '*.psd1')
        if ($LASTEXITCODE -ne 0) {
            Add-Error "git ls-files (powershell sources) failed with exit $LASTEXITCODE."
            return
        }
    }
    finally {
        Pop-Location
    }

    foreach ($rel in ($files | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $full = Join-Path $RepoRoot $rel
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            # Tracked but deleted in working tree; nothing to parse.
            continue
        }
        $tokens = $null
        $parseErrors = $null
        try {
            [void][System.Management.Automation.Language.Parser]::ParseFile(
                $full, [ref]$tokens, [ref]$parseErrors)
        }
        catch {
            Add-Error "PowerShell parse threw for $rel`: $($_.Exception.Message)"
            continue
        }
        if ($null -ne $parseErrors -and $parseErrors.Count -gt 0) {
            foreach ($err in $parseErrors) {
                Add-Error "PowerShell parse error in $rel`:$($err.Extent.StartLineNumber): $($err.Message)"
            }
        }
        else {
            Write-Diagnostic "parse OK: $rel"
        }
    }
}

Write-Diagnostic "Repo root: $RepoRoot"
Write-Diagnostic "Working directory: $((Get-Location).Path)"
Write-Diagnostic "PowerShell version: $($PSVersionTable.PSVersion)"

if (-not (Test-Path -LiteralPath $LlmDir -PathType Container)) {
    Add-Error 'Missing .llm directory.'
}

$files = [System.Collections.Generic.Dictionary[string, string]]::new()
if (Test-Path -LiteralPath $LlmDir -PathType Container) {
    try {
        Get-ChildItem -LiteralPath $LlmDir -Recurse -File | Where-Object {
            $_.Extension -eq '.md'
        } | ForEach-Object {
            Add-TrackedFile $files $_.FullName
        }
    }
    catch {
        Add-Error "Failed to enumerate markdown files in .llm: $($_.Exception.Message)"
    }
}

foreach ($pointerCheck in $pointerChecks) {
    Add-TrackedFile $files (Join-Path $RepoRoot $pointerCheck.Path)
}

foreach ($path in ($files.Keys | Sort-Object)) {
    $lineCount = 0
    try {
        $lineCount = @(Get-Content -LiteralPath $path -ErrorAction Stop).Count
    }
    catch {
        Add-Error "Failed to read $(Get-RelPath $path): $($_.Exception.Message)"
        continue
    }

    if ($lineCount -gt $MaxLines) {
        Add-Error "$(Get-RelPath $path): $lineCount lines exceeds max $MaxLines"
    }
    elseif ($VerboseOutput) {
        Write-Host "[llm-lint] OK: $(Get-RelPath $path) ($lineCount lines)"
    }
}

$requiredKeys = @('description', 'triggers', 'category')
if (Test-Path -LiteralPath $LlmDir -PathType Container) {
    try {
        Get-ChildItem -LiteralPath $LlmDir -Filter '*.md' -Recurse -File | Where-Object {
            (Get-RelPath $_.FullName) -ne '.llm/index.md'
        } | ForEach-Object {
            $metadata = Read-LlmFrontmatter -Path $_.FullName
            foreach ($key in $requiredKeys) {
                if (-not $metadata.Contains($key) -or [string]::IsNullOrWhiteSpace($metadata[$key])) {
                    Add-Error "$(Get-RelPath $_.FullName) missing frontmatter key: $key"
                }
            }
        }
    }
    catch {
        Add-Error "Failed while validating frontmatter metadata: $($_.Exception.Message)"
    }
}

foreach ($pointerCheck in $pointerChecks) {
    Test-PointerFile -PointerCheck $pointerCheck
}

Invoke-GeneratedIndexCheck
Invoke-StagingArtifactCheck
Invoke-PowerShellParseCheck

if ($errors.Count -gt 0) {
    Write-Host "[llm-lint] Diagnostics: repoRoot=$RepoRoot cwd=$((Get-Location).Path)" -ForegroundColor Yellow
    foreach ($pointerCheck in $pointerChecks) {
        $path = Join-Path $RepoRoot $pointerCheck.Path
        $exists = Test-Path -LiteralPath $path -PathType Leaf
        Write-Host "[llm-lint] Pointer status: $($pointerCheck.Path) => $exists" -ForegroundColor Yellow
    }
    Write-Host "[llm-lint] Failed with $($errors.Count) error(s)." -ForegroundColor Red
    exit 1
}

Write-Host '[llm-lint] All LLM harness checks passed.' -ForegroundColor Green
