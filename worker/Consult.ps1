# Consult.ps1
# AI同士の相談を、リポジトリ内のファイルで受け渡す（段階1：ローカル）。
# 外部（Codex・ChatGPT）へは送らない。送信は要承認（docs/consultation/CONSULT-DESIGN.md）。
#
# 使い方:
#   新しい相談:  .\worker\Consult.ps1 -Action New -Topic "件名" -Question "質問文" [-Requester "Claude Code"] [-TimeoutMinutes 30]
#                 → 相談IDを表示する
#   返信を書く:  .\worker\Consult.ps1 -Action Reply -Id <相談ID> -From "Codex" -Text "返信内容"
#   状態を見る:  .\worker\Consult.ps1 -Action Status -Id <相談ID>
#                 → waiting（待ち中）/ replied（返信あり）/ timeout（期限切れ：単独で進めてよい）
param(
  [Parameter(Mandatory)][ValidateSet('New', 'Reply', 'Status')][string]$Action,
  [string]$Id,
  [string]$Topic,
  [string]$Question,
  [string]$Requester = 'Claude Code',
  [string]$From,
  [string]$Text,
  [int]$TimeoutMinutes = 30,
  [string]$RepoPath = (Join-Path $PSScriptRoot '..')
)
$ErrorActionPreference = 'Stop'

$openDir = Join-Path (Join-Path $RepoPath 'consult') 'open'
New-Item -ItemType Directory -Force -Path $openDir | Out-Null

function Get-ConsultFile([string]$consultId) {
  if (-not $consultId) { throw '-Id が必要です' }
  $path = Join-Path $openDir "$consultId.md"
  if (-not (Test-Path $path)) { throw "相談が見つかりません: $consultId" }
  return $path
}

switch ($Action) {
  'New' {
    if (-not $Topic -or -not $Question) { throw 'New には -Topic と -Question が必要です' }
    if ($TimeoutMinutes -lt 1) { throw '-TimeoutMinutes は1以上にしてください' }

    $now = Get-Date
    $deadline = $now.AddMinutes($TimeoutMinutes)
    $consultId = '{0:yyyyMMdd-HHmmss}-{1}' -f $now, ([guid]::NewGuid().ToString('N').Substring(0, 6))
    $content = @"
---
id: $consultId
topic: $Topic
requester: $Requester
created: $($now.ToString('yyyy-MM-dd HH:mm:ss'))
deadline: $($deadline.ToString('yyyy-MM-dd HH:mm:ss'))
---

## 質問

$Question

## 返信
"@
    Set-Content -Path (Join-Path $openDir "$consultId.md") -Value $content -Encoding UTF8
    Write-Output $consultId
  }

  'Reply' {
    if (-not $From -or -not $Text) { throw 'Reply には -From と -Text が必要です' }
    $path = Get-ConsultFile $Id
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $path -Value "- [from: $From] ${stamp}: $Text" -Encoding UTF8
    Write-Output 'recorded'
  }

  'Status' {
    $path = Get-ConsultFile $Id
    $content = Get-Content -Raw -Path $path
    if ($content -match '(?m)^- \[from: ') {
      Write-Output 'replied'
      return
    }
    $deadlineText = [regex]::Match($content, '(?m)^deadline: (.+)$').Groups[1].Value.Trim()
    $deadline = [datetime]::ParseExact($deadlineText, 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
    if ((Get-Date) -gt $deadline) {
      Write-Output 'timeout'
    } else {
      Write-Output 'waiting'
    }
  }
}
