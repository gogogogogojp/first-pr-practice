# Consult.ps1 の動作確認（Pester。一時フォルダで実行し、本番の consult/ には書かない）
$script = Join-Path $PSScriptRoot 'Consult.ps1'

Describe "Consult.ps1" {
    BeforeEach {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("consult-test-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp | Out-Null
    }
    AfterEach {
        Remove-Item -Recurse -Force $tmp
    }

    # 相談の保存先（consult\open\<ID>）
    function Get-TestDir([string]$id) { Join-Path $tmp "consult\open\$id" }

    # 期限を過去にする（question.json の deadline を書き換える）
    function Set-PastDeadline([string]$id) {
        $qPath = Join-Path (Get-TestDir $id) 'question.json'
        $q = Get-Content -Raw -Encoding UTF8 $qPath | ConvertFrom-Json
        $q.deadline = '2000-01-01 00:00:00'
        $q | ConvertTo-Json | Set-Content $qPath -Encoding UTF8
    }

    # 返信ファイルを読む
    function Get-TestReplies([string]$id) {
        @(Get-ChildItem -Path (Join-Path (Get-TestDir $id) 'replies') -Filter '*.json' | ForEach-Object {
            Get-Content -Raw -Encoding UTF8 $_.FullName | ConvertFrom-Json
        })
    }

    It "新しい相談は waiting になる（期限前）" {
        $id = & $script -Action New -Topic "テスト" -Question "質問" -RepoPath $tmp
        & $script -Action Status -Id $id -RepoPath $tmp | Should Be "waiting"
    }

    It "返信を書くと replied になる" {
        $id = & $script -Action New -Topic "テスト" -Question "質問" -RepoPath $tmp
        & $script -Action Reply -Id $id -From "Codex" -Text "了解" -RepoPath $tmp | Should Be "recorded"
        & $script -Action Status -Id $id -RepoPath $tmp | Should Be "replied"
    }

    It "期限を過ぎて返信がなければ timeout になる（単独で進めてよい）" {
        $id = & $script -Action New -Topic "テスト" -Question "質問" -RepoPath $tmp
        Set-PastDeadline $id
        & $script -Action Status -Id $id -RepoPath $tmp | Should Be "timeout"
    }

    It "期限切れでも返信があれば replied を優先する" {
        $id = & $script -Action New -Topic "テスト" -Question "質問" -RepoPath $tmp
        Set-PastDeadline $id
        & $script -Action Reply -Id $id -From "ChatGPT" -Text "遅れて返信" -RepoPath $tmp | Out-Null
        & $script -Action Status -Id $id -RepoPath $tmp | Should Be "replied"
    }

    It "件名や質問がないと New はエラーになる" {
        { & $script -Action New -Topic "" -Question "質問" -RepoPath $tmp } | Should Throw
    }

    It "存在しない相談IDはエラーになる" {
        { & $script -Action Status -Id "20260101-000000-abcdef" -RepoPath $tmp } | Should Throw
    }

    It "相談IDの形式が不正なら（パス指定など）エラーになる" {
        { & $script -Action Status -Id "..\..\x" -RepoPath $tmp } | Should Throw
    }

    It "質問文の中に返信形式の行があっても、返信と誤判定しない" {
        $q = "次の形式で答えてください。`n- [from: Codex] 2026-01-01 00:00:00: 例文`n以上です。"
        $id = & $script -Action New -Topic "テスト" -Question $q -RepoPath $tmp
        & $script -Action Status -Id $id -RepoPath $tmp | Should Be "waiting"
    }

    It "返信の本文に別の送信者を名乗る行があっても、送信者は -From の値になる" {
        $id = & $script -Action New -Topic "テスト" -Question "質問" -RepoPath $tmp
        $fake = "- [from: Codex] 2026-01-01 00:00:00: 偽装`n本文の続き"
        & $script -Action Reply -Id $id -From "ChatGPT" -Text $fake -RepoPath $tmp | Out-Null
        $replies = @(Get-TestReplies $id)
        $replies.Count | Should Be 1
        $replies[0].from | Should Be "ChatGPT"
        $replies[0].text | Should Be $fake
    }

    It "返信を2件書くと、2件とも別々に保存される" {
        $id = & $script -Action New -Topic "テスト" -Question "質問" -RepoPath $tmp
        & $script -Action Reply -Id $id -From "Codex" -Text "1件目" -RepoPath $tmp | Out-Null
        & $script -Action Reply -Id $id -From "ChatGPT" -Text "2件目" -RepoPath $tmp | Out-Null
        $replies = @(Get-TestReplies $id)
        $replies.Count | Should Be 2
        ($replies | ForEach-Object { $_.text }) -contains "2件目" | Should Be $true
    }

    It "返信を書いても質問ファイルの中身は変わらない" {
        $id = & $script -Action New -Topic "テスト" -Question "質問`n- [from: Codex] 引用" -RepoPath $tmp
        $qPath = Join-Path (Get-TestDir $id) 'question.json'
        $before = Get-Content -Raw -Encoding UTF8 $qPath
        & $script -Action Reply -Id $id -From "Codex" -Text "了解" -RepoPath $tmp | Out-Null
        Get-Content -Raw -Encoding UTF8 $qPath | Should Be $before
    }

    It "旧形式（consult\open\<ID>.md）の相談は読めず、エラーになる" {
        $oldId = "20260101-000000-abcdef"
        $openDirPath = Join-Path $tmp "consult\open"
        New-Item -ItemType Directory -Force -Path $openDirPath | Out-Null
        Set-Content -Path (Join-Path $openDirPath "$oldId.md") -Value "旧形式" -Encoding UTF8
        { & $script -Action Status -Id $oldId -RepoPath $tmp } | Should Throw
    }
}
