# Signal Fish dev-container PowerShell profile.
# Persists PSReadLine history to the mounted volume so command history
# survives container rebuilds. The mount target is configured in
# devcontainer.json (`/commandhistory`).

if (Get-Module -ListAvailable PSReadLine) {
    Import-Module PSReadLine -ErrorAction SilentlyContinue

    $historyDir = '/commandhistory'
    if (Test-Path $historyDir) {
        $historyFile = Join-Path $historyDir 'pwsh_history.txt'
        Set-PSReadLineOption -HistorySavePath $historyFile
        Set-PSReadLineOption -HistorySaveStyle SaveIncrementally
        Set-PSReadLineOption -MaximumHistoryCount 10000
        Set-PSReadLineOption -PredictionSource HistoryAndPlugin -ErrorAction SilentlyContinue
        Set-PSReadLineOption -PredictionViewStyle ListView -ErrorAction SilentlyContinue
    }

    Set-PSReadLineOption -EditMode Emacs
    Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete
    Set-PSReadLineKeyHandler -Key UpArrow -Function HistorySearchBackward
    Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
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
