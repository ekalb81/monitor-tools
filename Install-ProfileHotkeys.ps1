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
            if (-not ('MonitorToolsShortcutNotificationsV1' -as [type])) {
                Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class MonitorToolsShortcutNotificationsV1 {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern void SHChangeNotify(uint change, uint flags, string item, IntPtr unused);
    public static void Updated(string path) { SHChangeNotify(0x00002000, 0x00001005, path, IntPtr.Zero); }
    public static void Deleted(string path) { SHChangeNotify(0x00000004, 0x00001005, path, IntPtr.Zero); }
}
'@
            }
            # Let Explorer release its shortcut hotkey before the tray claims it.
            # Notify with SHCNF_PATHW | SHCNF_FLUSH so delivery is not merely queued.
            $shell = $null
            $shortcut = $null
            try {
                $shell = New-Object -ComObject WScript.Shell
                $shortcut = $shell.CreateShortcut($shortcutPath)
                $shortcut.Hotkey = ''
                $shortcut.Save()
                [MonitorToolsShortcutNotificationsV1]::Updated($shortcutPath)
            }
            finally {
                if ($null -ne $shortcut -and [Runtime.InteropServices.Marshal]::IsComObject($shortcut)) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) }
                if ($null -ne $shell -and [Runtime.InteropServices.Marshal]::IsComObject($shell)) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) }
            }
            Remove-Item -LiteralPath $shortcutPath
            [MonitorToolsShortcutNotificationsV1]::Deleted($shortcutPath)
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
