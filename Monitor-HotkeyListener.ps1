[CmdletBinding()]
param(
    [string]$ThisPcHotkey = "CTRL+ALT+1",
    [string]$OtherPcHotkey = "CTRL+ALT+2",
    [string]$LogPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms

$scriptRoot = Split-Path -Parent $PSCommandPath
$switchScriptPath = Join-Path $scriptRoot "Switch-MonitorInput.ps1"
$powerShellPath = Join-Path $PSHOME "powershell.exe"

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Join-Path $env:LOCALAPPDATA "MonitorTools\monitor-hotkeys.log"
}

if (-not (Test-Path -LiteralPath $switchScriptPath)) {
    throw "Switch script '$switchScriptPath' was not found."
}

$logDirectory = Split-Path -Parent $LogPath
if (-not [string]::IsNullOrWhiteSpace($logDirectory)) {
    New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
}

function Write-ListenerLog {
    param([Parameter(Mandatory = $true)][string]$Message)

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -LiteralPath $LogPath -Value "[$timestamp] $Message"
}

function ConvertTo-HotkeyRegistration {
    param([Parameter(Mandatory = $true)][string]$HotkeyText)

    $tokens = $HotkeyText.Split("+", [StringSplitOptions]::RemoveEmptyEntries) |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ }

    if ($tokens.Count -lt 2) {
        throw "Hotkey '$HotkeyText' must include at least one modifier and one key."
    }

    [uint32]$modifiers = 0
    [uint32]$virtualKey = 0
    $normalizedTokens = New-Object System.Collections.Generic.List[string]

    foreach ($token in $tokens) {
        $normalized = $token.ToUpperInvariant()

        if ($normalized -eq "ALT") {
            $modifiers = $modifiers -bor 0x0001
            [void]$normalizedTokens.Add("ALT")
            continue
        }

        if ($normalized -in @("CTRL", "CONTROL")) {
            $modifiers = $modifiers -bor 0x0002
            [void]$normalizedTokens.Add("CTRL")
            continue
        }

        if ($normalized -eq "SHIFT") {
            $modifiers = $modifiers -bor 0x0004
            [void]$normalizedTokens.Add("SHIFT")
            continue
        }

        if ($normalized -eq "WIN") {
            $modifiers = $modifiers -bor 0x0008
            [void]$normalizedTokens.Add("WIN")
            continue
        }

        if ($virtualKey -ne 0) {
            throw "Hotkey '$HotkeyText' can only contain one non-modifier key."
        }

        $keyName = switch -Regex ($normalized) {
            '^\d$' { "D$normalized"; break }
            '^[A-Z]$' { $normalized; break }
            '^F([1-9]|1[0-9]|2[0-4])$' { $normalized; break }
            default { $normalized }
        }

        try {
            $parsedKey = [System.Enum]::Parse([System.Windows.Forms.Keys], $keyName, $true)
        }
        catch {
            throw "Hotkey '$HotkeyText' contains unsupported key '$token'."
        }

        $virtualKey = [uint32]([int]$parsedKey)
        [void]$normalizedTokens.Add($normalized)
    }

    if ($modifiers -eq 0) {
        throw "Hotkey '$HotkeyText' must include at least one modifier such as CTRL or ALT."
    }

    if ($virtualKey -eq 0) {
        throw "Hotkey '$HotkeyText' must include a non-modifier key."
    }

    [pscustomobject]@{
        Display    = ($normalizedTokens -join "+")
        Modifiers  = $modifiers
        VirtualKey = $virtualKey
    }
}

if (-not ("MonitorHotkeyWindowV1" -as [type])) {
Add-Type -ReferencedAssemblies "System.Windows.Forms.dll" -Language CSharp -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public sealed class MonitorHotkeyWindowV1 : Form
{
    public event Action<int> HotkeyPressed;
    public const int WM_HOTKEY = 0x0312;

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    public MonitorHotkeyWindowV1()
    {
        ShowInTaskbar = false;
        FormBorderStyle = FormBorderStyle.FixedToolWindow;
        WindowState = FormWindowState.Minimized;
        Opacity = 0;
    }

    protected override void SetVisibleCore(bool value)
    {
        base.SetVisibleCore(false);
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_HOTKEY && HotkeyPressed != null)
        {
            HotkeyPressed(m.WParam.ToInt32());
        }

        base.WndProc(ref m);
    }
}
"@
}

$mutexName = "Local\MonitorToolsHotkeyListener"
$mutex = New-Object System.Threading.Mutex($false, $mutexName)
$hasMutex = $false
$window = $null
$handler = $null
$registeredHotkeys = @()

try {
    $hasMutex = $mutex.WaitOne(0, $false)
    if (-not $hasMutex) {
        Write-ListenerLog "Another listener instance is already running. Exiting."
        return
    }

    $thisPcRegistration = ConvertTo-HotkeyRegistration -HotkeyText $ThisPcHotkey
    $otherPcRegistration = ConvertTo-HotkeyRegistration -HotkeyText $OtherPcHotkey

    $window = New-Object MonitorHotkeyWindowV1
    $null = $window.Handle

    $hotkeyMap = @{
        1 = [pscustomobject]@{
            Registration = $thisPcRegistration
            Profile      = "this-pc"
        }
        2 = [pscustomobject]@{
            Registration = $otherPcRegistration
            Profile      = "other-pc"
        }
    }

    foreach ($entry in $hotkeyMap.GetEnumerator()) {
        $id = [int]$entry.Key
        $registration = $entry.Value.Registration
        if (-not [MonitorHotkeyWindowV1]::RegisterHotKey($window.Handle, $id, $registration.Modifiers, $registration.VirtualKey)) {
            $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            throw "Failed to register hotkey '$($registration.Display)'. Win32 error: $errorCode"
        }

        $registeredHotkeys += $id
    }

    $handler = [System.Action[int]]{
        param([int]$Id)

        $mapping = $hotkeyMap[$Id]
        if ($null -eq $mapping) {
            return
        }

        $arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$switchScriptPath`" -Profile $($mapping.Profile)"
        Write-ListenerLog "Launching profile '$($mapping.Profile)' from hotkey '$($mapping.Registration.Display)'."

        try {
            $process = Start-Process -FilePath $powerShellPath -ArgumentList $arguments -WorkingDirectory $scriptRoot -WindowStyle Hidden -PassThru
            Write-ListenerLog "Started PID $($process.Id) for profile '$($mapping.Profile)'."
        }
        catch {
            Write-ListenerLog "Launch failed for profile '$($mapping.Profile)': $($_.Exception.Message)"
        }
    }

    $window.add_HotkeyPressed($handler)

    Write-ListenerLog "Listener active. this-pc=$($thisPcRegistration.Display), other-pc=$($otherPcRegistration.Display)."
    [System.Windows.Forms.Application]::Run($window)
}
finally {
    if ($null -ne $window -and $null -ne $handler) {
        $window.remove_HotkeyPressed($handler)
    }

    foreach ($id in $registeredHotkeys) {
        if ($null -ne $window) {
            [MonitorHotkeyWindowV1]::UnregisterHotKey($window.Handle, $id) | Out-Null
        }
    }

    if ($null -ne $window) {
        $window.Dispose()
    }

    if ($hasMutex) {
        $mutex.ReleaseMutex()
    }

    $mutex.Dispose()
}
