# Register-ClaudeWorker.ps1
# ごとうの PC で1回だけ実行する想定（管理者権限は不要）。
# 設計書: ~/workspace/claude-worker/DESIGN.md
# 前提: リポジトリが "$env:USERPROFILE\repos\first-pr-practice" に clone 済みで push できること。
$script = "$env:USERPROFILE\repos\first-pr-practice\worker\Invoke-ClaudeWorker.ps1"
if (-not (Test-Path $script)) {
  Write-Error "ワーカーが見つかりません: $script（先にリポジトリを pull してください）"
  exit 1
}
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
  -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$script`""
$triggers = @(
  (New-ScheduledTaskTrigger -AtLogOn),
  (New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 30))
)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -WakeToRun
Register-ScheduledTask -TaskName "ClaudeWorker" `
  -Action $action -Trigger $triggers -Settings $settings
Write-Output "登録完了: ClaudeWorker（ログオン時＋30分間隔）"
Write-Output "次に手動テスト: powershell -NoProfile -ExecutionPolicy Bypass -File `"$script`""
