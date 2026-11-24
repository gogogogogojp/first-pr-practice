# Invoke-ClaudeWorker.ps1
# inbox/ の未処理依頼を Claude Code ヘッドレスで処理し、結果を push する
# 設計書: ~/workspace/claude-worker/DESIGN.md（方式1：タスクスケジューラ）
# 注意: first-pr-practice は public リポジトリのため、業務データ・顧客名を含む依頼は流さないこと。
param(
  [string]$RepoPath = "$env:USERPROFILE\repos\first-pr-practice",
  # 空なら既定のモデルを使う。例: sonnet（依頼039の計画書の最終化で使う）
  [string]$Model = ''
)
$ErrorActionPreference = 'Stop'
Set-Location $RepoPath

$logDir = Join-Path $RepoPath 'logs'
$processedDir = Join-Path $RepoPath 'inbox\processed'
New-Item -ItemType Directory -Force -Path $logDir, $processedDir | Out-Null
$logFile = Join-Path $logDir ("worker-{0:yyyyMMdd-HHmm}.log" -f (Get-Date))
"=== worker start $(Get-Date -Format 'yyyy-MM-dd HH:mm') ===" | Out-File -Append $logFile

# 0. ネット接続の判定（未接続なら静かに終了。失敗扱いにしない）
#    github.com の443番ポートへ5秒以内に接続できるかを見る（データは送らない）。
function Test-Online([string]$HostName = 'github.com', [int]$Port = 443, [int]$TimeoutMs = 5000) {
  $client = New-Object System.Net.Sockets.TcpClient
  try {
    $task = $client.ConnectAsync($HostName, $Port)
    return ($task.Wait($TimeoutMs) -and $client.Connected)
  } catch {
    return $false
  } finally {
    $client.Dispose()
  }
}
if (-not (Test-Online)) {
  "オフラインのためスキップ" | Out-File -Append $logFile
  exit 0
}

# 記録の保存：未追跡の報告書・処理済み・ログも含めて commit & push する。
# 依頼が無い回や途中で終わった回でも必ず通るよう、exit の前に呼ぶ（依頼039の記録漏れ対策）。
function Save-Records([string]$message) {
  git add -A
  git diff --cached --quiet
  if ($LASTEXITCODE -eq 0) {
    "no changes to commit" | Out-File -Append $logFile
    return
  }
  git commit -m $message
  if ($LASTEXITCODE -ne 0) {
    "commit failed (exit $LASTEXITCODE)" | Out-File -Append $logFile
    return
  }
  git push
  if ($LASTEXITCODE -ne 0) {
    "push failed (exit $LASTEXITCODE). local commit kept; next run pushes it" | Out-File -Append $logFile
  }
}

# 1. 最新化
git pull --no-edit
if ($LASTEXITCODE -ne 0) {
  "pull failed (exit $LASTEXITCODE)" | Out-File -Append $logFile
  Save-Records "worker: save leftover records"
  exit 1
}

# 2. 未処理依頼の確認（なければ終了。ただし記録は保存してから終わる）
$requests = Get-ChildItem -Path .\inbox -Filter *.md |
  Where-Object { $_.Name -notlike 'README*' }
if (-not $requests) {
  "no requests" | Out-File -Append $logFile
  Save-Records "worker: save leftover records"
  exit 0
}

# 3. 依頼ごとに Claude Code をヘッドレス実行
#    失敗した依頼は processed に移さず inbox に残す（設計書の安全ルール通り）。
foreach ($req in $requests) {
  $prompt = @"
inbox/$($req.Name) の依頼を処理してください。
- 作業範囲は、依頼ファイルに範囲の指定がある場合はその指定を優先してください。指定がない場合の既定はこのリポジトリ内のみです
- 結果は依頼ファイルの「## 結果」欄に追記してください
- 金銭・対人関係・外部への送信を伴う内容は実行せず、結果欄に「要承認」と書いてください
"@
  $modelArgs = @()
  if ($Model) { $modelArgs = @('--model', $Model) }
  claude -p $prompt --allowedTools "Read,Edit,Write,Bash" @modelArgs
  if ($LASTEXITCODE -eq 0) {
    Move-Item $req.FullName $processedDir
    "processed: $($req.Name)" | Out-File -Append $logFile
  } else {
    "FAILED (left in inbox): $($req.Name) exit $LASTEXITCODE" | Out-File -Append $logFile
  }
}

# 4. 反映（変更がある場合のみ commit）
Save-Records "worker: process inbox requests"
"=== worker done $(Get-Date -Format 'yyyy-MM-dd HH:mm') ===" | Out-File -Append $logFile
