# Invoke-ClaudeWorker.ps1
# inbox/ の未処理依頼を Claude Code ヘッドレスで処理し、結果を push する
# 設計書: ~/workspace/claude-worker/DESIGN.md（方式1：タスクスケジューラ）
# 注意: first-pr-practice は public リポジトリのため、業務データ・顧客名を含む依頼は流さないこと。
param(
  [string]$RepoPath = "$env:USERPROFILE\repos\first-pr-practice"
)
$ErrorActionPreference = 'Stop'
Set-Location $RepoPath

$logDir = Join-Path $RepoPath 'logs'
$processedDir = Join-Path $RepoPath 'inbox\processed'
New-Item -ItemType Directory -Force -Path $logDir, $processedDir | Out-Null
$logFile = Join-Path $logDir ("worker-{0:yyyyMMdd-HHmm}.log" -f (Get-Date))
"=== worker start $(Get-Date -Format 'yyyy-MM-dd HH:mm') ===" | Out-File -Append $logFile

# 1. 最新化
git pull --ff-only
if ($LASTEXITCODE -ne 0) {
  "pull failed (exit $LASTEXITCODE)" | Out-File -Append $logFile
  exit 1
}

# 2. 未処理依頼の確認（なければ終了）
$requests = Get-ChildItem -Path .\inbox -Filter *.md |
  Where-Object { $_.Name -notlike 'README*' }
if (-not $requests) {
  "no requests" | Out-File -Append $logFile
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
  claude -p $prompt --allowedTools "Read,Edit,Write,Bash(git:*)"
  if ($LASTEXITCODE -eq 0) {
    Move-Item $req.FullName $processedDir
    "processed: $($req.Name)" | Out-File -Append $logFile
  } else {
    "FAILED (left in inbox): $($req.Name) exit $LASTEXITCODE" | Out-File -Append $logFile
  }
}

# 4. 反映（変更がある場合のみ commit）
git add -A
if (git diff --cached --quiet) {
  "no changes to commit" | Out-File -Append $logFile
  exit 0
}
git commit -m "worker: process inbox requests"
git push
"=== worker done $(Get-Date -Format 'yyyy-MM-dd HH:mm') ===" | Out-File -Append $logFile
