param(
    [switch]$Write
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $repoRoot
Import-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -ErrorAction Stop

$paths = @(git ls-files -- '*.ps1' '*.psm1' '*.psd1')
if ($LASTEXITCODE -ne 0) { throw 'Could not list PowerShell files.' }
$failed = $false
foreach ($path in $paths) {
    $fullPath = Join-Path $repoRoot $path
    $original = [System.IO.File]::ReadAllText($fullPath)
    $formatted = Invoke-Formatter -ScriptDefinition $original
    if ($formatted -eq $original) { continue }
    if ($Write) {
        [System.IO.File]::WriteAllText($fullPath, $formatted)
        Write-Output "Formatted $path"
    }
    else {
        Write-Error "Formatting needed: $path" -ErrorAction Continue
        $failed = $true
    }
}
if ($failed) { exit 1 }
