# Consult.ps1
# AI同士の相談を、リポジトリ内のファイルで受け渡す（段階1：ローカル）。
# 外部（Codex・ChatGPT）へは送らない。送信は要承認（docs/consultation/CONSULT-DESIGN.md）。
#
# 保存の形（依頼095で変更）:
#   consult/open/<相談ID>/question.json   … 質問・件名・期限（1件）
#   consult/open/<相談ID>/replies/*.json  … 返信（1返信1ファイル）
#   返信の文は「値」としてだけ保存し、文中の書式では判定しない。
#   送信者（from）は Reply の -From の値を、保存時に記録する。
#   旧形式（consult/open/<相談ID>.md）は読まない。移行は行わない（報告書参照）。
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
$dateFormat = 'yyyy-MM-dd HH:mm:ss'

function New-ConsultId([datetime]$now) {
  '{0:yyyyMMdd-HHmmss}-{1}' -f $now, ([guid]::NewGuid().ToString('N').Substring(0, 6))
}

function Save-ConsultJson([string]$path, $data) {
  $data | ConvertTo-Json -Depth 5 | Set-Content -Path $path -Encoding UTF8
}

function Read-ConsultJson([string]$path) {
  Get-Content -Raw -Encoding UTF8 -Path $path | ConvertFrom-Json
}

function Get-ConsultDir([string]$consultId) {
  if (-not $consultId) { throw '-Id が必要です' }
  if ($consultId -notmatch '^\d{8}-\d{6}-[0-9a-f]{6}$') { throw "相談IDの形式が正しくありません: $consultId" }
  $dir = Join-Path $openDir $consultId
  if (-not (Test-Path (Join-Path $dir 'question.json'))) {
    if (Test-Path (Join-Path $openDir "$consultId.md")) {
      throw "旧形式の相談です（この版では読めません）: $consultId"
    }
    throw "相談が見つかりません: $consultId"
  }
  return $dir
}

switch ($Action) {
  'New' {
    if (-not $Topic -or -not $Question) { throw 'New には -Topic と -Question が必要です' }
    if ($TimeoutMinutes -lt 1) { throw '-TimeoutMinutes は1以上にしてください' }

    $now = Get-Date
    $deadline = $now.AddMinutes($TimeoutMinutes)
    $consultId = New-ConsultId $now
    $dir = Join-Path $openDir $consultId
    New-Item -ItemType Directory -Force -Path (Join-Path $dir 'replies') | Out-Null

    Save-ConsultJson (Join-Path $dir 'question.json') ([ordered]@{
      id        = $consultId
      topic     = $Topic
      requester = $Requester
      created   = $now.ToString($dateFormat)
      deadline  = $deadline.ToString($dateFormat)
      question  = $Question
    })
    Write-Output $consultId
  }

  'Reply' {
    if (-not $From -or -not $Text) { throw 'Reply には -From と -Text が必要です' }
    $dir = Get-ConsultDir $Id
    $now = Get-Date
    $replyId = New-ConsultId $now
    Save-ConsultJson (Join-Path $dir "replies\$replyId.json") ([ordered]@{
      consult = $Id
      from    = $From
      replied = $now.ToString($dateFormat)
      text    = $Text
    })
    Write-Output 'recorded'
  }

  'Status' {
    $dir = Get-ConsultDir $Id
    $replyFiles = @(Get-ChildItem -Path (Join-Path $dir 'replies') -Filter '*.json' -File -ErrorAction SilentlyContinue)
    if ($replyFiles.Count -gt 0) {
      Write-Output 'replied'
      return
    }
    # 変数名は $questionData（$Question は param と同じ変数になるため使わない）
    $questionData = Read-ConsultJson (Join-Path $dir 'question.json')
    $deadline = [datetime]::ParseExact([string]$questionData.deadline, $dateFormat, [Globalization.CultureInfo]::InvariantCulture)
    if ((Get-Date) -gt $deadline) {
      Write-Output 'timeout'
    } else {
      Write-Output 'waiting'
    }
  }
}
