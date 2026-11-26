# CodexWorkerGuard.ps1 の動作確認（一時フォルダに作った試験用リポジトリとローカルの remote で実行。本物のリポジトリとGitHubには触れない）
# 実行例：powershell.exe -NoProfile -ExecutionPolicy Bypass -File worker\CodexWorkerGuard.Tests.ps1

[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'CodexWorkerGuard.ps1')

$script:Logs = New-Object System.Collections.Generic.List[string]
function Write-Log([string]$Message) { $script:Logs.Add($Message) }

$results = New-Object System.Collections.Generic.List[string]
function Assert-Test([string]$Name, [bool]$Condition) {
    if ($Condition) { $results.Add("PASS  $Name") } else { $results.Add("FAIL  $Name") }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('guard-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $bare = Join-Path $root 'remote.git'
    $script:RepoPath = Join-Path $root 'work'
    & git.exe init --bare --initial-branch=main $bare | Out-Null
    & git.exe clone $bare $script:RepoPath 2>&1 | Out-Null
    Push-Location $script:RepoPath
    & git.exe config user.email 'test@example.invalid'
    & git.exe config user.name 'guard-test'
    & git.exe checkout -b main 2>$null | Out-Null
    [IO.File]::WriteAllText((Join-Path $script:RepoPath 'AGENTS.md'), "ルールA`n", (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $script:RepoPath 'a.txt'), "元`n", (New-Object Text.UTF8Encoding($false)))
    & git.exe add -A; & git.exe commit -m init | Out-Null
    & git.exe push -u origin main 2>&1 | Out-Null
    Pop-Location

    $utf8 = New-Object Text.UTF8Encoding($false)

    # 1. 指示書の判定
    Assert-Test 'AGENTS.md は指示書' (Test-InstructionFile 'AGENTS.md')
    Assert-Test 'docs/owl/CLAUDE.md は指示書' (Test-InstructionFile 'docs/owl/CLAUDE.md')
    Assert-Test 'AGENTS.md.bak は指示書ではない' (-not (Test-InstructionFile 'AGENTS.md.bak'))
    Assert-Test 'reports配下のAGENTS名は指示書ではない' (-not (Test-InstructionFile 'reports/AGENTS-x.md'))

    # 2. 未保存の変更（指示書なし）を退避ブランチへ保存し、mainを戻す
    Push-Location $script:RepoPath
    $mainBefore = (& git.exe rev-parse HEAD).Trim()
    [IO.File]::WriteAllText((Join-Path $script:RepoPath 'a.txt'), "変更`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $script:RepoPath 'メモ.md'), "新規`n", $utf8)
    Pop-Location
    $dirty = @(Get-DirtyPaths)
    Assert-Test '未保存の変更を2件検出' ($dirty.Count -eq 2)
    $br = Save-ChangesToHoldBranch -Pathspec @('.', ':(exclude)logs') -Tag '未保存の変更' -Original 'main'
    Push-Location $script:RepoPath
    $remoteHas = (& git.exe ls-remote --heads origin $br) -match [regex]::Escape($br)
    Assert-Test '退避ブランチがremoteへpushされた' ([bool]$remoteHas)
    Assert-Test '退避ブランチ名は worker-退避/ で始まる' ($br -like 'worker-退避/*')
    Assert-Test 'mainに戻っている' ((& git.exe rev-parse --abbrev-ref HEAD).Trim() -eq 'main')
    Assert-Test 'mainのHEADは変わらない' ((& git.exe rev-parse HEAD).Trim() -eq $mainBefore)
    Assert-Test 'mainの作業ツリーは最新（未保存なし）' (-not (Get-DirtyPaths))
    Assert-Test '退避ブランチに変更内容が入っている' (((& git.exe show "${br}:a.txt") -join '') -match '変更')
    Assert-Test '退避ブランチに新規ファイルが入っている' ((Invoke-GitQuiet @('cat-file', '-e', "${br}:メモ.md")).Code -eq 0)
    Assert-Test '退避後のstashは残っていない' (-not ((& git.exe stash list) -match 'worker-hold'))
    Pop-Location

    # 3. Codex実行後の指示書の変更（C1）：指示書は保留、それ以外は残す
    Push-Location $script:RepoPath
    [IO.File]::WriteAllText((Join-Path $script:RepoPath 'AGENTS.md'), "ルールA`nルールB（追加）`n", $utf8)
    New-Item -ItemType Directory -Path (Join-Path $script:RepoPath 'docs/owl') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $script:RepoPath 'docs/owl/CLAUDE.md'), "新しい指示`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $script:RepoPath 'a.txt'), "Codexの成果`n", $utf8)
    Pop-Location
    $hold = Hold-InstructionChanges 'main'
    Push-Location $script:RepoPath
    Assert-Test '指示書の保留節を作った' ($hold -match '指示書の変更を保留')
    Assert-Test '報告書の節に変更箇所（追加行）が載る' ($hold -match 'ルールB')
    Assert-Test '保留節に退避ブランチ名が入る' ($hold -match 'worker-退避/\S+-指示書')
    Assert-Test 'AGENTS.mdはmainの版に戻った' (((Get-Content -LiteralPath 'AGENTS.md' -Raw -Encoding UTF8) -replace "`r", '') -eq "ルールA`n")
    Assert-Test '新規の指示書は作業ツリーから消えた' (-not (Test-Path -LiteralPath 'docs/owl/CLAUDE.md'))
    Assert-Test 'Codexの成果（指示書以外）は作業ツリーに残った' (((Get-Content -LiteralPath 'a.txt' -Raw -Encoding UTF8) -replace "`r", '') -eq "Codexの成果`n")
    $holdBranch = [regex]::Match($hold, 'worker-退避/\S+-指示書').Value
    Assert-Test '退避ブランチにAGENTS.mdの追加が入っている' (((& git.exe show "${holdBranch}:AGENTS.md") -join "`n") -match 'ルールB')
    Assert-Test '退避ブランチにはCodexの成果を含めていない' (((& git.exe show "${holdBranch}:a.txt") -join '') -match '^元')
    Assert-Test '指示書の退避後のstashは残っていない' (-not ((& git.exe stash list) -match 'worker-hold'))
    Pop-Location

    # 4. 指示書の変更がなければ何もしない
    Push-Location $script:RepoPath
    & git.exe checkout -- a.txt
    Pop-Location
    Assert-Test '指示書の変更がなければ節を作らない' ($null -eq (Hold-InstructionChanges 'main'))
}
finally {
    Set-Location $PSScriptRoot
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

$results
$failed = @($results | Where-Object { $_ -like 'FAIL*' }).Count
Write-Output ("結果: {0} 件中 {1} 件失敗" -f $results.Count, $failed)
if ($script:Logs.Count -gt 0) { Write-Output '--- ログ ---'; $script:Logs | ForEach-Object { Write-Output $_ } }
if ($failed -gt 0) { exit 1 }
