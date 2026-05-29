# Signal Fish dev-container PowerShell profile.
# Persists PSReadLine history to the mounted volume so command history
# survives container rebuilds. The mount target is configured in
# devcontainer.json (`/commandhistory`).

$psReadLineModule = Get-Module PSReadLine -ErrorAction SilentlyContinue
if (-not $psReadLineModule) {
    try {
        Import-Module PSReadLine -ErrorAction Stop
        $psReadLineModule = Get-Module PSReadLine -ErrorAction SilentlyContinue
    } catch {
        $psReadLineModule = $null
    }
}

if ($psReadLineModule) {

    $historyDir = '/commandhistory'
    if (Test-Path $historyDir) {
        $historyFile = Join-Path $historyDir 'pwsh_history.txt'
        Set-PSReadLineOption -HistorySavePath $historyFile -ErrorAction SilentlyContinue
        Set-PSReadLineOption -HistorySaveStyle SaveIncrementally -ErrorAction SilentlyContinue
        Set-PSReadLineOption -MaximumHistoryCount 10000 -ErrorAction SilentlyContinue
        Set-PSReadLineOption -PredictionSource HistoryAndPlugin -ErrorAction SilentlyContinue
        Set-PSReadLineOption -PredictionViewStyle ListView -ErrorAction SilentlyContinue
    }

    Set-PSReadLineOption -EditMode Emacs -ErrorAction SilentlyContinue
    Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete -ErrorAction SilentlyContinue
    Set-PSReadLineKeyHandler -Key UpArrow -Function HistorySearchBackward -ErrorAction SilentlyContinue
    Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward -ErrorAction SilentlyContinue
}

# Friendly prompt: short cwd + git branch if available.
function prompt {
    $cwd = Split-Path -Leaf (Get-Location)
    $branch = ''
    try {
        $b = git rev-parse --abbrev-ref HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $b) { $branch = " ($b)" }
    } catch { }
    "PS $cwd$branch> "
}
