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

$lock = $null
try {
    $lock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
    Write-Log '起動'
    $schemaPath = Join-Path $logDir 'codex-worker-report-schema.json'
    $schema = '{"type":"object","properties":{"status":{"type":"string","enum":["completed","approval_required","failed"]},"report":{"type":"string"}},"required":["status","report"],"additionalProperties":false}'
    [IO.File]::WriteAllText($schemaPath, $schema, $utf8)
    if (Invoke-Git status --porcelain=v1 --untracked-files=all -- @trackedPaths) {
        throw '未コミットの変更があります。確認できるよう作業ツリーに残しました。'
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

        $processedDir = Join-Path $RepoPath 'inbox-codex\processed'
        $reportsDir = Join-Path $RepoPath 'reports'
        New-Item -ItemType Directory -Force -Path $processedDir, $reportsDir | Out-Null
        $processedPath = Join-Path $processedDir $request.Name
        $reportPath = Join-Path $reportsDir ($request.BaseName + '_Codex報告書.md')
        if ((Test-Path -LiteralPath $processedPath) -or (Test-Path -LiteralPath $reportPath)) {
            throw "移動先または報告書が既に存在します。$($request.Name)"
        }

        $draftPath = Join-Path $logDir ($request.BaseName + '-' + [guid]::NewGuid().ToString('N') + '-Codex出力.md')
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
            & codex.cmd -a never -c "windows.sandbox='elevated'" -c 'sandbox_workspace_write.network_access=false' -c "web_search='disabled'" -c 'mcp_servers={}' --disable apps --disable plugins --disable remote_plugin --disable hooks --disable in_app_browser exec --ignore-user-config --ephemeral --sandbox workspace-write --color never --json --output-schema $schemaPath --output-last-message $draftPath $prompt 2>$null |
                ForEach-Object {
                    if ($_ -match '"type"\s*:\s*"mcp_tool_call"') { $mcpCall = $true }
                }
            $codexExit = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousPreference
        }

        if ($codexExit -ne 0 -or -not (Test-Path -LiteralPath $draftPath -PathType Leaf)) {
            throw "Codexの実行または報告書保存が失敗しました (exit $codexExit)。依頼は受付に残っています。"
        }
        if ($mcpCall) { throw '外部連携ツールの呼び出しを検出しました。この回の変更を保留しました。' }
        $result = Get-Content -LiteralPath $draftPath -Encoding UTF8 -Raw | ConvertFrom-Json
        if ($result.status -notin @('completed', 'approval_required') -or [string]::IsNullOrWhiteSpace($result.report)) {
            throw '依頼は未完了です。Codex出力をローカルログに保存しました。'
        }
        $approvalNote = ''
        if ($result.status -eq 'approval_required') { $approvalNote = "**要承認**" + [Environment]::NewLine + [Environment]::NewLine }
        $reportText = '# Codex作業報告書' + [Environment]::NewLine + [Environment]::NewLine + $approvalNote + $result.report + [Environment]::NewLine
        $deleted = Invoke-Git diff HEAD --no-renames --diff-filter=D --name-only --
        if ($deleted) { throw '削除されたファイルがあります。この回の変更を保留しました。' }

        [IO.File]::WriteAllText($reportPath, $reportText, $utf8)
        Move-Item -LiteralPath $request.FullName -Destination $processedPath
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
