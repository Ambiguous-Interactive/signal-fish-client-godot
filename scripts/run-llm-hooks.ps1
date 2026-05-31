[CmdletBinding()]
param(
    [ValidateSet('PreCommit', 'AgentFast', 'Full', 'CI')]
    [string]$Mode = 'Full',
    # Skip the staged-files dirty check. Used by wrappers that validate
    # outside a local staging flow.
    [switch]$SkipStagedCheck,
    # Local hooks use AutoFix to stage generated files and remove scoped
    # harness junk. NoAutoFix wins for CI and agent checks.
    [switch]$AutoFix,
    [switch]$NoAutoFix,
    [switch]$VerboseOutput,
    # Print per-stage timings.
    [switch]$Profile,
    # Used by CI after it has already run scripts/preflight.ps1 as a separate
    # loud -NoAutoFix step.
    [switch]$PreflightAlreadyDone
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptsDir = $PSScriptRoot
$RepoRoot = Split-Path -Parent $ScriptsDir
$ModulePath = Join-Path $ScriptsDir 'lib/LlmHarness.psm1'
$SelfTests = Join-Path $ScriptsDir 'test-llm-harness.ps1'
$Preflight = Join-Path $ScriptsDir 'preflight.ps1'
$GithubConfigValidator = Join-Path $ScriptsDir 'validate-github-config.py'
$GeneratedFiles = @('.llm/index.md', '.llm/context.md')
$PointerFiles = @(
    'AGENTS.md', 'CLAUDE.md', 'GEMINI.md', 'CHATGPT.md', 'CODEX.md',
    'llms.txt', '.cursorrules', '.windsurfrules',
    '.github/copilot-instructions.md', '.cursor/rules/signal-fish-llm-context.mdc'
)

$autoFixEnabled = [bool]$AutoFix -and -not $NoAutoFix -and $Mode -notin @('AgentFast', 'CI')
$fastMode = $Mode -in @('PreCommit', 'AgentFast')
$timings = [System.Collections.Generic.List[object]]::new()
$script:generatedFilesWrittenByHook = @()

function Write-HookLine {
    param([string]$Message, [string]$Color = 'Gray')
    Write-Host "[llm-hook] $Message" -ForegroundColor $Color
}

function Invoke-HookStage {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Body
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        & $Body
    } finally {
        $sw.Stop()
        $script:timings.Add([pscustomobject]@{ Name = $Name; Milliseconds = $sw.ElapsedMilliseconds })
        if ($Profile) {
            Write-HookLine ("timing {0}: {1} ms" -f $Name, $sw.ElapsedMilliseconds)
        }
    }
}

function ConvertFrom-GeneratedFileStatusLine {
    param([AllowEmptyString()][string]$Line)

    if ($null -eq $Line) { $Line = '' }
    $index = if ($Line.Length -ge 1) { $Line[0] } else { ' ' }
    $worktree = if ($Line.Length -ge 2) { $Line[1] } else { ' ' }
    $path = if ($Line.Length -ge 4) { $Line.Substring(3) } else { $Line }
    $isUntracked = $index -eq '?' -and $worktree -eq '?'
    $hasIndexChange = -not $isUntracked -and $index -ne ' '
    $hasWorktreeChange = -not $isUntracked -and $worktree -ne ' '
    $needsWorktreeStaging = -not [string]::IsNullOrWhiteSpace($Line) -and
        ($isUntracked -or $hasWorktreeChange)

    return [pscustomobject]@{
        Raw                  = $Line
        Index                = $index
        Worktree             = $worktree
        Path                 = $path
        IsUntracked          = $isUntracked
        HasIndexChange       = $hasIndexChange
        HasWorktreeChange    = $hasWorktreeChange
        NeedsWorktreeStaging = $needsWorktreeStaging
    }
}

function Get-ChangedPaths {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        return @()
    }
    Push-Location $RepoRoot
    try {
        if ($SkipStagedCheck) {
            $raw = @(& git diff --name-only -z 2>$null)
            if ($LASTEXITCODE -ne 0) { return @() }
            $cachedRaw = @(& git diff --cached --name-only -z 2>$null)
            if ($LASTEXITCODE -eq 0) {
                $raw += $cachedRaw
            }
            $untrackedRaw = @(& git ls-files --others --exclude-standard -z 2>$null)
            if ($LASTEXITCODE -eq 0) {
                $raw += $untrackedRaw
            }
        } else {
            $raw = @(& git diff --cached --name-only -z 2>$null)
            if ($LASTEXITCODE -ne 0) { return @() }
        }
    } finally {
        Pop-Location
    }
    $joined = ($raw -join '')
    return @($joined -split "`0" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { ($_ -replace '\\', '/') })
}

function Test-LlmPathTouched {
    param([string[]]$Paths)
    foreach ($path in $Paths) {
        if ($path.StartsWith('.llm/') -or $PointerFiles -contains $path) {
            return $true
        }
    }
    return $false
}

function Test-ToolingPathTouched {
    param([string[]]$Paths)
    foreach ($path in $Paths) {
        if ($path.StartsWith('scripts/') -or
            $path.StartsWith('.githooks/') -or
            $path.StartsWith('.github/workflows/') -or
            $path.StartsWith('.devcontainer/') -or
            $path.StartsWith('.claude/') -or
            $path -in @(
                '.pre-commit-config.yaml',
                '.gitattributes',
                '.gitignore',
                '.github/dependabot.yml',
                '.github/dependabot.yaml',
                'requirements-automation.txt'
            )) {
            return $true
        }
    }
    return $false
}

function Test-GitHubConfigPathTouched {
    param([string[]]$Paths)
    foreach ($path in $Paths) {
        if ($path.StartsWith('.github/workflows/') -or
            $path -in @(
                '.github/dependabot.yml',
                '.github/dependabot.yaml',
                'scripts/dependabot-auto-merge.sh',
                'scripts/validate-github-config.py',
                'requirements-automation.txt'
            )) {
            return $true
        }
    }
    return $false
}

function Test-MinimalGeneratedSanity {
    foreach ($generated in $GeneratedFiles) {
        $full = Join-Path $RepoRoot $generated
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            Write-HookLine "Missing generated file: $generated" 'Red'
            return $false
        }
    }
    $context = [System.IO.File]::ReadAllText((Join-Path $RepoRoot '.llm/context.md'))
    if ($context -notmatch '<!-- LLM-INDEX:START -->' -or $context -notmatch '<!-- LLM-INDEX:END -->') {
        Write-HookLine 'Generated context markers are missing.' 'Red'
        return $false
    }
    return $true
}

function Invoke-PreflightIfNeeded {
    param([switch]$Required)
    if (-not $Required) { return }

    $skipPreflight = [bool]$PreflightAlreadyDone
    if ($skipPreflight) {
        Write-HookLine 'Skipping preflight (PreflightAlreadyDone; already run by outer wrapper).'
        return
    }

    $preflightTokens = $null
    $preflightErrors = $null
    try {
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $Preflight, [ref]$preflightTokens, [ref]$preflightErrors)
    } catch {
        Write-HookLine "Failed to parse-check preflight.ps1: $($_.Exception.Message)" 'Red'
        exit 1
    }
    if ($null -ne $preflightErrors -and $preflightErrors.Count -gt 0) {
        Write-HookLine 'preflight.ps1 has parse errors:' 'Red'
        foreach ($e in $preflightErrors) {
            Write-HookLine "  preflight.ps1:$($e.Extent.StartLineNumber): $($e.Message)" 'Red'
        }
        if ($autoFixEnabled -and (Get-Command git -ErrorAction SilentlyContinue)) {
            $backupPath = New-HookRecoveryBackup -RelativePath 'scripts/preflight.ps1'
            if ([string]::IsNullOrWhiteSpace($backupPath)) {
                Write-HookLine 'AutoFix: refusing to restore scripts/preflight.ps1 without a recovery backup.' 'Red'
                exit 1
            }
            Restore-HookPowerShellFileFromGit `
                -RelativePath 'scripts/preflight.ps1' `
                -FullPath $Preflight `
                -BackupPath $backupPath
        } else {
            Write-HookLine 'Re-run with -AutoFix to recover from the index first, then HEAD fallback, with backups preserved.' 'Yellow'
            exit 1
        }
    }

    Write-HookLine 'Running preflight (parse-check toolkit sources)...'
    $preArgs = @('-NoProfile', '-File', $Preflight)
    if ($autoFixEnabled) { $preArgs += '-AutoFix' } else { $preArgs += '-NoAutoFix' }
    if ($VerboseOutput) { $preArgs += '-VerboseOutput' }
    & pwsh @preArgs
    $preExit = $LASTEXITCODE
    if ($preExit -eq 1) {
        Write-HookLine 'Preflight reported unrecoverable corruption; aborting.' 'Red'
        exit 1
    }
    if ($preExit -eq 2) {
        Write-HookLine 'Preflight auto-recovered one or more sources. Continuing.' 'Yellow'
    } elseif ($preExit -ne 0) {
        Write-HookLine "Preflight failed with unexpected exit $preExit." 'Red'
        exit $preExit
    }
}

function New-HookRecoveryBackup {
    param([Parameter(Mandatory)][string]$RelativePath)

    $full = Join-Path $RepoRoot $RelativePath
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        return $null
    }
    $stamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $token = "$stamp-$PID-$([Guid]::NewGuid().ToString('N'))"
    $recoveryParent = Resolve-HookGitPath -GitPath 'preflight-recovery'
    $dir = Join-Path $recoveryParent $token
    try {
        if (-not (Test-Path -LiteralPath $recoveryParent -PathType Container)) {
            New-Item -ItemType Directory -Path $recoveryParent -Force -ErrorAction Stop | Out-Null
        }
        New-Item -ItemType Directory -Path $dir -ErrorAction Stop | Out-Null
        $encoded = $RelativePath -replace '[\\/]', '__'
        $backupPath = Join-Path $dir $encoded
        [System.IO.File]::Copy($full, $backupPath, $true)
        return $backupPath
    } catch {
        Write-HookLine "AutoFix: failed to back up $RelativePath before restore: $($_.Exception.Message)" 'Red'
        return $null
    }
}

function Copy-HookGitBlobToFile {
    param(
        [Parameter(Mandatory)][string]$Blob,
        [Parameter(Mandatory)][string]$Destination
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'git'
    [void]$psi.ArgumentList.Add('cat-file')
    [void]$psi.ArgumentList.Add('blob')
    [void]$psi.ArgumentList.Add($Blob)
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false

    Push-Location $RepoRoot
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $stream = [System.IO.File]::Open($Destination, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $proc.StandardOutput.BaseStream.CopyTo($stream)
        } finally {
            $stream.Dispose()
        }
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        if ($proc.ExitCode -ne 0) {
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            throw "git cat-file blob $Blob failed with exit $($proc.ExitCode): $stderr"
        }
    } finally {
        Pop-Location
    }
}

function New-HookIndexRecoveryBackup {
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$WorktreeBackupPath
    )

    Push-Location $RepoRoot
    try {
        $stageLine = @(& git ls-files --stage -- $RelativePath 2>&1) | Select-Object -First 1
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($stageLine)) {
            return $null
        }
    } finally {
        Pop-Location
    }
    if ($stageLine -notmatch '^(?<Mode>\d+)\s+(?<Sha>[0-9a-f]{40,64})\s+\d+\s+') {
        throw "Could not parse index entry for $RelativePath`: $stageLine"
    }

    $indexBackupPath = "$WorktreeBackupPath.index"
    Copy-HookGitBlobToFile -Blob $Matches['Sha'] -Destination $indexBackupPath
    return [pscustomobject]@{
        Path = $indexBackupPath
        Mode = $Matches['Mode']
    }
}

function Restore-HookIndexRecoveryBackup {
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)]$IndexBackup
    )

    Push-Location $RepoRoot
    try {
        $hashOutput = @(& git hash-object -w -- $IndexBackup.Path 2>&1)
        if ($LASTEXITCODE -ne 0 -or $hashOutput.Count -eq 0) {
            Write-HookLine "AutoFix: failed to hash index backup for $RelativePath (exit $LASTEXITCODE): $($hashOutput -join '; ')" 'Red'
            return
        }
        $blobSha = "$($hashOutput[0])".Trim()
        $updateOutput = @(& git update-index --add --cacheinfo $IndexBackup.Mode $blobSha $RelativePath 2>&1)
        if ($LASTEXITCODE -ne 0) {
            Write-HookLine "AutoFix: failed to restore index backup for $RelativePath (exit $LASTEXITCODE): $($updateOutput -join '; ')" 'Red'
        }
    } finally {
        Pop-Location
    }
}

function Get-HookPowerShellParseErrors {
    param([Parameter(Mandatory)][string]$Path)

    $tokens = $null
    $parseErrors = $null
    try {
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $Path, [ref]$tokens, [ref]$parseErrors)
    } catch {
        return @($_)
    }
    return @($parseErrors)
}

function Restore-HookPowerShellFileFromGit {
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$FullPath,
        [Parameter(Mandatory)][string]$BackupPath
    )

    $restoredFrom = $null
    $recheckErrors = @()
    $indexBackup = $null
    try {
        $indexBackup = New-HookIndexRecoveryBackup -RelativePath $RelativePath -WorktreeBackupPath $BackupPath
        if ($null -ne $indexBackup) {
            Write-HookLine "AutoFix: backed up index copy of $RelativePath to $($indexBackup.Path)" 'Yellow'
        }
    } catch {
        Write-HookLine "AutoFix: failed to write index recovery backup for $RelativePath`: $($_.Exception.Message). Refusing to overwrite staged WIP." 'Red'
        exit 1
    }

    Push-Location $RepoRoot
    try {
        $indexOut = @(& git checkout -- $RelativePath 2>&1)
        if ($LASTEXITCODE -eq 0) {
            $recheckErrors = @(Get-HookPowerShellParseErrors -Path $FullPath)
            if ($recheckErrors.Count -eq 0) {
                $restoredFrom = 'index'
            } else {
                Write-HookLine "AutoFix: index copy of $RelativePath also has parse errors; falling back to HEAD." 'Yellow'
            }
        } else {
            Write-HookLine "AutoFix: git checkout from index failed for $RelativePath (exit $LASTEXITCODE): $($indexOut -join '; '). Falling back to HEAD." 'Yellow'
        }

        if ($null -eq $restoredFrom) {
            if ($null -eq $indexBackup) {
                Write-HookLine "AutoFix: cannot fall back to HEAD for $RelativePath without an index backup; restoring backed-up WIP." 'Red'
                Copy-Item -LiteralPath $BackupPath -Destination $FullPath -Force
                exit 1
            }
            $headOut = @(& git checkout HEAD -- $RelativePath 2>&1)
            if ($LASTEXITCODE -ne 0) {
                Write-HookLine "AutoFix: git checkout HEAD failed for $RelativePath (exit $LASTEXITCODE): $($headOut -join '; '). Recovery backup at $BackupPath." 'Red'
                Restore-HookIndexRecoveryBackup -RelativePath $RelativePath -IndexBackup $indexBackup
                exit 1
            }
            $recheckErrors = @(Get-HookPowerShellParseErrors -Path $FullPath)
            if ($recheckErrors.Count -eq 0) {
                $restoredFrom = 'HEAD'
            }
        }
    } finally {
        Pop-Location
    }

    if ($null -eq $restoredFrom) {
        Write-HookLine "AutoFix: HEAD copy of $RelativePath is also corrupt; restoring backed-up WIP." 'Red'
        try {
            Copy-Item -LiteralPath $BackupPath -Destination $FullPath -Force
        } catch {
            Write-HookLine "AutoFix: failed to restore $RelativePath from $BackupPath`: $($_.Exception.Message)" 'Red'
        }
        if ($null -ne $indexBackup) {
            Restore-HookIndexRecoveryBackup -RelativePath $RelativePath -IndexBackup $indexBackup
        }
        foreach ($e in $recheckErrors) {
            $line = if ($e.PSObject.Properties.Name -contains 'Extent') { $e.Extent.StartLineNumber } else { '?' }
            $message = if ($e.PSObject.Properties.Name -contains 'Message') { $e.Message } else { "$e" }
            Write-HookLine "  HEAD ${RelativePath}:$line`: $message" 'Red'
        }
        exit 1
    }

    $indexNote = if ($restoredFrom -eq 'HEAD' -and $null -ne $indexBackup) { "; staged/index WIP backed up to $($indexBackup.Path)" } else { '' }
    Write-HookLine "AutoFix: recovered $RelativePath from $restoredFrom; corrupt WIP backed up to $BackupPath$indexNote." 'Yellow'
}

function Resolve-HookGitPath {
    param([Parameter(Mandatory)][string]$GitPath)

    if (Get-Command git -ErrorAction SilentlyContinue) {
        Push-Location $RepoRoot
        try {
            $raw = @(& git rev-parse --git-path $GitPath 2>$null) | Select-Object -First 1
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($raw)) {
                if ([System.IO.Path]::IsPathRooted($raw)) {
                    return [System.IO.Path]::GetFullPath($raw)
                }
                return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $raw))
            }
        } finally {
            Pop-Location
        }
    }

    return [System.IO.Path]::GetFullPath((Join-Path (Join-Path $RepoRoot '.git') $GitPath))
}

function Get-HookPythonCommand {
    $candidates = @(
        (Join-Path $RepoRoot '.venv-ci/bin/python'),
        (Join-Path $RepoRoot '.venv-ci/Scripts/python.exe'),
        'py',
        'python3',
        'python'
    )
    foreach ($candidate in $candidates) {
        if ([System.IO.Path]::IsPathRooted($candidate) -or $candidate.Contains('/') -or $candidate.Contains('\')) {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                if ((Test-HookPythonCommandPath -Path $candidate) -and (Test-HookPythonCanImportYaml -Python $candidate)) {
                    return $candidate
                }
            }
            continue
        }
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            if ((Test-HookPythonCommandPath -Path $command.Source) -and (Test-HookPythonCanImportYaml -Python $command.Source)) {
                return $command.Source
            }
        }
    }
    return $null
}

function Test-HookPythonCommandPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [bool]$TreatAsWindows = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
            [System.Runtime.InteropServices.OSPlatform]::Windows)
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not $TreatAsWindows) { return $true }

    $leaf = Split-Path -Leaf $Path
    if ($leaf -notin @('python.exe', 'python3.exe')) { return $true }

    $normalized = $Path -replace '/', '\'
    return $normalized -notmatch '\\Microsoft\\WindowsApps\\python3?\.exe$'
}

function Test-HookPythonCanImportYaml {
    param([Parameter(Mandatory)][string]$Python)

    $output = @(& $Python -c 'import yaml' 2>&1)
    return $LASTEXITCODE -eq 0
}

function New-GitHubConfigIndexSnapshot {
    $snapshot = Join-Path ([System.IO.Path]::GetTempPath()) ("llm-github-config-index-$([Guid]::NewGuid())")
    New-Item -ItemType Directory -Path $snapshot -Force | Out-Null
    $prefix = [System.IO.Path]::GetFullPath($snapshot)
    if (-not $prefix.EndsWith([System.IO.Path]::DirectorySeparatorChar) -and
        -not $prefix.EndsWith([System.IO.Path]::AltDirectorySeparatorChar)) {
        $prefix = "$prefix$([System.IO.Path]::DirectorySeparatorChar)"
    }

    Push-Location $RepoRoot
    try {
        $output = @(& git checkout-index -a -f "--prefix=$prefix" 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "git checkout-index failed with exit $LASTEXITCODE`: $($output -join '; ')"
        }
    } finally {
        Pop-Location
    }
    return $snapshot
}

function Invoke-GitHubConfigCheck {
    if (-not (Test-Path -LiteralPath $GithubConfigValidator -PathType Leaf)) {
        Write-HookLine "Missing GitHub config validator: $GithubConfigValidator" 'Red'
        exit 1
    }
    $python = Get-HookPythonCommand
    if ([string]::IsNullOrWhiteSpace($python)) {
        Write-HookLine 'python3 with PyYAML is required to validate GitHub and Dependabot config.' 'Red'
        Write-HookLine 'Install it with: python -m pip install -r requirements-automation.txt (or py -m pip on Windows).' 'Yellow'
        exit 1
    }
    Write-HookLine 'Validating GitHub workflow and Dependabot config...'
    $validationRoot = $RepoRoot
    $validator = $GithubConfigValidator
    $snapshot = $null
    if ($Mode -eq 'PreCommit' -and -not $SkipStagedCheck) {
        try {
            $snapshot = New-GitHubConfigIndexSnapshot
        } catch {
            Write-HookLine "Failed to materialize staged GitHub config snapshot: $($_.Exception.Message)" 'Red'
            exit 1
        }
        $validationRoot = $snapshot
        $validator = Join-Path $snapshot 'scripts/validate-github-config.py'
        if (-not (Test-Path -LiteralPath $validator -PathType Leaf)) {
            Write-HookLine 'Staged GitHub config validator is missing. Stage scripts/validate-github-config.py with related config changes.' 'Red'
            Remove-Item -LiteralPath $snapshot -Recurse -Force -ErrorAction SilentlyContinue
            exit 1
        }
        Write-HookLine 'Using staged index snapshot for PreCommit GitHub config validation.'
    }
    try {
        & $python $validator --self-test
        if ($LASTEXITCODE -ne 0) {
            Write-HookLine "GitHub config validator self-tests failed (exit $LASTEXITCODE)." 'Red'
            exit $LASTEXITCODE
        }
        & $python $validator --repo-root $validationRoot
        if ($LASTEXITCODE -ne 0) {
            Write-HookLine "GitHub config validation failed (exit $LASTEXITCODE)." 'Red'
            exit $LASTEXITCODE
        }
    } finally {
        if ($null -ne $snapshot) {
            Remove-Item -LiteralPath $snapshot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-FastPowerShellParseCheck {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return }
    Push-Location $RepoRoot
    try {
        $files = @(& git ls-files -- '*.ps1' '*.psm1' '*.psd1' 2>$null)
        if ($LASTEXITCODE -ne 0) {
            Write-HookLine "git ls-files (PowerShell sources) failed with exit $LASTEXITCODE." 'Red'
            exit 1
        }
    } finally {
        Pop-Location
    }
    foreach ($rel in ($files | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $full = Join-Path $RepoRoot $rel
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $full, [ref]$tokens, [ref]$parseErrors)
        if ($null -ne $parseErrors -and $parseErrors.Count -gt 0) {
            foreach ($err in $parseErrors) {
                Write-HookLine "PowerShell parse error in $rel`:$($err.Extent.StartLineNumber): $($err.Message)" 'Red'
            }
            if ($rel -eq 'scripts/preflight.ps1' -and $autoFixEnabled) {
                $backupPath = New-HookRecoveryBackup -RelativePath $rel
                if ([string]::IsNullOrWhiteSpace($backupPath)) {
                    Write-HookLine "AutoFix: refusing to restore $rel without a recovery backup." 'Red'
                    exit 1
                }
                Restore-HookPowerShellFileFromGit -RelativePath $rel -FullPath $full -BackupPath $backupPath
                continue
            }
            exit 1
        }
    }
}

function Test-InstallGitHooksUndefinedVariables {
    $path = Join-Path $ScriptsDir 'install-git-hooks.ps1'
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $path, [ref]$tokens, [ref]$parseErrors)
    if ($null -ne $parseErrors -and $parseErrors.Count -gt 0) {
        Write-HookLine "Parse errors in install-git-hooks.ps1: $($parseErrors | ForEach-Object { $_.Message } | Out-String)" 'Red'
        return $false
    }

    $defined = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($auto in @(
            'PSScriptRoot', 'PSCommandPath', 'PSBoundParameters', 'MyInvocation',
            'args', '_', 'PSItem', 'null', 'true', 'false', 'LASTEXITCODE',
            'Error', 'PWD', 'Host', 'HOME', 'PSVersionTable', 'ErrorActionPreference',
            'PSCmdlet', 'this', 'input', 'PID')) {
        [void]$defined.Add($auto)
    }
    $assignments = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -or
            $node -is [System.Management.Automation.Language.ParameterAst] -or
            $node -is [System.Management.Automation.Language.ForEachStatementAst]
        }, $true)
    foreach ($node in $assignments) {
        if ($node -is [System.Management.Automation.Language.AssignmentStatementAst]) {
            $target = $node.Left
            if ($target -is [System.Management.Automation.Language.VariableExpressionAst]) {
                [void]$defined.Add($target.VariablePath.UserPath)
            }
        } elseif ($node -is [System.Management.Automation.Language.ParameterAst]) {
            [void]$defined.Add($node.Name.VariablePath.UserPath)
        } elseif ($node -is [System.Management.Automation.Language.ForEachStatementAst]) {
            [void]$defined.Add($node.Variable.VariablePath.UserPath)
        }
    }

    $undefined = [System.Collections.Generic.List[string]]::new()
    foreach ($u in @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.VariableExpressionAst]
            }, $true))) {
        $name = $u.VariablePath.UserPath
        if ($u.VariablePath.IsDriveQualified) { continue }
        if ($defined.Contains($name)) { continue }
        $undefined.Add("`$$name (line $($u.Extent.StartLineNumber))")
    }
    if ($undefined.Count -gt 0) {
        Write-HookLine "Undefined variable references in install-git-hooks.ps1: $($undefined -join ', ')" 'Red'
        return $false
    }
    return $true
}

function Invoke-FastStructuralGuards {
    $runner = [System.IO.File]::ReadAllText((Join-Path $ScriptsDir 'run-llm-hooks.ps1'))
    $linter = [System.IO.File]::ReadAllText((Join-Path $ScriptsDir 'lint-llm.ps1'))
    $postCreate = [System.IO.File]::ReadAllText((Join-Path $RepoRoot '.devcontainer/post-create.sh'))

    if (-not (Test-InstallGitHooksUndefinedVariables)) { exit 1 }
    if ($linter -notmatch 'Invoke-LlmLint' -or $linter -match '&\s+pwsh' -or $linter -match 'generate-llm-index\.ps1') {
        Write-HookLine 'Fast guard failed: lint-llm.ps1 must delegate to Invoke-LlmLint without generator/pwsh subprocesses.' 'Red'
        exit 1
    }
    if ($runner -notmatch 'Invoke-LlmIndexGenerator' -or $runner -notmatch 'Invoke-LlmLint') {
        Write-HookLine 'Fast guard failed: run-llm-hooks.ps1 must call generator/linter shared functions in-process.' 'Red'
        exit 1
    }
    if ($postCreate -notmatch 'install-git-hooks\.ps1\s+-Force' -or $postCreate -match 'pre-commit\s+install') {
        Write-HookLine 'Fast guard failed: devcontainer must install the direct git shim, not the pre-commit framework hook.' 'Red'
        exit 1
    }
}

function Test-ControlledArtifactPath {
    param([Parameter(Mandatory)][string]$RelativePath)

    $normalized = "$RelativePath".Trim() -replace '\\', '/'
    while ($normalized.StartsWith('./')) {
        $normalized = $normalized.Substring(2)
    }
    if ([string]::IsNullOrWhiteSpace($normalized)) { return $false }
    $first = $normalized.Split('/', 2)[0]
    return @('scripts', '.llm', '.githooks', '.claude') -contains $first
}

function New-StrayArtifactLeafMatchers {
    param([Parameter(Mandatory)][string[]]$Patterns)

    $matchers = [System.Collections.Generic.List[System.Management.Automation.WildcardPattern]]::new()
    foreach ($pattern in @($Patterns)) {
        $p = "$pattern".Trim() -replace '\\', '/'
        if ([string]::IsNullOrWhiteSpace($p) -or $p.Contains('/')) { continue }
        $matchers.Add([System.Management.Automation.WildcardPattern]::new(
                $p,
                [System.Management.Automation.WildcardOptions]::IgnoreCase))
    }
    return @($matchers)
}

function Test-StrayArtifactLeafName {
    param(
        [Parameter(Mandatory)][string]$Leaf,
        [Parameter(Mandatory)][System.Management.Automation.WildcardPattern[]]$Matchers
    )

    foreach ($matcher in @($Matchers)) {
        if ($matcher.IsMatch($Leaf)) { return $true }
    }
    return $false
}

function Get-TrackedFileDirectories {
    param([Parameter(Mandatory)][System.Collections.Generic.HashSet[string]]$TrackedFiles)

    $dirs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($tracked in @($TrackedFiles)) {
        $normalized = "$tracked".Trim() -replace '\\', '/'
        if ([string]::IsNullOrWhiteSpace($normalized) -or $normalized.Contains('..')) { continue }
        if (Test-ControlledArtifactPath -RelativePath $normalized) { continue }

        $lastSlash = $normalized.LastIndexOf('/')
        $dir = if ($lastSlash -ge 0) { $normalized.Substring(0, $lastSlash) } else { '' }
        [void]$dirs.Add($dir)
    }
    return @($dirs | Sort-Object)
}

function Get-ControlledStrayArtifacts {
    param(
        [Parameter(Mandatory)][System.Collections.Generic.HashSet[string]]$TrackedFiles,
        [Parameter(Mandatory)][string[]]$Patterns
    )

    $controlledDirs = @('scripts', '.llm', '.githooks', '.claude')
    $leafMatchers = @(New-StrayArtifactLeafMatchers -Patterns $Patterns)
    $artifacts = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    foreach ($dir in $controlledDirs) {
        $fullDir = Join-Path $RepoRoot $dir
        if (-not (Test-Path -LiteralPath $fullDir -PathType Container)) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $fullDir -Recurse -Force -File -ErrorAction SilentlyContinue)) {
            if (-not (Test-StrayArtifactLeafName -Leaf $file.Name -Matchers $leafMatchers)) { continue }
            $rel = (Get-LlmRepoRelativePath -RepoRoot $RepoRoot -Path $file.FullName)
            if ([string]::IsNullOrWhiteSpace($rel) -or $artifacts.ContainsKey($rel)) { continue }
            $artifacts[$rel] = [pscustomobject]@{
                Path      = $rel
                IsTracked = $TrackedFiles.Contains($rel)
                IsIgnored = $false
            }
        }
    }

    foreach ($dir in @(Get-TrackedFileDirectories -TrackedFiles $TrackedFiles)) {
        $fullDir = if ([string]::IsNullOrWhiteSpace($dir)) { $RepoRoot } else { Join-Path $RepoRoot $dir }
        if (-not (Test-Path -LiteralPath $fullDir -PathType Container)) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $fullDir -Force -File -ErrorAction SilentlyContinue)) {
            if (-not (Test-StrayArtifactLeafName -Leaf $file.Name -Matchers $leafMatchers)) { continue }
            $rel = (Get-LlmRepoRelativePath -RepoRoot $RepoRoot -Path $file.FullName)
            if ([string]::IsNullOrWhiteSpace($rel) -or $artifacts.ContainsKey($rel)) { continue }
            if (-not (Test-LlmDeletableArtifact -RepoRoot $RepoRoot -RelativePath $rel -TrackedFiles $TrackedFiles)) { continue }
            $artifacts[$rel] = [pscustomobject]@{
                Path      = $rel
                IsTracked = $TrackedFiles.Contains($rel)
                IsIgnored = $false
            }
        }
    }

    return @($artifacts.Values | Sort-Object -Property Path)
}

function Invoke-StrayArtifactCheck {
    param([switch]$Broad, [switch]$ControlledOnly)
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return }

    $patterns = @(Get-LlmDefaultStrayPatterns)
    $trackedSet = Get-LlmTrackedFileSet -RepoRoot $RepoRoot
    try {
        $strayArtifacts = if ($ControlledOnly) {
            @(Get-ControlledStrayArtifacts -TrackedFiles $trackedSet -Patterns $patterns)
        } elseif ($Broad) {
            @(Get-LlmStrayWorkingTreeArtifacts -RepoRoot $RepoRoot -Patterns $patterns)
        } else {
            @(Get-LlmStagingArtifacts -RepoRoot $RepoRoot -Patterns $patterns)
        }
    } catch {
        Write-HookLine $_.Exception.Message 'Red'
        exit 1
    }

    $reportable = [System.Collections.Generic.List[string]]::new()
    $autoFixFailed = $false
    foreach ($artifact in $strayArtifacts) {
        $stray = $artifact.Path
        $full = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $stray))
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }

        $deletable = Test-LlmDeletableArtifact -RepoRoot $RepoRoot -RelativePath $stray -TrackedFiles $trackedSet
        if (-not $deletable) {
            if ($autoFixEnabled) {
                Write-HookLine "AutoFix: found stray $stray but it's outside controlled directories; leaving for manual review." 'Yellow'
            } else {
                $reportable.Add($stray)
            }
            continue
        }
        if (-not $autoFixEnabled) {
            $reportable.Add($stray)
            continue
        }
        try {
            Remove-Item -LiteralPath $full -Force -ErrorAction Stop
            Write-HookLine "AutoFix: removed stray staging artifact: $stray" 'Yellow'
        } catch {
            Write-HookLine "AutoFix: failed to remove $stray`: $($_.Exception.Message)" 'Red'
            $autoFixFailed = $true
        }
        if ($artifact.IsTracked) {
            $rmOutput = @(& git rm -f --quiet -- $stray 2>&1)
            if ($LASTEXITCODE -ne 0) {
                Write-HookLine "AutoFix: git rm failed for $stray (exit $LASTEXITCODE): $($rmOutput -join '; ')" 'Red'
                $autoFixFailed = $true
            }
        }
    }

    if ($autoFixFailed) {
        Write-HookLine 'AutoFix could not clean up stray artifacts; aborting before commit.' 'Red'
        exit 1
    }
    if ($reportable.Count -gt 0) {
        Write-HookLine 'Stray working-tree artifacts found (NoAutoFix mode):' 'Red'
        foreach ($s in $reportable) {
            Write-HookLine "  - $s" 'Red'
        }
        Write-HookLine 'Remove them manually or re-run with -AutoFix.' 'Yellow'
        exit 1
    }
}

function Get-ContextGeneratedBlock {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)

    $startMarker = '<!-- LLM-INDEX:START -->'
    $endMarker = '<!-- LLM-INDEX:END -->'
    $start = $Content.IndexOf($startMarker)
    $end = $Content.IndexOf($endMarker)
    if ($start -lt 0 -or $end -lt 0 -or $end -lt $start) {
        return $null
    }
    return $Content.Substring($start, ($end + $endMarker.Length) - $start)
}

function Test-ContextWorktreeDiffOnlyOutsideGeneratedBlock {
    param([Parameter(Mandatory)][string]$RelativePath)

    $worktreePath = Join-Path $RepoRoot $RelativePath
    if (-not (Test-Path -LiteralPath $worktreePath -PathType Leaf)) { return $false }

    $worktreeText = [System.IO.File]::ReadAllText($worktreePath)
    $indexLines = @(& git show ":$RelativePath" 2>$null)
    if ($LASTEXITCODE -ne 0) { return $false }
    $indexText = ($indexLines -join "`n")
    if ($indexLines.Count -gt 0) { $indexText += "`n" }

    $worktreeBlock = Get-ContextGeneratedBlock -Content $worktreeText
    $indexBlock = Get-ContextGeneratedBlock -Content $indexText
    if ($null -eq $worktreeBlock -or $null -eq $indexBlock) { return $false }

    return (ConvertTo-LlmNormalizedNewlines $worktreeBlock) -eq
        (ConvertTo-LlmNormalizedNewlines $indexBlock)
}

function Set-ContextGeneratedBlockInIndex {
    param([Parameter(Mandatory)][string]$RelativePath)

    $worktreePath = Join-Path $RepoRoot $RelativePath
    if (-not (Test-Path -LiteralPath $worktreePath -PathType Leaf)) {
        Write-HookLine "AutoFix: cannot stage only the generated block because $RelativePath is missing from the working tree." 'Red'
        return $false
    }

    $worktreeText = [System.IO.File]::ReadAllText($worktreePath)
    $indexLines = @(& git show ":$RelativePath" 2>$null)
    if ($LASTEXITCODE -ne 0) {
        Write-HookLine "AutoFix: cannot stage only the generated block because $RelativePath is not present in the index." 'Red'
        return $false
    }
    $indexText = ($indexLines -join "`n")
    if ($indexLines.Count -gt 0) { $indexText += "`n" }

    $startMarker = '<!-- LLM-INDEX:START -->'
    $endMarker = '<!-- LLM-INDEX:END -->'
    $indexStart = $indexText.IndexOf($startMarker)
    $indexEnd = $indexText.IndexOf($endMarker)
    $worktreeBlock = Get-ContextGeneratedBlock -Content $worktreeText
    if ($indexStart -lt 0 -or $indexEnd -lt 0 -or $indexEnd -lt $indexStart -or $null -eq $worktreeBlock) {
        Write-HookLine "AutoFix: cannot stage only the generated block because $RelativePath markers are missing or malformed." 'Red'
        return $false
    }

    $indexBlockEnd = $indexEnd + $endMarker.Length
    $indexPrefix = $indexText.Substring(0, $indexStart)
    $indexSuffix = $indexText.Substring($indexBlockEnd)
    $nextIndexText = "$indexPrefix$worktreeBlock$indexSuffix"
    if ((ConvertTo-LlmNormalizedNewlines $nextIndexText) -eq
        (ConvertTo-LlmNormalizedNewlines $indexText)) {
        return $true
    }

    $tempPath = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($tempPath, $nextIndexText, [System.Text.UTF8Encoding]::new($false))
        $hashOutput = @(& git hash-object -w -- $tempPath 2>&1)
        if ($LASTEXITCODE -ne 0 -or $hashOutput.Count -eq 0) {
            Write-HookLine "AutoFix: git hash-object failed while staging $RelativePath generated block (exit $LASTEXITCODE): $($hashOutput -join '; ')" 'Red'
            return $false
        }
        $blobSha = "$($hashOutput[0])".Trim()
        if ($blobSha -notmatch '^[0-9a-f]{40,64}$') {
            Write-HookLine "AutoFix: git hash-object returned an unexpected blob id for ${RelativePath}: $blobSha" 'Red'
            return $false
        }
        $updateOutput = @(& git update-index --add --cacheinfo 100644 $blobSha $RelativePath 2>&1)
        if ($LASTEXITCODE -ne 0) {
            Write-HookLine "AutoFix: git update-index failed while staging $RelativePath generated block (exit $LASTEXITCODE): $($updateOutput -join '; ')" 'Red'
            return $false
        }
        return $true
    } finally {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-UntrackedLlmMarkdownGenerationInputs {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        return @()
    }

    $errorPath = [System.IO.Path]::GetTempFileName()
    Push-Location $RepoRoot
    try {
        $raw = @(& git ls-files --others --exclude-standard -z -- '.llm/*.md' ':(glob).llm/**/*.md' 2> $errorPath)
        if ($LASTEXITCODE -ne 0) {
            $err = (Get-Content -LiteralPath $errorPath -Raw -ErrorAction SilentlyContinue).Trim()
            if ([string]::IsNullOrWhiteSpace($err)) {
                Write-HookLine "git ls-files (untracked .llm markdown) failed with exit $LASTEXITCODE." 'Red'
            } else {
                Write-HookLine "git ls-files (untracked .llm markdown) failed with exit $LASTEXITCODE`: $err" 'Red'
            }
            exit 1
        }

        # The generator inventories filesystem Markdown, so gitignored
        # untracked .llm inputs are just as generation-affecting as ordinary
        # untracked inputs. Keep the ignored scan pathspec-limited to avoid
        # paying for or reporting broad repository ignored output.
        $ignoredRaw = @(& git ls-files --others --ignored --exclude-standard -z -- '.llm/*.md' ':(glob).llm/**/*.md' 2> $errorPath)
        if ($LASTEXITCODE -ne 0) {
            $err = (Get-Content -LiteralPath $errorPath -Raw -ErrorAction SilentlyContinue).Trim()
            if ([string]::IsNullOrWhiteSpace($err)) {
                Write-HookLine "git ls-files (ignored untracked .llm markdown) failed with exit $LASTEXITCODE." 'Red'
            } else {
                Write-HookLine "git ls-files (ignored untracked .llm markdown) failed with exit $LASTEXITCODE`: $err" 'Red'
            }
            exit 1
        }
        $raw += $ignoredRaw
    } finally {
        Pop-Location
        Remove-Item -LiteralPath $errorPath -Force -ErrorAction SilentlyContinue
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($path in (($raw -join '') -split "`0")) {
        $normalized = "$path".Trim() -replace '\\', '/'
        if ([string]::IsNullOrWhiteSpace($normalized)) { continue }
        if ($normalized -eq '.llm/index.md') { continue }
        if ($seen.Add($normalized)) {
            $paths.Add($normalized)
        }
    }
    return @($paths | Sort-Object)
}

function Invoke-UntrackedLlmMarkdownInputCheck {
    if ($Mode -notin @('PreCommit', 'AgentFast')) { return }
    if ($Mode -eq 'PreCommit' -and -not $llmTouched) { return }

    $untrackedInputs = @(Get-UntrackedLlmMarkdownGenerationInputs)
    if ($untrackedInputs.Count -eq 0) { return }

    Write-HookLine 'Untracked .llm Markdown inputs would affect generated LLM files.' 'Red'
    foreach ($path in $untrackedInputs) {
        Write-HookLine " - $path" 'Red'
    }
    $rerunTarget = if ($Mode -eq 'AgentFast') { 'AgentFast' } else { 'PreCommit -AutoFix' }
    Write-HookLine "Stage these .llm Markdown files or remove them before rerunning $rerunTarget." 'Yellow'
    exit 1
}

function Invoke-GeneratedStagingCheck {
    param([string[]]$AutoFixPaths = @())

    if ($SkipStagedCheck) {
        Write-HookLine 'Skipping staged-files check (SkipStagedCheck).'
        return
    }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-HookLine 'git not found; cannot verify staged generated files.' 'Red'
        exit 1
    }

    $statusOutput = @(& git status --porcelain -- $GeneratedFiles)
    if ($LASTEXITCODE -ne 0) {
        Write-HookLine "git status failed (exit $LASTEXITCODE)." 'Red'
        exit $LASTEXITCODE
    }

    $dirty = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $statusOutput) {
        $statusEntry = ConvertFrom-GeneratedFileStatusLine -Line $line
        if (-not $statusEntry.NeedsWorktreeStaging) { continue }
        if ($statusEntry.IsUntracked) {
            $dirty.Add("untracked: $($statusEntry.Path)")
        } else {
            $dirty.Add("unstaged: $($statusEntry.Path)")
        }
    }

    if ($dirty.Count -eq 0) { return }
    $autoFixPathSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($path in @($AutoFixPaths)) {
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            [void]$autoFixPathSet.Add(($path -replace '\\', '/'))
        }
    }
    $effectiveAutoFix = $autoFixEnabled -and $autoFixPathSet.Count -gt 0
    $stagePaths = [System.Collections.Generic.List[string]]::new()
    $reportDirty = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $statusOutput) {
        $statusEntry = ConvertFrom-GeneratedFileStatusLine -Line $line
        if (-not $statusEntry.NeedsWorktreeStaging) { continue }
        $normalizedPath = $statusEntry.Path -replace '\\', '/'
        if ($effectiveAutoFix -and $autoFixPathSet.Contains($normalizedPath)) {
            $stagePaths.Add($normalizedPath)
            continue
        }
        if ($normalizedPath -eq '.llm/context.md' -and
            -not $statusEntry.IsUntracked -and
            (Test-ContextWorktreeDiffOnlyOutsideGeneratedBlock -RelativePath $normalizedPath)) {
            continue
        }
        if ($statusEntry.Index -eq '?' -and $statusEntry.Worktree -eq '?') {
            $reportDirty.Add("untracked: $($statusEntry.Path)")
        } else {
            $reportDirty.Add("unstaged: $($statusEntry.Path)")
        }
    }

    if ($stagePaths.Count -gt 0) {
        Write-HookLine 'AutoFix: staging regenerated LLM files.' 'Yellow'
        $uniqueStagePaths = @($stagePaths | Sort-Object -Unique)
        foreach ($path in $uniqueStagePaths) {
            Write-HookLine " - $path" 'Yellow'
        }

        $fullStagePaths = [System.Collections.Generic.List[string]]::new()
        foreach ($path in $uniqueStagePaths) {
            if ($path -eq '.llm/context.md') {
                if (-not (Set-ContextGeneratedBlockInIndex -RelativePath $path)) {
                    Write-HookLine 'AutoFix: refusing to stage .llm/context.md wholesale because unrelated prose may be present outside the generated block.' 'Red'
                    exit 1
                }
            } else {
                $fullStagePaths.Add($path)
            }
        }
        if ($fullStagePaths.Count -gt 0) {
            & git add -- @($fullStagePaths | Sort-Object -Unique)
            if ($LASTEXITCODE -ne 0) {
                Write-HookLine "AutoFix: git add failed (exit $LASTEXITCODE)." 'Red'
                exit $LASTEXITCODE
            }
        }
    }
    if ($reportDirty.Count -eq 0) {
        return
    }

    Write-HookLine 'Generated LLM files are out of sync with the index.' 'Red'
    foreach ($entry in $reportDirty) {
        Write-HookLine " - $entry" 'Red'
    }
    Write-HookLine 'Stage them with: git add .llm/index.md .llm/context.md' 'Yellow'
    if ($AutoFixPaths.Count -gt 0) {
        Write-HookLine 'Or re-run with -AutoFix to stage them automatically.' 'Yellow'
    } elseif ($Mode -eq 'AgentFast') {
        Write-HookLine 'AgentFast is non-mutating; run PreCommit or Full after reviewing generated drift.' 'Yellow'
    } else {
        Write-HookLine 'AutoFix did not stage these files because this hook did not regenerate them.' 'Yellow'
    }
    exit 1
}

function Invoke-CIGeneratedDiffCheck {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return }
    $diffOut = @(& git diff --exit-code -- $GeneratedFiles 2>&1)
    if ($LASTEXITCODE -ne 0) {
        Write-HookLine 'Generated .llm files differ from committed versions.' 'Red'
        foreach ($line in $diffOut) {
            if (-not [string]::IsNullOrWhiteSpace("$line")) {
                Write-HookLine "$line" 'Red'
            }
        }
        exit 1
    }
}

foreach ($required in @($ModulePath, $SelfTests, $Preflight, $GithubConfigValidator)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        Write-HookLine "Missing required harness file: $required" 'Red'
        exit 1
    }
}
if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
    Write-HookLine 'pwsh is required but was not found on PATH.' 'Red'
    exit 1
}

$changedPaths = @(Get-ChangedPaths)
$llmTouched = Test-LlmPathTouched -Paths $changedPaths
$toolingTouched = Test-ToolingPathTouched -Paths $changedPaths
$githubConfigTouched = Test-GitHubConfigPathTouched -Paths $changedPaths
$relevantFastChange = $llmTouched -or $toolingTouched
$generatedStatusRelevant = ($Mode -in @('Full', 'CI') -or $llmTouched)

if ($VerboseOutput -and $fastMode) {
    $changedText = if ($changedPaths.Count -gt 0) { $changedPaths -join ', ' } else { '(none)' }
    Write-HookLine "Fast-mode changed paths: $changedText"
}

Invoke-HookStage 'preflight' {
    Invoke-PreflightIfNeeded -Required:($Mode -in @('Full', 'CI'))
    if ($fastMode -and $toolingTouched) {
        Invoke-FastPowerShellParseCheck
        Invoke-FastStructuralGuards
    }
}

Import-Module $ModulePath -Force

Push-Location $RepoRoot
try {
    if ($Mode -in @('PreCommit', 'AgentFast', 'Full', 'CI')) {
        Invoke-HookStage 'stray-artifacts' {
            Invoke-StrayArtifactCheck `
                -Broad:($Mode -in @('Full', 'CI')) `
                -ControlledOnly:($Mode -in @('PreCommit', 'AgentFast'))
        }
    }

    if ($Mode -in @('PreCommit', 'AgentFast')) {
        Invoke-HookStage 'untracked-llm-inputs' {
            Invoke-UntrackedLlmMarkdownInputCheck
        }
    }

    if ($Mode -in @('Full', 'CI') -or $githubConfigTouched) {
        Invoke-HookStage 'github-config' {
            Invoke-GitHubConfigCheck
        }
    }

    if ($fastMode -and -not $relevantFastChange) {
        Invoke-HookStage 'minimal-generated-sanity' {
            if (-not (Test-MinimalGeneratedSanity)) { exit 1 }
        }
        Write-HookLine 'No staged LLM/harness changes; fast hook OK.' 'Green'
        exit 0
    }

    if ($Mode -in @('Full', 'CI') -or $llmTouched) {
        Invoke-HookStage 'generate' {
            $checkOnly = ($Mode -eq 'AgentFast')
            if ($checkOnly) {
                Write-HookLine 'Checking generated LLM index and context section...'
            } else {
                Write-HookLine 'Regenerating LLM index and context section...'
            }
            $result = Invoke-LlmIndexGenerator -RepoRoot $RepoRoot -Check:$checkOnly -VerboseOutput:$VerboseOutput -PassThru
            if (-not $result.Success) { exit 1 }
            if (-not $checkOnly) {
                $script:generatedFilesWrittenByHook = @($result.WrittenPaths)
            }
        }
    }

    if ($Mode -in @('Full', 'CI') -or $llmTouched -or $toolingTouched) {
        Invoke-HookStage 'lint' {
            Write-HookLine 'Running LLM harness linter...'
            $ok = Invoke-LlmLint `
                -RepoRoot $RepoRoot `
                -VerboseOutput:$VerboseOutput `
                -SkipPowerShellParseCheck:($fastMode) `
                -SkipGeneratedIndexCheck:($fastMode) `
                -SkipStagingArtifactCheck:($true)
            if (-not $ok) { exit 1 }
        }
    }

    if ($Mode -in @('Full', 'CI')) {
        Invoke-HookStage 'self-tests' {
            Write-HookLine 'Running LLM harness self-tests...'
            $testArgs = @('-NoProfile', '-File', $SelfTests)
            if ($VerboseOutput) { $testArgs += '-VerboseOutput' }
            & pwsh @testArgs
            if ($LASTEXITCODE -ne 0) {
                Write-HookLine "Self-tests failed (exit $LASTEXITCODE)." 'Red'
                exit $LASTEXITCODE
            }
        }
    } elseif ($toolingTouched) {
        Write-HookLine 'Skipping behavioral subprocess self-tests in fast mode; in-process static guards already ran. Run agent-check.ps1 -Full or Mode Full for exhaustive validation.'
    }

    if ($generatedStatusRelevant) {
        Invoke-HookStage 'generated-staging' {
            Invoke-GeneratedStagingCheck -AutoFixPaths $script:generatedFilesWrittenByHook
        }
    }

    if ($Mode -eq 'CI') {
        Invoke-HookStage 'ci-generated-diff' {
            Invoke-CIGeneratedDiffCheck
        }
    }

    if ($Profile) {
        $total = ($timings | Measure-Object -Property Milliseconds -Sum).Sum
        Write-HookLine ("timing total: {0} ms" -f $total)
    }
    Write-HookLine 'LLM harness OK.' 'Green'
    exit 0
} finally {
    Pop-Location
}
