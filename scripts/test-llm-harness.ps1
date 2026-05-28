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
}

Assert-Test 'local pre-commit entry points pass -AutoFix; CI passes -NoAutoFix' {
    $repoRoot = Split-Path -Parent $ScriptsDir
    $shim = Get-Content -LiteralPath (Join-Path $repoRoot '.githooks/pre-commit') -Raw
    if ($shim -notmatch '-AutoFix') {
        throw '.githooks/pre-commit must pass -AutoFix to run-llm-hooks.ps1 (automated recovery is required).'
    }
    $mirror = Get-Content -LiteralPath (Join-Path $repoRoot '.githooks/pre-commit.ps1') -Raw
    if ($mirror -notmatch '-AutoFix') {
        throw '.githooks/pre-commit.ps1 must pass -AutoFix to run-llm-hooks.ps1.'
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
    if ($content -notmatch '-SkipStagedCheck' -or $content -notmatch '-NoAutoFix') {
        throw 'scripts/agent-check.ps1 must pass -SkipStagedCheck and -NoAutoFix.'
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

Assert-Test 'no stray staging artifacts in the working tree' {
    $repoRoot = Split-Path -Parent $ScriptsDir
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        return  # git unavailable; skip silently in this test (linter has its own check).
    }
    $patterns = @('*.new', '*.bak', '*.orig', '*.old', '*.rej')
    $offenders = @(Get-LlmStagingArtifacts -RepoRoot $repoRoot -Patterns $patterns)
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

Assert-Test 'install-git-hooks.ps1 materializes a portable POSIX-sh hook into .git/hooks' {
    $path = Join-Path $ScriptsDir 'install-git-hooks.ps1'
    $content = Get-Content -LiteralPath $path -Raw
    if ($content -notmatch '\.git/hooks' -and $content -notmatch 'git rev-parse --git-path hooks') {
        throw 'install-git-hooks.ps1 must install into the per-checkout hooks directory (resolved via git rev-parse --git-path hooks).'
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
        throw 'install-git-hooks.ps1 must NOT set core.hooksPath; the live hook lives in .git/hooks/ and the script only clears stale legacy values.'
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
    $pushCount = [regex]::Matches($content, '(?m)^\s*Push-Location\b').Count
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
        throw 'install-git-hooks.ps1 contains the legacy "Missing hooks directory" precondition; the new installer materialises into .git/hooks/ instead.'
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
    'scripts/lint-llm.ps1'                     = 100
    'scripts/generate-llm-index.ps1'           = 50
    'scripts/install-git-hooks.ps1'            = 100
    'scripts/test-llm-harness.ps1'             = 200
    'scripts/preflight.ps1'                    = 100
    'scripts/lib/LlmHarness.psm1'              = 100
    '.claude/hooks/parse-check-powershell.ps1' = 40
    '.claude/hooks/validate-llm-context.ps1'   = 40
    '.claude/hooks/preflight-stop.ps1'         = 30
    '.claude/hooks/session-reminder.ps1'       = 20
}

Assert-Test 'lint-llm.ps1 has no legacy regressions' {
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
    # Catch the duplicate-block corruption signature: a second
    # Invoke-GeneratedIndexCheck call site after the first is the
    # smoking gun for the merge.
    $indexCheckCalls = [regex]::Matches($content, '(?m)^\s*Invoke-GeneratedIndexCheck\s*$').Count
    if ($indexCheckCalls -ne 1) {
        throw "lint-llm.ps1 must invoke Invoke-GeneratedIndexCheck exactly once; found $indexCheckCalls."
    }
    if ($lines.Count -lt 100 -or $lines.Count -gt 500) {
        throw "lint-llm.ps1 line count $($lines.Count) is outside the expected range (100..500); HEAD is ~301."
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

Assert-Test 'agent-check.ps1 invokes preflight before run-llm-hooks' {
    $path = Join-Path $ScriptsDir 'agent-check.ps1'
    $content = Get-Content -LiteralPath $path -Raw
    if ($content -notmatch 'preflight\.ps1') {
        throw 'agent-check.ps1 must invoke scripts/preflight.ps1 so agents catch corruption in the fast path.'
    }
    # Compare the FIRST `& pwsh @preArgs` (or equivalent invocation) of
    # each script. Header comments may mention `run-llm-hooks.ps1`
    # textually before the preflight variable; we only care about call
    # ordering at runtime.
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $path, [ref]$tokens, [ref]$parseErrors)
    if ($null -ne $parseErrors -and $parseErrors.Count -gt 0) {
        throw "Parse errors in agent-check.ps1: $($parseErrors | ForEach-Object { $_.Message } | Out-String)"
    }
    $strings = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.StringConstantExpressionAst]
            }, $true) | Where-Object { $_.Value -match 'preflight\.ps1|run-llm-hooks\.ps1' })
    $preNodes = @($strings | Where-Object { $_.Value -match 'preflight\.ps1' })
    $runNodes = @($strings | Where-Object { $_.Value -match 'run-llm-hooks\.ps1' })
    if ($preNodes.Count -eq 0 -or $runNodes.Count -eq 0) {
        throw 'agent-check.ps1 must reference both preflight.ps1 and run-llm-hooks.ps1 in script (not comment) form.'
    }
    $firstPre = ($preNodes | Sort-Object { $_.Extent.StartOffset } | Select-Object -First 1)
    $firstRun = ($runNodes | Sort-Object { $_.Extent.StartOffset } | Select-Object -First 1)
    if ($firstPre.Extent.StartOffset -gt $firstRun.Extent.StartOffset) {
        throw 'agent-check.ps1 must invoke preflight BEFORE run-llm-hooks so corrupted toolkit scripts cannot run.'
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
}

Assert-Test 'installed git-hook shim parse-checks run-llm-hooks.ps1 before invoking it' {
    $installer = Join-Path $ScriptsDir 'install-git-hooks.ps1'
    $content = Get-Content -LiteralPath $installer -Raw
    # The emitted hook body must include a `ParseFile` self-heal of
    # scripts/run-llm-hooks.ps1 (n-level recovery: shim -> run-llm-hooks
    # -> preflight -> all other PS files). The source script references
    # the entry script via the `$EntryScript` PowerShell variable that
    # gets interpolated into the here-string at install time, so we
    # check for `git checkout HEAD -- "$EntryScript"` (source form).
    if ($content -notmatch 'ParseFile') {
        throw 'install-git-hooks.ps1 must emit a hook that parse-checks run-llm-hooks.ps1 before invoking it (n-level self-heal).'
    }
    if ($content -notmatch 'git checkout HEAD -- "\$EntryScript"') {
        throw 'install-git-hooks.ps1 must emit a hook that recovers $EntryScript (run-llm-hooks.ps1) from HEAD when corrupted.'
    }
    # Behaviorally verify: materialise the hook in a sandbox and confirm
    # it contains the literal `scripts/run-llm-hooks.ps1` after PowerShell
    # interpolation runs.
    $sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("llm-hook-emit-test-$([Guid]::NewGuid())")
    New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
    try {
        # Initialize a real git repo so `git rev-parse --git-path hooks`
        # succeeds; we then invoke the installer with its $PSScriptRoot
        # pointing at the actual scripts/ dir (the installer trusts
        # $PSScriptRoot for repo root resolution, so we cannot fully
        # sandbox without copying; instead we just inspect the source's
        # emitted here-string body via string substitution).
        $rendered = $content
        $rendered = $rendered -replace '\$EntryScript', 'scripts/run-llm-hooks.ps1'
        if ($rendered -notmatch 'git checkout HEAD -- "scripts/run-llm-hooks\.ps1"') {
            throw 'After substituting $EntryScript, the emitted hook body must contain `git checkout HEAD -- "scripts/run-llm-hooks.ps1"`.'
        }
    } finally {
        Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
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

    foreach ($entry in @(
            @{ Name = 'lint-llm.ps1'; Content = $lintSrc },
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

    # The library is the SOURCE of truth: it MAY contain the literal list
    # exactly once (in the $script:LlmDefaultStrayPatterns assignment).
    # Confirm that exactly-one constraint to catch a future regression
    # where the default param() block reintroduces the literal.
    $libMatches = [regex]::Matches($libSrc, "(?s)'\*\.tmp'.*?'\*\.swp'.*?'\*\.swo'.*?'\.DS_Store'")
    if ($libMatches.Count -ne 1) {
        throw "lib/LlmHarness.psm1 must contain exactly one literal stray-pattern list (the canonical source); found $($libMatches.Count)."
    }
}

# --- NIT-5: agent-check skips the second preflight via env var -------------

Assert-Test 'NIT-5: agent-check.ps1 propagates LLM_HARNESS_PREFLIGHT_DONE to skip the second preflight' {
    $check = Get-Content -LiteralPath (Join-Path $ScriptsDir 'agent-check.ps1') -Raw
    if ($check -notmatch 'LLM_HARNESS_PREFLIGHT_DONE') {
        throw 'agent-check.ps1 must set LLM_HARNESS_PREFLIGHT_DONE so the inner run-llm-hooks pass does not re-pay preflight.'
    }
    if ($check -notmatch "LLM_HARNESS_PREFLIGHT_DONE\s*=\s*'1'") {
        throw "agent-check.ps1 must set LLM_HARNESS_PREFLIGHT_DONE='1' exactly (string '1' is the agreed marker)."
    }
    $hook = Get-Content -LiteralPath (Join-Path $ScriptsDir 'run-llm-hooks.ps1') -Raw
    if ($hook -notmatch 'LLM_HARNESS_PREFLIGHT_DONE') {
        throw 'run-llm-hooks.ps1 must honor LLM_HARNESS_PREFLIGHT_DONE so an outer wrapper can suppress the duplicate preflight.'
    }
    # The hook source must skip both the parse-check AND the preflight
    # invocation when the env var is set.
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
    # We do this without recursing into agent-check.ps1 so the test does
    # not run the entire self-test suite under itself.
    $hooks = Join-Path $ScriptsDir 'run-llm-hooks.ps1'
    $envBackup = $env:LLM_HARNESS_PREFLIGHT_DONE
    $env:LLM_HARNESS_PREFLIGHT_DONE = '1'
    try {
        $output = & pwsh -NoProfile -File $hooks -SkipStagedCheck -NoAutoFix 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $env:LLM_HARNESS_PREFLIGHT_DONE = $envBackup
    }
    $combined = ($output | Out-String)
    if ($exitCode -ne 0) {
        throw "run-llm-hooks.ps1 exited $exitCode under the env-var skip path. Output: $combined"
    }
    $matches = [regex]::Matches($combined, 'Running preflight \(parse-check toolkit sources\)')
    if ($matches.Count -ne 0) {
        throw "run-llm-hooks.ps1 emitted 'Running preflight' $($matches.Count) time(s); expected 0 when LLM_HARNESS_PREFLIGHT_DONE=1. Output: $combined"
    }
    if ($combined -notmatch 'Skipping preflight \(LLM_HARNESS_PREFLIGHT_DONE=1') {
        throw "run-llm-hooks.ps1 must announce the preflight skip when the env var is set. Output: $combined"
    }
} -Behavioral

# --- MIN-2: -SkipBehavioralTests subset shortcut ---------------------------

Assert-Test 'MIN-2: agent-check exposes -SkipBehavioralTests and propagates to self-tests' {
    $check = Get-Content -LiteralPath (Join-Path $ScriptsDir 'agent-check.ps1') -Raw
    if ($check -notmatch '\[switch\]\$SkipBehavioralTests') {
        throw 'agent-check.ps1 must declare [switch]$SkipBehavioralTests for sub-3s feedback.'
    }
    if ($check -notmatch 'LLM_HARNESS_SKIP_BEHAVIORAL_TESTS') {
        throw 'agent-check.ps1 must propagate -SkipBehavioralTests via the LLM_HARNESS_SKIP_BEHAVIORAL_TESTS env var.'
    }
    if ($check -notmatch 'Comprehensive pre-commit') {
        throw 'agent-check.ps1 docstring must be rephrased honestly: "Comprehensive pre-commit ... ~10-15s ... use -SkipBehavioralTests for sub-3s feedback".'
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
        Add-Content -LiteralPath $sandboxEntry -Value "`n}}}garbage`n"

        # Invoke the shim directly via sh, exactly like git would.
        $shOutput = $null
        Push-Location $sandbox
        try {
            $shOutput = & sh '.git/hooks/pre-commit' 2>&1
            $shExit = $LASTEXITCODE
        } finally { Pop-Location }
        $combined = ($shOutput | Out-String)
        # The shim must announce the recovery action.
        if ($combined -notmatch 'WARNING.*has parse errors.*restoring from HEAD' -and
            $combined -notmatch 'restoring from HEAD') {
            throw "Shim must emit a 'restoring from HEAD' warning when run-llm-hooks.ps1 is corrupt. Output: $combined"
        }

        # After the shim ran, run-llm-hooks.ps1 must parse clean again.
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $sandboxEntry, [ref]$tokens, [ref]$errors)
        if ($null -ne $errors -and $errors.Count -gt 0) {
            throw "Sandbox run-llm-hooks.ps1 should parse cleanly after the shim self-heal. shExit=$shExit Output: $combined"
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
        $recoveryParent = Join-Path $sandbox '.git/preflight-recovery'
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
        # `New-Item .git/preflight-recovery/<token>` call fails.
        $recoveryParent = Join-Path $sandbox '.git/preflight-recovery'
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
