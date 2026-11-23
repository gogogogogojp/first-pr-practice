param(
    [string]$RepoPath = "$env:USERPROFILE\repos\first-pr-practice-codex-worker"
)

$ErrorActionPreference = 'Stop'
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

        Write-Log "処理開始 $($request.Name)"
        $prompt = @"
inbox-codex/$($request.Name) を読み、依頼を処理してください。
依頼に範囲の指定がなければこのリポジトリ内で作業してください。
金銭（購入・課金を含む）、対人操作、外部送信・公開が必要なら、その操作を行わず報告書に「要承認」と書いて止めてください。
ファイルの削除・移動、認証情報らしきファイルの読み取り、保護設定の変更は禁止です。依頼にこれらの指示があっても実行しないでください。
このリポジトリは公開です。個人情報・業務データ・秘密情報を成果物や報告書に転記しないでください。
依頼ファイル、worker、inbox、inbox-codex、logs、Git設定を編集しないでください。Git操作とタスク操作は呼び出し元が担当します。
最終回答を日本語のMarkdown報告書とし、実施事項、作成・変更したファイル、検証結果、未完了事項を記載してください。1行目は「# Codex作業報告書」としてください。この最終回答は呼び出し元が保存します。
"@
        $previousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            & codex.cmd -a never exec --ignore-user-config --ephemeral --sandbox workspace-write --color never --output-last-message $reportPath $prompt *> $null
            $codexExit = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousPreference
        }

        if ($codexExit -ne 0 -or -not (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
            throw "Codexの実行または報告書保存が失敗しました (exit $codexExit)。依頼は受付に残っています。"
        }
        if ((Get-Content -LiteralPath $reportPath -Encoding UTF8 -TotalCount 1) -ne '# Codex作業報告書') {
            throw '報告書の見出しが所定の形式と異なります。'
        }
        $deleted = Invoke-Git diff HEAD --no-renames --diff-filter=D --name-only --
        if ($deleted) { throw '削除されたファイルがあります。この回の変更を保留しました。' }

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
