# 利用枠記録.ps1 の動作確認（Pester。一時フォルダで実行し、本物の reports/ と生の出力フォルダには書かない）
. (Join-Path $PSScriptRoot '利用枠記録.ps1')

# 形式は実際の stream-json と同じ構造の合成データ（値は試験用）
$sampleLine = '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":1795590600,"rateLimitType":"five_hour","unifiedWindows":{"five_hour":{"utilization":0.02,"resetsAt":1795590600,"status":"allowed"},"seven_day":{"utilization":0.48,"resetsAt":1795752000,"status":"allowed"}}}}'

Describe "利用枠記録.ps1" {
    BeforeEach {
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("usage-test-" + [guid]::NewGuid().ToString('N'))
        $repo = Join-Path $tmp 'repo'
        $raw = Join-Path $tmp 'raw'
        New-Item -ItemType Directory -Path (Join-Path $repo 'reports') -Force | Out-Null
    }
    AfterEach {
        Remove-Item -Recurse -Force $tmp
    }

    It "リセット時刻を日本時間の報告の形にする" {
        Format-UsageReset -EpochSeconds 1795590600 | Should Be '11月25日水曜日16時10分まで'
        Format-UsageReset -EpochSeconds 1795752000 | Should Be '11月27日金曜日13時まで'
    }

    It "利用率は unifiedWindows から取り出す（rate_limit_event 以外や壊れた行は無視）" {
        $w = Get-ClaudeUsageWindows -Lines @('not json', '{"type":"assistant"}', $sampleLine)
        $w.five_hour.utilization | Should Be 0.02
        $w.seven_day.utilization | Should Be 0.48
    }

    It "利用率が無ければ null を返す" {
        Get-ClaudeUsageWindows -Lines @('{"type":"result"}') | Should Be $null
    }

    It "最新値の報告書と生の出力を書く" {
        $msg = Save-ClaudeUsage -Lines @($sampleLine) -RepoPath $repo -Source 'Test' -RawDir $raw
        $msg | Should Match '利用率を記録しました'
        $report = Get-Content -LiteralPath (Join-Path $repo 'reports\利用枠_最新.md') -Raw -Encoding UTF8
        $report | Should Match '5時間枠：\*\*2%\*\*（11月25日水曜日16時10分まで）'
        $report | Should Match '7日枠：\*\*48%\*\*（11月27日金曜日13時まで）'
        @(Get-ChildItem -LiteralPath $raw -Filter '*.jsonl').Count | Should Be 1
    }

    It "利用率が無い時は報告書を作らず、理由を返す" {
        $msg = Save-ClaudeUsage -Lines @('{"type":"result"}') -RepoPath $repo -Source 'Test' -RawDir $raw
        $msg | Should Match '利用率の記録なし'
        Test-Path -LiteralPath (Join-Path $repo 'reports\利用枠_最新.md') | Should Be $false
    }

    It "生の出力は新しい順に20件までしか残さない（7日より古いものは消す）" {
        New-Item -ItemType Directory -Path $raw -Force | Out-Null
        for ($i = 0; $i -lt 25; $i++) {
            $p = Join-Path $raw ("old-{0:00}.jsonl" -f $i)
            Set-Content -LiteralPath $p -Value 'x'
            (Get-Item -LiteralPath $p).LastWriteTime = (Get-Date).AddHours(-$i)
        }
        $stale = Join-Path $raw 'stale.jsonl'
        Set-Content -LiteralPath $stale -Value 'x'
        (Get-Item -LiteralPath $stale).LastWriteTime = (Get-Date).AddDays(-30)

        Save-ClaudeUsage -Lines @($sampleLine) -RepoPath $repo -Source 'Test' -RawDir $raw | Out-Null
        @(Get-ChildItem -LiteralPath $raw -Filter '*.jsonl').Count | Should Be 20
        Test-Path -LiteralPath $stale | Should Be $false
    }
}
