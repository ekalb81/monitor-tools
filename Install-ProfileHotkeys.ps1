[CmdletBinding()]
param(
    [string]$ThisPcHotkey = "CTRL+ALT+1",
    [string]$OtherPcHotkey = "CTRL+ALT+2"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $PSCommandPath
$shortcutDirectory = Join-Path ([Environment]::GetFolderPath("Programs")) "Monitor Tools"
$startupDirectory = [Environment]::GetFolderPath("Startup")
$powerShellPath = Join-Path $PSHOME "powershell.exe"
$switchScriptPath = Join-Path $scriptRoot "Switch-MonitorInput.ps1"
$listenerScriptPath = Join-Path $scriptRoot "Monitor-HotkeyListener.ps1"
$wshShell = New-Object -ComObject WScript.Shell

New-Item -ItemType Directory -Force -Path $shortcutDirectory | Out-Null
New-Item -ItemType Directory -Force -Path $startupDirectory | Out-Null

function New-Shortcut {
    param(
        [Parameter(Mandatory = $true)][string]$DirectoryPath,
        [Parameter(Mandatory = $true)][string]$ShortcutName,
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [Parameter(Mandatory = $true)][string]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$Description,
        [string]$Hotkey = ""
    )

    $shortcutPath = Join-Path $DirectoryPath "$ShortcutName.lnk"
    $shortcut = $wshShell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $TargetPath
    $shortcut.Arguments = $Arguments
    $shortcut.WorkingDirectory = $WorkingDirectory
    $shortcut.Description = $Description
    $shortcut.IconLocation = "$powerShellPath,0"
    $shortcut.Hotkey = $Hotkey
    $shortcut.Save()

    [pscustomobject]@{
        Shortcut = $shortcutPath
        Target   = $TargetPath
        Hotkey   = $Hotkey
    }
}

function Get-ListenerProcesses {
    $listenerPattern = [regex]::Escape($listenerScriptPath)
    Get-CimInstance Win32_Process |
        Where-Object {
            $_.Name -ieq "powershell.exe" -and
            $_.CommandLine -match $listenerPattern
        }
}

function Stop-ListenerProcesses {
    $stoppedIds = @()
    foreach ($process in Get-ListenerProcesses) {
        Stop-Process -Id $process.ProcessId -Force
        $stoppedIds += $process.ProcessId
    }

    return ,@($stoppedIds)
}

$switchThisPcArguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$switchScriptPath`" -Profile this-pc"
$switchOtherPcArguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$switchScriptPath`" -Profile other-pc"
$listenerArguments = "-NoProfile -Sta -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$listenerScriptPath`" -ThisPcHotkey `"$ThisPcHotkey`" -OtherPcHotkey `"$OtherPcHotkey`""

$results = @(
    (New-Shortcut -DirectoryPath $shortcutDirectory -ShortcutName "This PC Profile" -TargetPath $powerShellPath -Arguments $switchThisPcArguments -WorkingDirectory $scriptRoot -Description "Switch monitor inputs to the this-pc profile."),
    (New-Shortcut -DirectoryPath $shortcutDirectory -ShortcutName "Other PC Profile" -TargetPath $powerShellPath -Arguments $switchOtherPcArguments -WorkingDirectory $scriptRoot -Description "Switch monitor inputs to the other-pc profile."),
    (New-Shortcut -DirectoryPath $shortcutDirectory -ShortcutName "Monitor Hotkeys" -TargetPath $powerShellPath -Arguments $listenerArguments -WorkingDirectory $scriptRoot -Description "Run the background monitor hotkey listener."),
    (New-Shortcut -DirectoryPath $startupDirectory -ShortcutName "Monitor Hotkeys" -TargetPath $powerShellPath -Arguments $listenerArguments -WorkingDirectory $scriptRoot -Description "Run the background monitor hotkey listener at sign-in.")
)

$stoppedIds = Stop-ListenerProcesses
$listenerProcess = Start-Process -FilePath $powerShellPath -ArgumentList $listenerArguments -WorkingDirectory $scriptRoot -WindowStyle Hidden -PassThru

$results += [pscustomobject]@{
    Shortcut = "listener-process"
    Target   = $listenerProcess.Id
    Hotkey   = "this-pc=$ThisPcHotkey, other-pc=$OtherPcHotkey"
}

$results | Format-Table -AutoSize

if ($stoppedIds.Count -gt 0) {
    Write-Host "Restarted listener. Stopped old PID(s): $($stoppedIds -join ', ')"
}
