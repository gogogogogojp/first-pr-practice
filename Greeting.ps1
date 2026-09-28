function Get-Greeting {
    param(
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return "こんにちは、ゲストさん!"
    }

    return "こんにちは、$($Name.Trim())さん!"
}
