[CmdletBinding()]
param(
    [switch]$VerboseOutput
)

# Lightweight self-tests for the shared LLM harness library.
#
# Goals:
#   - Prevent regressions in frontmatter parsing edge cases (closed/unclosed
#     fences, quoted values, mixed casing, blank lines, BOM).
#   - Catch drift between generator and linter (both must import the same
#     module).
#   - Provide an executable spec so future contributors see exactly what is
#     guaranteed.
#
# This avoids a Pester dependency to keep the harness portable across
# minimal pwsh installs.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptsDir = $PSScriptRoot
$ModulePath = Join-Path $ScriptsDir 'lib/LlmHarness.psm1'
Import-Module $ModulePath -Force

$failures = New-Object System.Collections.Generic.List[string]
$passed = 0

function Assert-Test {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Body
    )
    try {
        & $Body
        $script:passed++
        if ($VerboseOutput) {
            Write-Host "[llm-test] PASS: $Name" -ForegroundColor Green
        }
    } catch {
        $script:failures.Add("$Name -> $($_.Exception.Message)")
        Write-Host "[llm-test] FAIL: $Name -> $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Expect-Equal {
    param($Actual, $Expected, [string]$Because = '')
    if ($Actual -ne $Expected) {
        throw "Expected '$Expected' but got '$Actual'. $Because"
    }
}

function New-TempFile {
    param([string]$Content)
    $path = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "llm-harness-test-$([Guid]::NewGuid()).md")
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Content)
    [System.IO.File]::WriteAllBytes($path, $bytes)
    return $path
}

# --- Read-LlmFrontmatter ---------------------------------------------------

Assert-Test 'frontmatter: parses standard block' {
    $path = New-TempFile "---`ndescription: Hello`ntriggers: a, b`ncategory: Core`n---`n# Title`n"
    try {
        $meta = Read-LlmFrontmatter -Path $path
        Expect-Equal $meta['description'] 'Hello'
        Expect-Equal $meta['triggers'] 'a, b'
        Expect-Equal $meta['category'] 'Core'
    } finally { Remove-Item -LiteralPath $path -Force }
}

Assert-Test 'frontmatter: strips surrounding quotes' {
    $path = New-TempFile "---`ndescription: `"quoted`"`ntriggers: 'single'`ncategory: X`n---`n"
    try {
        $meta = Read-LlmFrontmatter -Path $path
        Expect-Equal $meta['description'] 'quoted'
        Expect-Equal $meta['triggers'] 'single'
    } finally { Remove-Item -LiteralPath $path -Force }
}

Assert-Test 'frontmatter: lowercases keys' {
    $path = New-TempFile "---`nDescription: x`nTRIGGERS: y`nCategory: z`n---`n"
    try {
        $meta = Read-LlmFrontmatter -Path $path
        Expect-Equal $meta['description'] 'x'
        Expect-Equal $meta['triggers'] 'y'
        Expect-Equal $meta['category'] 'z'
    } finally { Remove-Item -LiteralPath $path -Force }
}

Assert-Test 'frontmatter: returns empty when no opening fence' {
    $path = New-TempFile "# Title`ndescription: nope`n"
    try {
        $meta = Read-LlmFrontmatter -Path $path
        Expect-Equal $meta.Count 0
    } finally { Remove-Item -LiteralPath $path -Force }
}

Assert-Test 'frontmatter: returns empty when closing fence missing' {
    $path = New-TempFile "---`ndescription: orphan`ntriggers: x`n"
    try {
        $meta = Read-LlmFrontmatter -Path $path
        Expect-Equal $meta.Count 0 'Unclosed frontmatter must be treated as no frontmatter to avoid silent acceptance.'
    } finally { Remove-Item -LiteralPath $path -Force }
}

Assert-Test 'frontmatter: returns empty for too-short files' {
    $path = New-TempFile "---`n---`n"
    try {
        $meta = Read-LlmFrontmatter -Path $path
        Expect-Equal $meta.Count 0
    } finally { Remove-Item -LiteralPath $path -Force }
}

# --- Get-LlmFrontmatterValue ----------------------------------------------

Assert-Test 'frontmatter value: returns fallback for missing key' {
    $meta = [ordered]@{ 'a' = 'x' }
    Expect-Equal (Get-LlmFrontmatterValue -Metadata $meta -Key 'b' -Fallback 'fb') 'fb'
}

Assert-Test 'frontmatter value: returns fallback for whitespace' {
    $meta = [ordered]@{ 'a' = '   ' }
    Expect-Equal (Get-LlmFrontmatterValue -Metadata $meta -Key 'a' -Fallback 'fb') 'fb'
}

# --- Generator + Linter both import the same module -----------------------

Assert-Test 'generator imports shared module' {
    $content = Get-Content -LiteralPath (Join-Path $ScriptsDir 'generate-llm-index.ps1') -Raw
    if ($content -notmatch 'lib/LlmHarness\.psm1') {
        throw 'generate-llm-index.ps1 must import lib/LlmHarness.psm1'
    }
    if ($content -match '(?m)^\s*function\s+Read-Frontmatter\b') {
        throw 'generate-llm-index.ps1 must not redefine Read-Frontmatter locally.'
    }
}

Assert-Test 'linter imports shared module' {
    $content = Get-Content -LiteralPath (Join-Path $ScriptsDir 'lint-llm.ps1') -Raw
    if ($content -notmatch 'lib/LlmHarness\.psm1') {
        throw 'lint-llm.ps1 must import lib/LlmHarness.psm1'
    }
    if ($content -match '(?m)^\s*function\s+Read-Frontmatter\b') {
        throw 'lint-llm.ps1 must not redefine Read-Frontmatter locally.'
    }
}

# --- Hook scripts present and consistent -----------------------------------

Assert-Test 'pre-commit shim exists and delegates to run-llm-hooks.ps1' {
    $shim = Join-Path (Split-Path -Parent $ScriptsDir) '.githooks/pre-commit'
    if (-not (Test-Path -LiteralPath $shim -PathType Leaf)) {
        throw 'Missing .githooks/pre-commit'
    }
    $content = Get-Content -LiteralPath $shim -Raw
    if ($content -notmatch 'run-llm-hooks\.ps1') {
        throw '.githooks/pre-commit must delegate to scripts/run-llm-hooks.ps1'
    }
}

Assert-Test 'pre-commit.ps1 mirror exists and delegates to run-llm-hooks.ps1' {
    $mirror = Join-Path (Split-Path -Parent $ScriptsDir) '.githooks/pre-commit.ps1'
    if (-not (Test-Path -LiteralPath $mirror -PathType Leaf)) {
        throw 'Missing .githooks/pre-commit.ps1'
    }
    $content = Get-Content -LiteralPath $mirror -Raw
    if ($content -notmatch 'run-llm-hooks\.ps1') {
        throw '.githooks/pre-commit.ps1 must delegate to scripts/run-llm-hooks.ps1'
    }
}

Assert-Test 'run-llm-hooks.ps1 exists' {
    $entry = Join-Path $ScriptsDir 'run-llm-hooks.ps1'
    if (-not (Test-Path -LiteralPath $entry -PathType Leaf)) {
        throw 'Missing scripts/run-llm-hooks.ps1'
    }
}

# --- Summary ---------------------------------------------------------------

if ($failures.Count -gt 0) {
    Write-Host "[llm-test] $($failures.Count) test(s) failed; $passed passed." -ForegroundColor Red
    exit 1
}

Write-Host "[llm-test] All $passed test(s) passed." -ForegroundColor Green
exit 0
