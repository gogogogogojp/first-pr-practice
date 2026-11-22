# Watch-ClaudeWorker.ps1
# ハチ機能1「詰まりの自己検知と自動修理」の最初の版（見張り係）。
# 最新化（git pull）の詰まりを検知し、安全な修理（再試行）だけを自動で行う。
# 作業中の変更を消す操作（stash・reset・削除・強制上書き）はしない。該当時は「要承認」として終了する。
# 終了コード: 0 = 正常 / 1 = 自動修理に失敗（再試行の上限到達） / 2 = 要承認（人の判断が必要）
# 注意: 定期実行への登録はまだ行わない（タスクスケジューラの変更は要承認）。
param(
  [string]$RepoPath = "$env:USERPROFILE\repos\first-pr-practice",
  [int]$MaxRetry = 3,
  [int]$RetryWaitSec = 60
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $RepoPath)) {
  Write-Error "リポジトリが見つかりません: $RepoPath"
  exit 2
}
Set-Location $RepoPath

$logDir  = Join-Path $RepoPath 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir ("watch-{0:yyyyMMdd}.log" -f (Get-Date))

function Write-WatchLog([string]$status, [string]$detail) {
  $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $status, $detail
  $line | Out-File -Append -Encoding utf8 $logFile
  Write-Output $line
}

# 0. Git リポジトリか確認
git rev-parse --is-inside-work-tree *> $null
if ($LASTEXITCODE -ne 0) {
  Write-WatchLog 'NEEDS_APPROVAL' 'Gitリポジトリではありません。対応は人が判断します。'
  exit 2
}

# 1. 最新化を試し、失敗の種類で対応を分ける
$attempt = 0
while ($true) {
  $attempt++
  # git の標準エラーで停止しないよう、この呼び出しだけ EAP を Continue にする
  $out  = & { $ErrorActionPreference = 'Continue'; git pull --no-edit 2>&1 | Out-String }
  $code = $LASTEXITCODE
  if ($code -eq 0) {
    Write-WatchLog 'OK' "git pull 成功（試行 $attempt 回目）"
    exit 0
  }

  $text = $out.Trim()
  $tail = ($text -split "`r?`n" | Select-Object -Last 3) -join ' / '

  # 競合・手元の変更との衝突は、自動では直さない（作業内容を失うおそれがあるため）
  if ($text -match 'CONFLICT|Automatic merge failed|would be overwritten by merge|Your local changes') {
    Write-WatchLog 'NEEDS_APPROVAL' "競合・手元の変更との衝突。自動修理しません: $tail"
    exit 2
  }

  # 通信の問題は時間をおいて再試行する（ネットが戻れば直る想定）
  $isNetwork = $text -match 'Could not resolve host|unable to access|Failed to connect|timed out|Connection (refused|reset)'
  if ($attempt -ge $MaxRetry) {
    Write-WatchLog 'FAILED' "再試行 $MaxRetry 回で失敗（exit $code）。通信=$isNetwork: $tail"
    exit 1
  }
  Write-WatchLog 'RETRY' "pull 失敗（exit $code, 通信=$isNetwork）。$RetryWaitSec 秒後に再試行: $tail"
  Start-Sleep -Seconds $RetryWaitSec
}
