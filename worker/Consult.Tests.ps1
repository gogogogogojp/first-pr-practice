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
        $path = Join-Path $tmp "consult\open\$id.md"
        (Get-Content -Raw $path) -replace '(?m)^deadline: .+$', 'deadline: 2000-01-01 00:00:00' | Set-Content $path -Encoding UTF8
        & $script -Action Status -Id $id -RepoPath $tmp | Should Be "timeout"
    }

    It "期限切れでも返信があれば replied を優先する" {
        $id = & $script -Action New -Topic "テスト" -Question "質問" -RepoPath $tmp
        $path = Join-Path $tmp "consult\open\$id.md"
        (Get-Content -Raw $path) -replace '(?m)^deadline: .+$', 'deadline: 2000-01-01 00:00:00' | Set-Content $path -Encoding UTF8
        & $script -Action Reply -Id $id -From "ChatGPT" -Text "遅れて返信" -RepoPath $tmp | Out-Null
        & $script -Action Status -Id $id -RepoPath $tmp | Should Be "replied"
    }

    It "件名や質問がないと New はエラーになる" {
        { & $script -Action New -Topic "" -Question "質問" -RepoPath $tmp } | Should Throw
    }

    It "存在しない相談IDはエラーになる" {
        { & $script -Action Status -Id "no-such-id" -RepoPath $tmp } | Should Throw
    }
}
