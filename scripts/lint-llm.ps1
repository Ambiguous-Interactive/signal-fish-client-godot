[CmdletBinding()]
param(
    [int]$MaxLines = 300,
    [switch]$VerboseOutput
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'lib/LlmHarness.psm1') -Force

$repoRoot = Get-LlmRepoRoot -ScriptRoot $PSScriptRoot
$ok = Invoke-LlmLint -RepoRoot $repoRoot -MaxLines $MaxLines -VerboseOutput:$VerboseOutput
if ($ok) {
    exit 0
}
exit 1
