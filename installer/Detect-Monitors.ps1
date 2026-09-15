Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding
try {
    $monitors = @(& (Join-Path $PSScriptRoot 'Switch-MonitorInput.ps1') -List -PassThru)
    ConvertTo-Json -InputObject $monitors -Depth 4 -Compress
}
catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
}
