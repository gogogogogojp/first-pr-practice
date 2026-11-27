# Invoke-ClaudeWorker.ps1
# inbox/ の未処理依頼を Claude Code ヘッドレスで処理し、結果を push する
# 設計書: ~/workspace/claude-worker/DESIGN.md（方式1：タスクスケジューラ）
# 注意: first-pr-practice は public リポジトリのため、業務データ・顧客名を含む依頼は流さないこと。
param(
  [string]$RepoPath = "$env:USERPROFILE\repos\first-pr-practice",
  # 既定はSonnet（依頼118）。依頼ファイルに「モデル：Opus」と書かれた回だけ、その回だけOpusにする。
  [string]$Model = 'claude-sonnet-5-5'
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
# オフラインが3回続いたら reports/オフライン警告.md に1行書く（依頼123・提案1）。警告の失敗で本処理は止めない。
. (Join-Path $PSScriptRoot 'オフライン警告.ps1')
$online = Test-Online
try {
  $offlineCount = Update-OfflineCount -RepoPath $RepoPath -Online $online
} catch {
  "オフライン回数の記録に失敗: $($_.Exception.Message)" | Out-File -Append $logFile
}
if (-not $online) {
  "オフラインのためスキップ（連続 $offlineCount 回）" | Out-File -Append $logFile
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
  # 依頼の「モデル：」「思考の深さ：」行で、この回だけ変える（依頼118）。使えない指定は既定に戻す。
  . (Join-Path $PSScriptRoot 'モデル割り当て.ps1')
  $requestText = Get-Content -LiteralPath $req.FullName -Raw -Encoding UTF8
  $override = Get-RequestModelOverride -Text $requestText
  $modelChoice = Resolve-RequestChoice -Requested $override.Model -Allowed $ClaudeModelMap -Default $Model
  $effortChoice = Resolve-RequestChoice -Requested $override.Effort -Allowed $EffortMap -Default ''
  $modelArgs = @('--model', $modelChoice.Value)
  if ($effortChoice.Value) { $modelArgs += @('--effort', $effortChoice.Value) }
  $effortLabel = if ($effortChoice.Value) { "$($effortChoice.Value)（$($effortChoice.Source)）" } else { '既定' }
  "モデル: $($modelChoice.Value)（$($modelChoice.Source)）／思考の深さ: $effortLabel $($modelChoice.Note) $($effortChoice.Note)" | Out-File -Append $logFile
  # 実行時出力（stream-json）から利用率を取り出し、reports/利用枠_最新.md に書く（依頼092）
  . (Join-Path $RepoPath 'worker\利用枠記録.ps1')
  $claudeOutput = & claude -p $prompt --allowedTools "Read,Edit,Write,Bash" --output-format stream-json --verbose @modelArgs
  $claudeExit = $LASTEXITCODE
  # 切り替え前後の比較用に、利用枠の行にもモデル名を残す（依頼118）
  "利用枠: $(Save-ClaudeUsage -Lines $claudeOutput -RepoPath $RepoPath -Source 'ClaudeWorker')（モデル: $($modelChoice.Value)）" | Out-File -Append $logFile
  if ($claudeExit -eq 0) {
    Move-Item $req.FullName $processedDir
    "processed: $($req.Name)" | Out-File -Append $logFile
  } else {
    "FAILED (left in inbox): $($req.Name) exit $claudeExit" | Out-File -Append $logFile
  }
}

# 4. 反映（変更がある場合のみ commit）
Save-Records "worker: process inbox requests"
"=== worker done $(Get-Date -Format 'yyyy-MM-dd HH:mm') ===" | Out-File -Append $logFile
