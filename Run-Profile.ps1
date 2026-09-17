[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$')]
    [string]$Profile,

    [string]$ConfigPath,
    [string]$MonitorId,
    [switch]$PassThru,
    [switch]$SaveCurrentSettings,
    [string]$LogPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$commonPath = Join-Path $PSScriptRoot "MonitorTools.Common.ps1"
if (Test-Path -LiteralPath $commonPath) { . $commonPath }
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    if (Get-Command Get-MonitorToolsConfigPath -ErrorAction SilentlyContinue) { $ConfigPath = Get-MonitorToolsConfigPath -Root $PSScriptRoot }
    else { $ConfigPath = Join-Path $PSScriptRoot "monitor-profiles.json" }
}

try {
    & (Join-Path $PSScriptRoot "Switch-MonitorInput.ps1") -Profile $Profile `
        -ConfigPath $ConfigPath -MonitorId $MonitorId -PassThru:$PassThru `
        -SaveCurrentSettings:$SaveCurrentSettings -WhatIf:$WhatIfPreference
}
catch {
    $failure = $_
    try {
        if ([string]::IsNullOrWhiteSpace($LogPath)) {
            $LogPath = Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "Monitor Tools\last-error.log"
        }
        $logFile = [System.IO.Path]::GetFullPath($LogPath)
        [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($logFile))
        $details = @(
            "Time (UTC): $([DateTime]::UtcNow.ToString('o'))"
            "Profile: $Profile"
            "Configuration: $ConfigPath"
            "PowerShell: $($PSVersionTable.PSVersion)"
            "Error: $($failure.Exception.Message)"
            $failure.ScriptStackTrace
        ) -join [Environment]::NewLine
        # Log errors even when a preview fails. This never changes monitor settings.
        [System.IO.File]::WriteAllText($logFile, $details)
        Write-Warning "Profile '$Profile' failed. Details saved to '$logFile'."
    }
    catch {
        Write-Warning "Could not save the error log: $($_.Exception.Message)"
    }
    throw $failure
}
