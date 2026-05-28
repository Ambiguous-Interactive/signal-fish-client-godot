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

Assert-Test 'pre-commit hooks pass -AutoFix; CI passes -NoAutoFix' {
    $repoRoot = Split-Path -Parent $ScriptsDir
    $shim = Get-Content -LiteralPath (Join-Path $repoRoot '.githooks/pre-commit') -Raw
    if ($shim -notmatch '-AutoFix') {
        throw '.githooks/pre-commit must pass -AutoFix to run-llm-hooks.ps1 (automated recovery is required).'
    }
    $mirror = Get-Content -LiteralPath (Join-Path $repoRoot '.githooks/pre-commit.ps1') -Raw
    if ($mirror -notmatch '-AutoFix') {
        throw '.githooks/pre-commit.ps1 must pass -AutoFix to run-llm-hooks.ps1.'
    }
    $workflow = Join-Path $repoRoot '.github/workflows/llm-harness.yml'
    if (Test-Path -LiteralPath $workflow -PathType Leaf) {
        $ci = Get-Content -LiteralPath $workflow -Raw
        if ($ci -notmatch '-NoAutoFix') {
            throw '.github/workflows/llm-harness.yml must pass -NoAutoFix so CI fails loudly on drift.'
        }
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

Assert-Test 'no stray staging artifacts in the working tree' {
    $repoRoot = Split-Path -Parent $ScriptsDir
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        return  # git unavailable; skip silently in this test (linter has its own check).
    }
    Push-Location $repoRoot
    try {
        $patterns = @('*.new', '*.bak', '*.orig', '*.old', '*.rej')
        $tracked = @(& git ls-files -- @patterns 2>$null) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        $untracked = @(& git ls-files --others --exclude-standard -- @patterns 2>$null) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        $offenders = @($tracked + $untracked | Sort-Object -Unique)
        if ($offenders.Count -gt 0) {
            throw "Found stray staging artifacts: $($offenders -join ', ')"
        }
    } finally {
        Pop-Location
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
        $files = @(& git ls-files -- '*.ps1' '*.psm1' '*.psd1' 2>$null) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
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
            'PSCmdlet', 'this', 'input', 'Force')) {
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
    # the broken pattern.
    $hereStringMatch = [regex]::Match($content, '(?s)@"\s*\r?\n(?<body>.*?)\r?\n"@')
    if ($hereStringMatch.Success -and $hereStringMatch.Groups['body'].Value -match '(?m)^#!/usr/bin/env pwsh') {
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

# --- Summary ---------------------------------------------------------------

if ($failures.Count -gt 0) {
    Write-Host "[llm-test] $($failures.Count) test(s) failed; $passed passed." -ForegroundColor Red
    exit 1
}

Write-Host "[llm-test] All $passed test(s) passed." -ForegroundColor Green
exit 0
