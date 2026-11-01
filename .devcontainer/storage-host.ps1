#!/usr/bin/env pwsh
#Requires -Version 7.0
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Report', 'PruneBuildCache', 'CleanExtensions', 'RemoveContainer', 'RemoveImage')]
    [string]$Action = 'Report',
    [string]$Builder = '',
    [string]$ContainerId = '',
    [string]$ResourceId = '',
    [string]$ContainerScript = '/workspaces/signal-fish-client-godot/scripts/storage.py',
    [switch]$SessionsClosed,
    [string[]]$VhdPath = @(),
    [switch]$AsJson
)
$ErrorActionPreference = 'Stop'

function Read-Native {
    param([string]$Tool, [string[]]$Arguments)
    if (-not (Get-Command $Tool -ErrorAction SilentlyContinue)) {
        return @{ command = $Tool; exit_code = $null; error = 'Command unavailable' }
    }
    $output = & $Tool @Arguments 2>&1 | Out-String
    return @{ command = "$Tool $($Arguments -join ' ')"; exit_code = $LASTEXITCODE; output = $output.Trim() }
}

$report = [ordered]@{
    measured_utc = [DateTime]::UtcNow.ToString('o')
    accounting = 'Shared layers and filesystem totals overlap. Do not sum categories.'
    context = Read-Native docker @('context', 'show')
    version = Read-Native docker @('version', '--format', '{{json .}}')
    backend = Read-Native docker @('info', '--format', '{{json .Driver}} {{json .DriverStatus}} {{json .DockerRootDir}}')
    objects = Read-Native docker @('system', 'df', '-v')
    containers = Read-Native docker @('ps', '-a', '--size', '--format', '{{.ID}} {{.Names}} {{.Image}} {{.Size}}')
    volumes = Read-Native docker @('volume', 'ls', '--format', '{{.Name}} {{.Driver}}')
    drives = @(Get-PSDrive -PSProvider FileSystem | Select-Object Name, Used, Free)
    wsl_version = Read-Native wsl.exe @('--version')
    wsl_distributions = Read-Native wsl.exe @('--list', '--verbose')
}
$builderArgs = @('buildx')
if ($Builder) { $builderArgs += @('--builder', $Builder) }
$report.builder = Read-Native docker ($builderArgs + @('inspect'))
$report.build_cache = Read-Native docker ($builderArgs + @('du', '--verbose'))
$report.volume_consumers = Read-Native docker @('ps', '-a', '--format', '{{.ID}} {{.Mounts}}')
$report.virtual_disks = @()
if ($IsWindows) {
    if (-not $VhdPath -and $env:LOCALAPPDATA) {
        $directory = Join-Path $env:LOCALAPPDATA 'Docker/wsl'
        if (Test-Path $directory) {
            $VhdPath = @(Get-ChildItem $directory -Recurse -Filter '*.vhdx' -File | ForEach-Object FullName)
        }
    }
    if (-not ('SignalFish.StorageAllocation' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace SignalFish {
    public static class StorageAllocation {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern uint GetCompressedFileSizeW(string name, out uint high);
    }
}
'@
    }
    foreach ($disk in $VhdPath) {
        $item = Get-Item -LiteralPath $disk
        [uint32]$high = 0
        $low = [SignalFish.StorageAllocation]::GetCompressedFileSizeW($item.FullName, [ref]$high)
        $allocated = [uint64]$high * 4294967296 + $low
        $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        $report.virtual_disks += @{
            path = $item.FullName
            file_length = $item.Length
            allocated_bytes = $(if ($low -eq [uint32]::MaxValue -and $errorCode -ne 0) { $null } else { $allocated })
        }
    }
}

if ($Action -eq 'Report' -and $ContainerId) {
    if ($ContainerId -notmatch '^[a-f0-9]{12,64}$') { throw 'Supply one exact ContainerId.' }
    $report.server_cache = Read-Native docker @('exec', $ContainerId, 'python3', $ContainerScript, '--json', 'server-cache')
}

if ($Action -ne 'Report') {
    if ($report.context.exit_code -ne 0) { throw 'Docker context is unavailable.' }
    switch ($Action) {
        'PruneBuildCache' {
            $help = Read-Native docker ($builderArgs + @('prune', '--help'))
            if ($help.output -notmatch '--max-used-space') {
                throw 'This buildx version lacks --max-used-space. Upgrade buildx before pruning.'
            }
            if ($PSCmdlet.ShouldProcess($report.builder.output, 'Prune selected builder cache to 10 GB')) {
                $report.maintenance = Read-Native docker ($builderArgs + @('prune', '--max-used-space', '10GB', '--force'))
            }
        }
        'CleanExtensions' {
            if (-not $SessionsClosed -or $ContainerId -notmatch '^[a-f0-9]{12,64}$') {
                throw 'Supply an exact ContainerId and SessionsClosed after closing all shared VS Code sessions.'
            }
            $running = Read-Native docker @('ps', '-q', '--no-trunc')
            if ($running.exit_code -ne 0) { throw 'Could not enumerate active containers.' }
            foreach ($id in ($running.output -split '\s+' | Where-Object { $_ })) {
                if (-not $id.StartsWith($ContainerId)) { throw 'Stop other containers before shared cache maintenance.' }
            }
            $command = @('exec', '--user', 'root', $ContainerId, 'python3', $ContainerScript, '--json', 'extension-cache')
            $report.extension_preview = Read-Native docker $command
            if ($report.extension_preview.exit_code -ne 0) { throw 'Extension cache preview failed.' }
            if ($PSCmdlet.ShouldProcess('Shared VS Code extension downloads', 'Remove oldest downloads above 2 GiB')) {
                $report.maintenance = Read-Native docker ($command + @('--apply', '--sessions-closed'))
            }
        }
        { $_ -in 'RemoveContainer', 'RemoveImage' } {
            if ($ResourceId -notmatch '^(sha256:)?[a-f0-9]{12,64}$') { throw 'Supply one exact resource ID.' }
            $verb = if ($Action -eq 'RemoveContainer') { 'container' } else { 'image' }
            if ($PSCmdlet.ShouldProcess($ResourceId, "Remove selected $verb without force")) {
                $report.maintenance = Read-Native docker @($verb, 'rm', $ResourceId)
            }
        }
    }
    if ($report.Contains('maintenance') -and $report.maintenance.exit_code -ne 0) {
        throw "Maintenance failed: $($report.maintenance.output)"
    }
    $report.after = Read-Native docker @('system', 'df', '-v')
}
if ($AsJson) { $report | ConvertTo-Json -Depth 12 }
else { $report.GetEnumerator() | ForEach-Object { "$($_.Key): $($_.Value | ConvertTo-Json -Depth 10 -Compress)" } }
