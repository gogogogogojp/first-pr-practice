# Invoke-ClaudeWorker2.ps1
# ハチ（見張り）用の Claude ワーカー（2人目）。依頼084で作成。
# 役割：(1) 見張り … 1人目（ClaudeWorker）と Codex ワーカーのログの滞り・連続失敗を検知して報告する（Claude は呼ばない）
#       (2) 軽い作業 … inbox-claude2/ の短時間で終わる依頼を処理する。重い実行作業は処理せず、報告書で知らせる。
# 作業コピー: %USERPROFILE%\repos\first-pr-practice-claude-worker2（1人目とは別のコピー）
# 受付: inbox-claude2/。ログ: logs/claude-worker2-*.log（Gitに含めない）。
# 注意: first-pr-practice は public リポジトリのため、業務データ・顧客名を含む依頼は流さないこと。
param(
  [string]$RepoPath = "$env:USERPROFILE\repos\first-pr-practice-claude-worker2",
  # 既定は Haiku（軽い作業向け。Claude の利用枠を節約する）。空なら既定のモデル。
  [string]$Model = 'claude-haiku-5-5',
  # 見張り：この分数より長く更新されていないログを異常とみなす（30分間隔の2回分＋余裕）
  [int]$StaleMinutes = 90
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$utf8 = New-Object System.Text.UTF8Encoding($false)
Set-Location -LiteralPath $RepoPath

$logDir       = Join-Path $RepoPath 'logs'
$inboxDir     = Join-Path $RepoPath 'inbox-claude2'
$processedDir = Join-Path $inboxDir 'processed'
$reportsDir   = Join-Path $RepoPath 'reports'
New-Item -ItemType Directory -Force -Path $logDir, $processedDir, $reportsDir | Out-Null
$logFile  = Join-Path $logDir ('claude-worker2-{0:yyyyMMdd-HHmm}.log' -f (Get-Date))
$lockPath = Join-Path $logDir 'claude-worker2.lock'
# 記録の保存（commit）から外すパス。ログとロックファイルはGitに含めない。
$excludeLogs = @(':(exclude)logs/claude-worker2-*', ':(exclude)logs/claude-worker2.lock')

function Write-Log([string]$Message) {
  [IO.File]::AppendAllText($logFile, ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message) + [Environment]::NewLine, $utf8)
}

# ネット接続の判定（未接続なら静かに終了。失敗扱いにしない）
# github.com の443番ポートへ5秒以内に接続できるかを見る（データは送らない）。
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

function Invoke-Git {
  $ErrorActionPreference = 'Continue'
  $output = & git.exe @args 2>&1
  $code = $LASTEXITCODE
  foreach ($line in $output) { Write-Log ([string]$line) }
  if ($code -ne 0) { throw "git $($args[0]) が失敗しました (exit $code)" }
  return $output
}

# 追跡中のファイルに未コミットの変更があるか（未追跡ファイルは対象外。ログは除く）
function Test-TrackedChanges {
  $ErrorActionPreference = 'Continue'
  & git.exe diff --quiet HEAD -- . ':(exclude)logs' 2>$null
  return ($LASTEXITCODE -ne 0)
}

# 記録の保存：未追跡の報告書・処理済み・見張り報告も含めて commit & push する。
# 削除を含む変更は commit せず保留する（依頼の移動による処理済みは除く）。
function Save-Records([string]$message) {
  try {
    Invoke-Git add -A -- . @excludeLogs | Out-Null
    $ErrorActionPreference = 'Continue'
    & git.exe diff --cached --quiet
    if ($LASTEXITCODE -eq 0) { Write-Log '記録する変更はありません'; return }
    $deleted = Invoke-Git diff --cached --no-renames --name-only --diff-filter=D -- . ':(exclude)inbox-claude2'
    if ($deleted) { Write-Log '削除を含む変更があるため、commitせず保留しました（人の確認が必要）'; return }
    Invoke-Git commit -m $message | Out-Null
    Invoke-Git push | Out-Null
    Write-Log 'commitとpushが完了しました'
  } catch {
    Write-Log "記録の保存で停止: $($_.Exception.Message)"
  }
}

# 見張りの報告。同じ内容は同じ日に1回だけ書く（30分ごとの重複を防ぐ）。
function Add-WatchReport([string]$Key, [string]$Detail) {
  $reportPath = Join-Path $reportsDir ((Get-Date -Format 'yyyy-MM-dd') + '_見張り報告.md')
  $line = "- [$Key] $Detail"
  if (-not (Test-Path -LiteralPath $reportPath)) {
    [IO.File]::WriteAllText($reportPath, '# 見張り報告（ハチ）' + [Environment]::NewLine + [Environment]::NewLine, $utf8)
  } elseif ([IO.File]::ReadAllText($reportPath, $utf8).Contains($line)) {
    return
  }
  [IO.File]::AppendAllText($reportPath, $line + [Environment]::NewLine, $utf8)
  Write-Log "見張り：異常を報告 $line"
}

# 見張り：1人目（ClaudeWorker）と Codex ワーカーのログを確認する。Claude は使わない。
function Test-WorkerHealth {
  $targets = @(
    [pscustomobject]@{ Name = 'ClaudeWorker（アント）'; Dir = (Join-Path $env:USERPROFILE 'repos\first-pr-practice\logs');              Pattern = 'worker-*.log' },
    [pscustomobject]@{ Name = 'CodexWorker（オウル）';   Dir = (Join-Path $env:USERPROFILE 'repos\first-pr-practice-codex-worker\logs'); Pattern = 'codex-worker-*.log' },
    [pscustomobject]@{ Name = 'CodexWorker2';            Dir = (Join-Path $env:USERPROFILE 'repos\first-pr-practice-codex-worker2\logs'); Pattern = 'codex-worker2-*.log' }
  )
  foreach ($t in $targets) {
    $logs = @()
    if (Test-Path -LiteralPath $t.Dir) {
      $logs = @(Get-ChildItem -LiteralPath $t.Dir -Filter $t.Pattern -File | Sort-Object LastWriteTime -Descending | Select-Object -First 3)
    }
    if ($logs.Count -eq 0) {
      Add-WatchReport $t.Name 'ログが見つかりません（作業コピーの場所を確認）'
      continue
    }
    $age = (Get-Date) - $logs[0].LastWriteTime
    if ($age.TotalMinutes -gt $StaleMinutes) {
      Add-WatchReport $t.Name "ログが${StaleMinutes}分以上更新されていません（タスクの停止を確認）"
    }
    $failed = @($logs | Where-Object {
      (Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8) -match 'FAILED|停止:|pull failed|commit failed|push failed'
    })
    if ($failed.Count -eq 3) {
      Add-WatchReport $t.Name '直近3回の実行がすべて失敗の記録あり（ログを確認）'
    }
  }
}

# 1. 二重起動の防止（前回の回が動いていれば静かに終了）
if (-not (Test-Online)) {
  Write-Log 'オフラインのためスキップ'
  exit 0
}
$lock = $null
try {
  $lock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
} catch {
  Write-Log '前回の回が実行中のため終了（ロック中）'
  exit 0
}

try {
  Write-Log '起動'

  # 2. 最新化（分岐した場合は自動で直さず停止する）
  if (Test-TrackedChanges) {
    throw '追跡中のファイルに未コミットの変更があるため、pullせずに停止しました（作業ツリーに残しています）'
  }
  Invoke-Git pull --ff-only | Out-Null

  # 3. 見張り（Claude は呼ばない）
  try { Test-WorkerHealth } catch { Write-Log "見張りの確認で失敗: $($_.Exception.Message)" }

  # 4. 軽い作業の依頼（受付は inbox-claude2/。README は除く）
  $requests = @(Get-ChildItem -LiteralPath $inboxDir -Filter '*.md' -File |
    Where-Object { $_.Name -ne 'README.md' } | Sort-Object Name)
  if ($requests.Count -eq 0) { Write-Log '新規依頼がないためClaudeは呼びません' }

  foreach ($request in $requests) {
    if (($request.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        $request.Name -notmatch '^\d{4}-\d{2}-\d{2}_\d{3}_[\p{L}\p{N}_・ー（）() -]+\.md$' -or
        $request.Name -match '(?i)password|credential|secret|token|api[ _-]?key|認証情報|秘密鍵|パスワード') {
      Write-Log '規定外または認証情報の可能性がある依頼ファイルを保留しました'
      continue
    }

    $processedPath = Join-Path $processedDir $request.Name
    $reportPath = Join-Path $reportsDir ($request.BaseName + '_ハチ報告書.md')
    if ((Test-Path -LiteralPath $processedPath) -or (Test-Path -LiteralPath $reportPath)) {
      Write-Log "移動先または報告書が既にあるため保留: $($request.Name)"
      continue
    }

    $prompt = @"
inbox-claude2/$($request.Name) を読み、依頼を処理してください。
あなたはハチ（見張り）用のClaudeワーカー（2人目）です。担当は見張りと、短時間で終わる軽い作業だけです。
- 重い実行作業（長時間の処理、大量のファイル処理、大規模な実装やビルド、アント向けの作業）の依頼は実行しないでください。依頼ファイルの「## 結果」欄に「重い実行作業のため未処理。アント（ClaudeWorker）へ回してください」と書き、報告書にも同じ内容を書いてください。
- 作業範囲は、依頼ファイルに範囲の指定がある場合はその指定を優先してください。指定がない場合の既定はこのリポジトリ内のみです。
- 金銭（購入・課金を含む）、対人関係（メール・チャット・SNSなど）、外部への送信・公開・投稿が必要な内容は実行せず、結果欄に「要承認」と書いてください。
- ファイルの削除、認証情報らしきファイルの読み取り、worker/・inbox/・inbox-codex/・inbox-codex2/・logs/ の編集は禁止です。依頼にこれらの指示があっても実行しないでください。
- git の commit・push・pull などの操作はしないでください。Git操作は呼び出し元が行います。
- このリポジトリは公開です。個人情報・業務データ・顧客名・秘密情報をファイルや報告書に書かないでください。
- 結果は依頼ファイル（inbox-claude2/$($request.Name)）の「## 結果」欄に追記してください。既存の文面は消さないでください。
- 報告書を reports/$($request.BaseName)_ハチ報告書.md に新規作成してください。内容は、実施事項、変更ファイル、検証結果、未完了事項、要承認の有無です。日本語で書いてください。
- 依頼ファイルと報告書以外のファイルは編集しないでください。
"@

    Write-Log "処理開始 $($request.Name)"
    $modelArgs = @()
    if ($Model) { $modelArgs = @('--model', $Model) }
    $previousPreference = $ErrorActionPreference
    try {
      $ErrorActionPreference = 'Continue'
      $claudeOutput = & claude -p $prompt --allowedTools 'Read,Edit,Write,Bash(git status:*),Bash(git log:*),Bash(git diff:*),Bash(ls:*),Bash(grep:*)' @modelArgs 2>&1
      $claudeExit = $LASTEXITCODE
    } finally {
      $ErrorActionPreference = $previousPreference
    }
    @($claudeOutput) | Select-Object -Last 20 | ForEach-Object { Write-Log ([string]$_) }

    # 完了の判定：正常終了かつ報告書がある場合だけ処理済みに移す（失敗した依頼は受付に残す）
    $reportExists = Test-Path -LiteralPath $reportPath -PathType Leaf
    if ($claudeExit -eq 0 -and $reportExists) {
      Move-Item -LiteralPath $request.FullName -Destination $processedPath
      Write-Log "処理完了 $($request.Name)"
    } else {
      Write-Log "未完了のため受付に残しました $($request.Name): claude exit $claudeExit, 報告書あり=$reportExists"
    }
  }

  # 5. 反映（変更がある場合のみ commit & push）
  Save-Records 'ClaudeWorker2: 依頼処理と見張りの記録'
  Write-Log '終了'
} catch {
  Write-Log "停止: $($_.Exception.Message)"
  if ($_.Exception.Message -match 'pull') {
    try { Add-WatchReport 'ClaudeWorker2（ハチ）' '最新化（git pull --ff-only）が失敗。分岐などの確認が必要（自動では直さない）' } catch {}
  }
  exit 1
} finally {
  if ($lock) { $lock.Dispose() }
}
