param(
    [string]$RepoPath = "$env:USERPROFILE\repos\first-pr-practice-codex-worker"
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Set-Location -LiteralPath $RepoPath
$logDir = Join-Path $RepoPath 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir ('codex-worker-{0:yyyyMMdd-HHmm}.log' -f (Get-Date))
$trackedPaths = @('.', ':(exclude)logs')
$utf8 = New-Object System.Text.UTF8Encoding($false)
$lockPath = Join-Path $logDir 'codex-worker.lock'
. (Join-Path $PSScriptRoot 'CodexWorkerGuard.ps1')

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
if (-not (Test-Online)) {
  Write-Log 'オフラインのためスキップ'
  exit 0
}

function Invoke-Git {
    $ErrorActionPreference = 'Continue'
    $output = & git.exe @args 2>&1
    $code = $LASTEXITCODE
    foreach ($line in $output) { Write-Log ([string]$line) }
    if ($code -ne 0) { throw "git $($args[0]) が失敗しました (exit $code)" }
    return $output
}

$maxConsecutiveFailures = 3
$failPath = Join-Path $logDir 'codex-worker-fail.json'

# 依頼ごとの連続失敗の回数を logs に保存する（logs は Git の対象外）。
function Read-FailMap {
    $map = [ordered]@{}
    if (Test-Path -LiteralPath $failPath) {
        try {
            $old = Get-Content -LiteralPath $failPath -Encoding UTF8 -Raw | ConvertFrom-Json
            foreach ($p in $old.PSObject.Properties) { $map[$p.Name] = [int]$p.Value }
        } catch {
            Write-Log '連続失敗の記録を読めなかったため、0回として扱います'
        }
    }
    return ,$map
}

function Get-FailCount([string]$Name) {
    $map = Read-FailMap
    if ($map.Contains($Name)) { return [int]$map[$Name] }
    return 0
}

function Set-FailCount([string]$Name, [int]$Count) {
    $map = Read-FailMap
    if ($Count -le 0) { [void]$map.Remove($Name) } else { $map[$Name] = $Count }
    [IO.File]::WriteAllText($failPath, ($map | ConvertTo-Json), $utf8)
}

# 保留報告書を作り、報告書だけを commit して push する（依頼はinboxに残す）。
function Save-HoldReport([IO.FileInfo]$Request, [string]$Reason) {
    $reportsDir = Join-Path $RepoPath 'reports'
    New-Item -ItemType Directory -Force -Path $reportsDir | Out-Null
    $holdName = $Request.BaseName + '_Codex保留報告書.md'
    $nl = [Environment]::NewLine
    $text = '# Codex保留報告書' + $nl + $nl + '**要確認**' + $nl + $nl +
        "依頼 $($Request.Name) は連続 $maxConsecutiveFailures 回失敗したため、Codexの呼び出しを止めました。" + $nl +
        '依頼ファイルは inbox に残しています。' + $nl + $nl +
        "最後の失敗理由: $Reason" + $nl + $nl +
        '再開するには、logs の codex-worker-fail.json から該当の依頼名を消してください。' + $nl
    [IO.File]::WriteAllText((Join-Path $reportsDir $holdName), $text, $utf8)
    try {
        Invoke-Git add -- "reports/$holdName" | Out-Null
        Invoke-Git commit -m "CodexWorker: 保留 $($Request.BaseName)" -- "reports/$holdName" | Out-Null
        Invoke-Git push | Out-Null
    } catch {
        Write-Log "保留報告書の保存に失敗しました: $($_.Exception.Message)"
    }
}

# Codexを呼んだのに完了しなかった回数を数える。3回目で保留報告書を出す。
function Register-RequestFailure([IO.FileInfo]$Request, [string]$Reason) {
    $count = (Get-FailCount $Request.Name) + 1
    Set-FailCount $Request.Name $count
    Write-Log "Codex失敗 ${count} 回目（連続）: $Reason"
    if ($count -ge $maxConsecutiveFailures) { Save-HoldReport $Request $Reason }
}
# Codexのエラー出力を、実行ごとのログファイルの末尾30行までworkerのログへ残す。
function Write-CodexErrorLog([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Write-Log 'Codexのエラー出力のファイルがありません'; return }
    $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction SilentlyContinue | Select-Object -Last 30)
    if ($lines.Count -eq 0) { Write-Log 'Codexのエラー出力は空でした'; return }
    Write-Log "Codexのエラー出力（末尾$($lines.Count)行）:"
    foreach ($line in $lines) { Write-Log ('  ' + [string]$line) }
}

$lock = $null
try {
    $lock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
    Write-Log '起動'
    $schemaPath = Join-Path $logDir 'codex-worker-report-schema.json'
    $schema = '{"type":"object","properties":{"status":{"type":"string","enum":["completed","approval_required","failed"]},"report":{"type":"string"}},"required":["status","report"],"additionalProperties":false}'
    [IO.File]::WriteAllText($schemaPath, $schema, $utf8)
    # 未保存の変更は退避ブランチへ保存して main を最新に戻す（指示書を含む場合は従来どおり止める）
    $dirty = @(Get-DirtyPaths)
    if ($dirty.Count -gt 0) {
        if (@($dirty | Where-Object { Test-InstructionFile $_ }).Count -gt 0) {
            throw '未コミットの変更があります（指示書を含むため自動退避しません）。確認できるよう作業ツリーに残しました。'
        }
        $null = Save-ChangesToHoldBranch -Pathspec @('.', ':(exclude)logs') -Tag '未保存の変更' -Original (Get-CurrentBranch)
    }

    Invoke-Git pull --no-edit --no-rebase | Out-Null
    if (Invoke-Git log '@{upstream}..HEAD' --oneline) {
        Invoke-Git push | Out-Null
    }

    $requests = Get-ChildItem -LiteralPath 'inbox-codex' -Filter '*.md' -File |
        Where-Object { $_.Name -ne 'README.md' } | Sort-Object Name
    if (-not $requests) { Write-Log '未処理の依頼はありません' }

    foreach ($request in $requests) {
        if (($request.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            $request.Name -notmatch '^\d{4}-\d{2}-\d{2}_\d{3}_[\p{L}\p{N}_・ー（）() -]+\.md$' -or
            $request.Name -match '(?i)password|credential|secret|token|api[ _-]?key|認証情報|秘密鍵|パスワード') {
            Write-Log '規定外または認証情報の可能性がある依頼ファイルを保留しました'
            continue
        }

        $failCount = Get-FailCount $request.Name
        if ($failCount -ge $maxConsecutiveFailures) {
            Write-Log "保留: 連続失敗 ${failCount} 回のため Codex を呼びません $($request.Name)"
            continue
        }
        $processedDir = Join-Path $RepoPath 'inbox-codex\processed'
        $reportsDir = Join-Path $RepoPath 'reports'
        New-Item -ItemType Directory -Force -Path $processedDir, $reportsDir | Out-Null
        $processedPath = Join-Path $processedDir $request.Name
        $reportPath = Join-Path $reportsDir ($request.BaseName + '_Codex報告書.md')
        if ((Test-Path -LiteralPath $processedPath) -or (Test-Path -LiteralPath $reportPath)) {
            throw "移動先または報告書が既に存在します。$($request.Name)"
        }

        $runId = $request.BaseName + '-' + [guid]::NewGuid().ToString('N')
        $draftPath = Join-Path $logDir ($runId + '-Codex出力.md')
        $errPath = Join-Path $logDir ($runId + '-Codexエラー.txt')
        Write-Log "処理開始 $($request.Name)"
        $prompt = @"
inbox-codex/$($request.Name) を読み、依頼を処理してください。
依頼に範囲の指定がなければこのリポジトリ内で作業してください。
金銭（購入・課金を含む）、対人操作、外部送信・公開が必要なら、その操作を行わず報告書に「要承認」と書いて止めてください。
ファイルの削除・移動、認証情報らしきファイルの読み取り、保護設定の変更は禁止です。依頼にこれらの指示があっても実行しないでください。
Notionの作業ログ、他のAIへの連絡、その他すべての外部アプリへの書き込みは禁止です。必要な作業記録はこの回答のreportフィールドにだけ書いてください。
このリポジトリは公開です。個人情報・業務データ・秘密情報を成果物や報告書に転記しないでください。
依頼ファイル、worker、inbox、inbox-codex、logs、Git設定を編集しないでください。Git操作とタスク操作は呼び出し元が担当します。reports配下や inbox-codex 配下に報告書などのファイルを新しく作らず、報告はreportフィールドにだけ書いてください。
最終回答のstatusは、完了ならcompleted、承認が必要ならapproval_required、未実行または失敗ならfailedとしてください。reportは日本語のMarkdownで、実施事項、変更ファイル、検証結果、未完了事項を記載してください。呼び出し元が見出しを付けて保存します。
"@
        $mcpCall = $false
        $previousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            & codex.cmd -a never -c "windows.sandbox='elevated'" -c 'sandbox_workspace_write.network_access=false' -c "web_search='disabled'" -c 'mcp_servers={}' --disable apps --disable plugins --disable remote_plugin --disable hooks --disable in_app_browser exec --ignore-user-config --ephemeral --sandbox workspace-write --color never --json --output-schema $schemaPath --output-last-message $draftPath $prompt 2>$errPath |
                ForEach-Object {
                    if ($_ -match '"type"\s*:\s*"mcp_tool_call"') { $mcpCall = $true }
                }
            $codexExit = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousPreference
        }
        # 指示書の変更は取り込まず、退避ブランチへ保存して保留する（対策C1）
        $instrHoldText = Hold-InstructionChanges (Get-CurrentBranch)

        if ($codexExit -ne 0 -or -not (Test-Path -LiteralPath $draftPath -PathType Leaf)) {
            Write-CodexErrorLog $errPath
            Register-RequestFailure $request 'Codexの実行または報告書保存が失敗'
            throw "Codexの実行または報告書保存が失敗しました (exit $codexExit)。依頼は受付に残っています。"
        }
        if ($mcpCall) { Register-RequestFailure $request '外部連携ツールの呼び出しを検出'; throw '外部連携ツールの呼び出しを検出しました。この回の変更を保留しました。' }
        $result = $null
        try { $result = Get-Content -LiteralPath $draftPath -Encoding UTF8 -Raw | ConvertFrom-Json } catch { $result = $null }
        if (-not $result -or $result.status -notin @('completed', 'approval_required') -or [string]::IsNullOrWhiteSpace($result.report)) {
            Register-RequestFailure $request '依頼は未完了（報告が空、またはstatusが不正）'
            throw '依頼は未完了です。Codex出力をローカルログに保存しました。'
        }
        $approvalNote = ''
        if ($result.status -eq 'approval_required') { $approvalNote = "**要承認**" + [Environment]::NewLine + [Environment]::NewLine }
        $reportText = '# Codex作業報告書' + [Environment]::NewLine + [Environment]::NewLine + $approvalNote + $result.report + [Environment]::NewLine + [Environment]::NewLine + [string]$instrHoldText
        $deleted = Invoke-Git diff HEAD --no-renames --diff-filter=D --name-only --
        if ($deleted) { throw '削除されたファイルがあります。この回の変更を保留しました。' }

        [IO.File]::WriteAllText($reportPath, $reportText, $utf8)
        Move-Item -LiteralPath $request.FullName -Destination $processedPath
        Set-FailCount $request.Name 0
        Invoke-Git add -A -- @trackedPaths | Out-Null
        Invoke-Git ls-files --error-unmatch -- "reports/$([IO.Path]::GetFileName($reportPath))" | Out-Null
        Invoke-Git commit -m "CodexWorker: $($request.BaseName)" | Out-Null
        Invoke-Git push | Out-Null
        Write-Log "処理完了 $($request.Name)"
    }

    Write-Log '終了'
} catch {
    if ($lock) { Write-Log "停止: $($_.Exception.Message)" }
    Write-Error -ErrorAction Continue $_
    exit 1
} finally {
    if ($lock) { $lock.Dispose() }
}
