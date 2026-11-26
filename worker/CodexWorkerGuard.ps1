# Codexワーカー（Invoke-CodexWorker.ps1 / Invoke-CodexWorker2.ps1）の共通処理
# 対策B（案2）：未保存の変更を退避ブランチへ保存して main を最新に戻す
# 対策C（C1）：Codex実行後に指示書（AGENTS.md・CLAUDE.md など）の変更を退避し、取り込まず保留する
#
# 呼び出し側が事前に用意するもの：$RepoPath（作業リポジトリ）と Write-Log（ログ関数）
# 退避ブランチ名：worker-退避/<日時>（指示書の退避は worker-退避/<日時>-指示書）
# 退避ブランチの整理：残す期間は30日の目安。削除は親方の承認後に行う（自動では消さない）。
#
# 注意：PowerShell 5.1 は日本語のファイル名をgitへ渡すと文字化けするため、
# gitに渡すパスは英字だけにする（未保存の変更は「全体（logs以外）」で扱う）。

# 指示書の判定：AGENTS.md・CLAUDE.md（どの階層でも）
$script:InstructionPattern = '(^|/)(AGENTS|CLAUDE)\.md$'

function Test-InstructionFile([string]$RelPath) {
    return (($RelPath -replace '\\', '/') -match $script:InstructionPattern)
}

# git を実行し、終了コードと出力行を返す（ログには書かない）
function Invoke-GitQuiet([string[]]$GitArgs) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & git.exe -C $RepoPath @GitArgs 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    return [pscustomobject]@{ Code = $code; Lines = @($out | ForEach-Object { [string]$_ }) }
}

# git を実行し、失敗したら例外にする
function Invoke-GitStrict([string[]]$GitArgs) {
    $r = Invoke-GitQuiet $GitArgs
    if ($r.Code -ne 0) {
        throw "git $($GitArgs[0]) が失敗しました (exit $($r.Code)): $($r.Lines -join ' ')"
    }
    return $r.Lines
}

function Get-CurrentBranch {
    return (Invoke-GitStrict @('rev-parse', '--abbrev-ref', 'HEAD'))[0]
}

# 未コミットの変更（logs 以外）のパス一覧
function Get-DirtyPaths {
    $r = Invoke-GitQuiet @('-c', 'core.quotepath=off', 'status', '--porcelain=v1', '--untracked-files=all', '--', '.', ':(exclude)logs')
    if ($r.Code -ne 0) { throw "git status が失敗しました (exit $($r.Code))" }
    return @($r.Lines | Where-Object { $_.Length -gt 3 } | ForEach-Object { $_.Substring(3) })
}

# 退避ブランチ名を作る（同じ秒に作られた場合は連番を付ける）
function New-HoldBranchName([string]$Tag) {
    $base = 'worker-退避/' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    if ($Tag -eq '指示書') { $base += '-指示書' }
    $name = $base
    $n = 2
    while ((Invoke-GitQuiet @('show-ref', '--verify', '--quiet', "refs/heads/$name")).Code -eq 0) {
        $name = "$base-$n"
        $n++
    }
    return $name
}

# 変更を「退避ブランチ」へ commit して push し、元のブランチへ戻す。
# $Pathspec の対象だけを退避する（英字のパスのみ）。
# 手順：stash（退避）→ 退避ブランチ作成 → stash を適用 → 追加 → commit → push → 元のブランチへ戻る → 印の stash を削除。
# 途中で失敗しても stash に変更が残るので、変更は消えない。
function Save-ChangesToHoldBranch([string[]]$Pathspec, [string]$Tag, [string]$Original) {
    if (-not $Pathspec -or $Pathspec.Count -eq 0) { throw '退避する対象がありません' }
    $branch = New-HoldBranchName $Tag
    $marker = "worker-hold:$branch"
    Invoke-GitStrict (@('stash', 'push', '--include-untracked', '-m', $marker, '--') + $Pathspec) | Out-Null
    $pushed = $false
    try {
        Invoke-GitStrict @('switch', '-c', $branch) | Out-Null
        Invoke-GitStrict @('stash', 'apply', 'stash@{0}') | Out-Null
        Invoke-GitStrict (@('add', '-A', '--') + $Pathspec) | Out-Null
        Invoke-GitStrict @('commit', '-m', "CodexWorker: 退避（$Tag）$branch") | Out-Null
        Invoke-GitStrict @('push', '-u', 'origin', $branch) | Out-Null
        $pushed = $true
    } finally {
        $back = Invoke-GitQuiet @('switch', $Original)
        if ($back.Code -ne 0) { Write-Log "警告: 元のブランチ $Original へ戻れませんでした。stash に変更が残っています ($marker)" }
    }
    if ($pushed) {
        # 退避が成功したので、同じ印の stash だけを削除する
        $list = Invoke-GitQuiet @('stash', 'list', '--format=%gd %gs')
        $entry = @($list.Lines | Where-Object { $_ -like "*$marker*" }) | Select-Object -First 1
        if ($entry) { Invoke-GitStrict @('stash', 'drop', ($entry -split ' ')[0]) | Out-Null }
    }
    Write-Log "退避ブランチへ保存しました: $branch（対象 $($Pathspec -join ' ')）"
    return $branch
}

# 指示書の変更の内容を、報告書に載せる形でまとめる（追加・変更・削除の件数と先頭の抜粋）
function Get-InstructionChangeSection([string[]]$Paths) {
    $nl = [Environment]::NewLine
    $rows = New-Object System.Collections.Generic.List[string]
    $excerpt = New-Object System.Collections.Generic.List[string]
    foreach ($p in $Paths) {
        $full = Join-Path $RepoPath $p
        $tracked = (Invoke-GitQuiet @('cat-file', '-e', "HEAD:$($p -replace '\\', '/')")).Code -eq 0
        if (-not $tracked) {
            $lines = @()
            if (Test-Path -LiteralPath $full -PathType Leaf) { $lines = @(Get-Content -LiteralPath $full -Encoding UTF8 -ErrorAction SilentlyContinue) }
            $rows.Add("| $p | 追加 | +$($lines.Count) | -0 |")
            $excerpt.Add("--- 新規: $p")
            foreach ($l in ($lines | Select-Object -First 40)) { $excerpt.Add('+' + [string]$l) }
        } elseif (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            $rows.Add("| $p | 削除 | +0 | -（全行） |")
            $excerpt.Add("--- 削除: $p")
        } else {
            $num = [string](Invoke-GitQuiet @('diff', '--numstat', 'HEAD', '--', $p)).Lines[0]
            $parts = @($num -split '\s+')
            $added = if ($parts.Count -ge 2) { $parts[0] } else { '?' }
            $removed = if ($parts.Count -ge 2) { $parts[1] } else { '?' }
            $rows.Add("| $p | 変更 | +$added | -$removed |")
            $diff = (Invoke-GitQuiet @('diff', 'HEAD', '--', $p)).Lines
            $changed = @($diff | Where-Object { ($_ -like '+*' -or $_ -like '-*') -and $_ -notlike '+++*' -and $_ -notlike '---*' })
            $excerpt.Add("--- 変更: $p")
            foreach ($l in ($changed | Select-Object -First 40)) { $excerpt.Add($l) }
        }
    }
    return '## 指示書の変更を保留' + $nl + $nl +
        '指示書の変更は取り込んでいません。承認されるまで反映しません。変更は退避ブランチに保存しています。' + $nl + $nl +
        '| ファイル | 種類 | 追加行 | 削除行 |' + $nl + '|---|---|---|---|' + $nl +
        ($rows -join $nl) + $nl + $nl +
        '変更箇所（先頭40行まで）:' + $nl + $nl + '```diff' + $nl + ($excerpt -join $nl) + $nl + '```' + $nl
}

# Codex実行後の確認（C1）：指示書に差分があれば退避し、作業ツリーの指示書を元に戻す。
# 戻り値：報告書に載せる「指示書の変更を保留」の節（差分が無ければ $null）
function Hold-InstructionChanges([string]$Original) {
    $dirty = @(Get-DirtyPaths)
    $instr = @($dirty | Where-Object { Test-InstructionFile $_ })
    if ($instr.Count -eq 0) { return $null }
    $nonAscii = @($instr | Where-Object { $_ -match '[^\x00-\x7F]' })
    if ($nonAscii.Count -gt 0) {
        throw "指示書のパスに日本語を含むため自動保留できません（要確認）: $($nonAscii -join ', ')"
    }
    Write-Log "指示書の変更を検知したため保留します: $($instr -join ', ')"
    $section = Get-InstructionChangeSection $instr
    $branch = Save-ChangesToHoldBranch -Pathspec $instr -Tag '指示書' -Original $Original
    return ($section + [Environment]::NewLine + "退避ブランチ: ``$branch``" + [Environment]::NewLine)
}
