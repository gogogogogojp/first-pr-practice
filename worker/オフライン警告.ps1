# オフライン警告.ps1（依頼123・提案1）
# オフラインでスキップした回を数え、3回続いたら reports/オフライン警告.md に1行の警告を書く。
# 接続が戻った回で数を0に戻し、3回以上止まっていた場合は「復旧」の1行も書く。
# 記録だけで、外部には何も送らない。

function Update-OfflineCount {
  param(
    [Parameter(Mandatory)][string]$RepoPath,
    [Parameter(Mandatory)][bool]$Online,
    [int]$Threshold = 3,
    [datetime]$Now = (Get-Date),
    [string]$Source = 'ClaudeWorker'
  )
  $countFile = Join-Path $RepoPath 'logs\オフライン連続回数.txt'
  $warnFile = Join-Path $RepoPath 'reports\オフライン警告.md'
  $count = 0
  if (Test-Path -LiteralPath $countFile) {
    [int]::TryParse((Get-Content -LiteralPath $countFile -Raw -Encoding UTF8).Trim(), [ref]$count) | Out-Null
  }
  $stamp = $Now.ToString('yyyy-MM-dd HH:mm')
  $line = $null
  if ($Online) {
    if ($count -ge $Threshold) { $line = "- $stamp 復旧：$Source は接続が戻りました（オフラインでスキップ：連続 $count 回）" }
    $count = 0
  } else {
    $count++
    if ($count -eq $Threshold) { $line = "- $stamp 警告：$Source がオフラインで $count 回続けてスキップしています。ネット接続を確認してください" }
  }
  New-Item -ItemType Directory -Force -Path (Split-Path $countFile), (Split-Path $warnFile) | Out-Null
  Set-Content -LiteralPath $countFile -Value $count -Encoding UTF8
  if ($line) { Add-Content -LiteralPath $warnFile -Value $line -Encoding UTF8 }
  return $count
}
