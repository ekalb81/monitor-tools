[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("this-pc", "other-pc")]
    [string]$Profile,

    [string]$ConfigPath,
    [switch]$SaveCurrentSettings,
    [string]$LogPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot "monitor-profiles.json"
}

try {
    & (Join-Path $PSScriptRoot "Switch-MonitorInput.ps1") -Profile $Profile `
        -ConfigPath $ConfigPath -SaveCurrentSettings:$SaveCurrentSettings -WhatIf:$WhatIfPreference
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
