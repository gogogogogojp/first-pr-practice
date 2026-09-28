. "$PSScriptRoot\Greeting.ps1"

Describe "Get-Greeting" {
    It "名前を渡すと、その名前であいさつする" {
        Get-Greeting -Name "たろう" | Should Be "こんにちは、たろうさん!"
    }

    It "名前の前後の空白は取り除く" {
        Get-Greeting -Name "  はなこ  " | Should Be "こんにちは、はなこさん!"
    }

    It "名前を省略するとゲストにあいさつする" {
        Get-Greeting | Should Be "こんにちは、ゲストさん!"
    }

    It "空白だけの名前はゲスト扱いにする" {
        Get-Greeting -Name "   " | Should Be "こんにちは、ゲストさん!"
    }
}
