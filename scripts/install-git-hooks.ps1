[CmdletBinding()]
param(
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$hooksPath = Join-Path $repoRoot '.githooks'
$desiredHooksPath = '.githooks'

function ConvertTo-FullHooksPath {
    param([string]$ConfiguredPath)

    if ([string]::IsNullOrWhiteSpace($ConfiguredPath)) {
        return ''
    }

    if ([System.IO.Path]::IsPathRooted($ConfiguredPath)) {
        $fullPath = [System.IO.Path]::GetFullPath($ConfiguredPath)
    }
    else {
        $fullPath = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $ConfiguredPath))
    }

    $trimChars = [char[]]@(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    return $fullPath.TrimEnd($trimChars)
}

if (-not (Test-Path $hooksPath)) {
    throw "Missing hooks directory: $hooksPath"
}

Push-Location $repoRoot
try {
    $existingHooksPath = (@(git config --get core.hooksPath 2>$null) | Select-Object -First 1)
    if ($null -eq $existingHooksPath) {
        $existingHooksPath = ''
    }

    $configuredPath = ConvertTo-FullHooksPath $existingHooksPath
    $expectedPath = ConvertTo-FullHooksPath $desiredHooksPath

    if (-not [string]::IsNullOrWhiteSpace($existingHooksPath) -and
        $configuredPath -ne $expectedPath -and
        -not $Force) {
        throw "Refusing to overwrite existing core.hooksPath '$existingHooksPath'. Re-run with -Force to replace it with $desiredHooksPath."
    }

    git config core.hooksPath $desiredHooksPath
    Write-Host '[llm-hooks] Git hooks installed from .githooks'
}
finally {
    Pop-Location
}

