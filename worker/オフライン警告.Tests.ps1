# オフライン警告.ps1 の動作確認（Pester。一時フォルダで実行し、本物の reports/ には書かない）
. (Join-Path $PSScriptRoot 'オフライン警告.ps1')

Describe "オフライン警告.ps1" {
    BeforeEach {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("offline-test-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        $warn = Join-Path $tmp 'reports\オフライン警告.md'
        $t = [datetime]'2026-11-27 11:04'
    }
    AfterEach {
        Remove-Item -Recurse -Force $tmp
    }

    It "2回までは警告を書かない" {
        Update-OfflineCount -RepoPath $tmp -Online $false -Now $t | Should Be 1
        Update-OfflineCount -RepoPath $tmp -Online $false -Now $t | Should Be 2
        Test-Path $warn | Should Be $false
    }

    It "3回続いたら警告を1行だけ書く（4回目以降は増やさない）" {
        1..5 | ForEach-Object { Update-OfflineCount -RepoPath $tmp -Online $false -Now $t } | Out-Null
        $lines = @(Get-Content $warn -Encoding UTF8)
        $lines.Count | Should Be 1
        $lines[0] | Should Match '警告：ClaudeWorker がオフラインで 3 回'
        $lines[0] | Should Match '2026-11-27 11:04'
    }

    It "接続が戻ったら0に戻し、復旧の1行を書く" {
        1..10 | ForEach-Object { Update-OfflineCount -RepoPath $tmp -Online $false -Now $t } | Out-Null
        Update-OfflineCount -RepoPath $tmp -Online $true -Now ([datetime]'2026-11-27 16:04') | Should Be 0
        $lines = @(Get-Content $warn -Encoding UTF8)
        $lines.Count | Should Be 2
        $lines[1] | Should Match '復旧.*連続 10 回'
    }

    It "2回以下で戻った時は何も書かない" {
        Update-OfflineCount -RepoPath $tmp -Online $false -Now $t | Out-Null
        Update-OfflineCount -RepoPath $tmp -Online $true -Now $t | Should Be 0
        Test-Path $warn | Should Be $false
    }

    It "回数ファイルが壊れていても0から数え直す" {
        New-Item -ItemType Directory -Path (Join-Path $tmp 'logs') -Force | Out-Null
        Set-Content (Join-Path $tmp 'logs\オフライン連続回数.txt') 'abc' -Encoding UTF8
        Update-OfflineCount -RepoPath $tmp -Online $false -Now $t | Should Be 1
    }
}
