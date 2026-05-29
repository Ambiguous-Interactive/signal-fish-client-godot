[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$VerboseOutput
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'lib/LlmHarness.psm1') -Force

$repoRoot = Get-LlmRepoRoot -ScriptRoot $PSScriptRoot
$ok = Invoke-LlmIndexGenerator -RepoRoot $repoRoot -Check:$Check -VerboseOutput:$VerboseOutput
if ($ok) {
    exit 0
}
exit 1
