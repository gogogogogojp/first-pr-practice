# Register-ClaudeWorker2.ps1
# ハチ（見張り）用の Claude ワーカー（2人目）をタスクスケジューラに登録する。依頼084で作成。
# 1回だけ実行する想定（管理者権限は不要）。同じ名前で登録済みなら上書きする。
# 登録内容：ログオン時＋10分間隔。開始は毎時09分・39分（1人目 ClaudeWorker と当たらないようずらす）。
# 前提: 作業コピー "$env:USERPROFILE\repos\first-pr-practice-claude-worker2" が clone 済みであること。
$script = "$env:USERPROFILE\repos\first-pr-practice-claude-worker2\worker\Invoke-ClaudeWorker2.ps1"
if (-not (Test-Path -LiteralPath $script)) {
  Write-Error "ワーカーが見つかりません: $script（先に作業コピーを clone してください）"
  exit 1
}

# 最初の起動時刻：次の 09分 または 39分
$now = Get-Date
$minute = if ($now.Minute -lt 9) { 9 } elseif ($now.Minute -lt 39) { 39 } else { 69 }
$firstRun = $now.Date.AddHours($now.Hour).AddMinutes($minute)

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$script`""
$triggers = @(
  (New-ScheduledTaskTrigger -AtLogOn),
  (New-ScheduledTaskTrigger -Once -At $firstRun -RepetitionInterval (New-TimeSpan -Minutes 10))
)
# 同時に2つ動かさない（IgnoreNew）。1時間を超えたら打ち切る。
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
  -ExecutionTimeLimit (New-TimeSpan -Hours 1)
Register-ScheduledTask -TaskName 'ClaudeWorker2' -Description 'ハチ（見張り）用Claudeワーカー（2人目）' `
  -Action $action -Trigger $triggers -Settings $settings -Force | Out-Null

Write-Output "登録完了: ClaudeWorker2（ログオン時＋10分間隔、開始 $($firstRun.ToString('HH:mm'))）"
Write-Output "次に手動テスト: powershell -NoProfile -ExecutionPolicy Bypass -File `"$script`""
