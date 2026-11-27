# モデル割り当て.ps1
# 依頼ファイルの1行で、その回だけのモデルと思考の深さを決める（依頼118）。
# 書き方（行の先頭に書く。例）:
#   モデル：Opus
#   思考の深さ：高
# 何も書かなければ、各ワーカーの既定を使う。書かれた値が使えない時は既定を使い、その旨をログに書く。
# 使い方：. "$PSScriptRoot\モデル割り当て.ps1" の後に、Get-RequestModelOverride と Resolve-RequestChoice を呼ぶ。
# Windows PowerShell 5.1 でも動く書き方にしている。

# Claude（claude CLI の --model）。キーは小文字。表示名（Opus など）も受け付ける。
$script:ClaudeModelMap = @{
    'opus'            = 'claude-opus-5-5'
    'sonnet'          = 'claude-sonnet-5-5'
    'haiku'           = 'claude-haiku-5-5'
    'claude-opus-5-5'   = 'claude-opus-5-5'
    'claude-sonnet-5-5' = 'claude-sonnet-5-5'
    'claude-haiku-5-5'  = 'claude-haiku-5-5'
}

# Codex（codex exec の -m）。キーは小文字。表示名（GPT-6.1 Terra など）は空白をハイフンにして照合する。
# 値は codex debug models で選べると確認したモデル（2026-11-27）。
$script:CodexModelMap = @{
    'gpt-6.2-sol'    = 'gpt-6.2-sol'
    'gpt-6.2-astra'  = 'gpt-6.2-astra'
    'gpt-6.1-terra'  = 'gpt-6.1-terra'
    'gpt-6.1-sol'    = 'gpt-6.1-sol'
    'gpt-6-astra'    = 'gpt-6-astra'
    'gpt-6-sol'      = 'gpt-6-sol'
    'gpt-6-luna'     = 'gpt-6-luna'
    'gpt-5.6-sol'    = 'gpt-5.6-sol'
    'gpt-5.6-terra'  = 'gpt-5.6-terra'
    'gpt-5.6-luna'   = 'gpt-5.6-luna'
}

# 思考の深さ。日本語（低・中・高）も受け付ける。
$script:EffortMap = @{
    '低'       = 'low'
    '中'       = 'medium'
    '高'       = 'high'
    'low'      = 'low'
    'medium'   = 'medium'
    'high'     = 'high'
    'xhigh'    = 'xhigh'
    'max'      = 'max'
}

# 依頼本文から「モデル：」「思考の深さ：」の行を探す。行の先頭（空白のみ可）にある行だけを見る。
# 文中の引用（「- ……「モデル：Opus」……」など）は対象にしない。
function Get-RequestModelOverride {
    param([string]$Text = '')
    $model = $null
    $effort = $null
    if ($Text -match '(?m)^[ \t]*モデル[:：][ \t]*(\S+)') { $model = $Matches[1] }
    if ($Text -match '(?m)^[ \t]*思考の深さ[:：][ \t]*(\S+)') { $effort = $Matches[1] }
    return [pscustomobject]@{ Model = $model; Effort = $effort }
}

# 依頼の指定を、使える値に直す。使えない・指定なしの時は既定の値を返す。
# 返り値：Value（使う値）、Source（依頼／既定）、Note（ログ用の補足。通常は空）
function Resolve-RequestChoice {
    param(
        [string]$Requested = '',
        [hashtable]$Allowed = @{},
        [string]$Default = ''
    )
    if ([string]::IsNullOrWhiteSpace($Requested)) {
        return [pscustomobject]@{ Value = $Default; Source = '既定'; Note = '' }
    }
    $key = $Requested.Trim().ToLowerInvariant().Replace(' ', '-')
    if ($Allowed.ContainsKey($key)) {
        return [pscustomobject]@{ Value = [string]$Allowed[$key]; Source = '依頼'; Note = '' }
    }
    return [pscustomobject]@{
        Value  = $Default
        Source = '既定'
        Note   = "依頼の指定「$Requested」は使えないため、既定を使いました"
    }
}
