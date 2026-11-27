# モデル割り当て.ps1 の動作確認（Pester 3 形式）。外部へは何も送らず、ファイルも書かない。
. (Join-Path $PSScriptRoot 'モデル割り当て.ps1')

Describe "依頼の行からモデルと思考の深さを読む" {
    It "「モデル：Opus」の行を読む" {
        $o = Get-RequestModelOverride -Text "# 依頼`nモデル：Opus`n本文"
        $o.Model | Should Be 'Opus'
        $o.Effort | Should Be $null
    }
    It "半角コロンと思考の深さも読む" {
        $o = Get-RequestModelOverride -Text "モデル:GPT-6.2-Sol`n思考の深さ:高"
        $o.Model | Should Be 'GPT-6.2-Sol'
        $o.Effort | Should Be '高'
    }
    It "文中の引用や行の途中の「モデル：」は読まない" {
        $o = Get-RequestModelOverride -Text "- アント：標準は Sonnet。「モデル：Opus」と書かれた回だけ Opus"
        $o.Model | Should Be $null
    }
    It "指定がなければ両方とも空" {
        $o = Get-RequestModelOverride -Text "普通の依頼文"
        $o.Model | Should Be $null
        $o.Effort | Should Be $null
    }
}

Describe "指定を使える値に直す" {
    It "Claude：Opus は claude-opus-5-5 になる" {
        $c = Resolve-RequestChoice -Requested 'Opus' -Allowed $script:ClaudeModelMap -Default 'claude-sonnet-5-5'
        $c.Value | Should Be 'claude-opus-5-5'
        $c.Source | Should Be '依頼'
    }
    It "指定がなければ既定を使う" {
        $c = Resolve-RequestChoice -Requested '' -Allowed $script:ClaudeModelMap -Default 'claude-sonnet-5-5'
        $c.Value | Should Be 'claude-sonnet-5-5'
        $c.Source | Should Be '既定'
    }
    It "使えない指定は既定に戻し、理由を残す" {
        $c = Resolve-RequestChoice -Requested 'Gemini' -Allowed $script:ClaudeModelMap -Default 'claude-sonnet-5-5'
        $c.Value | Should Be 'claude-sonnet-5-5'
        $c.Source | Should Be '既定'
        $c.Note | Should Match 'Gemini'
    }
    It "Codex：GPT-6.1 Terra（表示名）は gpt-6.1-terra になる" {
        $c = Resolve-RequestChoice -Requested 'GPT-6.1 Terra' -Allowed $script:CodexModelMap -Default 'gpt-6.2-sol'
        $c.Value | Should Be 'gpt-6.1-terra'
    }
    It "Codex：GPT-6.2-Sol（ハイフン表記）も受け付ける" {
        $c = Resolve-RequestChoice -Requested 'GPT-6.2-Sol' -Allowed $script:CodexModelMap -Default 'gpt-6.1-terra'
        $c.Value | Should Be 'gpt-6.2-sol'
    }
    It "思考の深さ：高 は high、指定なしは既定の medium" {
        (Resolve-RequestChoice -Requested '高' -Allowed $script:EffortMap -Default 'medium').Value | Should Be 'high'
        (Resolve-RequestChoice -Requested '' -Allowed $script:EffortMap -Default 'medium').Value | Should Be 'medium'
    }
}
