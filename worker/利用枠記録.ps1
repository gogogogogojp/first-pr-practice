# 利用枠記録.ps1
# Claude Code の実行時出力（stream-json）から利用率（5時間枠・7日枠）を取り出し、最新値を reports/利用枠_最新.md に書く。
# 依頼092。読むのは利用率とリセット時刻だけ。認証情報ファイルには触れない。
# 生の出力は %LOCALAPPDATA%\claude-worker\stream-json に保存する（リポジトリの外。会話内容を含むため公開リポジトリに入れない）。
# 保存の上限：新しい順に20件まで。7日より古いものは削除（この関数が作った生成物だけが対象）。
# 使い方：. "<リポジトリ>\worker\利用枠記録.ps1" の後に Save-ClaudeUsage を呼ぶ。Windows PowerShell 5.1 でも動く書き方にしている。

$script:UsageRawDir    = Join-Path $env:LOCALAPPDATA 'claude-worker\stream-json'
$script:UsageKeepCount = 20
$script:UsageKeepDays  = 7
$script:UsageTz        = [TimeZoneInfo]::FindSystemTimeZoneById('Tokyo Standard Time')
$script:UsageUtf8      = New-Object System.Text.UTF8Encoding($false)

# UNIX時刻（秒）を「11月27日金曜日13時まで」の形にする（報告の形：依頼093）。分が0以外なら「13時05分まで」。
function Format-UsageReset {
  param([Parameter(Mandatory)][long]$EpochSeconds)
  $jst = [TimeZoneInfo]::ConvertTime([DateTimeOffset]::FromUnixTimeSeconds($EpochSeconds), $script:UsageTz)
  $week = @('日', '月', '火', '水', '木', '金', '土')[[int]$jst.DayOfWeek]
  if ($jst.Minute -eq 0) {
    $time = '{0}時' -f $jst.Hour
  } else {
    $time = '{0}時{1:00}分' -f $jst.Hour, $jst.Minute
  }
  return ('{0}月{1}日{2}曜日{3}まで' -f $jst.Month, $jst.Day, $week, $time)
}

# stream-json の行から、最後に出た利用率（unifiedWindows）を取り出す。見つからなければ $null。
# 認証情報は含まれない行（rate_limit_event 以外）は読み飛ばす。
function Get-ClaudeUsageWindows {
  param([string[]]$Lines = @())
  $latest = $null
  foreach ($line in $Lines) {
    if ($line -notlike '*rate_limit_event*') { continue }
    try {
      $obj = $line | ConvertFrom-Json
    } catch {
      continue
    }
    $info = $obj.rate_limit_info
    if ($null -eq $info -or $null -eq $info.unifiedWindows) { continue }
    $latest = $info.unifiedWindows
  }
  return $latest
}

# 1枠ぶんの行を作る。例：「- 5時間枠：**7%**（11月25日水曜日16時10分まで）」
function Format-UsageLine {
  param([string]$Label, $Window)
  if ($null -eq $Window -or $null -eq $Window.utilization) {
    return ('- {0}：不明（記録なし）' -f $Label)
  }
  $percent = [math]::Round([double]$Window.utilization * 100, 1)
  if ($Window.resetsAt) {
    $reset = Format-UsageReset -EpochSeconds ([long]$Window.resetsAt)
  } else {
    $reset = '不明'
  }
  return ('- {0}：**{1}%**（{2}）' -f $Label, $percent, $reset)
}

# 古い生の出力を削除する（新しい順に上限件数まで残し、保存期間を過ぎたものは消す）。
function Remove-OldClaudeUsageRaw {
  param([string]$RawDir = $script:UsageRawDir)
  if (-not (Test-Path -LiteralPath $RawDir)) { return }
  $cutoff = (Get-Date).AddDays(-$script:UsageKeepDays)
  $files = @(Get-ChildItem -LiteralPath $RawDir -Filter '*.jsonl' -File | Sort-Object LastWriteTime -Descending)
  for ($i = 0; $i -lt $files.Count; $i++) {
    if ($i -ge $script:UsageKeepCount -or $files[$i].LastWriteTime -lt $cutoff) {
      Remove-Item -LiteralPath $files[$i].FullName -Force
    }
  }
}

# 本体：生の出力を保存 → 古いものを整理 → 利用率を読む → reports/利用枠_最新.md を書き換える。
# 戻り値は記録内容の一行要約（ログ用）。失敗しても例外を投げず、理由を文字列で返す（ワーカーを止めない）。
function Save-ClaudeUsage {
  param(
    [object[]]$Lines = @(),
    [Parameter(Mandatory)][string]$RepoPath,
    [Parameter(Mandatory)][string]$Source,
    [string]$RawDir = $script:UsageRawDir
  )
  $texts = @($Lines | ForEach-Object { [string]$_ })
  try {
    New-Item -ItemType Directory -Force -Path $RawDir | Out-Null
    $rawPath = Join-Path $RawDir ('{0:yyyyMMdd-HHmmss}-{1}.jsonl' -f (Get-Date), $Source)
    [IO.File]::WriteAllLines($rawPath, [string[]]$texts, $script:UsageUtf8)
    Remove-OldClaudeUsageRaw -RawDir $RawDir
  } catch {
    return ('生の出力の保存で失敗: {0}' -f $_.Exception.Message)
  }

  $windows = Get-ClaudeUsageWindows -Lines $texts
  if ($null -eq $windows) {
    return '利用率の記録なし（rate_limit_event が出力に無い）'
  }

  $nowJst = [TimeZoneInfo]::ConvertTime([DateTimeOffset]::UtcNow, $script:UsageTz).ToString('yyyy-MM-dd HH:mm')
  $body = @(
    '# 利用枠（最新）',
    '',
    ('取得：{0} JST（{1} の実行時）' -f $nowJst, $Source),
    '取得元：Claude Code の実行時出力（rate_limit_event）。実行した時点の値で、ライブ値ではない。',
    '',
    (Format-UsageLine -Label '5時間枠' -Window $windows.five_hour),
    (Format-UsageLine -Label '7日枠' -Window $windows.seven_day),
    ''
  )
  $reportPath = Join-Path $RepoPath 'reports\利用枠_最新.md'
  try {
    [IO.File]::WriteAllText($reportPath, ($body -join [Environment]::NewLine), $script:UsageUtf8)
  } catch {
    return ('最新値の書き出しに失敗: {0}' -f $_.Exception.Message)
  }
  return ('利用率を記録しました（{0} JST・reports/利用枠_最新.md）' -f $nowJst)
}
