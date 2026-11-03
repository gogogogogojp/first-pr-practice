# first-pr-practice

初めてのプルリクエストを練習するための、小さな PowerShell プロジェクトです。
作った人：gogogogogojp
## 使い方

```powershell
. .\Greeting.ps1
Get-Greeting -Name "ゴゴゴゴゴ"
# => こんにちは、ゴゴゴゴゴさん!
```

名前を省略すると「ゲストさん」にあいさつします。

## テストの実行

Windows に標準で入っている [Pester](https://pester.dev/) でテストできます。

```powershell
Invoke-Pester .\Greeting.Tests.ps1
```
