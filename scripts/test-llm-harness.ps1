[CmdletBinding()]
param(
    [switch]$VerboseOutput,
    # Skip the subprocess-spawning behavioral test subset. These tests
    # fork `pwsh -File ...` to exercise sandbox / end-to-end recovery
    # paths and dominate the wall time of the self-test pass. Tag
    # individual tests with `-Behavioral` so callers can opt out for
    # fast inner-loop feedback. Honors `LLM_HARNESS_SKIP_BEHAVIORAL_TESTS=1`
    # in the environment so wrappers like `agent-check.ps1` can flip the
    # switch without altering arg propagation. (MIN-2)
    [switch]$SkipBehavioralTests
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
$skipped = 0
# Honor the env var or the explicit switch. Either suffices.
$script:SkipBehavioral = [bool]$SkipBehavioralTests -or
    ($env:LLM_HARNESS_SKIP_BEHAVIORAL_TESTS -eq '1')

# Recursion-prevention contract: a behavioral test spawns
# `pwsh -File run-llm-hooks.ps1` to exercise the harness end-to-end.
# `run-llm-hooks.ps1` then re-invokes THIS script as its self-test step.
# Without a guard, that child runs behavioral tests too, which spawn
# `run-llm-hooks.ps1`, which re-invokes THIS script... an unbounded fork
# bomb. We propagate `LLM_HARNESS_SKIP_BEHAVIORAL_TESTS=1` to ALL
# children we spawn so they skip behavioral tests and break the chain.
# DO NOT clear the env var here: clearing it would let our own children
# re-enter the recursion. Parent invokers that legitimately want fresh
# behavioral runs simply unset the var before calling us.
$env:LLM_HARNESS_SKIP_BEHAVIORAL_TESTS = '1'

function Assert-Test {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Body,
        # Mark this test as behavioral (subprocess-spawning, slow). When
        # `-SkipBehavioralTests` or `LLM_HARNESS_SKIP_BEHAVIORAL_TESTS=1`
        # is set the body is skipped and the test counts as skipped.
        [switch]$Behavioral
    )
    if ($Behavioral -and $script:SkipBehavioral) {
        $script:skipped++
        if ($VerboseOutput) {
            Write-Host "[llm-test] SKIP (behavioral): $Name" -ForegroundColor DarkGray
        }
        return
    }
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

function Get-TextDiagnosticLines {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory)][string]$Pattern,
        [int]$Limit = 8
    )

    $matches = [System.Collections.Generic.List[string]]::new()
    $lines = @($Content -split "`r?`n")
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $Pattern) {
            $matches.Add(("{0}: {1}" -f ($i + 1), $lines[$i].TrimEnd()))
            if ($matches.Count -ge $Limit) { break }
        }
    }
    if ($matches.Count -eq 0) {
        return "(no lines matched diagnostic pattern '$Pattern')"
    }
    return ($matches -join "`n")
}

function Assert-TextMatches {
    param(
        [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$Requirement,
        [string]$DiagnosticPattern = ''
    )

    if ($Content -match $Pattern) { return }
    $details = if ([string]::IsNullOrWhiteSpace($DiagnosticPattern)) {
        ''
    } else {
        "`nDiagnostic lines:`n$(Get-TextDiagnosticLines -Content $Content -Pattern $DiagnosticPattern)"
    }
    throw "$Subject must $Requirement. Missing pattern: $Pattern$details"
}

function Assert-TextDoesNotMatch {
    param(
        [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$Requirement,
        [string]$DiagnosticPattern = ''
    )

    if ($Content -notmatch $Pattern) { return }
    $details = if ([string]::IsNullOrWhiteSpace($DiagnosticPattern)) {
        ''
    } else {
        "`nMatching lines:`n$(Get-TextDiagnosticLines -Content $Content -Pattern $DiagnosticPattern)"
    }
    throw "$Subject must $Requirement. Forbidden pattern: $Pattern$details"
}

function Assert-DirectPosixShimBootstrap {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Content
    )

    $normalized = $Content -replace '`', ''
    foreach ($needle in @(
            '#!/usr/bin/env sh',
            'unset LLM_HARNESS_PREFLIGHT_DONE',
            'unset LLM_HARNESS_SKIP_BEHAVIORAL_TESTS',
            'BOOTSTRAP_SCRIPT=',
            'SHIM_BOOTSTRAP',
            'ParseFile',
            'Test-TargetParsesClean',
            'Resolve-HookGitPath',
            'git rev-parse --git-path $GitPath',
            "Resolve-HookGitPath -GitPath 'preflight-recovery'",
            'index WIP',
            'restoring backed-up WIP')) {
        if ($normalized -notmatch ([regex]::Escape($needle))) {
            throw "$Name must contain '$needle'."
        }
    }
    if ($normalized -match 'Join-Path\s+\$repoRoot\s+["'']\.git/preflight-recovery') {
        throw "$Name must resolve preflight-recovery via git rev-parse --git-path, not Join-Path `$repoRoot .git/preflight-recovery."
    }
    if ($normalized -notmatch 'git checkout -- \$entryScript') {
        throw "$Name must try the index/staged copy before HEAD when the entry script is parse-corrupt."
    }
    if ($normalized -notmatch 'git checkout HEAD -- \$entryScript') {
        throw "$Name must fall back to restoring run-llm-hooks.ps1 from HEAD when the index copy is unavailable or corrupt."
    }
    $backupIdx = $normalized.IndexOf('[System.IO.File]::Copy($target, $backupPath, $true)')
    $indexCheckoutIdx = $normalized.IndexOf('git checkout -- $entryScript')
    $headCheckoutIdx = $normalized.IndexOf('git checkout HEAD -- $entryScript')
    if ($backupIdx -lt 0 -or $indexCheckoutIdx -lt 0 -or $backupIdx -gt $indexCheckoutIdx) {
        throw "$Name must back up run-llm-hooks.ps1 before restoring it from the index."
    }
    if ($headCheckoutIdx -lt 0 -or $indexCheckoutIdx -gt $headCheckoutIdx) {
        throw "$Name must try index recovery before HEAD fallback."
    }
    if ($normalized -notmatch '&\s+\$target\s+-Mode\s+PreCommit\s+-AutoFix') {
        throw "$Name must invoke run-llm-hooks.ps1 -Mode PreCommit -AutoFix inside the bootstrap pwsh process."
    }
    $pwshCount = [regex]::Matches($normalized, '(?m)^\s*pwsh\s+-NoProfile\s+-File\s+"\$BOOTSTRAP_SCRIPT"').Count
    if ($pwshCount -ne 1) {
        throw "$Name must start exactly one bootstrap pwsh process; found $pwshCount."
    }
}

function New-TempFile {
    param(
        [string]$Content,
        [switch]$Utf8Bom
    )
    $path = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "llm-harness-test-$([Guid]::NewGuid()).md")
    $bytes = [System.Text.UTF8Encoding]::new([bool]$Utf8Bom).GetBytes($Content)
    [System.IO.File]::WriteAllBytes($path, $bytes)
    return $path
}

function New-HookBehaviorSandbox {
    param([string]$Prefix = 'llm-hook-behavior')

    $repoRoot = Split-Path -Parent $ScriptsDir
    $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("$Prefix-$([Guid]::NewGuid())")
    New-Item -ItemType Directory -Path $sandbox -Force | Out-Null

    $files = @(
        '.gitignore',
        'AGENTS.md', 'CLAUDE.md', 'GEMINI.md', 'CHATGPT.md', 'CODEX.md',
        'llms.txt', '.cursorrules', '.windsurfrules',
        '.github/copilot-instructions.md', '.cursor/rules/signal-fish-llm-context.mdc',
        '.githooks/pre-commit',
        '.devcontainer/post-create.sh',
        '.github/workflows/llm-harness.yml',
        '.pre-commit-config.yaml',
        '.llm/context.md', '.llm/index.md', '.llm/README.md',
        'scripts/run-llm-hooks.ps1',
        'scripts/generate-llm-index.ps1',
        'scripts/test-llm-harness.ps1',
        'scripts/preflight.ps1',
        'scripts/lint-llm.ps1',
        'scripts/install-git-hooks.ps1',
        'scripts/lib/LlmHarness.psm1'
    )

    foreach ($file in $files) {
        $src = Join-Path $repoRoot $file
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { continue }
        $dst = Join-Path $sandbox $file
        $dstDir = Split-Path -Parent $dst
        if (-not (Test-Path -LiteralPath $dstDir -PathType Container)) {
            New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
        }
        Copy-Item -LiteralPath $src -Destination $dst -Force
    }

    Push-Location $sandbox
    try {
        & git init -q --initial-branch=main 2>&1 | Out-Null
        & git config user.email 'test@example.com' 2>&1 | Out-Null
        & git config user.name 'test' 2>&1 | Out-Null
        & git add -A 2>&1 | Out-Null
        & git commit -q -m 'baseline' 2>&1 | Out-Null
    } finally {
        Pop-Location
    }

    return $sandbox
}

function Resolve-TestGitPath {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$GitPath
    )

    return (Resolve-LlmGitPath -RepoRoot $RepoRoot -GitPath $GitPath)
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

Assert-Test 'frontmatter: Read-LlmFrontmatter delegates to line parser' {
    $moduleContent = Get-Content -LiteralPath $ModulePath -Raw
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput(
        $moduleContent, [ref]$tokens, [ref]$parseErrors)
    if ($null -ne $parseErrors -and $parseErrors.Count -gt 0) {
        throw "LlmHarness.psm1 has parse errors: $($parseErrors | ForEach-Object { $_.Message } | Out-String)"
    }
    $func = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Read-LlmFrontmatter'
            }, $false))
    if ($func.Count -ne 1) {
        throw "Expected exactly one Read-LlmFrontmatter definition; got $($func.Count)."
    }
    $body = $func[0].Body.Extent.Text
    if ($body -notmatch 'ConvertFrom-LlmFrontmatterLines') {
        throw 'Read-LlmFrontmatter must delegate parsing to ConvertFrom-LlmFrontmatterLines so file and pre-read line callers cannot drift.'
    }
    if ($body -match 'for\s*\(' -or $body -match '^\s*\$closed\s*=' -or
        $body -match '\[A-Za-z0-9_-\]\+\):') {
        throw 'Read-LlmFrontmatter must not duplicate the frontmatter parsing loop or regex.'
    }
}

Assert-Test 'frontmatter: parses UTF-8 BOM-prefixed block' {
    $path = New-TempFile "---`ndescription: BOM ok`ntriggers: bom`ncategory: Core`n---`n# Title`n" -Utf8Bom
    try {
        $meta = Read-LlmFrontmatter -Path $path
        Expect-Equal $meta['description'] 'BOM ok'
        Expect-Equal $meta['triggers'] 'bom'
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

Assert-Test 'hook runner imports shared module' {
    $content = Get-Content -LiteralPath (Join-Path $ScriptsDir 'run-llm-hooks.ps1') -Raw
    if ($content -notmatch 'lib/LlmHarness\.psm1') {
        throw 'run-llm-hooks.ps1 must import lib/LlmHarness.psm1'
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

Assert-Test 'run-llm-hooks.ps1 invokes the self-tests' {
    $entry = Join-Path $ScriptsDir 'run-llm-hooks.ps1'
    $content = Get-Content -LiteralPath $entry -Raw
    if ($content -notmatch 'test-llm-harness\.ps1') {
        throw 'run-llm-hooks.ps1 must invoke scripts/test-llm-harness.ps1 (advertised behavior).'
    }
}

Assert-Test 'run-llm-hooks.ps1 exposes -AutoFix and -NoAutoFix switches' {
    $entry = Join-Path $ScriptsDir 'run-llm-hooks.ps1'
    $content = Get-Content -LiteralPath $entry -Raw
    if ($content -notmatch '\[switch\]\$AutoFix') {
        throw 'run-llm-hooks.ps1 must declare [switch]$AutoFix for self-healing pre-commit behavior.'
    }
    if ($content -notmatch '\[switch\]\$NoAutoFix') {
        throw 'run-llm-hooks.ps1 must declare [switch]$NoAutoFix so CI can force loud failure.'
    }
    if ($content -notmatch "\[ValidateSet\('PreCommit', 'AgentFast', 'Full', 'CI'\)\]") {
        throw 'run-llm-hooks.ps1 must expose explicit PreCommit, AgentFast, Full, and CI modes.'
    }
    if ($content -notmatch '\[switch\]\$Profile') {
        throw 'run-llm-hooks.ps1 must expose -Profile for hook performance diagnostics.'
    }
}

Assert-Test 'run-llm-hooks.ps1 generated status parser separates index and worktree states' {
    $entry = Join-Path $ScriptsDir 'run-llm-hooks.ps1'
    $content = Get-Content -LiteralPath $entry -Raw
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput(
        $content, [ref]$tokens, [ref]$parseErrors)
    if ($null -ne $parseErrors -and $parseErrors.Count -gt 0) {
        throw "run-llm-hooks.ps1 has parse errors: $($parseErrors | ForEach-Object { $_.Message } | Out-String)"
    }
    $func = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'ConvertFrom-GeneratedFileStatusLine'
            }, $false))
    if ($func.Count -ne 1) {
        throw "Expected exactly one ConvertFrom-GeneratedFileStatusLine definition; got $($func.Count)."
    }
    if ($func[0].Extent.Text -match '\bNeedsStaging\b') {
        throw 'Generated status parser must not expose the ambiguous NeedsStaging name; use explicit index/worktree fields.'
    }
    . ([scriptblock]::Create($func[0].Extent.Text))

    $cases = @(
        @{ Line = ' M .llm/index.md'; Index = ' '; Worktree = 'M'; Path = '.llm/index.md'; IsUntracked = $false; HasIndex = $false; HasWorktree = $true; Needs = $true },
        @{ Line = 'M  .llm/index.md'; Index = 'M'; Worktree = ' '; Path = '.llm/index.md'; IsUntracked = $false; HasIndex = $true; HasWorktree = $false; Needs = $false },
        @{ Line = 'MM .llm/index.md'; Index = 'M'; Worktree = 'M'; Path = '.llm/index.md'; IsUntracked = $false; HasIndex = $true; HasWorktree = $true; Needs = $true },
        @{ Line = 'A  .llm/index.md'; Index = 'A'; Worktree = ' '; Path = '.llm/index.md'; IsUntracked = $false; HasIndex = $true; HasWorktree = $false; Needs = $false },
        @{ Line = 'AM .llm/index.md'; Index = 'A'; Worktree = 'M'; Path = '.llm/index.md'; IsUntracked = $false; HasIndex = $true; HasWorktree = $true; Needs = $true },
        @{ Line = '?? .llm/new.md'; Index = '?'; Worktree = '?'; Path = '.llm/new.md'; IsUntracked = $true; HasIndex = $false; HasWorktree = $false; Needs = $true },
        @{ Line = ' D .llm/index.md'; Index = ' '; Worktree = 'D'; Path = '.llm/index.md'; IsUntracked = $false; HasIndex = $false; HasWorktree = $true; Needs = $true },
        @{ Line = 'D  .llm/index.md'; Index = 'D'; Worktree = ' '; Path = '.llm/index.md'; IsUntracked = $false; HasIndex = $true; HasWorktree = $false; Needs = $false },
        @{ Line = ''; Index = ' '; Worktree = ' '; Path = ''; IsUntracked = $false; HasIndex = $false; HasWorktree = $false; Needs = $false }
    )
    foreach ($case in $cases) {
        $parsed = ConvertFrom-GeneratedFileStatusLine -Line $case.Line
        Expect-Equal "$($parsed.Index)" $case.Index "index column for '$($case.Line)'"
        Expect-Equal "$($parsed.Worktree)" $case.Worktree "worktree column for '$($case.Line)'"
        Expect-Equal $parsed.Path $case.Path "path for '$($case.Line)'"
        Expect-Equal $parsed.IsUntracked $case.IsUntracked "IsUntracked for '$($case.Line)'"
        Expect-Equal $parsed.HasIndexChange $case.HasIndex "HasIndexChange for '$($case.Line)'"
        Expect-Equal $parsed.HasWorktreeChange $case.HasWorktree "HasWorktreeChange for '$($case.Line)'"
        Expect-Equal $parsed.NeedsWorktreeStaging $case.Needs "NeedsWorktreeStaging for '$($case.Line)'"
    }
}

Assert-Test 'local pre-commit entry points pass -AutoFix; CI passes -NoAutoFix' {
    $repoRoot = Split-Path -Parent $ScriptsDir
    $shim = Get-Content -LiteralPath (Join-Path $repoRoot '.githooks/pre-commit') -Raw
    if ($shim -notmatch '-AutoFix') {
        throw '.githooks/pre-commit must pass -AutoFix to run-llm-hooks.ps1 (automated recovery is required).'
    }
    if ($shim -notmatch '-Mode PreCommit') {
        throw '.githooks/pre-commit must pass -Mode PreCommit to use the fast local hook path.'
    }
    $mirror = Get-Content -LiteralPath (Join-Path $repoRoot '.githooks/pre-commit.ps1') -Raw
    if ($mirror -notmatch '-AutoFix') {
        throw '.githooks/pre-commit.ps1 must pass -AutoFix to run-llm-hooks.ps1.'
    }
    if ($mirror -notmatch '-Mode PreCommit') {
        throw '.githooks/pre-commit.ps1 must pass -Mode PreCommit.'
    }
    $preCommitConfigPath = Join-Path $repoRoot '.pre-commit-config.yaml'
    if (Test-Path -LiteralPath $preCommitConfigPath -PathType Leaf) {
        $preCommitConfig = Get-Content -LiteralPath $preCommitConfigPath -Raw
        $entryLine = ($preCommitConfig -split "`r?`n" | Where-Object { $_ -match '^\s*entry:\s+.*run-llm-hooks\.ps1' } | Select-Object -First 1)
        if ([string]::IsNullOrWhiteSpace($entryLine)) {
            throw '.pre-commit-config.yaml must define a run-llm-hooks.ps1 entry.'
        }
        if ($entryLine -notmatch '-AutoFix') {
            throw '.pre-commit-config.yaml must pass -AutoFix to mirror installed local hook recovery behavior.'
        }
        if ($entryLine -notmatch '-Mode\s+PreCommit') {
            throw '.pre-commit-config.yaml must use -Mode PreCommit so compatibility hooks use the fast path.'
        }
        if ($entryLine -match '-SkipStagedCheck') {
            throw '.pre-commit-config.yaml must not pass -SkipStagedCheck; AutoFix must be able to stage regenerated files.'
        }
        if ($entryLine -match '-NoAutoFix') {
            throw '.pre-commit-config.yaml must not pass -NoAutoFix; CI owns loud failure mode.'
        }
    }
    $workflow = Join-Path $repoRoot '.github/workflows/llm-harness.yml'
    if (Test-Path -LiteralPath $workflow -PathType Leaf) {
        $ci = Get-Content -LiteralPath $workflow -Raw
        if ($ci -notmatch '-NoAutoFix') {
            throw '.github/workflows/llm-harness.yml must pass -NoAutoFix so CI fails loudly on drift.'
        }
    }
}

Assert-Test 'run-llm-hooks.ps1 uses shared staging artifact helper' {
    $entry = Join-Path $ScriptsDir 'run-llm-hooks.ps1'
    $content = Get-Content -LiteralPath $entry -Raw
    # Either the strict helper (Get-LlmStagingArtifacts) or the broader
    # superset (Get-LlmStrayWorkingTreeArtifacts) is acceptable; both are
    # null-safe and single-sourced through LlmHarness.psm1. The broader
    # helper additionally catches the gitignored `*.tmp` blind spot.
    if ($content -notmatch 'Get-LlmStagingArtifacts' -and $content -notmatch 'Get-LlmStrayWorkingTreeArtifacts') {
        throw 'run-llm-hooks.ps1 must use Get-LlmStagingArtifacts or Get-LlmStrayWorkingTreeArtifacts for null-safe, single-sourced artifact discovery.'
    }
    if ($content -match '(?m)^\s*\$StagingArtifactPatterns\s*=') {
        throw 'run-llm-hooks.ps1 must not declare $StagingArtifactPatterns; use Get-LlmDefaultStrayPatterns from the shared module.'
    }
    if ($content -match '@\(& git ls-files -- @StagingArtifactPatterns\)\s*\|') {
        throw 'run-llm-hooks.ps1 must not filter git artifact output during assignment; that pattern can collapse empty arrays to $null.'
    }
}

Assert-Test 'agent-check.ps1 exists and delegates to run-llm-hooks.ps1' {
    $check = Join-Path $ScriptsDir 'agent-check.ps1'
    if (-not (Test-Path -LiteralPath $check -PathType Leaf)) {
        throw 'Missing scripts/agent-check.ps1 (fast post-edit validator for agents).'
    }
    $content = Get-Content -LiteralPath $check -Raw
    if ($content -notmatch 'run-llm-hooks\.ps1') {
        throw 'scripts/agent-check.ps1 must delegate to run-llm-hooks.ps1 to stay single-sourced.'
    }
    if ($content -notmatch 'SkipStagedCheck\s*=\s*\$true' -or $content -notmatch 'NoAutoFix\s*=\s*\$true') {
        throw 'scripts/agent-check.ps1 must pass SkipStagedCheck and NoAutoFix to the runner.'
    }
    if ($content -notmatch 'Mode\s*=\s*\$mode' -or $content -notmatch 'AgentFast') {
        throw 'scripts/agent-check.ps1 must delegate to run-llm-hooks.ps1 -Mode AgentFast by default.'
    }
}

# --- Repo hygiene: no stray staging artifacts ------------------------------

Assert-Test 'staging artifact helper returns empty array when no files match' {
    $repoRoot = Split-Path -Parent $ScriptsDir
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        return  # git unavailable; skip silently in this test (linter has its own check).
    }
    $artifacts = @(Get-LlmStagingArtifacts -RepoRoot $repoRoot -Patterns @('llm-harness-no-such-artifact-*.definitely-missing'))
    Expect-Equal $artifacts.Count 0
}

Assert-Test 'staging artifact helper returns empty array for empty patterns' {
    $repoRoot = Split-Path -Parent $ScriptsDir
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        return  # git unavailable; skip silently in this test (linter has its own check).
    }
    $artifacts = @(Get-LlmStagingArtifacts -RepoRoot $repoRoot -Patterns @())
    Expect-Equal $artifacts.Count 0
}

Assert-Test 'stray-artifact pathspec expansion recurses basename patterns' {
    if (-not (Get-Command ConvertTo-LlmStrayArtifactPathspecs -ErrorAction SilentlyContinue)) {
        throw 'ConvertTo-LlmStrayArtifactPathspecs is not exported from the shared module.'
    }
    $pathspecs = @(ConvertTo-LlmStrayArtifactPathspecs -Patterns @(
            '.DS_Store', 'Thumbs.db', '.#*', '#*#', 'scripts/*.tmp', '', $null
        ))
    foreach ($expected in @(
            '.DS_Store',
            ':(glob)**/.DS_Store',
            'Thumbs.db',
            ':(glob)**/Thumbs.db',
            '.#*',
            ':(glob)**/.#*',
            '#*#',
            ':(glob)**/#*#',
            'scripts/*.tmp'
        )) {
        if ($pathspecs -notcontains $expected) {
            throw "Expected expanded pathspec '$expected'; got: $($pathspecs -join ', ')"
        }
    }
    if ($pathspecs -contains ':(glob)**/scripts/*.tmp') {
        throw 'Directory-qualified pathspecs must not be rewritten as basename globs.'
    }

    $deduped = @(ConvertTo-LlmStrayArtifactPathspecs -Patterns @('.DS_Store', '.DS_Store'))
    Expect-Equal (@($deduped | Where-Object { $_ -eq '.DS_Store' }).Count) 1
    Expect-Equal (@($deduped | Where-Object { $_ -eq ':(glob)**/.DS_Store' }).Count) 1
}

Assert-Test 'staging artifact helper default patterns find non-ignored editor artifacts' {
    $repoRoot = Split-Path -Parent $ScriptsDir
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        return  # git unavailable; skip silently in this test (linter has its own check).
    }
    $tempName = "llm-harness-default-pattern-$([Guid]::NewGuid()).swp"
    $tempPath = Join-Path $repoRoot $tempName
    [System.IO.File]::WriteAllText($tempPath, 'sentinel')
    try {
        $artifacts = @(Get-LlmStagingArtifacts -RepoRoot $repoRoot)
        $found = @($artifacts | Where-Object { $_.Path -eq $tempName })
        if ($found.Count -ne 1) {
            throw "Expected Get-LlmStagingArtifacts default patterns to find $tempName; got: $($artifacts.Path -join ', ')"
        }
        if ($found[0].IsTracked) {
            throw "$tempName should be reported as IsTracked=false."
        }
    } finally {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    }
}

Assert-Test 'stray helpers find nested basename-style editor artifacts' {
    $repoRoot = Split-Path -Parent $ScriptsDir
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        return  # git unavailable; skip silently in this test (linter has its own check).
    }
    $tempDirName = "llm-harness-recursive-stray-$([Guid]::NewGuid())"
    $nestedDir = Join-Path (Join-Path (Join-Path $repoRoot $tempDirName) 'deep') 'nested'
    New-Item -ItemType Directory -Path $nestedDir -Force | Out-Null
    $files = @(
        @{ Rel = "$tempDirName/deep/nested/.DS_Store"; Full = Join-Path $nestedDir '.DS_Store' },
        @{ Rel = "$tempDirName/deep/nested/.#notes.md"; Full = Join-Path $nestedDir '.#notes.md' },
        @{ Rel = "$tempDirName/deep/nested/#notes.md#"; Full = Join-Path $nestedDir '#notes.md#' }
    )
    foreach ($file in $files) {
        [System.IO.File]::WriteAllText($file.Full, 'sentinel')
    }
    try {
        $patterns = @('.DS_Store', '.#*', '#*#')
        $stagingArtifacts = @(Get-LlmStagingArtifacts -RepoRoot $repoRoot -Patterns $patterns)
        $strayArtifacts = @(Get-LlmStrayWorkingTreeArtifacts -RepoRoot $repoRoot -Patterns $patterns)
        foreach ($file in $files) {
            if ($stagingArtifacts.Path -notcontains $file.Rel) {
                throw "Expected Get-LlmStagingArtifacts to find nested artifact $($file.Rel); got: $($stagingArtifacts.Path -join ', ')"
            }
            if ($strayArtifacts.Path -notcontains $file.Rel) {
                throw "Expected Get-LlmStrayWorkingTreeArtifacts to find nested artifact $($file.Rel); got: $($strayArtifacts.Path -join ', ')"
            }
        }
    } finally {
        Remove-Item -LiteralPath (Join-Path $repoRoot $tempDirName) -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Assert-Test 'no stray staging artifacts in the working tree' {
    $repoRoot = Split-Path -Parent $ScriptsDir
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        return  # git unavailable; skip silently in this test (linter has its own check).
    }
    $patterns = @(Get-LlmDefaultStrayPatterns)
    $offenders = @(Get-LlmStrayWorkingTreeArtifacts -RepoRoot $repoRoot -Patterns $patterns)
    if ($offenders.Count -gt 0) {
        throw "Found stray staging artifacts: $($offenders.Path -join ', ')"
    }
}

# --- All committed PowerShell sources parse cleanly ------------------------

Assert-Test 'all committed PowerShell sources parse cleanly' {
    $repoRoot = Split-Path -Parent $ScriptsDir
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        return  # git unavailable; skip silently.
    }
    Push-Location $repoRoot
    try {
        $files = @(& git ls-files -- '*.ps1' '*.psm1' '*.psd1' 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "git ls-files (PowerShell sources) failed with exit $LASTEXITCODE`: $($files -join '; ')"
        }
        $files = @($files | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    } finally {
        Pop-Location
    }
    $failed = New-Object System.Collections.Generic.List[string]
    foreach ($rel in $files) {
        $full = Join-Path $repoRoot $rel
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $full, [ref]$tokens, [ref]$parseErrors)
        if ($null -ne $parseErrors -and $parseErrors.Count -gt 0) {
            foreach ($err in $parseErrors) {
                $failed.Add("$rel`:$($err.Extent.StartLineNumber): $($err.Message)")
            }
        }
    }
    if ($failed.Count -gt 0) {
        throw "PowerShell parse errors:`n  - " + ($failed -join "`n  - ")
    }
}

Assert-Test 'tracked shebang scripts use LF attributes and bytes' {
    $repoRoot = Split-Path -Parent $ScriptsDir
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        return  # git unavailable; skip silently.
    }
    Push-Location $repoRoot
    try {
        $files = @(& git ls-files -- '*.ps1' '*.psm1' '*.psd1' '.githooks/*' '.claude/hooks/*' 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "git ls-files (shebang candidates) failed with exit $LASTEXITCODE`: $($files -join '; ')"
        }
        $files = @($files | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    } finally {
        Pop-Location
    }

    $checked = 0
    $failed = New-Object System.Collections.Generic.List[string]
    foreach ($rel in $files) {
        $full = Join-Path $repoRoot $rel
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
        $bytes = [System.IO.File]::ReadAllBytes($full)
        if ($bytes.Length -lt 2 -or $bytes[0] -ne 35 -or $bytes[1] -ne 33) {
            continue
        }
        $checked++
        $newlineIndex = [Array]::IndexOf($bytes, [byte]10)
        if ($newlineIndex -lt 0) {
            $failed.Add("$rel has a shebang but no LF newline after it.")
        } elseif ($newlineIndex -gt 0 -and $bytes[$newlineIndex - 1] -eq 13) {
            $failed.Add("$rel has a CRLF shebang line; direct Unix execution may look for pwsh\\r.")
        }
        Push-Location $repoRoot
        try {
            $attrOutput = @(& git check-attr eol -- $rel 2>&1)
            if ($LASTEXITCODE -ne 0) {
                $failed.Add("git check-attr failed for $rel`: $($attrOutput -join '; ')")
                continue
            }
        } finally {
            Pop-Location
        }
        $attrLine = ($attrOutput -join "`n")
        if ($attrLine -notmatch ':\s+eol:\s+lf(\s|$)') {
            $failed.Add("$rel must have git attribute eol=lf; got '$attrLine'.")
        }
    }
    if ($checked -eq 0) {
        throw 'No tracked shebang scripts were found; the LF guard is not exercising anything.'
    }
    if ($failed.Count -gt 0) {
        throw "Shebang line-ending failures:`n  - " + ($failed -join "`n  - ")
    }
}

# --- Dev container guardrails ---------------------------------------------

Assert-Test 'devcontainer Codex installer is pinned, parseable, and validated' {
    $repoRoot = Split-Path -Parent $ScriptsDir
    $installer = Join-Path $repoRoot '.devcontainer/install-codex.sh'
    if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
        throw 'Missing .devcontainer/install-codex.sh'
    }
    $content = Get-Content -LiteralPath $installer -Raw
    if ($content -notmatch 'CODEX_CLI_VERSION="\$\{CODEX_CLI_VERSION:-[0-9]+\.[0-9]+\.[0-9]+\}"') {
        throw 'install-codex.sh must pin CODEX_CLI_VERSION to a concrete semver default.'
    }
    if ($content -notmatch 'CODEX_NPM_PACKAGE="@openai/codex"') {
        throw 'install-codex.sh must identify @openai/codex as the package to install.'
    }
    if ($content -notmatch 'npm install --global' -or $content -notmatch '\$\{CODEX_NPM_PACKAGE\}@\$\{CODEX_CLI_VERSION\}') {
        throw 'install-codex.sh must install the official @openai/codex package at the pinned version.'
    }
    if ($content -notmatch 'command -v codex' -or $content -notmatch 'codex --version') {
        throw 'install-codex.sh must verify codex is on PATH and report its version.'
    }
    if ($content -notmatch 'npm config get prefix' -or $content -notmatch 'npm_bin_dir=' -or $content -notmatch 'export PATH="\$\{npm_bin_dir\}:\$\{PATH\}"') {
        throw 'install-codex.sh must derive npm global bin directory and prepend it to PATH.'
    }
    if ($content -notmatch 'could not parse npm package metadata' -or $content -notmatch 'npm list returned no package metadata') {
        throw 'install-codex.sh must log npm metadata lookup failures before reinstalling.'
    }
    if (Get-Command bash -ErrorAction SilentlyContinue) {
        & bash -n $installer
        if ($LASTEXITCODE -ne 0) {
            throw 'install-codex.sh failed bash -n syntax validation.'
        }
    }
}

Assert-Test 'devcontainer post-create installs direct hooks, Codex, and reports summary' {
    $repoRoot = Split-Path -Parent $ScriptsDir
    $postCreate = Join-Path $repoRoot '.devcontainer/post-create.sh'
    if (-not (Test-Path -LiteralPath $postCreate -PathType Leaf)) {
        throw 'Missing .devcontainer/post-create.sh'
    }
    $content = Get-Content -LiteralPath $postCreate -Raw

    foreach ($requirement in @(
            [pscustomobject]@{
                Pattern     = 'install-codex\.sh'
                Requirement = 'invoke .devcontainer/install-codex.sh'
                Diagnostic  = 'install-codex|Codex CLI|CODEX_VERSION_OUTPUT'
            },
            [pscustomobject]@{
                Pattern     = 'install-git-hooks\.ps1\s+-Force'
                Requirement = 'install the direct .git/hooks shim with scripts/install-git-hooks.ps1 -Force'
                Diagnostic  = 'install-git-hooks|git hooks|pre-commit'
            },
            [pscustomobject]@{
                Pattern     = 'codex --version'
                Requirement = 'include codex --version in the toolchain summary'
                Diagnostic  = 'Toolchain summary|codex|CODEX_VERSION_OUTPUT'
            },
            [pscustomobject]@{
                Pattern     = 'CODEX_VERSION_OUTPUT='
                Requirement = 'capture Codex version output before reporting the toolchain summary'
                Diagnostic  = 'CODEX_VERSION_OUTPUT|codex --version|Codex CLI'
            },
            [pscustomobject]@{
                Pattern     = 'Codex CLI is missing after post-create install'
                Requirement = 'fail loudly if Codex is missing after install-codex.sh runs'
                Diagnostic  = 'Codex CLI|CODEX_VERSION_OUTPUT|exit 1'
            },
            [pscustomobject]@{
                Pattern     = 'Failed to install PowerShell profile'
                Requirement = 'fail loudly if PowerShell profile installation fails'
                Diagnostic  = 'PowerShell profile|profile.ps1|exit 1'
            },
            [pscustomobject]@{
                Pattern     = 'ensure_writable_dir'
                Requirement = 'repair root-owned mounted directories before installing hooks'
                Diagnostic  = 'ensure_writable_dir|sudo chown|commandhistory'
            },
            [pscustomobject]@{
                Pattern     = 'sudo chown -R'
                Requirement = 'repair root-owned mounted directories before installing hooks'
                Diagnostic  = 'ensure_writable_dir|sudo chown|commandhistory'
            }
        )) {
        Assert-TextMatches `
            -Subject '.devcontainer/post-create.sh' `
            -Content $content `
            -Pattern $requirement.Pattern `
            -Requirement $requirement.Requirement `
            -DiagnosticPattern $requirement.Diagnostic
    }
    Assert-TextDoesNotMatch `
        -Subject '.devcontainer/post-create.sh' `
        -Content $content `
        -Pattern 'pre-commit\s+install' `
        -Requirement 'not install the pre-commit framework hook; the direct shim is canonical' `
        -DiagnosticPattern 'pre-commit|install-git-hooks|direct git hooks'

    if (Get-Command bash -ErrorAction SilentlyContinue) {
        & bash -n $postCreate
        if ($LASTEXITCODE -ne 0) {
            throw 'post-create.sh failed bash -n syntax validation.'
        }
    }
}

Assert-Test 'devcontainer pre-commit remnants are optional compatibility only' {
    $repoRoot = Split-Path -Parent $ScriptsDir
    $dockerfile = Get-Content -LiteralPath (Join-Path $repoRoot '.devcontainer/Dockerfile') -Raw
    $devcontainer = Get-Content -LiteralPath (Join-Path $repoRoot '.devcontainer/devcontainer.json') -Raw
    $postCreate = Get-Content -LiteralPath (Join-Path $repoRoot '.devcontainer/post-create.sh') -Raw
    $readme = Get-Content -LiteralPath (Join-Path $repoRoot '.devcontainer/README.md') -Raw

    Assert-TextDoesNotMatch `
        -Subject '.devcontainer/post-create.sh' `
        -Content $postCreate `
        -Pattern 'pre-commit\s+install' `
        -Requirement 'not install the pre-commit framework hook; scripts/install-git-hooks.ps1 owns the canonical direct shim' `
        -DiagnosticPattern 'pre-commit|install-git-hooks|direct git hooks'

    $optionalCompatibilityContracts = @(
        [pscustomobject]@{
            Subject           = '.devcontainer/Dockerfile'
            Content           = $dockerfile
            AppliesWhen       = 'pipx install pre-commit'
            Requirements      = @(
                [pscustomobject]@{ Pattern = 'Optional compatibility'; Requirement = 'document pre-commit as optional compatibility tooling' },
                [pscustomobject]@{ Pattern = 'git rev-parse --git-path hooks'; Requirement = 'point readers at the canonical direct hook path' },
                [pscustomobject]@{ Pattern = 'devcontainer must not run\s+`pre-commit install`'; Requirement = 'explicitly forbid framework hook installation' }
            )
            DiagnosticPattern = 'pre-commit|compatibility|canonical|git rev-parse'
        },
        [pscustomobject]@{
            Subject           = '.devcontainer/devcontainer.json'
            Content           = $devcontainer
            AppliesWhen       = '\.cache/pre-commit'
            Requirements      = @(
                [pscustomobject]@{ Pattern = 'Optional compatibility cache'; Requirement = 'mark the pre-commit cache as optional compatibility tooling' },
                [pscustomobject]@{ Pattern = 'canonical hook is the direct shim'; Requirement = 'name the direct shim as canonical' }
            )
            DiagnosticPattern = 'pre-commit|compatibility|canonical|cache'
        },
        [pscustomobject]@{
            Subject           = '.devcontainer/README.md'
            Content           = $readme
            AppliesWhen       = 'pre-commit'
            Requirements      = @(
                [pscustomobject]@{ Pattern = 'optional compatibility'; Requirement = 'identify pre-commit as optional compatibility tooling only' },
                [pscustomobject]@{ Pattern = 'no framework hook'; Requirement = 'document that no framework hook is installed' }
            )
            DiagnosticPattern = 'pre-commit|compatibility|framework hook|Git hook'
        },
        [pscustomobject]@{
            Subject           = '.devcontainer/post-create.sh'
            Content           = $postCreate
            AppliesWhen       = 'pre-commit --version'
            Requirements      = @(
                [pscustomobject]@{
                    Pattern     = '(?m)^\s*printf\s+[''"]\s*pre-commit(?:\s+optional|\s*\(optional\)|\s*\[optional\])\s*:\s+%s\\n[''"]\s+["'']\$\(\s*pre-commit --version\b'
                    Requirement = 'label the pre-commit toolchain summary as optional when reporting the CLI'
                }
            )
            DiagnosticPattern = 'pre-commit|Toolchain summary'
        }
    )

    foreach ($contract in $optionalCompatibilityContracts) {
        if ($contract.Content -notmatch $contract.AppliesWhen) { continue }
        foreach ($requirement in @($contract.Requirements)) {
            Assert-TextMatches `
                -Subject $contract.Subject `
                -Content $contract.Content `
                -Pattern $requirement.Pattern `
                -Requirement $requirement.Requirement `
                -DiagnosticPattern $contract.DiagnosticPattern
        }
    }
}

Assert-Test 'devcontainer PowerShell profile tolerates PSReadLine assembly preload conflicts' {
    $repoRoot = Split-Path -Parent $ScriptsDir
    $profilePath = Join-Path $repoRoot '.devcontainer/pwsh-profile.ps1'
    if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
        throw 'Missing .devcontainer/pwsh-profile.ps1'
    }
    $content = Get-Content -LiteralPath $profilePath -Raw
    if ($content -match 'Get-Module\s+-ListAvailable\s+PSReadLine') {
        throw 'pwsh-profile.ps1 must not use Get-Module -ListAvailable as the PSReadLine loaded-state guard.'
    }
    if ($content -match 'Import-Module\s+PSReadLine\s+-ErrorAction\s+SilentlyContinue') {
        throw 'pwsh-profile.ps1 must catch PSReadLine import failures instead of relying on SilentlyContinue.'
    }

    $tempScript = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "llm-pwsh-profile-test-$([Guid]::NewGuid()).ps1")
    $profileLiteral = $profilePath.Replace("'", "''")
    $testScript = @"
`$ErrorActionPreference = 'Stop'
function Import-Module {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromRemainingArguments = `$true)]
        [object[]]`$RemainingArgs
    )
    throw [System.IO.FileLoadException]::new("Could not load file or assembly 'Microsoft.PowerShell.PSReadLine, Version=2.4.5.0, Culture=neutral, PublicKeyToken=null'. Assembly with same name is already loaded")
}
. '$profileLiteral'
'profile-ok'
"@
    try {
        [System.IO.File]::WriteAllText($tempScript, $testScript, [System.Text.UTF8Encoding]::new($false))
        $output = @(& pwsh -NoProfile -File $tempScript 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "profile load failed with exit $LASTEXITCODE`: $($output -join '; ')"
        }
        if ($output -notcontains 'profile-ok') {
            throw "profile load did not reach completion. Output: $($output -join '; ')"
        }
    } finally {
        Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
    }
} -Behavioral

# --- install-git-hooks.ps1 only references defined variables ---------------

Assert-Test 'install-git-hooks.ps1 has no undefined variable references' {
    $path = Join-Path $ScriptsDir 'install-git-hooks.ps1'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw 'Missing scripts/install-git-hooks.ps1'
    }
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $path, [ref]$tokens, [ref]$parseErrors)
    if ($null -ne $parseErrors -and $parseErrors.Count -gt 0) {
        throw "Parse errors in install-git-hooks.ps1: $($parseErrors | ForEach-Object { $_.Message } | Out-String)"
    }
    # Collect variable assignments (definitions) and usages.
    $defined = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    # Built-in / automatic variables that are always available.
    foreach ($auto in @(
            'PSScriptRoot', 'PSCommandPath', 'PSBoundParameters', 'MyInvocation',
            'args', '_', 'PSItem', 'null', 'true', 'false', 'LASTEXITCODE',
            'Error', 'PWD', 'Host', 'HOME', 'PSVersionTable', 'ErrorActionPreference',
            'PSCmdlet', 'this', 'input')) {
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
    $usages = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.VariableExpressionAst]
        }, $true)
    $undefined = New-Object System.Collections.Generic.List[string]
    foreach ($u in $usages) {
        $name = $u.VariablePath.UserPath
        if ($u.VariablePath.IsDriveQualified) { continue }
        if ($defined.Contains($name)) { continue }
        $undefined.Add("`$$name (line $($u.Extent.StartLineNumber))")
    }
    if ($undefined.Count -gt 0) {
        throw "Undefined variable references: " + ($undefined -join ', ')
    }
}

Assert-Test 'install-git-hooks.ps1 materializes a portable POSIX-sh hook into git hooks path' {
    $path = Join-Path $ScriptsDir 'install-git-hooks.ps1'
    $content = Get-Content -LiteralPath $path -Raw
    if ($content -notmatch 'git rev-parse --git-path hooks') {
        throw 'install-git-hooks.ps1 must install into the hooks directory resolved via git rev-parse --git-path hooks.'
    }
    # MUST be a POSIX sh shebang, NOT pwsh: PowerShell's -File parameter
    # refuses files without a `.ps1` extension, so on Windows (where git
    # dispatches hooks via Git-for-Windows' bundled sh.exe) a pwsh shebang
    # produces: "Processing -File '.git/hooks/pre-commit' failed because
    # the file does not have a '.ps1' extension." A `#!/usr/bin/env sh`
    # shim works on Linux, macOS, AND Windows.
    if ($content -notmatch '#!/usr/bin/env sh') {
        throw 'install-git-hooks.ps1 must emit a #!/usr/bin/env sh shebang. A pwsh shebang on an extensionless hook breaks on Windows because pwsh -File requires a .ps1 extension.'
    }
    # Guard against regression: the *emitted hook body* (here-string)
    # must not start with a pwsh shebang. We scan only the here-string
    # body, not the surrounding documentation comments which may reference
    # the broken pattern. The non-greedy `.*?` only matches up to the
    # FIRST closing `"@`; install-git-hooks.ps1 has exactly one here-
    # string today so this targets the hook body. If a second here-string
    # is ever added we will need to iterate Matches() instead — defend
    # against that here so the test stays scoped.
    $hereStringMatches = [regex]::Matches($content, '(?s)@"\s*\r?\n(?<body>.*?)\r?\n"@')
    if ($hereStringMatches.Count -gt 1) {
        throw "install-git-hooks.ps1 has $($hereStringMatches.Count) here-strings; this test only validates the first one. Either consolidate or extend the test to iterate all of them."
    }
    if ($hereStringMatches.Count -eq 1 -and $hereStringMatches[0].Groups['body'].Value -match '(?m)^#!/usr/bin/env pwsh') {
        throw 'install-git-hooks.ps1 must NOT emit a #!/usr/bin/env pwsh shebang for the .git/hooks/pre-commit shim (Windows pwsh -File rejects extensionless files).'
    }
    if ($content -notmatch 'llm-harness-installed-hook') {
        throw 'install-git-hooks.ps1 must mark its generated hook so re-installs are idempotent and foreign hooks are detected.'
    }
    if ($content -notmatch 'run-llm-hooks\.ps1') {
        throw 'install-git-hooks.ps1 must delegate to scripts/run-llm-hooks.ps1.'
    }
    if ($content -notmatch '-AutoFix') {
        throw 'install-git-hooks.ps1 must pass -AutoFix to run-llm-hooks.ps1 (automated recovery is required).'
    }
}

Assert-Test '.githooks/pre-commit.ps1 carries a pwsh shebang' {
    $repoRoot = Split-Path -Parent $ScriptsDir
    $mirror = Join-Path $repoRoot '.githooks/pre-commit.ps1'
    $first = (Get-Content -LiteralPath $mirror -TotalCount 1)
    if ($first -ne '#!/usr/bin/env pwsh') {
        throw ".githooks/pre-commit.ps1 must start with '#!/usr/bin/env pwsh' so Git can execute it directly on Windows-without-sh installs. Got: '$first'"
    }
}

# Defensive structural test. The install script has been corrupted twice
# by stale editor buffers re-introducing the legacy code on top of the
# new code, producing parse errors and undefined `$shimTarget`
# references. These assertions fail loudly the instant any such
# regression appears, before the linter / hook ever runs the corrupted
# script.
Assert-Test 'install-git-hooks.ps1 has no legacy / duplicate-block regressions' {
    $path = Join-Path $ScriptsDir 'install-git-hooks.ps1'
    $content = Get-Content -LiteralPath $path -Raw

    # The new installer does NOT set `core.hooksPath = .githooks`; it only
    # CLEARS that legacy value. Forbid the assignment pattern so an
    # accidental re-merge of the old script is rejected. Matches:
    #   git config core.hooksPath $desiredHooksPath
    #   git config core.hooksPath .githooks
    if ($content -match '(?m)^\s*(?:&\s*)?git\s+config\s+core\.hooksPath\s+(?!--unset|--get)\S') {
        throw 'install-git-hooks.ps1 must NOT set core.hooksPath; the live hook lives in the resolved git hooks path and the script only clears stale legacy values.'
    }

    # The legacy installer used `$shimTarget`; the new installer uses
    # `$installedHook`. Forbid the legacy name so its reappearance fails
    # before pwsh ever parses it.
    if ($content -match '\$shimTarget\b') {
        throw 'install-git-hooks.ps1 references the legacy $shimTarget variable; the new installer uses $installedHook resolved from `git rev-parse --git-path hooks`.'
    }

    # The script must contain EXACTLY ONE Push-Location block. A second
    # one is the unmistakable signature of the corruption pattern (old
    # block + new block merged together).
    $pushCount = [regex]::Matches($content, '(?m)^\s*Push-Location\s+\$RepoRoot\b').Count
    if ($pushCount -ne 1) {
        throw "install-git-hooks.ps1 must contain exactly one Push-Location block; found $pushCount. This usually means a stale editor buffer re-merged old code on top of the new script."
    }

    # Same for the param() block.
    $paramCount = [regex]::Matches($content, '(?m)^param\s*\(').Count
    if ($paramCount -ne 1) {
        throw "install-git-hooks.ps1 must contain exactly one param() block; found $paramCount."
    }

    # The legacy installer required a `.githooks` directory to exist as a
    # precondition (`throw "Missing hooks directory: $hooksPath"`). The
    # new installer does not. Catch reintroduction of the legacy check.
    if ($content -match 'Missing hooks directory:') {
        throw 'install-git-hooks.ps1 contains the legacy "Missing hooks directory" precondition; the new installer materialises into the resolved git hooks path instead.'
    }
}

Assert-Test 'install-git-hooks.ps1 normalizes legacy core.hooksPath variants' {
    $path = Join-Path $ScriptsDir 'install-git-hooks.ps1'
    $content = Get-Content -LiteralPath $path -Raw
    if ($content -match '\$existingHooksPath\s+-eq\s+[''"`]\.githooks[''"`]') {
        throw 'install-git-hooks.ps1 must not compare core.hooksPath to only the exact string .githooks; trailing separators and relative variants must be normalized.'
    }

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$tokens, [ref]$parseErrors)
    if ($null -ne $parseErrors -and $parseErrors.Count -gt 0) {
        throw "Parse errors in install-git-hooks.ps1: $($parseErrors | ForEach-Object { $_.Message } | Out-String)"
    }

    $neededFunctions = @('Get-InstallPathComparison', 'ConvertTo-NormalizedHooksPath', 'Test-LegacyHooksPath')
    $functions = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $neededFunctions -contains $node.Name
            }, $false))
    $missingFunctions = @($neededFunctions | Where-Object { $functions.Name -notcontains $_ })
    if ($missingFunctions.Count -gt 0) {
        throw "install-git-hooks.ps1 is missing path-normalization helpers: $($missingFunctions -join ', ')"
    }

    $repoRoot = Split-Path -Parent $ScriptsDir
    $repoRootLiteral = $repoRoot.Replace("'", "''")
    $functionText = ($functions | ForEach-Object { $_.Extent.Text }) -join "`n`n"
    $normalizationCheck = @"
Set-StrictMode -Version Latest
`$RepoRoot = '$repoRootLiteral'
$functionText
`$variants = @('.githooks', '.githooks/', '.githooks\', './.githooks', '.\.githooks/')
foreach (`$variant in `$variants) {
    if (-not (Test-LegacyHooksPath `$variant)) {
        throw "Expected variant '`$variant' to be recognized as legacy .githooks."
    }
}
if (Test-LegacyHooksPath '.githooks-other') {
    throw 'Foreign hook paths must not be treated as legacy .githooks values.'
}
"@
    & ([scriptblock]::Create($normalizationCheck))
}

# --- Toolkit-wide structural defenses --------------------------------------

# The lint-llm.ps1 corruption that motivated `preflight.ps1` was an editor
# saving stale buffer contents on top of a freshly rewritten script,
# leaving orphan code blocks after the last legitimate statement. The
# install-git-hooks regression had the same shape. The assertions below
# generalize the install-script-only guards to every toolkit entry point
# so any future "agent re-introduces stale code" failure surfaces in a
# unit test rather than a hook crash.

# Scripts that take a `param()` block (entry-point .ps1). Module files
# (.psm1) and library scripts deliberately do not. The structural tests
# for param() / orphan content / parse cleanliness all use this list.
$ToolkitScripts = @(
    'scripts/run-llm-hooks.ps1',
    'scripts/lint-llm.ps1',
    'scripts/generate-llm-index.ps1',
    'scripts/install-git-hooks.ps1',
    'scripts/agent-check.ps1',
    'scripts/test-llm-harness.ps1',
    'scripts/preflight.ps1',
    '.claude/hooks/parse-check-powershell.ps1',
    '.claude/hooks/validate-llm-context.ps1',
    '.claude/hooks/preflight-stop.ps1',
    '.claude/hooks/session-reminder.ps1'
)

# Modules and other PowerShell files that should also parse-check clean
# but do NOT declare a top-level `param()` block.
$ToolkitModules = @(
    'scripts/lib/LlmHarness.psm1'
)

# Minimum line counts for the most important toolkit scripts. Catches the
# "empty file parses cleanly" blind spot: a 0-line `lint-llm.ps1` would pass
# the parse-check above but obviously fail any real check.
$ToolkitScriptMinLines = @{
    'scripts/run-llm-hooks.ps1'                = 100
    'scripts/lint-llm.ps1'                     = 10
    'scripts/generate-llm-index.ps1'           = 10
    'scripts/install-git-hooks.ps1'            = 100
    'scripts/test-llm-harness.ps1'             = 200
    'scripts/preflight.ps1'                    = 100
    'scripts/lib/LlmHarness.psm1'              = 100
    '.claude/hooks/parse-check-powershell.ps1' = 40
    '.claude/hooks/validate-llm-context.ps1'   = 40
    '.claude/hooks/preflight-stop.ps1'         = 30
    '.claude/hooks/session-reminder.ps1'       = 20
}

Assert-Test 'lint-llm.ps1 is a thin shared-module wrapper' {
    $path = Join-Path $ScriptsDir 'lint-llm.ps1'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw 'Missing scripts/lint-llm.ps1'
    }
    $content = Get-Content -LiteralPath $path -Raw
    $lines = @(Get-Content -LiteralPath $path)

    $paramCount = [regex]::Matches($content, '(?m)^param\s*\(').Count
    if ($paramCount -ne 1) {
        throw "lint-llm.ps1 must contain exactly one param() block; found $paramCount."
    }
    # The legacy local helper Read-Frontmatter was replaced by
    # Read-LlmFrontmatter from the shared module. Forbid the legacy name
    # outside of the test-regex assertions (the linter test itself
    # references it as a forbidden pattern).
    if ($content -match '(?m)^\s*function\s+Read-Frontmatter\b') {
        throw 'lint-llm.ps1 must not define Read-Frontmatter; use Read-LlmFrontmatter from the shared module.'
    }
    if ($content -match '(?<!Read-Llm)Read-Frontmatter\s+\$') {
        throw 'lint-llm.ps1 must not call Read-Frontmatter; use Read-LlmFrontmatter from the shared module.'
    }
    # The legacy local helper Get-RepoRelativePath was replaced by
    # Get-LlmRepoRelativePath (via Get-RelPath wrapper).
    if ($content -match '(?m)^\s*function\s+Get-RepoRelativePath\b') {
        throw 'lint-llm.ps1 must not define Get-RepoRelativePath; use Get-LlmRepoRelativePath via Get-RelPath.'
    }
    if ($content -match 'Get-RepoRelativePath\s+\$') {
        throw 'lint-llm.ps1 must not call Get-RepoRelativePath; use Get-RelPath / Get-LlmRepoRelativePath.'
    }
    if ($content -notmatch 'Invoke-LlmLint') {
        throw 'lint-llm.ps1 must delegate lint implementation to Invoke-LlmLint in LlmHarness.psm1.'
    }
    if ($content -match 'generate-llm-index\.ps1' -or $content -match '&\s+pwsh') {
        throw 'lint-llm.ps1 must not invoke the generator or spawn pwsh; runner fast paths call shared functions in-process.'
    }
    if ($lines.Count -lt 10 -or $lines.Count -gt 80) {
        throw "lint-llm.ps1 line count $($lines.Count) is outside the expected thin-wrapper range (10..80)."
    }
}

Assert-Test 'every toolkit script has exactly one param() block' {
    $repoRoot = Split-Path -Parent $ScriptsDir
    foreach ($rel in $ToolkitScripts) {
        $full = Join-Path $repoRoot $rel
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            throw "Missing toolkit script: $rel"
        }
        $content = Get-Content -LiteralPath $full -Raw
        $count = [regex]::Matches($content, '(?m)^param\s*\(').Count
        if ($count -ne 1) {
            throw "$rel must contain exactly one param() block; found $count (likely stale-buffer corruption)."
        }
    }
}

Assert-Test 'every toolkit script has no orphan content after the last top-level statement' {
    $repoRoot = Split-Path -Parent $ScriptsDir
    foreach ($rel in @($ToolkitScripts) + @($ToolkitModules)) {
        $full = Join-Path $repoRoot $rel
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            throw "Missing toolkit script: $rel"
        }
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $full, [ref]$tokens, [ref]$parseErrors)
        if ($null -ne $parseErrors -and $parseErrors.Count -gt 0) {
            throw "Parse errors in ${rel}: $($parseErrors | ForEach-Object { $_.Message } | Out-String)"
        }
        # ScriptBlockAst.EndBlock holds the top-level statements. Anything
        # textually after the last statement's extent that is not pure
        # whitespace / comments would be an orphan block.
        $endBlock = $ast.EndBlock
        if ($null -eq $endBlock -or $null -eq $endBlock.Statements -or $endBlock.Statements.Count -eq 0) {
            continue
        }
        $lastStmt = $endBlock.Statements[$endBlock.Statements.Count - 1]
        $fileText = Get-Content -LiteralPath $full -Raw
        $tail = $fileText.Substring($lastStmt.Extent.EndOffset)
        # Strip comments and whitespace; anything left is an orphan.
        # Block comments first (`<# ... #>`, possibly multi-line, non-greedy),
        # then per-line `#` comments, then collapse whitespace.
        $stripped = $tail -replace '(?s)<#.*?#>', ''
        $stripped = $stripped -replace '(?m)^\s*#.*$', ''
        $stripped = $stripped -replace '\s+', ''
        if ($stripped.Length -gt 0) {
            throw "$rel has executable content after the last top-level statement (orphan block?): '$tail'"
        }
    }
}

Assert-Test 'preflight.ps1 declares SelfCheck and orders self-parse before enumeration (static)' {
    $path = Join-Path $ScriptsDir 'preflight.ps1'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw 'Missing scripts/preflight.ps1 (self-healing bootstrap).'
    }
    $content = Get-Content -LiteralPath $path -Raw
    if ($content -notmatch '\[switch\]\$SelfCheck') {
        throw 'preflight.ps1 must declare [switch]$SelfCheck so its own integrity is checkable before anything else.'
    }
    # The self-parse must happen BEFORE the toolkit-wide enumeration.
    $selfParseIdx = $content.IndexOf('Test-PowerShellFileParse -Path $ScriptPath')
    $gitLsIdx = $content.IndexOf("git ls-files")
    if ($selfParseIdx -lt 0 -or $gitLsIdx -lt 0 -or $selfParseIdx -gt $gitLsIdx) {
        throw 'preflight.ps1 must parse-check itself BEFORE enumerating toolkit sources.'
    }
}

Assert-Test 'preflight.ps1 self-check surfaces structured failure on corruption' {
    # Behavioral check: a corrupted preflight.ps1 in a separate working tree
    # must surface a structured `[preflight] Self-parse failed` message
    # rather than an opaque pwsh parse error. We materialise the script
    # under TEMP, corrupt it, run it, and confirm the branded error.
    $path = Join-Path $ScriptsDir 'preflight.ps1'
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("llm-preflight-selfcheck-test-$([Guid]::NewGuid())")
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    try {
        $tempScript = Join-Path $tempDir 'preflight.ps1'
        Copy-Item -LiteralPath $path -Destination $tempScript -Force
        # Inject a parse error (close paren never opens). The corrupted
        # script lives outside any git repo; we only care about the
        # child-process self-check branch firing here.
        Add-Content -LiteralPath $tempScript -Value "`n) # deliberate syntax error for test`n"
        $output = & pwsh -NoProfile -File $tempScript 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
            throw "Corrupted preflight.ps1 must exit non-zero; got 0. Output: $($output -join '; ')"
        }
        # The child-pwsh self-check branch should emit '[preflight] Self-parse failed'
        # OR (if pwsh -File itself refused the corrupted file) a clear pwsh
        # parse error in the output. Either way the user sees something
        # actionable, not silence. We accept either prefix.
        $combined = ($output | Out-String)
        if ($combined -notmatch 'Self-parse failed' -and $combined -notmatch 'ParserError' -and $combined -notmatch 'parse error') {
            throw "Expected branded preflight self-parse failure or pwsh parse error, got: $combined"
        }
    } finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
} -Behavioral

Assert-Test 'Get-LlmStrayWorkingTreeArtifacts finds gitignored .tmp files' {
    if (-not (Get-Command Get-LlmStrayWorkingTreeArtifacts -ErrorAction SilentlyContinue)) {
        throw 'Get-LlmStrayWorkingTreeArtifacts is not exported from the shared module.'
    }
    $repoRoot = Split-Path -Parent $ScriptsDir
    # `.gitignore` already includes `*.tmp`, so this file is gitignored.
    # The standard helper (Get-LlmStagingArtifacts) cannot see it; the
    # stray helper must, because it passes `--ignored`.
    $tempName = "llm-harness-stray-test-$([Guid]::NewGuid()).tmp"
    $tempPath = Join-Path $repoRoot $tempName
    [System.IO.File]::WriteAllText($tempPath, 'sentinel')
    try {
        $strays = @(Get-LlmStrayWorkingTreeArtifacts -RepoRoot $repoRoot -Patterns @('*.tmp'))
        $found = @($strays | Where-Object { $_.Path -eq $tempName })
        if ($found.Count -ne 1) {
            throw "Expected helper to find $tempName; got: $($strays.Path -join ', ')"
        }
        if (-not $found[0].IsIgnored) {
            throw "$tempName should be reported as IsIgnored=true (it matches .gitignore)."
        }
        if ($found[0].IsTracked) {
            throw "$tempName should not be IsTracked."
        }
    } finally {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    }
}

Assert-Test 'Get-LlmStrayWorkingTreeArtifacts returns empty for empty patterns' {
    $repoRoot = Split-Path -Parent $ScriptsDir
    $artifacts = @(Get-LlmStrayWorkingTreeArtifacts -RepoRoot $repoRoot -Patterns @())
    Expect-Equal $artifacts.Count 0
}

Assert-Test 'agent-check.ps1 delegates to AgentFast in-process' {
    $path = Join-Path $ScriptsDir 'agent-check.ps1'
    $content = Get-Content -LiteralPath $path -Raw
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $path, [ref]$tokens, [ref]$parseErrors)
    if ($null -ne $parseErrors -and $parseErrors.Count -gt 0) {
        throw "Parse errors in agent-check.ps1: $($parseErrors | ForEach-Object { $_.Message } | Out-String)"
    }
    if ($content -notmatch 'run-llm-hooks\.ps1') {
        throw 'agent-check.ps1 must delegate to run-llm-hooks.ps1.'
    }
    if ($content -notmatch 'AgentFast') {
        throw 'agent-check.ps1 must use run-llm-hooks.ps1 -Mode AgentFast by default.'
    }
    if ($content -match '&\s+pwsh') {
        throw 'agent-check.ps1 must invoke run-llm-hooks.ps1 in-process, not spawn another pwsh.'
    }
}

Assert-Test 'run-llm-hooks.ps1 invokes preflight as the FIRST step' {
    $path = Join-Path $ScriptsDir 'run-llm-hooks.ps1'
    $content = Get-Content -LiteralPath $path -Raw
    if ($content -notmatch 'preflight\.ps1') {
        throw 'run-llm-hooks.ps1 must invoke scripts/preflight.ps1.'
    }
    # Preflight must run before the generator / linter / self-tests.
    $preIdx = $content.IndexOf('Running preflight')
    $genIdx = $content.IndexOf('Regenerating LLM index')
    if ($preIdx -lt 0 -or $genIdx -lt 0 -or $preIdx -gt $genIdx) {
        throw 'run-llm-hooks.ps1 must run preflight before regenerating the index.'
    }
}

Assert-Test 'CI workflow runs preflight as a separate -NoAutoFix step' {
    $repoRoot = Split-Path -Parent $ScriptsDir
    $workflow = Join-Path $repoRoot '.github/workflows/llm-harness.yml'
    if (-not (Test-Path -LiteralPath $workflow -PathType Leaf)) {
        return  # workflow absent in some test contexts; skip silently.
    }
    $content = Get-Content -LiteralPath $workflow -Raw
    if ($content -notmatch 'preflight\.ps1') {
        throw 'CI workflow must run scripts/preflight.ps1 so a corrupted toolkit script fails CI immediately.'
    }
}

Assert-Test '.claude/settings.json wires PostToolUse parse-check hook' {
    $repoRoot = Split-Path -Parent $ScriptsDir
    $settings = Join-Path $repoRoot '.claude/settings.json'
    if (-not (Test-Path -LiteralPath $settings -PathType Leaf)) {
        throw 'Missing .claude/settings.json (agentic guardrail config).'
    }
    $content = Get-Content -LiteralPath $settings -Raw
    $json = $null
    try {
        $json = $content | ConvertFrom-Json
    } catch {
        throw ".claude/settings.json is not valid JSON: $($_.Exception.Message)"
    }
    if (-not ($json.PSObject.Properties.Name -contains 'hooks')) {
        throw '.claude/settings.json must define a `hooks` object.'
    }
    if (-not ($json.hooks.PSObject.Properties.Name -contains 'PostToolUse')) {
        throw '.claude/settings.json must declare a PostToolUse hook block.'
    }
    if (-not ($json.hooks.PSObject.Properties.Name -contains 'Stop')) {
        throw '.claude/settings.json must declare a Stop hook block (preflight safety net).'
    }
    if (-not ($json.hooks.PSObject.Properties.Name -contains 'SessionStart')) {
        throw '.claude/settings.json must declare a SessionStart reminder so agents know writes are auto-validated.'
    }
    # Matchers must be anchored so `NotebookEdit` does not silently match a
    # `Write|Edit|MultiEdit` substring filter.
    $postToolUse = @($json.hooks.PostToolUse)
    if ($postToolUse.Count -eq 0) {
        throw '.claude/settings.json PostToolUse must contain at least one block.'
    }
    foreach ($block in $postToolUse) {
        if (-not ($block.PSObject.Properties.Name -contains 'matcher')) {
            throw 'Each PostToolUse block must declare a matcher.'
        }
        if ($block.matcher -notmatch '^\^') {
            throw "PostToolUse matcher must be anchored (`^...$`); got '$($block.matcher)'."
        }
        if ($block.matcher -notmatch '\$$') {
            throw "PostToolUse matcher must be anchored (`^...$`); got '$($block.matcher)'."
        }
    }
    # Hook commands must use `\$CLAUDE_PROJECT_DIR` so Claude Code can
    # invoke them from any cwd. Relative paths like
    # `.claude/hooks/parse-check-powershell.ps1` silently break.
    foreach ($block in $postToolUse) {
        foreach ($hook in @($block.hooks)) {
            if ($hook.command -notmatch '\$CLAUDE_PROJECT_DIR') {
                throw "PostToolUse hook command must use `$CLAUDE_PROJECT_DIR; got '$($hook.command)'."
            }
        }
    }
    foreach ($block in @($json.hooks.Stop)) {
        foreach ($hook in @($block.hooks)) {
            if ($hook.command -notmatch '\$CLAUDE_PROJECT_DIR') {
                throw "Stop hook command must use `$CLAUDE_PROJECT_DIR; got '$($hook.command)'."
            }
        }
    }
    foreach ($block in @($json.hooks.SessionStart)) {
        foreach ($hook in @($block.hooks)) {
            if ($hook.command -notmatch '\$CLAUDE_PROJECT_DIR') {
                throw "SessionStart hook command must use `$CLAUDE_PROJECT_DIR; got '$($hook.command)'."
            }
        }
    }
}

Assert-Test '.claude/settings.local.json is local-only, untracked, and gitignored' {
    $repoRoot = Split-Path -Parent $ScriptsDir
    $gitignore = Get-Content -LiteralPath (Join-Path $repoRoot '.gitignore') -Raw
    if ($gitignore -notmatch '(?m)^\.claude/settings\.local\.json$') {
        throw '.gitignore must ignore .claude/settings.local.json so local Claude permission overrides stay local.'
    }
    if (Get-Command git -ErrorAction SilentlyContinue) {
        Push-Location $repoRoot
        try {
            $tracked = @(& git ls-files -- '.claude/settings.local.json' 2>&1)
            if ($LASTEXITCODE -ne 0) {
                throw "git ls-files failed while checking .claude/settings.local.json: $($tracked -join '; ')"
            }
            $status = @(& git status --porcelain -- '.claude/settings.local.json' 2>&1)
            if ($LASTEXITCODE -ne 0) {
                throw "git status failed while checking .claude/settings.local.json: $($status -join '; ')"
            }
        } finally {
            Pop-Location
        }
        $trackedLocalSettings = @($tracked | Where-Object { $_ -eq '.claude/settings.local.json' })
        $isDeletedInThisWorktree = (($status -join "`n") -match '(?m)^(?:D | D)\s+\.claude/settings\.local\.json$')
        if ($trackedLocalSettings.Count -gt 0 -and -not $isDeletedInThisWorktree) {
            throw '.claude/settings.local.json must not be tracked; use .claude/settings.json for shared hooks and local ignored files for machine-specific permissions.'
        }
    }
}

Assert-Test '.claude/hooks scripts exist and self-parse cleanly' {
    $repoRoot = Split-Path -Parent $ScriptsDir
    $hooksDir = Join-Path $repoRoot '.claude/hooks'
    $expected = @(
        'parse-check-powershell.ps1',
        'validate-llm-context.ps1',
        'preflight-stop.ps1',
        'session-reminder.ps1'
    )
    foreach ($name in $expected) {
        $full = Join-Path $hooksDir $name
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            throw "Missing agent hook script: .claude/hooks/$name"
        }
        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $full, [ref]$tokens, [ref]$parseErrors)
        if ($null -ne $parseErrors -and $parseErrors.Count -gt 0) {
            throw "Parse error in .claude/hooks/$name`: $($parseErrors | ForEach-Object { $_.Message } | Out-String)"
        }
    }
}

Assert-Test '.claude hook JSON variables use explicit names' {
    $repoRoot = Split-Path -Parent $ScriptsDir
    $hooksDir = Join-Path $repoRoot '.claude/hooks'
    $expectations = @{
        'parse-check-powershell.ps1' = @('hookInput', 'blockResponse')
        'validate-llm-context.ps1'   = @('hookInput', 'blockResponse')
        'preflight-stop.ps1'         = @('blockResponse')
        'session-reminder.ps1'       = @('sessionStartResponse')
    }

    foreach ($name in $expectations.Keys) {
        $full = Join-Path $hooksDir $name
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            throw "Missing agent hook script: .claude/hooks/$name"
        }
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $full, [ref]$tokens, [ref]$parseErrors)
        if ($null -ne $parseErrors -and $parseErrors.Count -gt 0) {
            throw "Parse error in .claude/hooks/$name`: $($parseErrors | ForEach-Object { $_.Message } | Out-String)"
        }
        $variables = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($node in @($ast.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    -not $n.VariablePath.IsDriveQualified
                }, $true))) {
            [void]$variables.Add($node.VariablePath.UserPath)
        }
        if ($variables.Contains('payload')) {
            throw ".claude/hooks/$name must not use generic `$payload; use explicit hookInput/blockResponse/sessionStartResponse names."
        }
        foreach ($expected in $expectations[$name]) {
            if (-not $variables.Contains($expected)) {
                throw ".claude/hooks/$name must use `$$expected for JSON hook data."
            }
        }
    }
}

# --- FIX-15: toolkit scripts respect minimum line counts -------------------

Assert-Test 'toolkit scripts respect minimum line counts (catch empty-file regressions)' {
    $repoRoot = Split-Path -Parent $ScriptsDir
    foreach ($entry in $ToolkitScriptMinLines.GetEnumerator()) {
        $full = Join-Path $repoRoot $entry.Key
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            throw "Missing toolkit script: $($entry.Key)"
        }
        $actual = @(Get-Content -LiteralPath $full).Count
        if ($actual -lt $entry.Value) {
            throw "$($entry.Key) has $actual lines, below minimum $($entry.Value); empty/truncated file?"
        }
    }
}

# --- FIX-13: parse-check hook emits stdout JSON `decision=block` -----------

Assert-Test 'parse-check-powershell.ps1 emits stdout decision-block JSON on parse error' {
    $repoRoot = Split-Path -Parent $ScriptsDir
    $hook = Join-Path $repoRoot '.claude/hooks/parse-check-powershell.ps1'
    if (-not (Test-Path -LiteralPath $hook -PathType Leaf)) {
        throw 'Missing parse-check hook.'
    }
    # Materialise a broken ps1 in TEMP, send tool_input JSON to the hook,
    # confirm stdout JSON shape and exit 2.
    $tempScript = Join-Path ([System.IO.Path]::GetTempPath()) ("llm-broken-$([Guid]::NewGuid()).ps1")
    [System.IO.File]::WriteAllText($tempScript, "}}}garbage`n")
    try {
        $payload = @{ tool_name = 'Edit'; tool_input = @{ file_path = $tempScript } } | ConvertTo-Json -Compress
        # Use Start-Process to capture stdout separately from stderr.
        $stdoutPath = [System.IO.Path]::GetTempFileName()
        $stderrPath = [System.IO.Path]::GetTempFileName()
        $stdinPath = [System.IO.Path]::GetTempFileName()
        [System.IO.File]::WriteAllText($stdinPath, $payload)
        try {
            $proc = Start-Process -FilePath 'pwsh' -ArgumentList @(
                '-NoProfile', '-File', $hook
            ) -RedirectStandardInput $stdinPath `
                -RedirectStandardOutput $stdoutPath `
                -RedirectStandardError $stderrPath `
                -PassThru -Wait -NoNewWindow
            $exitCode = $proc.ExitCode
            $stdout = (Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue)
            if ($exitCode -ne 2) {
                $stderr = (Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue)
                throw "parse-check hook must exit 2 on parse error; got $exitCode. stdout: '$stdout' stderr: '$stderr'"
            }
            if ([string]::IsNullOrWhiteSpace($stdout)) {
                throw 'parse-check hook must emit JSON to stdout on parse error.'
            }
            $parsed = $null
            try { $parsed = $stdout | ConvertFrom-Json -ErrorAction Stop } catch {
                throw "parse-check hook stdout must be valid JSON; got '$stdout'"
            }
            if (-not ($parsed.PSObject.Properties.Name -contains 'decision')) {
                throw 'parse-check hook stdout JSON must contain a `decision` field.'
            }
            if ($parsed.decision -ne 'block') {
                throw "parse-check hook stdout decision must equal 'block'; got '$($parsed.decision)'."
            }
            if (-not ($parsed.PSObject.Properties.Name -contains 'reason') -or
                [string]::IsNullOrWhiteSpace($parsed.reason)) {
                throw 'parse-check hook stdout JSON must contain a non-empty `reason` field.'
            }
        } finally {
            Remove-Item -LiteralPath $stdoutPath, $stderrPath, $stdinPath -Force -ErrorAction SilentlyContinue
        }
    } finally {
        Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
    }
} -Behavioral

# --- FIX-9: validate-llm-context gates on $CLAUDE_PROJECT_DIR --------------

Assert-Test 'validate-llm-context.ps1 ignores .llm paths outside the repo' {
    $repoRoot = Split-Path -Parent $ScriptsDir
    $hook = Join-Path $repoRoot '.claude/hooks/validate-llm-context.ps1'
    if (-not (Test-Path -LiteralPath $hook -PathType Leaf)) {
        throw 'Missing validate-llm-context hook.'
    }
    # Build a path that looks .llm-shaped but lives OUTSIDE the repo.
    # We keep the top-level GUID dir EXPLICIT so cleanup does not rely on
    # `Split-Path -Parent` arithmetic over a path that may or may not have
    # a trailing separator (m-4 nit).
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("llm-foreign-$([Guid]::NewGuid())")
    $tempDir = Join-Path $tempRoot '.llm/skills'
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    $tempFile = Join-Path $tempDir 'foreign.md'
    [System.IO.File]::WriteAllText($tempFile, "no frontmatter here`n")
    try {
        $payload = @{ tool_name = 'Edit'; tool_input = @{ file_path = $tempFile } } | ConvertTo-Json -Compress
        $stdinPath = [System.IO.Path]::GetTempFileName()
        [System.IO.File]::WriteAllText($stdinPath, $payload)
        try {
            # Force CLAUDE_PROJECT_DIR to the real repo root so the hook
            # gates against it, not the temp path. Using Start-Process so
            # we can scope the env var to the child only.
            $envBackup = $env:CLAUDE_PROJECT_DIR
            $env:CLAUDE_PROJECT_DIR = $repoRoot
            try {
                $proc = Start-Process -FilePath 'pwsh' -ArgumentList @(
                    '-NoProfile', '-File', $hook
                ) -RedirectStandardInput $stdinPath `
                    -PassThru -Wait -NoNewWindow
                $exitCode = $proc.ExitCode
                if ($exitCode -ne 0) {
                    throw "Hook must exit 0 silently for paths outside `$CLAUDE_PROJECT_DIR; got $exitCode."
                }
            } finally {
                $env:CLAUDE_PROJECT_DIR = $envBackup
            }
        } finally {
            Remove-Item -LiteralPath $stdinPath -Force -ErrorAction SilentlyContinue
        }
    } finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
} -Behavioral

Assert-Test 'validate-llm-context.ps1 blocks invalid and accepts valid repo-local LLM markdown' {
    $repoRoot = Split-Path -Parent $ScriptsDir
    $hook = Join-Path $repoRoot '.claude/hooks/validate-llm-context.ps1'
    if (-not (Test-Path -LiteralPath $hook -PathType Leaf)) {
        throw 'Missing validate-llm-context hook.'
    }

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("llm-validate-hook-$([Guid]::NewGuid())")
    $tempSkills = Join-Path $tempRoot '.llm/skills'
    $tempLib = Join-Path $tempRoot 'scripts/lib'
    New-Item -ItemType Directory -Path $tempSkills, $tempLib -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot 'scripts/lib/LlmHarness.psm1') `
        -Destination (Join-Path $tempLib 'LlmHarness.psm1') -Force

    $invalidFile = Join-Path $tempSkills 'missing-frontmatter.md'
    $validFile = Join-Path $tempSkills 'valid.md'
    [System.IO.File]::WriteAllText($invalidFile, "# Missing Frontmatter`n")
    [System.IO.File]::WriteAllText($validFile, "---`ndescription: Valid hook test`ntriggers: hook`ncategory: Test`n---`n# Valid`n")

    function Invoke-ValidateHookForTest {
        param([Parameter(Mandatory)][string]$FilePath)
        $stdinPath = [System.IO.Path]::GetTempFileName()
        $stdoutPath = [System.IO.Path]::GetTempFileName()
        $stderrPath = [System.IO.Path]::GetTempFileName()
        $hookPayloadJson = @{ tool_name = 'Edit'; tool_input = @{ file_path = $FilePath } } | ConvertTo-Json -Compress
        [System.IO.File]::WriteAllText($stdinPath, $hookPayloadJson)
        $envBackup = $env:CLAUDE_PROJECT_DIR
        try {
            $env:CLAUDE_PROJECT_DIR = $tempRoot
            $proc = Start-Process -FilePath 'pwsh' -ArgumentList @(
                '-NoProfile', '-File', $hook
            ) -RedirectStandardInput $stdinPath `
                -RedirectStandardOutput $stdoutPath `
                -RedirectStandardError $stderrPath `
                -PassThru -Wait -NoNewWindow
            return [pscustomobject]@{
                ExitCode = $proc.ExitCode
                Stdout   = (Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue)
                Stderr   = (Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue)
            }
        } finally {
            if ($null -eq $envBackup) {
                Remove-Item Env:CLAUDE_PROJECT_DIR -ErrorAction SilentlyContinue
            } else {
                $env:CLAUDE_PROJECT_DIR = $envBackup
            }
            Remove-Item -LiteralPath $stdinPath, $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
        }
    }

    try {
        $invalid = Invoke-ValidateHookForTest -FilePath $invalidFile
        if ($invalid.ExitCode -ne 2) {
            throw "validate hook must exit 2 for missing frontmatter; got $($invalid.ExitCode). stdout: '$($invalid.Stdout)' stderr: '$($invalid.Stderr)'"
        }
        if ([string]::IsNullOrWhiteSpace($invalid.Stdout)) {
            throw 'validate hook must emit JSON to stdout when blocking missing frontmatter.'
        }
        $parsed = $null
        try { $parsed = $invalid.Stdout | ConvertFrom-Json -ErrorAction Stop } catch {
            throw "validate hook stdout must be valid JSON; got '$($invalid.Stdout)'"
        }
        if ($parsed.decision -ne 'block') {
            throw "validate hook stdout decision must equal 'block'; got '$($parsed.decision)'."
        }
        if (-not ($parsed.PSObject.Properties.Name -contains 'reason') -or
            [string]::IsNullOrWhiteSpace($parsed.reason)) {
            throw 'validate hook stdout JSON must contain a non-empty `reason` field.'
        }
        if ($parsed.reason -notmatch 'missing required frontmatter keys') {
            throw "validate hook block reason must name missing frontmatter; got '$($parsed.reason)'."
        }

        $valid = Invoke-ValidateHookForTest -FilePath $validFile
        if ($valid.ExitCode -ne 0) {
            throw "validate hook must exit 0 for valid frontmatter; got $($valid.ExitCode). stdout: '$($valid.Stdout)' stderr: '$($valid.Stderr)'"
        }
    } finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
} -Behavioral

# --- FIX-8: Test-LlmDeletableArtifact scopes AutoFix correctly -------------

Assert-Test 'Test-LlmDeletableArtifact: artifact in controlled dir is deletable' {
    if (-not (Get-Command Test-LlmDeletableArtifact -ErrorAction SilentlyContinue)) {
        throw 'Test-LlmDeletableArtifact is not exported from the shared module.'
    }
    $repoRoot = Split-Path -Parent $ScriptsDir
    $tracked = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $deletable = Test-LlmDeletableArtifact -RepoRoot $repoRoot -RelativePath 'scripts/foo.tmp' -TrackedFiles $tracked
    if (-not $deletable) {
        throw 'A `.tmp` under scripts/ must be deletable (controlled directory).'
    }
}

Assert-Test 'Test-LlmDeletableArtifact: artifact outside controlled dirs is NOT deletable' {
    $repoRoot = Split-Path -Parent $ScriptsDir
    $tracked = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $deletable = Test-LlmDeletableArtifact -RepoRoot $repoRoot -RelativePath 'notes/random.md.swp' -TrackedFiles $tracked
    if ($deletable) {
        throw 'A `.swp` under notes/ must NOT be deletable; nothing tracks it.'
    }
}

Assert-Test 'Test-LlmDeletableArtifact: sibling-of-tracked-source is deletable' {
    $repoRoot = Split-Path -Parent $ScriptsDir
    $tracked = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    [void]$tracked.Add('whatever/foo.ps1')
    $deletable = Test-LlmDeletableArtifact -RepoRoot $repoRoot -RelativePath 'whatever/foo.ps1.tmp' -TrackedFiles $tracked
    if (-not $deletable) {
        throw 'A `.tmp` next to a tracked `.ps1` must be deletable (sibling rule).'
    }
}

Assert-Test 'Test-LlmDeletableArtifact: empty path is NOT deletable (defensive)' {
    $repoRoot = Split-Path -Parent $ScriptsDir
    $tracked = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $deletable = Test-LlmDeletableArtifact -RepoRoot $repoRoot -RelativePath '' -TrackedFiles $tracked
    if ($deletable) {
        throw 'Empty path must never be auto-deletable.'
    }
}

Assert-Test 'run-llm-hooks.ps1 AutoFix uses Test-LlmDeletableArtifact for scoped deletion' {
    $path = Join-Path $ScriptsDir 'run-llm-hooks.ps1'
    $content = Get-Content -LiteralPath $path -Raw
    if ($content -notmatch 'Test-LlmDeletableArtifact') {
        throw 'run-llm-hooks.ps1 must call Test-LlmDeletableArtifact so AutoFix never nukes unrelated swap/tmp files.'
    }
    if ($content -notmatch 'leaving for manual review') {
        throw 'run-llm-hooks.ps1 must emit a manual-review warning for out-of-scope artifacts (so the user knows they were skipped).'
    }
    if ($content -notmatch "ControlledOnly:\(\`$Mode -in @\('PreCommit', 'AgentFast'\)\)" -or
        $content -notmatch 'Get-LlmStrayWorkingTreeArtifacts') {
        throw 'run-llm-hooks.ps1 PreCommit and AgentFast modes must catch controlled gitignored strays such as scripts/*.tmp.'
    }
}

Assert-Test 'run-llm-hooks.ps1 fast sibling stray scan is directory-based' {
    $path = Join-Path $ScriptsDir 'run-llm-hooks.ps1'
    $content = Get-Content -LiteralPath $path -Raw
    if ($content -match 'Get-TrackedSiblingArtifactCandidates') {
        throw 'Fast sibling stray detection must not synthesize and probe tracked-file x pattern candidate paths.'
    }
    if ($content -notmatch 'Get-TrackedFileDirectories' -or
        $content -notmatch 'Get-ChildItem -LiteralPath \$fullDir -Force -File') {
        throw 'Fast sibling stray detection must enumerate each tracked-file directory once and inspect sibling files.'
    }
    $controlledFunc = [regex]::Match($content, '(?s)function Get-ControlledStrayArtifacts \{(?<body>.*?)\r?\n\}')
    if (-not $controlledFunc.Success) {
        throw 'Missing Get-ControlledStrayArtifacts implementation.'
    }
    if ($controlledFunc.Groups['body'].Value -match 'foreach\s*\(\$tracked\b.*?foreach\s*\(\$pattern\b') {
        throw 'Get-ControlledStrayArtifacts must not do O(tracked files * patterns) sibling probing.'
    }
}

# --- M-5: Test-LlmDeletableArtifact strips ./ prefix -----------------------

Assert-Test 'Test-LlmDeletableArtifact strips leading ./ prefix' {
    $repoRoot = Split-Path -Parent $ScriptsDir
    $tracked = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $deletable = Test-LlmDeletableArtifact -RepoRoot $repoRoot -RelativePath './scripts/foo.ps1.tmp' -TrackedFiles $tracked
    if (-not $deletable) {
        throw "Path './scripts/foo.ps1.tmp' must be deletable; the './' prefix must be stripped before the controlled-dir check."
    }
    # Also test the backslash + ./ variant.
    $deletable = Test-LlmDeletableArtifact -RepoRoot $repoRoot -RelativePath '.\scripts\foo.ps1.tmp' -TrackedFiles $tracked
    if (-not $deletable) {
        throw "Path '.\\scripts\\foo.ps1.tmp' must be deletable; backslash + ./ prefix must normalize."
    }
}

# --- NIT-1: Test-LlmDeletableArtifact collapses repeated `/` and `./` ------

Assert-Test 'Test-LlmDeletableArtifact collapses repeated `./` and `//` prefixes' {
    $repoRoot = Split-Path -Parent $ScriptsDir
    $tracked = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    # Repeated `./` followed by `//` must reduce to `scripts/foo.ps1.tmp`.
    $deletable = Test-LlmDeletableArtifact -RepoRoot $repoRoot -RelativePath './/scripts/foo.ps1.tmp' -TrackedFiles $tracked
    if (-not $deletable) {
        throw "Path './/scripts/foo.ps1.tmp' must be deletable; repeated // must collapse before the controlled-dir check."
    }
    # Triple-slash and chained `./` segments.
    $deletable = Test-LlmDeletableArtifact -RepoRoot $repoRoot -RelativePath './/./scripts///foo.ps1.tmp' -TrackedFiles $tracked
    if (-not $deletable) {
        throw "Path './/./scripts///foo.ps1.tmp' must be deletable; repeated `./` and `///` must normalize."
    }
}

# --- M-6: lint-llm.ps1 detects gitignored .tmp strays ----------------------

Assert-Test 'lint-llm.ps1 fails on stray .tmp file inside controlled dir' {
    $repoRoot = Split-Path -Parent $ScriptsDir
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        return  # git unavailable; skip silently.
    }
    $strayName = "scripts/llm-harness-test-stray-$([Guid]::NewGuid()).tmp"
    $strayFull = Join-Path $repoRoot $strayName
    [System.IO.File]::WriteAllText($strayFull, 'sentinel')
    try {
        $linter = Join-Path $ScriptsDir 'lint-llm.ps1'
        $output = & pwsh -NoProfile -File $linter 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
            throw "lint-llm.ps1 must exit non-zero when a stray .tmp exists under scripts/; got 0. Output: $($output -join '; ')"
        }
        $combined = ($output | Out-String)
        if ($combined -notmatch [regex]::Escape($strayName)) {
            throw "lint-llm.ps1 must name the stray artifact in its output; got: $combined"
        }
        if ($combined -notmatch 'Stray staging artifact') {
            throw "lint-llm.ps1 must use the 'Stray staging artifact' prefix; got: $combined"
        }
    } finally {
        Remove-Item -LiteralPath $strayFull -Force -ErrorAction SilentlyContinue
    }
} -Behavioral

# --- M-6 (cont.): run-llm-hooks.ps1 -NoAutoFix reports strays --------------

Assert-Test 'run-llm-hooks.ps1 -NoAutoFix reports stray .tmp and fails' {
    $repoRoot = Split-Path -Parent $ScriptsDir
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        return
    }
    $strayName = "scripts/llm-harness-test-noautofix-$([Guid]::NewGuid()).tmp"
    $strayFull = Join-Path $repoRoot $strayName
    [System.IO.File]::WriteAllText($strayFull, 'sentinel')
    try {
        $hooks = Join-Path $ScriptsDir 'run-llm-hooks.ps1'
        $output = & pwsh -NoProfile -File $hooks -SkipStagedCheck -NoAutoFix 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
            throw "run-llm-hooks.ps1 -NoAutoFix must exit non-zero when a stray .tmp exists; got 0. Output: $($output -join '; ')"
        }
        $combined = ($output | Out-String)
        if ($combined -notmatch [regex]::Escape($strayName)) {
            throw "run-llm-hooks.ps1 -NoAutoFix must name the stray artifact; got: $combined"
        }
    } finally {
        Remove-Item -LiteralPath $strayFull -Force -ErrorAction SilentlyContinue
    }
} -Behavioral

Assert-Test 'run-llm-hooks.ps1 PreCommit reports gitignored scripts .tmp before fast exit' {
    $repoRoot = Split-Path -Parent $ScriptsDir
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        return
    }
    $strayName = "scripts/llm-harness-test-precommit-$([Guid]::NewGuid()).tmp"
    $strayFull = Join-Path $repoRoot $strayName
    [System.IO.File]::WriteAllText($strayFull, 'sentinel')
    try {
        $hooks = Join-Path $ScriptsDir 'run-llm-hooks.ps1'
        $output = & pwsh -NoProfile -File $hooks -Mode PreCommit -SkipStagedCheck -NoAutoFix 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
            throw "PreCommit must exit non-zero when a gitignored scripts/*.tmp exists; got 0. Output: $($output -join '; ')"
        }
        $combined = ($output | Out-String)
        if ($combined -notmatch [regex]::Escape($strayName)) {
            throw "PreCommit must name the gitignored stray artifact; got: $combined"
        }
    } finally {
        Remove-Item -LiteralPath $strayFull -Force -ErrorAction SilentlyContinue
    }
} -Behavioral

# --- M-9: run-llm-hooks.ps1 parse-checks preflight.ps1 first ---------------

Assert-Test 'run-llm-hooks.ps1 parse-checks preflight.ps1 before invoking it' {
    $path = Join-Path $ScriptsDir 'run-llm-hooks.ps1'
    $content = Get-Content -LiteralPath $path -Raw
    # The parse-check call MUST appear before the `Running preflight`
    # status line. We check both substrings exist and ordering is correct.
    $parseIdx = $content.IndexOf('ParseFile')
    $runIdx = $content.IndexOf('Running preflight')
    if ($parseIdx -lt 0) {
        throw 'run-llm-hooks.ps1 must call [System.Management.Automation.Language.Parser]::ParseFile to parse-check preflight.ps1 before invoking it.'
    }
    if ($runIdx -lt 0 -or $parseIdx -gt $runIdx) {
        throw 'run-llm-hooks.ps1 must parse-check preflight.ps1 BEFORE the "Running preflight" stage.'
    }
    $backupIdx = $content.IndexOf("New-HookRecoveryBackup -RelativePath 'scripts/preflight.ps1'")
    $restoreFuncIdx = $content.IndexOf('Restore-HookPowerShellFileFromGit')
    $indexCheckoutIdx = $content.IndexOf('git checkout -- $RelativePath')
    $headCheckoutIdx = $content.IndexOf('git checkout HEAD -- $RelativePath')
    if ($backupIdx -lt 0 -or $restoreFuncIdx -lt 0 -or $backupIdx -gt $restoreFuncIdx) {
        throw 'run-llm-hooks.ps1 must back up preflight.ps1 before restoring it from git.'
    }
    if ($indexCheckoutIdx -lt 0 -or $headCheckoutIdx -lt 0 -or $indexCheckoutIdx -gt $headCheckoutIdx) {
        throw 'run-llm-hooks.ps1 must try index/staged recovery before HEAD fallback.'
    }
    if ($content -notmatch 'restoring backed-up WIP') {
        throw 'run-llm-hooks.ps1 must restore the preflight WIP backup if the HEAD copy is also corrupt.'
    }
}

Assert-Test 'POSIX git-hook shims parse-check run-llm-hooks.ps1 before invoking it' {
    $installer = Join-Path $ScriptsDir 'install-git-hooks.ps1'
    $reference = Join-Path (Split-Path -Parent $ScriptsDir) '.githooks/pre-commit'
    $installerContent = Get-Content -LiteralPath $installer -Raw
    $referenceContent = Get-Content -LiteralPath $reference -Raw

    # Both POSIX entry points must include the same n-level recovery contract:
    # shim -> run-llm-hooks -> preflight -> all other PowerShell sources.
    Assert-DirectPosixShimBootstrap -Name 'install-git-hooks.ps1 emitted hook' -Content $installerContent
    Assert-DirectPosixShimBootstrap -Name '.githooks/pre-commit reference shim' -Content $referenceContent
}

# --- MIN-1: pattern triplication closed -----------------------------------

Assert-Test 'MIN-1: stray-artifact patterns sourced from shared module' {
    # Get-LlmDefaultStrayPatterns must exist; the 3 known call sites must
    # consume it (or the $script:LlmDefaultStrayPatterns variable) rather
    # than redeclare the literal list.
    if (-not (Get-Command Get-LlmDefaultStrayPatterns -ErrorAction SilentlyContinue)) {
        throw 'Get-LlmDefaultStrayPatterns must be exported from the shared module.'
    }
    $patterns = @(Get-LlmDefaultStrayPatterns)
    if ($patterns.Count -lt 5) {
        throw "Get-LlmDefaultStrayPatterns must return the canonical list; got $($patterns.Count) entries."
    }
    foreach ($needle in @('*.tmp', '*.swp', '*.bak', '*.new', '.DS_Store')) {
        if ($patterns -notcontains $needle) {
            throw "Get-LlmDefaultStrayPatterns is missing the canonical pattern '$needle'."
        }
    }

    $repoRoot = Split-Path -Parent $ScriptsDir
    $lintSrc = Get-Content -LiteralPath (Join-Path $ScriptsDir 'lint-llm.ps1') -Raw
    $hookSrc = Get-Content -LiteralPath (Join-Path $ScriptsDir 'run-llm-hooks.ps1') -Raw
    $libSrc = Get-Content -LiteralPath (Join-Path $ScriptsDir 'lib/LlmHarness.psm1') -Raw

    if ($hookSrc -match '(?m)^\s*\$StagingArtifactPatterns\s*=') {
        throw 'run-llm-hooks.ps1 must not retain an unused $StagingArtifactPatterns variable.'
    }
    if ($libSrc -match '\[string\[\]\]\$Patterns\s*=\s*@\(') {
        throw 'Get-LlmStagingArtifacts must not hardcode a local default pattern list; use Get-LlmDefaultStrayPatterns.'
    }
    if ($libSrc -notmatch '\[string\[\]\]\$Patterns\s*=\s*\(Get-LlmDefaultStrayPatterns\)') {
        throw 'Get-LlmStagingArtifacts must default -Patterns to Get-LlmDefaultStrayPatterns.'
    }

    foreach ($entry in @(
            @{ Name = 'run-llm-hooks.ps1'; Content = $hookSrc }
        )) {
        if ($entry.Content -notmatch 'Get-LlmDefaultStrayPatterns') {
            throw "$($entry.Name) must consume Get-LlmDefaultStrayPatterns instead of redeclaring the artifact list."
        }
        # Forbid a literal redeclaration of the long stray-pattern list in
        # these call sites. A list containing all six anchor entries is
        # the unmistakable signature of the drift we want to prevent.
        $literalListPattern = "(?s)'\*\.tmp'.*?'\*\.swp'.*?'\*\.swo'.*?'\.DS_Store'"
        if ($entry.Content -match $literalListPattern) {
            throw "$($entry.Name) still contains a hardcoded copy of the stray-artifact pattern list; consume Get-LlmDefaultStrayPatterns instead."
        }
    }
    if ($lintSrc -notmatch 'Invoke-LlmLint') {
        throw 'lint-llm.ps1 must delegate artifact checks to Invoke-LlmLint in the shared module.'
    }

    # The library is the SOURCE of truth: it MAY contain the literal list
    # exactly once (in the $script:LlmDefaultStrayPatterns assignment).
    # Confirm that exactly-one constraint to catch a future regression
    # where the default param() block reintroduces the literal.
    $libMatches = [regex]::Matches($libSrc, "(?s)'\*\.tmp'.*?'\*\.swp'.*?'\*\.swo'.*?'\.DS_Store'")
    if ($libMatches.Count -ne 1) {
        throw "lib/LlmHarness.psm1 must contain exactly one literal stray-pattern list (the canonical source); found $($libMatches.Count)."
    }
}

# --- NIT-5: runner owns preflight gating ----------------------------------

Assert-Test 'NIT-5: run-llm-hooks.ps1 owns preflight skip and agent-check stays in-process' {
    $check = Get-Content -LiteralPath (Join-Path $ScriptsDir 'agent-check.ps1') -Raw
    if ($check -match '&\s+pwsh') {
        throw 'agent-check.ps1 must not spawn a second pwsh; it invokes run-llm-hooks.ps1 in-process.'
    }
    if ($check -notmatch 'AgentFast') {
        throw 'agent-check.ps1 must use AgentFast for the fast post-edit path.'
    }
    $hook = Get-Content -LiteralPath (Join-Path $ScriptsDir 'run-llm-hooks.ps1') -Raw
    if ($hook -notmatch 'LLM_HARNESS_PREFLIGHT_DONE') {
        throw 'run-llm-hooks.ps1 must honor LLM_HARNESS_PREFLIGHT_DONE so an outer wrapper can suppress the duplicate preflight.'
    }
    if ($hook -notmatch 'skipPreflight') {
        throw 'run-llm-hooks.ps1 must guard the preflight block with the $skipPreflight flag.'
    }
}

Assert-Test 'NIT-5: env var suppresses inner preflight pass and emits skip notice' {
    # Behavioral: invoke `run-llm-hooks.ps1 -SkipStagedCheck` directly
    # with LLM_HARNESS_PREFLIGHT_DONE=1 set and confirm
    #   (a) the inner preflight pass does NOT spawn its own preflight
    #       (no `Running preflight` HOOK line),
    #   (b) the skip notice DOES appear.
    # Check the skip invariants before the child exit code so a downstream
    # failure cannot hide whether preflight gating itself worked.
    $hooks = Join-Path $ScriptsDir 'run-llm-hooks.ps1'
    $envBackup = $env:LLM_HARNESS_PREFLIGHT_DONE
    $behaviorBackup = $env:LLM_HARNESS_SKIP_BEHAVIORAL_TESTS
    $env:LLM_HARNESS_PREFLIGHT_DONE = '1'
    $env:LLM_HARNESS_SKIP_BEHAVIORAL_TESTS = '1'
    try {
        $output = & pwsh -NoProfile -File $hooks -Mode Full -SkipStagedCheck -NoAutoFix 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $env:LLM_HARNESS_PREFLIGHT_DONE = $envBackup
        $env:LLM_HARNESS_SKIP_BEHAVIORAL_TESTS = $behaviorBackup
    }
    $combined = ($output | Out-String)
    $matches = [regex]::Matches($combined, 'Running preflight \(parse-check toolkit sources\)')
    if ($matches.Count -ne 0) {
        throw "run-llm-hooks.ps1 emitted 'Running preflight' $($matches.Count) time(s); expected 0 when LLM_HARNESS_PREFLIGHT_DONE=1. Output: $combined"
    }
    if ($combined -notmatch 'Skipping preflight \(LLM_HARNESS_PREFLIGHT_DONE=1') {
        throw "run-llm-hooks.ps1 must announce the preflight skip when the env var is set. Output: $combined"
    }
    if ($combined -notmatch 'Running LLM harness self-tests') {
        throw "run-llm-hooks.ps1 did not reach the self-test stage after skipping preflight. exit=$exitCode Output: $combined"
    }
    if ($exitCode -ne 0) {
        throw "run-llm-hooks.ps1 validated the skip notice/no-preflight invariants but exited $exitCode afterward. Output: $combined"
    }
} -Behavioral

# --- MIN-2: fast mode skips behavioral subprocesses ------------------------

Assert-Test 'MIN-2: agent-check uses AgentFast and Full remains explicit' {
    $check = Get-Content -LiteralPath (Join-Path $ScriptsDir 'agent-check.ps1') -Raw
    if ($check -notmatch '\[switch\]\$Full') {
        throw 'agent-check.ps1 must declare [switch]$Full for exhaustive validation.'
    }
    if ($check -notmatch 'AgentFast') {
        throw 'agent-check.ps1 must default to AgentFast.'
    }
    if ($check -notmatch 'LLM_HARNESS_SKIP_BEHAVIORAL_TESTS') {
        throw 'agent-check.ps1 must set LLM_HARNESS_SKIP_BEHAVIORAL_TESTS for the fast path.'
    }
    $runner = Get-Content -LiteralPath (Join-Path $ScriptsDir 'run-llm-hooks.ps1') -Raw
    if ($runner -notmatch 'Invoke-FastStructuralGuards') {
        throw 'run-llm-hooks.ps1 must run fast in-process structural guards for tooling changes.'
    }
    if ($runner -notmatch 'Skipping behavioral subprocess self-tests in fast mode') {
        throw 'run-llm-hooks.ps1 must not run behavioral subprocess self-tests in fast mode.'
    }
    if ($runner -notmatch '\$checkOnly = \(\$Mode -eq ''AgentFast''\)' -or
        $runner -notmatch 'Invoke-LlmIndexGenerator .* -Check:\$checkOnly') {
        throw 'AgentFast must check generated LLM files without writing them.'
    }
    $tests = Get-Content -LiteralPath (Join-Path $ScriptsDir 'test-llm-harness.ps1') -Raw
    if ($tests -notmatch '\[switch\]\$SkipBehavioralTests') {
        throw 'test-llm-harness.ps1 must declare [switch]$SkipBehavioralTests.'
    }
    if ($tests -notmatch 'LLM_HARNESS_SKIP_BEHAVIORAL_TESTS') {
        throw 'test-llm-harness.ps1 must honor LLM_HARNESS_SKIP_BEHAVIORAL_TESTS env var.'
    }
    if ($tests -notmatch '\[switch\]\$Behavioral') {
        throw 'Assert-Test must accept a -Behavioral switch so tests can be tagged.'
    }
    # At least one test must actually be tagged -Behavioral.
    if ($tests -notmatch '(?m)\}\s*-Behavioral\s*$') {
        throw 'test-llm-harness.ps1 must tag at least one test with -Behavioral.'
    }
}

Assert-Test 'MIN-2: every self-test pwsh subprocess is behavioral or full-only' {
    $tests = Get-Content -LiteralPath (Join-Path $ScriptsDir 'test-llm-harness.ps1') -Raw
    $offenders = [System.Collections.Generic.List[string]]::new()
    $lines = @($tests -split "`r?`n")
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch '(&\s+pwsh\b|Start-Process\s+-FilePath\s+''pwsh''|pwsh\s+-NoProfile\s+-File)') {
            continue
        }
        $start = $i
        while ($start -ge 0 -and $lines[$start] -notmatch "Assert-Test\s+'([^']+)'") {
            $start--
        }
        if ($start -lt 0) { continue }
        [void]($lines[$start] -match "Assert-Test\s+'([^']+)'")
        $name = $Matches[1]
        if ($name -eq 'MIN-2: every self-test pwsh subprocess is behavioral or full-only') { continue }
        $end = $i + 1
        while ($end -lt $lines.Count -and $lines[$end] -notmatch "Assert-Test\s+'([^']+)'") {
            $end++
        }
        $segment = ($lines[$start..($end - 1)] -join "`n")
        if ($segment -notmatch '(?m)\}\s*-Behavioral\s*$') {
            $offenders.Add($name)
        }
    }
    if ($offenders.Count -gt 0) {
        $unique = @($offenders | Sort-Object -Unique)
        throw "Subprocess-spawning self-tests must be tagged -Behavioral: $($unique -join ', ')"
    }
}

Assert-Test 'MIN-2: fast tooling modes run in-process static guards' {
    $runner = Get-Content -LiteralPath (Join-Path $ScriptsDir 'run-llm-hooks.ps1') -Raw
    if ($runner -match "Invoke-PreflightIfNeeded -Required:\(\`$Mode -in @\('Full', 'CI'\) -or \(\`$Mode -eq 'PreCommit'") {
        throw 'PreCommit fast tooling changes must not invoke preflight as a child pwsh process.'
    }
    if ($runner -notmatch '\$fastMode -and \$toolingTouched') {
        throw 'run-llm-hooks.ps1 must gate fast static guards on `$fastMode -and $toolingTouched`.'
    }
    if ($runner -notmatch 'Invoke-FastStructuralGuards') {
        throw 'run-llm-hooks.ps1 must run in-process structural guards for fast tooling changes.'
    }
    if ($runner -notmatch 'Test-InstallGitHooksUndefinedVariables') {
        throw 'Fast structural guards must include the install-git-hooks undefined-variable guard.'
    }
    if ($runner -notmatch 'Skipping behavioral subprocess self-tests in fast mode') {
        throw 'run-llm-hooks.ps1 must explicitly skip subprocess self-tests in fast mode.'
    }
}

Assert-Test 'MIN-2: AgentFast install guard catches undefined variables without child pwsh' {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return }
    if (-not (Get-Command chmod -ErrorAction SilentlyContinue)) { return }
    $realPwsh = (Get-Command pwsh -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if ([string]::IsNullOrWhiteSpace($realPwsh)) { return }

    $repoRoot = Split-Path -Parent $ScriptsDir
    $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("llm-agentfast-static-$([Guid]::NewGuid())")
    $fakeBin = Join-Path $sandbox 'fake-bin'
    New-Item -ItemType Directory -Path $fakeBin -Force | Out-Null
    try {
        Push-Location $sandbox
        try {
            & git init -q --initial-branch=main 2>&1 | Out-Null
            & git config user.email 'test@example.com' 2>&1 | Out-Null
            & git config user.name 'test' 2>&1 | Out-Null
        } finally { Pop-Location }

        foreach ($f in @(
                'scripts/run-llm-hooks.ps1',
                'scripts/install-git-hooks.ps1',
                'scripts/preflight.ps1',
                'scripts/lint-llm.ps1',
                'scripts/test-llm-harness.ps1',
                'scripts/lib/LlmHarness.psm1',
                '.devcontainer/post-create.sh'
            )) {
            $src = Join-Path $repoRoot $f
            $dst = Join-Path $sandbox $f
            $dstDir = Split-Path -Parent $dst
            if (-not (Test-Path -LiteralPath $dstDir -PathType Container)) {
                New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
            }
            Copy-Item -LiteralPath $src -Destination $dst -Force
        }

        Push-Location $sandbox
        try {
            & git add -A 2>&1 | Out-Null
            & git commit -q -m 'baseline' 2>&1 | Out-Null
        } finally { Pop-Location }

        Add-Content -LiteralPath (Join-Path $sandbox 'scripts/install-git-hooks.ps1') `
            -Value "`n`$undefinedFastGuardProbe | Out-Null`n"

        $fakeLog = Join-Path $sandbox 'fake-pwsh.log'
        $fakePwsh = Join-Path $fakeBin 'pwsh'
        [System.IO.File]::WriteAllText(
            $fakePwsh,
            "#!/usr/bin/env sh`necho child-pwsh >> `"$fakeLog`"`nexit 97`n",
            [System.Text.UTF8Encoding]::new($false))
        & chmod +x -- $fakePwsh 2>&1 | Out-Null

        $pathBackup = $env:PATH
        try {
            $env:PATH = "$fakeBin$([System.IO.Path]::PathSeparator)$pathBackup"
            $hooks = Join-Path $sandbox 'scripts/run-llm-hooks.ps1'
            Push-Location $sandbox
            try {
                $output = & $realPwsh -NoProfile -File $hooks -Mode AgentFast -SkipStagedCheck -NoAutoFix 2>&1
                $exitCode = $LASTEXITCODE
            } finally { Pop-Location }
        } finally {
            $env:PATH = $pathBackup
        }

        $combined = ($output | Out-String)
        if ($exitCode -eq 0) {
            throw "AgentFast must fail on the injected undefined installer variable; got exit 0. Output: $combined"
        }
        if ($combined -notmatch 'undefinedFastGuardProbe') {
            throw "AgentFast output must name the undefined installer variable; got: $combined"
        }
        if (Test-Path -LiteralPath $fakeLog -PathType Leaf) {
            throw "AgentFast spawned a child pwsh despite fast static-guard mode. Fake log: $([System.IO.File]::ReadAllText($fakeLog))"
        }
    } finally {
        Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
} -Behavioral

Assert-Test 'MIN-2: AgentFast reports controlled gitignored strays without deleting them' {
    $repoRoot = Split-Path -Parent $ScriptsDir
    $strayName = "scripts/llm-agentfast-stray-$([Guid]::NewGuid()).tmp"
    $strayFull = Join-Path $repoRoot $strayName
    [System.IO.File]::WriteAllText($strayFull, 'sentinel')
    try {
        $hooks = Join-Path $ScriptsDir 'run-llm-hooks.ps1'
        $output = & pwsh -NoProfile -File $hooks -Mode AgentFast -SkipStagedCheck -NoAutoFix 2>&1
        $exitCode = $LASTEXITCODE
        $combined = ($output | Out-String)
        if ($exitCode -eq 0) {
            throw "AgentFast must fail when a controlled stray exists; got exit 0. Output: $combined"
        }
        if ($combined -notmatch [regex]::Escape($strayName)) {
            throw "AgentFast must name the controlled stray artifact; got: $combined"
        }
        if (-not (Test-Path -LiteralPath $strayFull -PathType Leaf)) {
            throw 'AgentFast is non-mutating and must not delete controlled strays in NoAutoFix mode.'
        }
    } finally {
        Remove-Item -LiteralPath $strayFull -Force -ErrorAction SilentlyContinue
    }
} -Behavioral

Assert-Test 'adversarial: AgentFast checks controlled strays before no-change OK and ignores AutoFix' {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return }
    $sandbox = New-HookBehaviorSandbox -Prefix 'llm-agentfast-nochange-stray'
    $strayName = "scripts/llm-agentfast-nochange-$([Guid]::NewGuid()).tmp"
    $strayFull = Join-Path $sandbox $strayName
    [System.IO.File]::WriteAllText($strayFull, 'sentinel')
    try {
        Push-Location $sandbox
        try {
            $hooks = Join-Path $sandbox 'scripts/run-llm-hooks.ps1'
            $output = & pwsh -NoProfile -File $hooks -Mode AgentFast -SkipStagedCheck -AutoFix 2>&1
            $exitCode = $LASTEXITCODE
            $stagedGenerated = @(& git diff --cached --name-only -- '.llm/index.md' '.llm/context.md' 2>&1)
        } finally {
            Pop-Location
        }
        $combined = ($output | Out-String)
        if ($exitCode -eq 0) {
            throw "AgentFast must fail on a controlled stray even when there are no relevant changed paths; got 0. Output: $combined"
        }
        if ($combined -notmatch [regex]::Escape($strayName)) {
            throw "AgentFast must name the controlled stray before any no-change OK exit; got: $combined"
        }
        if ($combined -match 'No staged LLM/harness changes; fast hook OK') {
            throw "AgentFast emitted the no-change OK line despite a controlled stray. Output: $combined"
        }
        if (-not (Test-Path -LiteralPath $strayFull -PathType Leaf)) {
            throw 'AgentFast -AutoFix must remain non-mutating and leave controlled strays on disk.'
        }
        if (@($stagedGenerated | Where-Object { $_ -match '^\.llm/' }).Count -gt 0) {
            throw "AgentFast -AutoFix must not stage generated files; staged: $($stagedGenerated -join ', ')"
        }
    } finally {
        Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
} -Behavioral

Assert-Test 'adversarial: AgentFast catches tracked sibling strays outside controlled dirs before no-change OK' {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return }
    $sandbox = New-HookBehaviorSandbox -Prefix 'llm-agentfast-sibling-strays'
    $strays = @(
        '.devcontainer/post-create.sh.tmp',
        '.github/workflows/llm-harness.yml.tmp',
        '.pre-commit-config.yaml.tmp'
    )
    try {
        foreach ($stray in $strays) {
            [System.IO.File]::WriteAllText((Join-Path $sandbox $stray), 'sentinel')
        }
        Push-Location $sandbox
        try {
            $hooks = Join-Path $sandbox 'scripts/run-llm-hooks.ps1'
            $output = & pwsh -NoProfile -File $hooks -Mode AgentFast -SkipStagedCheck -AutoFix 2>&1
            $exitCode = $LASTEXITCODE
            $staged = @(& git diff --cached --name-only 2>&1)
        } finally {
            Pop-Location
        }

        $combined = ($output | Out-String)
        if ($exitCode -eq 0) {
            throw "AgentFast must fail on tracked sibling strays outside controlled dirs; got 0. Output: $combined"
        }
        foreach ($stray in $strays) {
            if ($combined -notmatch [regex]::Escape($stray)) {
                throw "AgentFast must name tracked sibling stray '$stray'; got: $combined"
            }
            if (-not (Test-Path -LiteralPath (Join-Path $sandbox $stray) -PathType Leaf)) {
                throw "AgentFast -AutoFix must remain non-mutating and leave '$stray' on disk."
            }
        }
        if ($combined -match 'No staged LLM/harness changes; fast hook OK') {
            throw "AgentFast emitted the no-change OK line despite tracked sibling strays. Output: $combined"
        }
        if (@($staged | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
            throw "AgentFast -AutoFix must not stage files; staged: $($staged -join ', ')"
        }
    } finally {
        Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
} -Behavioral

Assert-Test 'adversarial: PreCommit AutoFix deletes tracked sibling strays outside controlled dirs' {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return }
    $sandbox = New-HookBehaviorSandbox -Prefix 'llm-precommit-sibling-strays'
    $strays = @(
        '.devcontainer/post-create.sh.tmp',
        '.github/workflows/llm-harness.yml.tmp',
        '.pre-commit-config.yaml.tmp'
    )
    try {
        foreach ($stray in $strays) {
            [System.IO.File]::WriteAllText((Join-Path $sandbox $stray), 'sentinel')
        }
        Push-Location $sandbox
        try {
            $hooks = Join-Path $sandbox 'scripts/run-llm-hooks.ps1'
            $output = & pwsh -NoProfile -File $hooks -Mode PreCommit -AutoFix 2>&1
            $exitCode = $LASTEXITCODE
            $staged = @(& git diff --cached --name-only 2>&1)
        } finally {
            Pop-Location
        }

        $combined = ($output | Out-String)
        if ($exitCode -ne 0) {
            throw "PreCommit -AutoFix must delete tracked sibling strays and pass; got exit $exitCode. Output: $combined"
        }
        foreach ($stray in $strays) {
            if ($combined -notmatch [regex]::Escape($stray)) {
                throw "PreCommit -AutoFix must name removed tracked sibling stray '$stray'; got: $combined"
            }
            if (Test-Path -LiteralPath (Join-Path $sandbox $stray) -PathType Leaf) {
                throw "PreCommit -AutoFix must delete tracked sibling stray '$stray'."
            }
        }
        if (@($staged | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
            throw "PreCommit stray cleanup must not stage unrelated files; staged: $($staged -join ', ')"
        }
    } finally {
        Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
} -Behavioral

Assert-Test 'adversarial: AgentFast ignores unrelated gitignored tmp outside fast scope' {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return }
    $sandbox = New-HookBehaviorSandbox -Prefix 'llm-agentfast-unrelated-ignored'
    $unrelated = "unrelated-build-output-$([Guid]::NewGuid()).tmp"
    $unrelatedFull = Join-Path $sandbox $unrelated
    [System.IO.File]::WriteAllText($unrelatedFull, 'sentinel')
    try {
        Push-Location $sandbox
        try {
            $hooks = Join-Path $sandbox 'scripts/run-llm-hooks.ps1'
            $output = & pwsh -NoProfile -File $hooks -Mode AgentFast -SkipStagedCheck -NoAutoFix 2>&1
            $exitCode = $LASTEXITCODE
        } finally {
            Pop-Location
        }

        $combined = ($output | Out-String)
        if ($exitCode -ne 0) {
            throw "AgentFast must not run a broad ignored scan or fail on unrelated ignored tmp files. Output: $combined"
        }
        if ($combined -notmatch 'No staged LLM/harness changes; fast hook OK') {
            throw "AgentFast should take the no-change fast OK path for unrelated ignored tmp files. Output: $combined"
        }
        if (-not (Test-Path -LiteralPath $unrelatedFull -PathType Leaf)) {
            throw 'AgentFast must not delete unrelated ignored tmp files.'
        }
    } finally {
        Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
} -Behavioral

Assert-Test 'adversarial: AgentFast rejects ignored LLM markdown inputs before no-change OK' {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return }
    $sandbox = New-HookBehaviorSandbox -Prefix 'llm-agentfast-ignored-input'
    $ignoredRel = '.llm/skills/agentfast-ignored-generation-probe.md'
    $ignoredPath = Join-Path $sandbox $ignoredRel
    try {
        Push-Location $sandbox
        try {
            Add-Content -LiteralPath (Join-Path $sandbox '.gitignore') -Value "`n$ignoredRel`n"
            & git add -- '.gitignore' 2>&1 | Out-Null
            & git commit -q -m 'ignore AgentFast LLM markdown probe' 2>&1 | Out-Null
        } finally {
            Pop-Location
        }

        New-Item -ItemType Directory -Path (Split-Path -Parent $ignoredPath) -Force | Out-Null
        [System.IO.File]::WriteAllText($ignoredPath, @"
---
description: AgentFast ignored generation probe.
triggers: agentfast ignored generation probe
category: Test
---

# AgentFast Ignored Generation Probe
"@, [System.Text.UTF8Encoding]::new($false))

        Push-Location $sandbox
        try {
            $ignoredListed = @(& git ls-files --others --ignored --exclude-standard -- $ignoredRel 2>&1)
            if ($LASTEXITCODE -ne 0 -or $ignoredListed -notcontains $ignoredRel) {
                throw "Sandbox setup expected $ignoredRel to be ignored and untracked; got: $($ignoredListed -join '; ')"
            }

            $hooks = Join-Path $sandbox 'scripts/run-llm-hooks.ps1'
            $output = & pwsh -NoProfile -File $hooks -Mode AgentFast -SkipStagedCheck -AutoFix 2>&1
            $exitCode = $LASTEXITCODE
            $stagedGenerated = @(& git diff --cached --name-only -- '.llm/index.md' '.llm/context.md' 2>&1)
            $unstagedGenerated = @(& git diff --name-only -- '.llm/index.md' '.llm/context.md' 2>&1)
        } finally {
            Pop-Location
        }

        $combined = ($output | Out-String)
        if ($exitCode -eq 0) {
            throw "AgentFast must fail when ignored untracked .llm Markdown would affect generation. Output: $combined"
        }
        if ($combined -notmatch 'Untracked \.llm Markdown inputs' -or
            $combined -notmatch [regex]::Escape($ignoredRel)) {
            throw "AgentFast must name the ignored untracked generation input before no-change OK. Output: $combined"
        }
        if ($combined -match 'No staged LLM/harness changes; fast hook OK') {
            throw "AgentFast emitted the no-change OK line despite an ignored .llm Markdown input. Output: $combined"
        }
        if (@($stagedGenerated | Where-Object { $_ -match '^\.llm/' }).Count -gt 0) {
            throw "AgentFast must not stage generated outputs after detecting an ignored input; staged generated: $($stagedGenerated -join ', ')"
        }
        if (@($unstagedGenerated | Where-Object { $_ -match '^\.llm/' }).Count -gt 0) {
            throw "AgentFast should fail before rewriting generated outputs; unstaged generated: $($unstagedGenerated -join ', ')"
        }
        if (-not (Test-Path -LiteralPath $ignoredPath -PathType Leaf)) {
            throw 'AgentFast must not delete ignored untracked LLM markdown inputs.'
        }
    } finally {
        Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
} -Behavioral

Assert-Test 'adversarial: PreCommit AutoFix does not stage generated drift for tooling-only changes' {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return }
    $sandbox = New-HookBehaviorSandbox -Prefix 'llm-precommit-generated-drift'
    try {
        Add-Content -LiteralPath (Join-Path $sandbox 'scripts/lint-llm.ps1') `
            -Value "`n# staged tooling-only change for generated drift guard`n"
        Push-Location $sandbox
        try {
            & git add -- 'scripts/lint-llm.ps1' 2>&1 | Out-Null
        } finally {
            Pop-Location
        }
        Add-Content -LiteralPath (Join-Path $sandbox '.llm/index.md') `
            -Value "`n<!-- pre-existing generated drift: $([Guid]::NewGuid()) -->`n"

        Push-Location $sandbox
        try {
            $hooks = Join-Path $sandbox 'scripts/run-llm-hooks.ps1'
            $output = & pwsh -NoProfile -File $hooks -Mode PreCommit -AutoFix 2>&1
            $exitCode = $LASTEXITCODE
            $stagedGenerated = @(& git diff --cached --name-only -- '.llm/index.md' '.llm/context.md' 2>&1)
            $unstagedGenerated = @(& git diff --name-only -- '.llm/index.md' '.llm/context.md' 2>&1)
        } finally {
            Pop-Location
        }

        if ($exitCode -ne 0) {
            throw "PreCommit -AutoFix should not fail or stage unrelated generated drift for tooling-only changes. Output: $($output -join '; ')"
        }
        if (@($stagedGenerated | Where-Object { $_ -match '^\.llm/' }).Count -gt 0) {
            throw "PreCommit -AutoFix staged pre-existing generated drift without an LLM/pointer generation cause: $($stagedGenerated -join ', ')"
        }
        if ($unstagedGenerated -notcontains '.llm/index.md') {
            throw "Expected pre-existing generated drift to remain unstaged in the worktree; got: $($unstagedGenerated -join ', ')"
        }
    } finally {
        Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
} -Behavioral

Assert-Test 'adversarial: PreCommit AutoFix does not stage context prose when generator writes nothing' {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return }
    $sandbox = New-HookBehaviorSandbox -Prefix 'llm-precommit-context-prose'
    try {
        Push-Location $sandbox
        try {
            $generator = Join-Path $sandbox 'scripts/generate-llm-index.ps1'
            $genOutput = & pwsh -NoProfile -File $generator 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to normalize generated files in sandbox: $($genOutput -join '; ')"
            }
            & git add -- '.llm/index.md' '.llm/context.md' 2>&1 | Out-Null
            & git commit -q -m 'normalized generated baseline' 2>&1 | Out-Null
        } finally {
            Pop-Location
        }

        Add-Content -LiteralPath (Join-Path $sandbox '.llm/README.md') `
            -Value "`nStaged body-only README edit that should not affect generated output.`n"
        Push-Location $sandbox
        try {
            & git add -- '.llm/README.md' 2>&1 | Out-Null
        } finally {
            Pop-Location
        }
        Add-Content -LiteralPath (Join-Path $sandbox '.llm/context.md') `
            -Value "`nUnstaged prose outside the generated block: $([Guid]::NewGuid())`n"

        Push-Location $sandbox
        try {
            $hooks = Join-Path $sandbox 'scripts/run-llm-hooks.ps1'
            $output = & pwsh -NoProfile -File $hooks -Mode PreCommit -AutoFix 2>&1
            $exitCode = $LASTEXITCODE
            $staged = @(& git diff --cached --name-only 2>&1)
            $unstaged = @(& git diff --name-only 2>&1)
        } finally {
            Pop-Location
        }

        $combined = ($output | Out-String)
        if ($exitCode -ne 0) {
            throw "PreCommit -AutoFix must pass when only unstaged context prose is outside the generated block. Output: $combined"
        }
        if ($staged -contains '.llm/context.md') {
            throw "PreCommit -AutoFix staged unrelated .llm/context.md prose even though the generator wrote nothing. Staged: $($staged -join ', ') Output: $combined"
        }
        if ($staged -notcontains '.llm/README.md') {
            throw "Sandbox setup expected .llm/README.md to remain staged; staged: $($staged -join ', ')"
        }
        if ($unstaged -notcontains '.llm/context.md') {
            throw "Unstaged context prose should remain in the worktree; unstaged: $($unstaged -join ', ')"
        }
        if ($combined -match 'AutoFix: staging regenerated LLM files') {
            throw "PreCommit -AutoFix must not announce generated staging when the generator wrote nothing. Output: $combined"
        }
    } finally {
        Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
} -Behavioral

Assert-Test 'final-review: PreCommit AutoFix stages only generated context block when generator writes' {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return }
    $sandbox = New-HookBehaviorSandbox -Prefix 'llm-precommit-context-block-only'
    $proseMarker = "Unstaged context prose outside generated block: $([Guid]::NewGuid())"
    try {
        Push-Location $sandbox
        try {
            $generator = Join-Path $sandbox 'scripts/generate-llm-index.ps1'
            $genOutput = & pwsh -NoProfile -File $generator 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to normalize generated files in sandbox: $($genOutput -join '; ')"
            }
            & git add -- '.llm/index.md' '.llm/context.md' 2>&1 | Out-Null
            & git commit -q -m 'normalized generated baseline' 2>&1 | Out-Null
        } finally {
            Pop-Location
        }

        $skillDir = Join-Path $sandbox '.llm/skills'
        New-Item -ItemType Directory -Path $skillDir -Force | Out-Null
        $skillRel = '.llm/skills/generated-block-probe.md'
        $skillPath = Join-Path $sandbox $skillRel
        $skillContent = @"
---
description: Generated block staging probe.
triggers: generated block, staging probe
category: Test
---

# Generated Block Staging Probe
"@
        [System.IO.File]::WriteAllText($skillPath, $skillContent, [System.Text.UTF8Encoding]::new($false))
        Push-Location $sandbox
        try {
            & git add -- $skillRel 2>&1 | Out-Null
        } finally {
            Pop-Location
        }
        Add-Content -LiteralPath (Join-Path $sandbox '.llm/context.md') -Value "`n$proseMarker`n"

        Push-Location $sandbox
        try {
            $hooks = Join-Path $sandbox 'scripts/run-llm-hooks.ps1'
            $output = & pwsh -NoProfile -File $hooks -Mode PreCommit -AutoFix 2>&1
            $exitCode = $LASTEXITCODE
            $staged = @(& git diff --cached --name-only 2>&1)
            $unstaged = @(& git diff --name-only 2>&1)
            $stagedContext = (@(& git show ':.llm/context.md' 2>&1) -join "`n")
            $worktreeContext = [System.IO.File]::ReadAllText((Join-Path $sandbox '.llm/context.md'))
        } finally {
            Pop-Location
        }

        $combined = ($output | Out-String)
        if ($exitCode -ne 0) {
            throw "PreCommit -AutoFix must pass while staging only the generated context block. Output: $combined"
        }
        foreach ($expected in @($skillRel, '.llm/index.md', '.llm/context.md')) {
            if ($staged -notcontains $expected) {
                throw "Expected '$expected' to be staged; staged: $($staged -join ', ') Output: $combined"
            }
        }
        if ($stagedContext -notmatch 'Generated Block Staging Probe') {
            throw "Staged context must include the regenerated block entry. Staged context: $stagedContext"
        }
        if ($stagedContext -match [regex]::Escape($proseMarker)) {
            throw "PreCommit -AutoFix staged unrelated context prose outside the generated block. Staged context: $stagedContext"
        }
        if ($worktreeContext -notmatch [regex]::Escape($proseMarker)) {
            throw 'Unstaged context prose should remain in the working tree.'
        }
        if ($unstaged -notcontains '.llm/context.md') {
            throw "Unstaged context prose should remain as a worktree diff; unstaged: $($unstaged -join ', ')"
        }
    } finally {
        Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
} -Behavioral

Assert-Test 'final-review: PreCommit AutoFix rejects untracked LLM markdown generation inputs' {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return }
    $sandbox = New-HookBehaviorSandbox -Prefix 'llm-precommit-untracked-input'
    try {
        Push-Location $sandbox
        try {
            $generator = Join-Path $sandbox 'scripts/generate-llm-index.ps1'
            $genOutput = & pwsh -NoProfile -File $generator 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to normalize generated files in sandbox: $($genOutput -join '; ')"
            }
            & git add -- '.llm/index.md' '.llm/context.md' 2>&1 | Out-Null
            & git commit -q -m 'normalized generated baseline' 2>&1 | Out-Null
        } finally {
            Pop-Location
        }

        $skillDir = Join-Path $sandbox '.llm/skills'
        New-Item -ItemType Directory -Path $skillDir -Force | Out-Null
        $stagedRel = '.llm/skills/staged-generation-probe.md'
        $stagedPath = Join-Path $sandbox $stagedRel
        [System.IO.File]::WriteAllText($stagedPath, @"
---
description: Staged generation probe.
triggers: staged generation probe
category: Test
---

# Staged Generation Probe
"@, [System.Text.UTF8Encoding]::new($false))
        $untrackedRel = '.llm/skills/untracked-generation-probe.md'
        $untrackedPath = Join-Path $sandbox $untrackedRel
        [System.IO.File]::WriteAllText($untrackedPath, @"
---
description: Untracked generation probe.
triggers: untracked generation probe
category: Test
---

# Untracked Generation Probe
"@, [System.Text.UTF8Encoding]::new($false))
        Push-Location $sandbox
        try {
            & git add -- $stagedRel 2>&1 | Out-Null
            $hooks = Join-Path $sandbox 'scripts/run-llm-hooks.ps1'
            $output = & pwsh -NoProfile -File $hooks -Mode PreCommit -AutoFix 2>&1
            $exitCode = $LASTEXITCODE
            $stagedGenerated = @(& git diff --cached --name-only -- '.llm/index.md' '.llm/context.md' 2>&1)
            $unstagedGenerated = @(& git diff --name-only -- '.llm/index.md' '.llm/context.md' 2>&1)
            $stagedAll = @(& git diff --cached --name-only 2>&1)
        } finally {
            Pop-Location
        }

        $combined = ($output | Out-String)
        if ($exitCode -eq 0) {
            throw "PreCommit -AutoFix must fail when untracked .llm Markdown would affect generation. Output: $combined"
        }
        if ($combined -notmatch 'Untracked \.llm Markdown inputs' -or
            $combined -notmatch [regex]::Escape($untrackedRel)) {
            throw "PreCommit must name the untracked generation input before staging generated outputs. Output: $combined"
        }
        if (@($stagedGenerated | Where-Object { $_ -match '^\.llm/' }).Count -gt 0) {
            throw "PreCommit must not stage generated outputs after detecting an untracked input; staged generated: $($stagedGenerated -join ', ')"
        }
        if (@($unstagedGenerated | Where-Object { $_ -match '^\.llm/' }).Count -gt 0) {
            throw "PreCommit should fail before rewriting generated outputs; unstaged generated: $($unstagedGenerated -join ', ')"
        }
        if ($stagedAll -notcontains $stagedRel) {
            throw "Sandbox setup expected staged LLM input to remain staged; staged: $($stagedAll -join ', ')"
        }
    } finally {
        Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
} -Behavioral

Assert-Test 'final-review: PreCommit AutoFix rejects ignored untracked LLM markdown generation inputs' {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return }
    $sandbox = New-HookBehaviorSandbox -Prefix 'llm-precommit-ignored-input'
    try {
        Push-Location $sandbox
        try {
            $generator = Join-Path $sandbox 'scripts/generate-llm-index.ps1'
            $genOutput = & pwsh -NoProfile -File $generator 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to normalize generated files in sandbox: $($genOutput -join '; ')"
            }
            & git add -- '.llm/index.md' '.llm/context.md' 2>&1 | Out-Null
            & git commit -q -m 'normalized generated baseline' 2>&1 | Out-Null

            Add-Content -LiteralPath (Join-Path $sandbox '.gitignore') `
                -Value "`n.llm/skills/ignored-generation-probe.md`n"
            & git add -- '.gitignore' 2>&1 | Out-Null
            & git commit -q -m 'ignore ignored LLM markdown probe' 2>&1 | Out-Null
        } finally {
            Pop-Location
        }

        $skillDir = Join-Path $sandbox '.llm/skills'
        New-Item -ItemType Directory -Path $skillDir -Force | Out-Null
        $stagedRel = '.llm/skills/staged-ignored-generation-probe.md'
        $stagedPath = Join-Path $sandbox $stagedRel
        [System.IO.File]::WriteAllText($stagedPath, @"
---
description: Staged ignored-input generation probe.
triggers: staged ignored input generation probe
category: Test
---

# Staged Ignored Input Generation Probe
"@, [System.Text.UTF8Encoding]::new($false))
        $ignoredRel = '.llm/skills/ignored-generation-probe.md'
        $ignoredPath = Join-Path $sandbox $ignoredRel
        [System.IO.File]::WriteAllText($ignoredPath, @"
---
description: Ignored untracked generation probe.
triggers: ignored untracked generation probe
category: Test
---

# Ignored Untracked Generation Probe
"@, [System.Text.UTF8Encoding]::new($false))
        Push-Location $sandbox
        try {
            & git add -- $stagedRel 2>&1 | Out-Null
            $ignoredListed = @(& git ls-files --others --ignored --exclude-standard -- $ignoredRel 2>&1)
            if ($LASTEXITCODE -ne 0 -or $ignoredListed -notcontains $ignoredRel) {
                throw "Sandbox setup expected $ignoredRel to be ignored and untracked; got: $($ignoredListed -join '; ')"
            }

            $hooks = Join-Path $sandbox 'scripts/run-llm-hooks.ps1'
            $output = & pwsh -NoProfile -File $hooks -Mode PreCommit -AutoFix 2>&1
            $exitCode = $LASTEXITCODE
            $stagedGenerated = @(& git diff --cached --name-only -- '.llm/index.md' '.llm/context.md' 2>&1)
            $unstagedGenerated = @(& git diff --name-only -- '.llm/index.md' '.llm/context.md' 2>&1)
            $stagedAll = @(& git diff --cached --name-only 2>&1)
        } finally {
            Pop-Location
        }

        $combined = ($output | Out-String)
        if ($exitCode -eq 0) {
            throw "PreCommit -AutoFix must fail when ignored untracked .llm Markdown would affect generation. Output: $combined"
        }
        if ($combined -notmatch 'Untracked \.llm Markdown inputs' -or
            $combined -notmatch [regex]::Escape($ignoredRel)) {
            throw "PreCommit must name the ignored untracked generation input before staging generated outputs. Output: $combined"
        }
        if (@($stagedGenerated | Where-Object { $_ -match '^\.llm/' }).Count -gt 0) {
            throw "PreCommit must not stage generated outputs after detecting an ignored untracked input; staged generated: $($stagedGenerated -join ', ')"
        }
        if (@($unstagedGenerated | Where-Object { $_ -match '^\.llm/' }).Count -gt 0) {
            throw "PreCommit should fail before rewriting generated outputs; unstaged generated: $($unstagedGenerated -join ', ')"
        }
        if ($stagedAll -notcontains $stagedRel) {
            throw "Sandbox setup expected staged LLM input to remain staged; staged: $($stagedAll -join ', ')"
        }
        if (-not (Test-Path -LiteralPath $ignoredPath -PathType Leaf)) {
            throw 'PreCommit must not delete ignored untracked LLM markdown inputs.'
        }
    } finally {
        Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
} -Behavioral

Assert-Test 'adversarial: AgentFast AutoFix does not stage generated drift' {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return }
    $sandbox = New-HookBehaviorSandbox -Prefix 'llm-agentfast-generated-drift'
    try {
        Add-Content -LiteralPath (Join-Path $sandbox '.llm/index.md') `
            -Value "`n<!-- agentfast generated drift: $([Guid]::NewGuid()) -->`n"
        Push-Location $sandbox
        try {
            $hooks = Join-Path $sandbox 'scripts/run-llm-hooks.ps1'
            $output = & pwsh -NoProfile -File $hooks -Mode AgentFast -SkipStagedCheck -AutoFix 2>&1
            $exitCode = $LASTEXITCODE
            $stagedGenerated = @(& git diff --cached --name-only -- '.llm/index.md' '.llm/context.md' 2>&1)
            $unstagedGenerated = @(& git diff --name-only -- '.llm/index.md' '.llm/context.md' 2>&1)
        } finally {
            Pop-Location
        }
        if ($exitCode -eq 0) {
            throw "AgentFast should report generated drift in check-only mode; got exit 0. Output: $($output -join '; ')"
        }
        if (@($stagedGenerated | Where-Object { $_ -match '^\.llm/' }).Count -gt 0) {
            throw "AgentFast -AutoFix must not stage generated drift; staged: $($stagedGenerated -join ', ')"
        }
        if ($unstagedGenerated -notcontains '.llm/index.md') {
            throw "Expected AgentFast generated drift to remain unstaged in the worktree; got: $($unstagedGenerated -join ', ')"
        }
    } finally {
        Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
} -Behavioral

# --- MIN-3: shim parse-check has a behavioral sandbox cover ----------------

Assert-Test 'MIN-3: installed shim self-heals a corrupt run-llm-hooks.ps1 via git checkout' {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return }
    if (-not (Get-Command sh -ErrorAction SilentlyContinue)) { return }
    $repoRoot = Split-Path -Parent $ScriptsDir
    $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("llm-shim-test-$([Guid]::NewGuid())")
    New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
    # The sandbox shim ends up running run-llm-hooks.ps1, which in turn
    # runs the FULL self-test suite (this very file). Without this guard
    # we recurse infinitely as each child runs MIN-3 -> sh -> ... etc.
    # `LLM_HARNESS_SKIP_BEHAVIORAL_TESTS=1` makes the inner tests skip
    # all behavioral tests including this one, breaking the recursion.
    $envBehaviorBackup = $env:LLM_HARNESS_SKIP_BEHAVIORAL_TESTS
    $env:LLM_HARNESS_SKIP_BEHAVIORAL_TESTS = '1'
    try {
        Push-Location $sandbox
        try {
            & git init -q --initial-branch=main 2>&1 | Out-Null
            & git config user.email 'test@example.com' 2>&1 | Out-Null
            & git config user.name 'test' 2>&1 | Out-Null
        } finally { Pop-Location }

        # Materialise the scripts/ tree we need: install-git-hooks, the
        # entry script, preflight, lint, generator, self-tests, module.
        $sandboxScripts = Join-Path $sandbox 'scripts'
        $sandboxLib = Join-Path $sandboxScripts 'lib'
        New-Item -ItemType Directory -Path $sandboxLib -Force | Out-Null
        foreach ($f in @(
                '.githooks/pre-commit',
                'scripts/run-llm-hooks.ps1', 'scripts/preflight.ps1',
                'scripts/generate-llm-index.ps1', 'scripts/lint-llm.ps1',
                'scripts/test-llm-harness.ps1', 'scripts/install-git-hooks.ps1',
                'scripts/lib/LlmHarness.psm1'
            )) {
            $src = Join-Path $repoRoot $f
            $dst = Join-Path $sandbox $f
            $dstDir = Split-Path -Parent $dst
            if (-not (Test-Path -LiteralPath $dstDir)) {
                New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
            }
            Copy-Item -LiteralPath $src -Destination $dst -Force
        }
        Push-Location $sandbox
        try {
            & git add -A 2>&1 | Out-Null
            & git commit -q -m 'baseline' 2>&1 | Out-Null

            # Install the hook.
            $installer = Join-Path $sandboxScripts 'install-git-hooks.ps1'
            $installOut = & pwsh -NoProfile -File $installer 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "install-git-hooks.ps1 failed in sandbox (exit $LASTEXITCODE): $($installOut | Out-String)"
            }
            $hookPath = Join-Path $sandbox '.git/hooks/pre-commit'
            if (-not (Test-Path -LiteralPath $hookPath -PathType Leaf)) {
                throw "Installer did not materialise $hookPath."
            }
        } finally { Pop-Location }

        # Corrupt run-llm-hooks.ps1 so the shim's parse-check + git
        # checkout path actually has to fire.
        $sandboxEntry = Join-Path $sandboxScripts 'run-llm-hooks.ps1'
        $entryOriginal = [System.IO.File]::ReadAllText($sandboxEntry)
        $shimIndexSentinel = 'SHIM_INDEX_ONLY_SENTINEL'
        $shimWorktreeSentinel = 'SHIM_WORKTREE_ONLY_SENTINEL'
        [System.IO.File]::WriteAllText($sandboxEntry, "$entryOriginal`n}}}$shimIndexSentinel`n")
        Push-Location $sandbox
        try {
            & git add -- 'scripts/run-llm-hooks.ps1' 2>&1 | Out-Null
        } finally { Pop-Location }
        [System.IO.File]::WriteAllText($sandboxEntry, "$entryOriginal`n}}}$shimWorktreeSentinel`n")

        # Invoke the shim directly via sh, exactly like git would.
        $shOutput = $null
        Push-Location $sandbox
        try {
            $shOutput = & sh '.git/hooks/pre-commit' 2>&1
            $shExit = $LASTEXITCODE
        } finally { Pop-Location }
        $combined = ($shOutput | Out-String)
        # The shim must announce the recovery action.
        if ($combined -notmatch 'WARNING.*has parse errors.*restoring from index or HEAD' -and
            $combined -notmatch 'Recovered .* from (index|HEAD)') {
            throw "Shim must emit an index/HEAD restore warning when run-llm-hooks.ps1 is corrupt. Output: $combined"
        }

        # After the shim ran, run-llm-hooks.ps1 must parse clean again.
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $sandboxEntry, [ref]$tokens, [ref]$errors)
        if ($null -ne $errors -and $errors.Count -gt 0) {
            throw "Sandbox run-llm-hooks.ps1 should parse cleanly after the shim self-heal. shExit=$shExit Output: $combined"
        }
        $recoveryParent = Resolve-TestGitPath -RepoRoot $sandbox -GitPath 'preflight-recovery'
        $backupFiles = @(Get-ChildItem -LiteralPath $recoveryParent -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq 'scripts__run-llm-hooks.ps1' })
        if ($backupFiles.Count -eq 0) {
            throw "Shim recovery must preserve corrupt run-llm-hooks.ps1 WIP under $recoveryParent. Output: $combined"
        }
        $backupText = [System.IO.File]::ReadAllText($backupFiles[0].FullName)
        if ($backupText -notmatch [regex]::Escape($shimWorktreeSentinel) -or
            $backupText -match [regex]::Escape($shimIndexSentinel)) {
            throw "Shim recovery backup must contain the corrupt WIP bytes; got: $backupText"
        }
        $indexBackupFiles = @(Get-ChildItem -LiteralPath $recoveryParent -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq 'scripts__run-llm-hooks.ps1.index' })
        if ($indexBackupFiles.Count -eq 0) {
            throw "Shim recovery must preserve corrupt staged/index run-llm-hooks.ps1 WIP under $recoveryParent. Output: $combined"
        }
        $indexBackupText = [System.IO.File]::ReadAllText($indexBackupFiles[0].FullName)
        if ($indexBackupText -notmatch [regex]::Escape($shimIndexSentinel) -or
            $indexBackupText -match [regex]::Escape($shimWorktreeSentinel)) {
            throw "Shim recovery index backup must contain the corrupt staged bytes; got: $indexBackupText"
        }
    } finally {
        $env:LLM_HARNESS_SKIP_BEHAVIORAL_TESTS = $envBehaviorBackup
        Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
} -Behavioral

# --- MIN-4: preflight prune logic retains the 20 most-recent dirs ----------

Assert-Test 'MIN-4: preflight prunes recovery dirs to 20 most-recent' {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return }
    $repoRoot = Split-Path -Parent $ScriptsDir
    $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("llm-prune-test-$([Guid]::NewGuid())")
    New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
    try {
        Push-Location $sandbox
        try {
            & git init -q --initial-branch=main 2>&1 | Out-Null
            & git config user.email 'test@example.com' 2>&1 | Out-Null
            & git config user.name 'test' 2>&1 | Out-Null
        } finally { Pop-Location }

        $sandboxScripts = Join-Path $sandbox 'scripts'
        $sandboxLib = Join-Path $sandboxScripts 'lib'
        New-Item -ItemType Directory -Path $sandboxLib -Force | Out-Null
        foreach ($f in @(
                'scripts/preflight.ps1', 'scripts/lib/LlmHarness.psm1'
            )) {
            $src = Join-Path $repoRoot $f
            $dst = Join-Path $sandbox $f
            Copy-Item -LiteralPath $src -Destination $dst -Force
        }
        # Also copy the entry/lint/gen/tests so preflight's git ls-files
        # has stuff to enumerate (it errors if the ls-files set is empty
        # in some edge cases; defensive copy keeps the sandbox realistic).
        foreach ($f in @(
                'scripts/run-llm-hooks.ps1', 'scripts/generate-llm-index.ps1',
                'scripts/lint-llm.ps1', 'scripts/test-llm-harness.ps1',
                'scripts/install-git-hooks.ps1', 'scripts/agent-check.ps1'
            )) {
            $src = Join-Path $repoRoot $f
            $dst = Join-Path $sandbox $f
            Copy-Item -LiteralPath $src -Destination $dst -Force
        }
        Push-Location $sandbox
        try {
            & git add -A 2>&1 | Out-Null
            & git commit -q -m 'baseline' 2>&1 | Out-Null
        } finally { Pop-Location }

        # Materialise 25 fake recovery dirs with staggered mtimes so we
        # can verify the most-recent 20 survive.
        $recoveryParent = Resolve-TestGitPath -RepoRoot $sandbox -GitPath 'preflight-recovery'
        New-Item -ItemType Directory -Path $recoveryParent -Force | Out-Null
        $baseTime = [DateTime]::UtcNow.AddHours(-24)
        for ($i = 1; $i -le 25; $i++) {
            $name = ('dummy{0:D2}' -f $i)
            $dir = Join-Path $recoveryParent $name
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            # Stagger mtime by minute so sort ordering is unambiguous.
            $mtime = $baseTime.AddMinutes($i)
            (Get-Item -LiteralPath $dir).LastWriteTimeUtc = $mtime
            (Get-Item -LiteralPath $dir).CreationTimeUtc = $mtime
        }
        # Verify pre-state.
        $before = @(Get-ChildItem -LiteralPath $recoveryParent -Directory)
        if ($before.Count -ne 25) {
            throw "Sandbox setup wrong: expected 25 dummy dirs, got $($before.Count)."
        }

        # Run preflight; it prunes at startup.
        $sandboxPreflight = Join-Path $sandboxScripts 'preflight.ps1'
        Push-Location $sandbox
        try {
            & pwsh -NoProfile -File $sandboxPreflight 2>&1 | Out-Null
        } finally { Pop-Location }

        $after = @(Get-ChildItem -LiteralPath $recoveryParent -Directory |
            Where-Object { $_.Name -like 'dummy*' } |
            Sort-Object -Property LastWriteTimeUtc -Descending)
        if ($after.Count -ne 20) {
            throw "Expected 20 dummy dirs to remain after prune; got $($after.Count): $($after.Name -join ', ')"
        }
        # The five oldest (dummy01..dummy05) must be gone.
        foreach ($name in @('dummy01', 'dummy02', 'dummy03', 'dummy04', 'dummy05')) {
            if ($after.Name -contains $name) {
                throw "$name should have been pruned (older than the top 20)."
            }
        }
        # The newest five (dummy21..dummy25) must remain.
        foreach ($name in @('dummy21', 'dummy22', 'dummy23', 'dummy24', 'dummy25')) {
            if ($after.Name -notcontains $name) {
                throw "$name should have survived the prune (in the top 20)."
            }
        }
    } finally {
        Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
} -Behavioral

# --- MIN-5: HEAD-also-corrupt restores the working-tree backup -------------

Assert-Test 'MIN-5: AutoFix restores working-tree WIP when HEAD copy is also corrupt' {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return }
    $repoRoot = Split-Path -Parent $ScriptsDir
    $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("llm-headcorrupt-test-$([Guid]::NewGuid())")
    New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
    try {
        Push-Location $sandbox
        try {
            & git init -q --initial-branch=main 2>&1 | Out-Null
            & git config user.email 'test@example.com' 2>&1 | Out-Null
            & git config user.name 'test' 2>&1 | Out-Null
        } finally { Pop-Location }

        # Copy the real preflight + module + the tracked toolkit so
        # preflight's git ls-files enumerates this file.
        $sandboxScripts = Join-Path $sandbox 'scripts'
        $sandboxLib = Join-Path $sandboxScripts 'lib'
        New-Item -ItemType Directory -Path $sandboxLib -Force | Out-Null
        foreach ($f in @('scripts/preflight.ps1', 'scripts/lib/LlmHarness.psm1')) {
            Copy-Item -LiteralPath (Join-Path $repoRoot $f) -Destination (Join-Path $sandbox $f) -Force
        }
        # Add a "victim" tracked PS file we can corrupt at both HEAD and
        # working tree to force the restore-WIP branch.
        $victimRel = 'scripts/victim.ps1'
        $victimFull = Join-Path $sandbox $victimRel
        # Commit a CORRUPT victim first (parse error at HEAD).
        [System.IO.File]::WriteAllText($victimFull, "param()`n}}}headcorrupt`n")
        Push-Location $sandbox
        try {
            & git add -A 2>&1 | Out-Null
            & git commit -q -m 'baseline-with-broken-victim' 2>&1 | Out-Null
        } finally { Pop-Location }

        # Write DIFFERENT corrupt content in the working tree. AutoFix
        # will: backup the WIP, checkout HEAD (still corrupt), detect HEAD
        # is corrupt, RESTORE the WIP back. We assert the WIP content
        # survives byte-for-byte and the structured error message fires.
        $wipBytes = [System.Text.Encoding]::UTF8.GetBytes("param()`n}}}wipcorrupt`n")
        [System.IO.File]::WriteAllBytes($victimFull, $wipBytes)

        $sandboxPreflight = Join-Path $sandboxScripts 'preflight.ps1'
        $preOutput = $null
        Push-Location $sandbox
        try {
            $preOutput = & pwsh -NoProfile -File $sandboxPreflight -AutoFix 2>&1
            $preExit = $LASTEXITCODE
        } finally { Pop-Location }
        $combined = ($preOutput | Out-String)
        if ($preExit -ne 1) {
            throw "Expected exit 1 when HEAD is also corrupt; got $preExit. Output: $combined"
        }
        if ($combined -notmatch 'HEAD copy of .* is ALSO corrupt' -and
            $combined -notmatch 'HEAD copy of .* is in a corrupt state') {
            throw "Expected structured 'HEAD is ALSO corrupt' message; got: $combined"
        }
        # The working tree must hold the original WIP bytes (the backup
        # must have been restored).
        $afterBytes = [System.IO.File]::ReadAllBytes($victimFull)
        if (-not ([System.Linq.Enumerable]::SequenceEqual([byte[]]$afterBytes, [byte[]]$wipBytes))) {
            throw "Working-tree WIP was NOT restored byte-for-byte; backup-restore branch failed."
        }
    } finally {
        Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
} -Behavioral

# --- MIN-6: recovery dir creation failure surfaces and refuses overwrite ---

Assert-Test 'MIN-6: preflight refuses AutoFix when recovery dir is read-only' {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return }
    # NOTE: `$IsLinux`, `$IsMacOS`, `$IsWindows` are PowerShell automatic
    # variables (read-only). We use the runtime-information API directly
    # rather than shadowing them.
    $onLinux = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
        [System.Runtime.InteropServices.OSPlatform]::Linux)
    $onMac = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
        [System.Runtime.InteropServices.OSPlatform]::OSX)
    if (-not ($onLinux -or $onMac)) {
        # Windows ACL semantics differ enough that this test is gated
        # off; the recovery-failure code path is exercised via the
        # MIN-5 backup-restore test above on every platform.
        if ($VerboseOutput) {
            Write-Host "[llm-test] SKIP (windows acl differ): MIN-6" -ForegroundColor DarkGray
        }
        return
    }
    if (-not (Get-Command chmod -ErrorAction SilentlyContinue)) { return }

    $repoRoot = Split-Path -Parent $ScriptsDir
    $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("llm-readonly-test-$([Guid]::NewGuid())")
    New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
    $recoveryParent = $null
    try {
        Push-Location $sandbox
        try {
            & git init -q --initial-branch=main 2>&1 | Out-Null
            & git config user.email 'test@example.com' 2>&1 | Out-Null
            & git config user.name 'test' 2>&1 | Out-Null
        } finally { Pop-Location }

        $sandboxScripts = Join-Path $sandbox 'scripts'
        $sandboxLib = Join-Path $sandboxScripts 'lib'
        New-Item -ItemType Directory -Path $sandboxLib -Force | Out-Null
        foreach ($f in @('scripts/preflight.ps1', 'scripts/lib/LlmHarness.psm1')) {
            Copy-Item -LiteralPath (Join-Path $repoRoot $f) -Destination (Join-Path $sandbox $f) -Force
        }
        # Commit a clean baseline.
        $victimRel = 'scripts/victim2.ps1'
        $victimFull = Join-Path $sandbox $victimRel
        [System.IO.File]::WriteAllText($victimFull, "param()`nWrite-Host 'ok'`n")
        Push-Location $sandbox
        try {
            & git add -A 2>&1 | Out-Null
            & git commit -q -m 'baseline-clean' 2>&1 | Out-Null
        } finally { Pop-Location }

        # Corrupt working tree.
        $wipText = "param()`n}}}wipcorrupt`n"
        [System.IO.File]::WriteAllText($victimFull, $wipText)
        $wipBytes = [System.IO.File]::ReadAllBytes($victimFull)

        # Pre-create the recovery parent and make it read-only so the
        # `New-Item <resolved-preflight-recovery>/<token>` call fails.
        $recoveryParent = Resolve-TestGitPath -RepoRoot $sandbox -GitPath 'preflight-recovery'
        New-Item -ItemType Directory -Path $recoveryParent -Force | Out-Null
        & chmod 555 -- $recoveryParent 2>&1 | Out-Null

        $sandboxPreflight = Join-Path $sandboxScripts 'preflight.ps1'
        $preOutput = $null
        $preExit = $null
        Push-Location $sandbox
        try {
            $preOutput = & pwsh -NoProfile -File $sandboxPreflight -AutoFix 2>&1
            $preExit = $LASTEXITCODE
        } finally { Pop-Location }
        $combined = ($preOutput | Out-String)
        if ($preExit -ne 1) {
            throw "Expected exit 1 when recovery dir cannot be created; got $preExit. Output: $combined"
        }
        if ($combined -notmatch 'Failed to create recovery directory' -and
            $combined -notmatch 'cannot create recovery directory') {
            throw "Expected structured 'cannot create recovery directory' message; got: $combined"
        }
        # Working tree must be UNTOUCHED (WIP preserved).
        $afterBytes = [System.IO.File]::ReadAllBytes($victimFull)
        if (-not ([System.Linq.Enumerable]::SequenceEqual([byte[]]$afterBytes, [byte[]]$wipBytes))) {
            throw "Working tree was modified despite recovery-dir failure; preflight must refuse to touch WIP without a backup."
        }
    } finally {
        # Restore perms BEFORE recursive delete or rmdir fails.
        if ($null -ne $recoveryParent -and (Test-Path -LiteralPath $recoveryParent)) {
            & chmod 755 -- $recoveryParent 2>&1 | Out-Null
        }
        Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
} -Behavioral

Assert-Test 'worktree: preflight AutoFix writes backups under resolved git path' {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return }
    $sandbox = New-HookBehaviorSandbox -Prefix 'llm-worktree-preflight-main'
    $worktree = Join-Path ([System.IO.Path]::GetTempPath()) ("llm-worktree-preflight-linked-$([Guid]::NewGuid())")
    try {
        Push-Location $sandbox
        try {
            $out = @(& git worktree add --detach $worktree HEAD 2>&1)
            if ($LASTEXITCODE -ne 0) {
                throw "git worktree add failed: $($out -join '; ')"
            }
        } finally {
            Pop-Location
        }

        $gitFile = Join-Path $worktree '.git'
        if (-not (Test-Path -LiteralPath $gitFile -PathType Leaf)) {
            throw 'Linked worktree setup must produce a .git file; otherwise this test is not exercising the worktree path.'
        }
        $legacyRecoveryParent = Join-Path $gitFile 'preflight-recovery'
        $resolvedRecoveryParent = Resolve-TestGitPath -RepoRoot $worktree -GitPath 'preflight-recovery'
        if ($resolvedRecoveryParent -like "$worktree/.git/*") {
            throw "Resolved recovery path must not live under the linked worktree .git file; got $resolvedRecoveryParent"
        }

        $victimRel = 'scripts/lint-llm.ps1'
        $victimFull = Join-Path $worktree $victimRel
        $victimOriginal = [System.IO.File]::ReadAllText($victimFull)
        [System.IO.File]::WriteAllText($victimFull, "$victimOriginal`n}}}worktree-preflight-index-corrupt`n")
        Push-Location $worktree
        try {
            & git add -- $victimRel 2>&1 | Out-Null
        } finally {
            Pop-Location
        }
        [System.IO.File]::WriteAllText($victimFull, "$victimOriginal`n}}}worktree-preflight-corrupt`n")
        $preflight = Join-Path $worktree 'scripts/preflight.ps1'
        Push-Location $worktree
        try {
            $output = & pwsh -NoProfile -File $preflight -AutoFix 2>&1
            $exitCode = $LASTEXITCODE
        } finally {
            Pop-Location
        }

        $combined = ($output | Out-String)
        if ($exitCode -ne 2) {
            throw "Expected preflight -AutoFix to recover and exit 2 in linked worktree; got $exitCode. Output: $combined"
        }
        if ($combined -notmatch [regex]::Escape($resolvedRecoveryParent)) {
            throw "Preflight output must print the resolved recovery path. Expected '$resolvedRecoveryParent'. Output: $combined"
        }
        if (Test-Path -LiteralPath $legacyRecoveryParent) {
            throw "Preflight must not create recovery data under linked worktree .git file path: $legacyRecoveryParent"
        }
        $backupFiles = @(Get-ChildItem -LiteralPath $resolvedRecoveryParent -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq ($victimRel -replace '[\\/]', '__') })
        if ($backupFiles.Count -eq 0) {
            throw "Expected corrupt worktree WIP backup under $resolvedRecoveryParent. Output: $combined"
        }
        $backupText = [System.IO.File]::ReadAllText($backupFiles[0].FullName)
        if ($backupText -notmatch 'worktree-preflight-corrupt') {
            throw "Preflight worktree backup did not contain corrupt WIP bytes; got: $backupText"
        }
        $indexBackupFiles = @(Get-ChildItem -LiteralPath $resolvedRecoveryParent -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq "$( $victimRel -replace '[\\/]', '__' ).index" })
        if ($indexBackupFiles.Count -eq 0) {
            throw "Expected corrupt staged/index backup under $resolvedRecoveryParent. Output: $combined"
        }
        $indexBackupText = [System.IO.File]::ReadAllText($indexBackupFiles[0].FullName)
        if ($indexBackupText -notmatch 'worktree-preflight-index-corrupt') {
            throw "Preflight index backup did not contain corrupt staged bytes; got: $indexBackupText"
        }
    } finally {
        if (Test-Path -LiteralPath $worktree) {
            & git -C $sandbox worktree remove --force $worktree 2>&1 | Out-Null
            Remove-Item -LiteralPath $worktree -Recurse -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
} -Behavioral

Assert-Test 'worktree: run-llm-hooks recovery backup uses resolved git path' {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return }
    $sandbox = New-HookBehaviorSandbox -Prefix 'llm-worktree-runner-main'
    $worktree = Join-Path ([System.IO.Path]::GetTempPath()) ("llm-worktree-runner-linked-$([Guid]::NewGuid())")
    $envBehaviorBackup = $env:LLM_HARNESS_SKIP_BEHAVIORAL_TESTS
    $envPreflightBackup = $env:LLM_HARNESS_PREFLIGHT_DONE
    $env:LLM_HARNESS_SKIP_BEHAVIORAL_TESTS = '1'
    $env:LLM_HARNESS_PREFLIGHT_DONE = $null
    try {
        Push-Location $sandbox
        try {
            $out = @(& git worktree add --detach $worktree HEAD 2>&1)
            if ($LASTEXITCODE -ne 0) {
                throw "git worktree add failed: $($out -join '; ')"
            }
        } finally {
            Pop-Location
        }

        $gitFile = Join-Path $worktree '.git'
        if (-not (Test-Path -LiteralPath $gitFile -PathType Leaf)) {
            throw 'Linked worktree setup must produce a .git file; otherwise this test is not exercising the worktree path.'
        }
        $resolvedRecoveryParent = Resolve-TestGitPath -RepoRoot $worktree -GitPath 'preflight-recovery'
        $legacyRecoveryParent = Join-Path $gitFile 'preflight-recovery'

        $preflightRel = 'scripts/preflight.ps1'
        $preflight = Join-Path $worktree $preflightRel
        $preflightOriginal = [System.IO.File]::ReadAllText($preflight)
        [System.IO.File]::WriteAllText($preflight, "$preflightOriginal`n}}}worktree-runner-index-corrupt`n")
        Push-Location $worktree
        try {
            & git add -- $preflightRel 2>&1 | Out-Null
        } finally {
            Pop-Location
        }
        [System.IO.File]::WriteAllText($preflight, "$preflightOriginal`n}}}worktree-runner-corrupt`n")
        $hooks = Join-Path $worktree 'scripts/run-llm-hooks.ps1'
        Push-Location $worktree
        try {
            $output = & pwsh -NoProfile -File $hooks -Mode PreCommit -SkipStagedCheck -AutoFix 2>&1
            $exitCode = $LASTEXITCODE
        } finally {
            Pop-Location
        }

        $combined = ($output | Out-String)
        if ($exitCode -ne 0) {
            throw "run-llm-hooks.ps1 should recover corrupt preflight in linked worktree and complete; got $exitCode. Output: $combined"
        }
        if ($combined -notmatch 'preflight\.ps1 has parse errors' -and
            $combined -notmatch 'PowerShell parse error in scripts/preflight\.ps1') {
            throw "Expected run-llm-hooks.ps1 to detect corrupt preflight.ps1. Output: $combined"
        }
        if ($combined -notmatch [regex]::Escape($resolvedRecoveryParent)) {
            throw "run-llm-hooks.ps1 recovery output must include resolved recovery path '$resolvedRecoveryParent'. Output: $combined"
        }
        if (Test-Path -LiteralPath $legacyRecoveryParent) {
            throw "run-llm-hooks.ps1 must not create recovery data under linked worktree .git file path: $legacyRecoveryParent"
        }
        $backupFiles = @(Get-ChildItem -LiteralPath $resolvedRecoveryParent -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq 'scripts__preflight.ps1' })
        if ($backupFiles.Count -eq 0) {
            throw "Expected preflight.ps1 recovery backup under $resolvedRecoveryParent. Output: $combined"
        }
        $backupText = [System.IO.File]::ReadAllText($backupFiles[0].FullName)
        if ($backupText -notmatch 'worktree-runner-corrupt') {
            throw "run-llm-hooks worktree backup did not contain corrupt WIP bytes; got: $backupText"
        }
        $indexBackupFiles = @(Get-ChildItem -LiteralPath $resolvedRecoveryParent -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq 'scripts__preflight.ps1.index' })
        if ($indexBackupFiles.Count -eq 0) {
            throw "Expected preflight.ps1 staged/index recovery backup under $resolvedRecoveryParent. Output: $combined"
        }
        $indexBackupText = [System.IO.File]::ReadAllText($indexBackupFiles[0].FullName)
        if ($indexBackupText -notmatch 'worktree-runner-index-corrupt') {
            throw "run-llm-hooks index backup did not contain corrupt staged bytes; got: $indexBackupText"
        }
    } finally {
        $env:LLM_HARNESS_SKIP_BEHAVIORAL_TESTS = $envBehaviorBackup
        $env:LLM_HARNESS_PREFLIGHT_DONE = $envPreflightBackup
        if (Test-Path -LiteralPath $worktree) {
            & git -C $sandbox worktree remove --force $worktree 2>&1 | Out-Null
            Remove-Item -LiteralPath $worktree -Recurse -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
} -Behavioral

# --- MIN-7: Get-PreflightRepoRoot fallback layout assumption ---------------

Assert-Test 'MIN-7: Get-PreflightRepoRoot fallback documents the layout assumption' {
    $src = Get-Content -LiteralPath (Join-Path $ScriptsDir 'preflight.ps1') -Raw
    # The function must document the fallback's layout assumption so a
    # future move of preflight.ps1 surfaces the consideration in code.
    if ($src -notmatch 'LAYOUT ASSUMPTION') {
        throw 'Get-PreflightRepoRoot must document the layout assumption (LAYOUT ASSUMPTION comment).'
    }
    # Behaviorally pinch the function: extract it via AST, copy it into
    # a fresh runspace, and confirm fallback behavior over multiple
    # $ScriptDir shapes when git is "missing".
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput(
        $src, [ref]$tokens, [ref]$parseErrors)
    if ($null -ne $parseErrors -and $parseErrors.Count -gt 0) {
        throw "preflight.ps1 has parse errors: $($parseErrors | ForEach-Object { $_.Message } | Out-String)"
    }
    $func = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Get-PreflightRepoRoot'
            }, $false))
    if ($func.Count -ne 1) {
        throw "Expected exactly one Get-PreflightRepoRoot definition; got $($func.Count)."
    }
    # The expected fallback is `Split-Path -Parent $ScriptDir`. Confirm
    # that exact pattern appears (the function still falls back this way).
    if ($func[0].Extent.Text -notmatch 'Split-Path\s+-Parent\s+\$ScriptDir') {
        throw 'Get-PreflightRepoRoot must include `Split-Path -Parent $ScriptDir` as its fallback.'
    }
    # Synthetic shapes: confirm Split-Path -Parent does NOT crash on
    # diverse inputs (we cannot make git "disappear" here, so we test
    # the underlying primitive).
    foreach ($shape in @('/repo/scripts', '/repo/scripts/', 'C:\repo\scripts', '/repo/scripts/sub')) {
        $r = Split-Path -Parent $shape
        if ($null -eq $r) {
            throw "Split-Path -Parent returned `$null for shape '$shape'."
        }
    }
}

# --- M-9 behavioral: corrupt preflight -> detected by run-llm-hooks --------

Assert-Test 'run-llm-hooks.ps1 detects a parse-corrupt preflight before invoking it' {
    # We materialise a sandbox repo so we can corrupt preflight.ps1 and
    # `git checkout HEAD` will actually have something to restore. Doing
    # this against the live working tree is brittle (preflight may not
    # be committed in HEAD yet).
    $repoRoot = Split-Path -Parent $ScriptsDir
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return }
    $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("llm-recovery-test-$([Guid]::NewGuid())")
    New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
    # Run-llm-hooks invokes the sandbox's test-llm-harness.ps1 which
    # would recursively invoke this very test. Set the skip env var so
    # the inner self-test pass skips behavioral tests entirely.
    # Also clear LLM_HARNESS_PREFLIGHT_DONE: if the outer agent-check.ps1
    # set it as an optimization, the sandbox child would inherit it and
    # skip its preflight pass — defeating the very assertion this test
    # makes ("preflight.ps1 has parse errors" must appear).
    $envBehaviorBackup = $env:LLM_HARNESS_SKIP_BEHAVIORAL_TESTS
    $envPreflightBackup = $env:LLM_HARNESS_PREFLIGHT_DONE
    $env:LLM_HARNESS_SKIP_BEHAVIORAL_TESTS = '1'
    $env:LLM_HARNESS_PREFLIGHT_DONE = $null
    try {
        # Initialise a minimal sandbox with just the scripts we need.
        Push-Location $sandbox
        try {
            & git init -q --initial-branch=main 2>&1 | Out-Null
            & git config user.email 'test@example.com' 2>&1 | Out-Null
            & git config user.name 'test' 2>&1 | Out-Null
        } finally { Pop-Location }
        $sandboxScripts = Join-Path $sandbox 'scripts'
        $sandboxLib = Join-Path $sandboxScripts 'lib'
        New-Item -ItemType Directory -Path $sandboxLib -Force | Out-Null
        # Copy the toolkit files we need.
        foreach ($f in @(
                'scripts/run-llm-hooks.ps1', 'scripts/preflight.ps1',
                'scripts/generate-llm-index.ps1', 'scripts/lint-llm.ps1',
                'scripts/test-llm-harness.ps1', 'scripts/lib/LlmHarness.psm1'
            )) {
            $src = Join-Path $repoRoot $f
            $dst = Join-Path $sandbox $f
            $dstDir = Split-Path -Parent $dst
            if (-not (Test-Path -LiteralPath $dstDir)) {
                New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
            }
            Copy-Item -LiteralPath $src -Destination $dst -Force
        }
        # Commit a clean copy so `git checkout HEAD` has something to restore.
        Push-Location $sandbox
        try {
            & git add -A 2>&1 | Out-Null
            & git commit -q -m 'baseline' 2>&1 | Out-Null
        } finally { Pop-Location }
        # NOW corrupt preflight.ps1 in the sandbox working tree.
        $sandboxPreflight = Join-Path $sandbox 'scripts/preflight.ps1'
        Add-Content -LiteralPath $sandboxPreflight -Value "`n}}}garbage`n"
        # Invoke run-llm-hooks -AutoFix in the sandbox and confirm the
        # parse-check arm fires AND preflight ends up clean.
        $sandboxHooks = Join-Path $sandbox 'scripts/run-llm-hooks.ps1'
        Push-Location $sandbox
        try {
            $output = & pwsh -NoProfile -File $sandboxHooks -SkipStagedCheck -AutoFix 2>&1
        } finally { Pop-Location }
        $combined = ($output | Out-String)
        if ($combined -notmatch 'preflight\.ps1 has parse errors') {
            throw "run-llm-hooks.ps1 must print 'preflight.ps1 has parse errors' when corruption is detected. Output: $combined"
        }
        # After AutoFix the file should parse again.
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $sandboxPreflight, [ref]$tokens, [ref]$errors)
        if ($null -ne $errors -and $errors.Count -gt 0) {
            throw "Sandbox preflight.ps1 should parse cleanly after AutoFix. Output: $combined"
        }
        $recoveryParent = Resolve-TestGitPath -RepoRoot $sandbox -GitPath 'preflight-recovery'
        $backupFiles = @(Get-ChildItem -LiteralPath $recoveryParent -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq 'scripts__preflight.ps1' })
        if ($backupFiles.Count -eq 0) {
            throw "run-llm-hooks.ps1 recovery must preserve corrupt preflight.ps1 WIP under $recoveryParent. Output: $combined"
        }
        $backupText = [System.IO.File]::ReadAllText($backupFiles[0].FullName)
        if ($backupText -notmatch 'garbage') {
            throw "preflight recovery backup must contain the corrupt WIP bytes; got: $backupText"
        }
    } finally {
        $env:LLM_HARNESS_SKIP_BEHAVIORAL_TESTS = $envBehaviorBackup
        $env:LLM_HARNESS_PREFLIGHT_DONE = $envPreflightBackup
        Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
} -Behavioral

# --- Summary ---------------------------------------------------------------

if ($failures.Count -gt 0) {
    $skipNote = if ($skipped -gt 0) { " ($skipped skipped)" } else { '' }
    Write-Host "[llm-test] $($failures.Count) test(s) failed; $passed passed$skipNote." -ForegroundColor Red
    exit 1
}

$skipNote = if ($skipped -gt 0) { " ($skipped behavioral test(s) skipped)" } else { '' }
Write-Host "[llm-test] All $passed test(s) passed$skipNote." -ForegroundColor Green
exit 0
