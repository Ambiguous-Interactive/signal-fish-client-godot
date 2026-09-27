$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $repoRoot
Import-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -ErrorAction Stop

# CLI output and names, internal mutation helpers, and dynamic harness fixtures
# make these rules noisy without finding defects. Keep every other default rule.
$excludedRules = @(
    'PSAvoidUsingWriteHost',
    'PSUseSingularNouns',
    'PSUseShouldProcessForStateChangingFunctions',
    'PSUseBOMForUnicodeEncodedFile',
    'PSReviewUnusedParameter',
    'PSUseDeclaredVarsMoreThanAssignments',
    'PSUseApprovedVerbs'
)
$paths = @(git ls-files -- '*.ps1' '*.psm1' '*.psd1')
if ($LASTEXITCODE -ne 0) { throw 'Could not list PowerShell files.' }
$findings = [System.Collections.Generic.List[string]]::new()
foreach ($path in $paths) {
    $diagnostics = @(Invoke-ScriptAnalyzer -Path $path -Severity Error, Warning -ExcludeRule $excludedRules)
    foreach ($diagnostic in $diagnostics) {
        $findings.Add("{0}:{1} [{2}] {3}" -f $path, $diagnostic.Line, $diagnostic.RuleName, $diagnostic.Message)
    }
}
if ($findings.Count -gt 0) {
    $findings | ForEach-Object { Write-Output $_ }
    exit 1
}
Write-Output 'PowerShell analysis passed.'
