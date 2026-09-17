[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ThisPcHotkey = "CTRL+ALT+1",
    [string]$OtherPcHotkey = "CTRL+ALT+2",
    [switch]$ForceLegacyHotkeys,
    [switch]$Uninstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $PSCommandPath
$shortcutDirectory = Join-Path ([Environment]::GetFolderPath("Programs")) "Monitor Tools"
if ($Uninstall) {
    foreach ($name in @("This PC Profile.lnk", "Other PC Profile.lnk")) {
        $shortcutPath = Join-Path $shortcutDirectory $name
        if ((Test-Path -LiteralPath $shortcutPath -PathType Leaf) -and $PSCmdlet.ShouldProcess($shortcutPath, "Remove profile hotkey")) {
            Remove-Item -LiteralPath $shortcutPath
        }
    }
    return
}

$trayPath = Join-Path $scriptRoot 'app\MonitorTools.exe'
if ((Test-Path -LiteralPath $trayPath -PathType Leaf) -and -not $ForceLegacyHotkeys) {
    throw 'MonitorTools.exe owns global hotkeys for this installation. Configure hotkeys in the tray app, or use -ForceLegacyHotkeys only when the tray is disabled.'
}

$powerShellPath = Join-Path ([Environment]::GetFolderPath("System")) "WindowsPowerShell\v1.0\powershell.exe"
if (-not (Test-Path -LiteralPath $powerShellPath -PathType Leaf)) {
    throw "Windows PowerShell executable was not found at '$powerShellPath'."
}
$wshShell = New-Object -ComObject WScript.Shell

New-Item -ItemType Directory -Force -Path $shortcutDirectory | Out-Null

function New-ProfileShortcut {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$ShortcutName,
        [Parameter(Mandatory = $true)][string]$ProfileName,
        [Parameter(Mandatory = $true)][string]$Hotkey
    )

    $shortcutPath = Join-Path $shortcutDirectory "$ShortcutName.lnk"
    if (-not $PSCmdlet.ShouldProcess($shortcutPath, "Install profile hotkey $Hotkey")) {
        return
    }
    $shortcut = $wshShell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $powerShellPath
    $shortcut.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptRoot\Run-Profile.ps1`" -Profile $ProfileName"
    $shortcut.WorkingDirectory = $scriptRoot
    $shortcut.Description = "Switch monitor inputs to the $ProfileName profile."
    $shortcut.IconLocation = "$powerShellPath,0"
    $shortcut.Hotkey = $Hotkey
    $shortcut.Save()

    [pscustomobject]@{
        Shortcut = $shortcutPath
        Profile  = $ProfileName
        Hotkey   = $Hotkey
    }
}

$results = @(
    (New-ProfileShortcut -ShortcutName "This PC Profile" -ProfileName "this-pc" -Hotkey $ThisPcHotkey),
    (New-ProfileShortcut -ShortcutName "Other PC Profile" -ProfileName "other-pc" -Hotkey $OtherPcHotkey)
)

$results | Format-Table -AutoSize
