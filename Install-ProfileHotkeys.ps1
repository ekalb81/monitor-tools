[CmdletBinding()]
param(
    [string]$ThisPcHotkey = "CTRL+ALT+1",
    [string]$OtherPcHotkey = "CTRL+ALT+2"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $PSCommandPath
$shortcutDirectory = Join-Path ([Environment]::GetFolderPath("Programs")) "Monitor Tools"
$powerShellPath = Join-Path $PSHOME "powershell.exe"
$wshShell = New-Object -ComObject WScript.Shell

New-Item -ItemType Directory -Force -Path $shortcutDirectory | Out-Null

function New-ProfileShortcut {
    param(
        [Parameter(Mandatory = $true)][string]$ShortcutName,
        [Parameter(Mandatory = $true)][string]$ProfileName,
        [Parameter(Mandatory = $true)][string]$Hotkey
    )

    $shortcutPath = Join-Path $shortcutDirectory "$ShortcutName.lnk"
    $shortcut = $wshShell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $powerShellPath
    $shortcut.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptRoot\Switch-MonitorInput.ps1`" -Profile $ProfileName"
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
