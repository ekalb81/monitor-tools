[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = "List")]
param(
    [Parameter(ParameterSetName = "List")][switch]$List,
    [Parameter(ParameterSetName = "List")][switch]$IncludeCapabilities,
    [Parameter(ParameterSetName = "SetAll", Mandatory = $true)][string]$SetAll,
    [Parameter(ParameterSetName = "SetMonitor", Mandatory = $true, Position = 0, ValueFromRemainingArguments = $true)][string[]]$SetMonitor,
    [Parameter(ParameterSetName = "Profile", Mandatory = $true)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$')][string]$Profile,
    [Parameter(ParameterSetName = "Profile")][string]$MonitorId,
    [Parameter(ParameterSetName = "Test", Mandatory = $true)][string]$TestMonitor,
    [Parameter(ParameterSetName = "Test", Mandatory = $true)][string]$TestInput,
    [Parameter(ParameterSetName = "Test", Mandatory = $true)][string]$ReturnInput,
    [Parameter(ParameterSetName = "Test")]
    [Parameter(ParameterSetName = "TestProfile")][ValidateRange(3, 30)][int]$ReturnAfterSeconds = 5,
    [Parameter(ParameterSetName = "TestProfile", Mandatory = $true)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$')][string]$TestProfile,
    [Parameter(ParameterSetName = "TestProfile", Mandatory = $true)][ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$')][string]$ReturnProfile,
    [Parameter(ParameterSetName = "List")]
    [Parameter(ParameterSetName = "SetAll")]
    [Parameter(ParameterSetName = "SetMonitor")]
    [Parameter(ParameterSetName = "Profile")]
    [Parameter(ParameterSetName = "Test")]
    [Parameter(ParameterSetName = "TestProfile")][switch]$PassThru,
    [Parameter(ParameterSetName = "SetAll")]
    [Parameter(ParameterSetName = "SetMonitor")]
    [Parameter(ParameterSetName = "Profile")][switch]$SaveCurrentSettings,
    [ValidateRange(1, 30)][int]$MutexWaitSeconds = 10,
    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$commonPath = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) { $null } else { Join-Path $PSScriptRoot "MonitorTools.Common.ps1" }
if ($null -ne $commonPath -and (Test-Path -LiteralPath $commonPath)) { . $commonPath }
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    if (Get-Command Get-MonitorToolsConfigPath -ErrorAction SilentlyContinue) { $ConfigPath = Get-MonitorToolsConfigPath -Root $PSScriptRoot }
    else { $ConfigPath = Join-Path $PSScriptRoot "monitor-profiles.json" }
}

$script:InputAliases = @{
    "vga1" = 0x01; "dvi1" = 0x03; "dvi2" = 0x04
    "dp1" = 0x0F; "displayport" = 0x0F; "displayport1" = 0x0F
    "dp2" = 0x10; "displayport2" = 0x10; "hdmi" = 0x11; "hdmi1" = 0x11; "hdmi2" = 0x12
}
$script:PrimaryInputNames = @{ 0x01 = "vga1"; 0x03 = "dvi1"; 0x04 = "dvi2"; 0x0F = "displayport1"; 0x10 = "displayport2"; 0x11 = "hdmi1"; 0x12 = "hdmi2" }

if (-not ("DdcCiNativeV3" -as [type])) {
Add-Type -Language CSharp -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class DdcCiNativeV3
{
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)] public struct MONITORINFOEX
    {
        public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)] public struct PHYSICAL_MONITOR
    {
        public IntPtr hPhysicalMonitor;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szPhysicalMonitorDescription;
    }
    public delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdcMonitor, IntPtr lprcMonitor, IntPtr dwData);
    [DllImport("user32.dll")] public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc callback, IntPtr data);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFOEX monitorInfo);
    [DllImport("dxva2.dll", SetLastError = true)] public static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, out uint count);
    [DllImport("dxva2.dll", SetLastError = true)] public static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, uint count, [Out] PHYSICAL_MONITOR[] monitors);
    [DllImport("dxva2.dll", SetLastError = true)] public static extern bool DestroyPhysicalMonitor(IntPtr hMonitor);
    [DllImport("dxva2.dll", SetLastError = true)] public static extern bool GetCapabilitiesStringLength(IntPtr hMonitor, out uint length);
    [DllImport("dxva2.dll", SetLastError = true, CharSet = CharSet.Ansi)] public static extern bool CapabilitiesRequestAndCapabilitiesReply(IntPtr hMonitor, StringBuilder text, uint length);
    [DllImport("dxva2.dll", SetLastError = true)] public static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr hMonitor, byte code, out uint type, out uint current, out uint maximum);
    [ThreadStatic] static int lastError;
    [DllImport("dxva2.dll", EntryPoint = "SetVCPFeature", SetLastError = true)] static extern bool SetVCPFeatureNative(IntPtr hMonitor, byte code, uint value);
    [DllImport("dxva2.dll", EntryPoint = "SaveCurrentSettings", SetLastError = true)] static extern bool SaveCurrentSettingsNative(IntPtr hMonitor);
    public static bool SetVCPFeature(IntPtr hMonitor, byte code, uint value)
    {
        bool result = SetVCPFeatureNative(hMonitor, code, value);
        lastError = result ? 0 : Marshal.GetLastWin32Error();
        return result;
    }
    public static bool SaveCurrentSettings(IntPtr hMonitor)
    {
        bool result = SaveCurrentSettingsNative(hMonitor);
        lastError = result ? 0 : Marshal.GetLastWin32Error();
        return result;
    }
    public static int GetLastError() { return lastError; }
}
"@
}

# Identity discovery is separate from the DDC boundary so tests can replace it independently.
if (-not ("MonitorIdentityNativeV1" -as [type])) {
Add-Type -Language CSharp -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32;
using System.Text;
public static class MonitorIdentityNativeV1
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct DISPLAY_DEVICE
    {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }
    public sealed class IdentityInfo
    {
        public string Manufacturer, ProductCode, Model, Serial, DevicePath, IdentityStatus, StableMaterial;
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplayDevices(string device, uint number, ref DISPLAY_DEVICE display, uint flags);
    static string TextDescriptor(byte[] edid, byte tag)
    {
        if (edid == null) return null;
        for (int offset = 54; offset + 17 < edid.Length && offset < 126; offset += 18)
            if (edid[offset] == 0 && edid[offset + 1] == 0 && edid[offset + 2] == 0 && edid[offset + 3] == tag)
                return Encoding.ASCII.GetString(edid, offset + 5, 13).Trim('\0', ' ', '\r', '\n');
        return null;
    }
    static byte[] FindEdid(string hardwareId, string instanceId)
    {
        if (String.IsNullOrEmpty(hardwareId)) return null;
        try
        {
            using (RegistryKey root = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Enum\DISPLAY\" + hardwareId))
            {
                if (root == null) return null;
                if (String.IsNullOrWhiteSpace(instanceId)) return null;
                foreach (string instance in root.GetSubKeyNames())
                {
                    if (!String.Equals(instance, instanceId, StringComparison.OrdinalIgnoreCase)) continue;
                    using (RegistryKey parameters = root.OpenSubKey(instance + @"\Device Parameters"))
                    {
                        byte[] value = parameters == null ? null : parameters.GetValue("EDID") as byte[];
                        if (value != null && value.Length >= 18) return value;
                    }
                }
            }
        }
        catch { }
        return null;
    }
    public static bool ParseDeviceInterface(string deviceId, out string hardwareId, out string instanceId)
    {
        hardwareId = null; instanceId = null;
        if (String.IsNullOrWhiteSpace(deviceId)) return false;
        string[] parts = deviceId.Split('#');
        if (parts.Length < 3 || !parts[0].EndsWith("DISPLAY", StringComparison.OrdinalIgnoreCase)) return false;
        hardwareId = parts[1]; instanceId = parts[2];
        return !String.IsNullOrWhiteSpace(hardwareId) && !String.IsNullOrWhiteSpace(instanceId);
    }
    public static IdentityInfo DecodeEdid(byte[] edid, string path, string displayDevice, string description)
    {
        string manufacturer = null, product = null, serial = null, model = null;
        if (edid != null && edid.Length >= 18)
        {
            int word = (edid[8] << 8) | edid[9];
            manufacturer = new String(new [] { (char)(((word >> 10) & 31) + 64), (char)(((word >> 5) & 31) + 64), (char)((word & 31) + 64) });
            product = ((int)(edid[10] | (edid[11] << 8))).ToString("X4");
            model = TextDescriptor(edid, 0xFC); serial = TextDescriptor(edid, 0xFF);
            if (String.IsNullOrWhiteSpace(serial))
            {
                uint numeric = (uint)(edid[12] | (edid[13] << 8) | (edid[14] << 16) | (edid[15] << 24));
                if (numeric != 0) serial = numeric.ToString();
            }
        }
        if (String.IsNullOrWhiteSpace(model)) model = description;
        bool hasSerial = !String.IsNullOrWhiteSpace(serial);
        string stable = hasSerial ? String.Join("|", new [] { manufacturer ?? "", product ?? "", serial })
            : (!String.IsNullOrWhiteSpace(path) ? path : String.Join("|", new [] { displayDevice ?? "", description ?? "" }));
        return new IdentityInfo { Manufacturer = manufacturer, ProductCode = product, Model = model, Serial = serial, DevicePath = path,
            IdentityStatus = hasSerial ? "edid-serial" : "connection-fallback", StableMaterial = stable.ToLowerInvariant() };
    }
    public static IdentityInfo GetIdentity(string displayDevice, string description)
    {
        DISPLAY_DEVICE device = new DISPLAY_DEVICE(); device.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
        bool found = EnumDisplayDevices(displayDevice, 0, ref device, 1);
        string path = found && !String.IsNullOrWhiteSpace(device.DeviceID) ? device.DeviceID : displayDevice;
        string hardwareId, instanceId;
        ParseDeviceInterface(device.DeviceID, out hardwareId, out instanceId);
        byte[] edid = FindEdid(hardwareId, instanceId);
        string friendly = found && !String.IsNullOrWhiteSpace(device.DeviceString) ? device.DeviceString : description;
        return DecodeEdid(edid, path, displayDevice, friendly);
    }
}
"@
}

function Get-JsonPropertyValue {
    param($Object, [Parameter(Mandatory = $true)][string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}
function Get-StableId {
    param([Parameter(Mandatory = $true)][string]$Material)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Material)); return "id-$(([BitConverter]::ToString($hash, 0, 10)).Replace('-', '').ToLowerInvariant())" }
    finally { $sha.Dispose() }
}
function Get-PrimaryInputName {
    param([int]$Code)
    if ($script:PrimaryInputNames.ContainsKey($Code)) { return $script:PrimaryInputNames[$Code] }
    return ("0x{0:X2}" -f $Code)
}
function Resolve-InputCode {
    param([Parameter(Mandatory = $true)][string]$InputName)
    if ($InputName -match '^\s*0x([0-9a-fA-F]{1,2})\s*$') { return [Convert]::ToByte($Matches[1], 16) }
    if ($InputName -match '^\s*(\d{1,3})\s*$') {
        $value = [int]$Matches[1]
        if ($value -lt 0 -or $value -gt 255) { throw "Numeric input source values must be between 0 and 255." }
        return [byte]$value
    }
    $normalized = $InputName.Trim().ToLowerInvariant()
    if (-not $script:InputAliases.ContainsKey($normalized)) {
        $valid = ($script:InputAliases.Keys | Sort-Object -Unique) -join ", "
        throw "Unknown input source '$InputName'. Use one of: $valid, a decimal value, or a hex value like 0x11."
    }
    return [byte]$script:InputAliases[$normalized]
}
function Get-PositionLabels {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Inventory)
    $ordered = @($Inventory | Sort-Object @{ Expression = { $_.MonitorLeft } }, @{ Expression = { $_.MonitorTop } }, @{ Expression = { $_.Index } })
    if ($ordered.Count -eq 1) { return @{ $ordered[0].Index = "center" } }
    if ($ordered.Count -eq 2) { return @{ $ordered[0].Index = "left"; $ordered[1].Index = "right" } }
    if ($ordered.Count -eq 3) { return @{ $ordered[0].Index = "left"; $ordered[1].Index = "center"; $ordered[2].Index = "right" } }
    $labels = @{}; for ($i = 0; $i -lt $ordered.Count; $i++) { $labels[$ordered[$i].Index] = "position-$($i + 1)" }; return $labels
}
function Get-AdvertisedInputs {
    param([string]$Capabilities)
    if ([string]::IsNullOrWhiteSpace($Capabilities)) { return @() }
    $match = [regex]::Match($Capabilities, '60\(([^)]*)\)', 'IgnoreCase'); if (-not $match.Success) { return @() }
    return @($match.Groups[1].Value -split '\s+' | Where-Object { $_ } | ForEach-Object { Get-PrimaryInputName -Code ([Convert]::ToInt32($_, 16)) })
}
function Get-CapabilitiesString {
    param([IntPtr]$Handle)
    [uint32]$length = 0
    if (-not [DdcCiNativeV3]::GetCapabilitiesStringLength($Handle, [ref]$length) -or $length -le 0 -or $length -gt 65536) { return $null }
    $buffer = New-Object Text.StringBuilder ([int]$length)
    if (-not [DdcCiNativeV3]::CapabilitiesRequestAndCapabilitiesReply($Handle, $buffer, $length)) { return $null }
    return $buffer.ToString()
}
function Get-VcpValue {
    param([IntPtr]$Handle, [byte]$Code)
    [uint32]$type = 0; [uint32]$current = 0; [uint32]$maximum = 0
    if (-not [DdcCiNativeV3]::GetVCPFeatureAndVCPFeatureReply($Handle, $Code, [ref]$type, [ref]$current, [ref]$maximum)) { return $null }
    return [pscustomobject]@{ FeatureType = $type; Current = $current; Maximum = $maximum }
}
function Get-PhysicalMonitorInventory {
    param([switch]$IncludeCapabilities, [switch]$IncludeCurrentInput)
    $handles = New-Object Collections.Generic.List[object]
    $callback = [DdcCiNativeV3+MonitorEnumProc]{
        param($hMonitor, $hdcMonitor, $lprcMonitor, $dwData)
        $info = New-Object DdcCiNativeV3+MONITORINFOEX; $info.cbSize = [Runtime.InteropServices.Marshal]::SizeOf([type][DdcCiNativeV3+MONITORINFOEX])
        $hasInfo = [DdcCiNativeV3]::GetMonitorInfo($hMonitor, [ref]$info); [uint32]$count = 0
        if ([DdcCiNativeV3]::GetNumberOfPhysicalMonitorsFromHMONITOR($hMonitor, [ref]$count) -and $count -gt 0) {
            $physical = New-Object "DdcCiNativeV3+PHYSICAL_MONITOR[]" $count
            if ([DdcCiNativeV3]::GetPhysicalMonitorsFromHMONITOR($hMonitor, $count, $physical)) {
                foreach ($item in $physical) { [void]$handles.Add([pscustomobject]@{
                    PhysicalMonitor = $item; DisplayDevice = if ($hasInfo) { $info.szDevice } else { $null }
                    MonitorLeft = if ($hasInfo) { $info.rcMonitor.Left } else { 0 }; MonitorTop = if ($hasInfo) { $info.rcMonitor.Top } else { 0 }
                    MonitorRight = if ($hasInfo) { $info.rcMonitor.Right } else { 0 }; MonitorBottom = if ($hasInfo) { $info.rcMonitor.Bottom } else { 0 }
                }) }
            }
        }
        return $true
    }
    try {
        [DdcCiNativeV3]::EnumDisplayMonitors([IntPtr]::Zero, [IntPtr]::Zero, $callback, [IntPtr]::Zero) | Out-Null
        $index = 1
        $inventory = @(foreach ($monitor in $handles) {
            $description = $monitor.PhysicalMonitor.szPhysicalMonitorDescription; $identity = [MonitorIdentityNativeV1]::GetIdentity($monitor.DisplayDevice, $description)
            $capabilities = if ($IncludeCapabilities) { Get-CapabilitiesString $monitor.PhysicalMonitor.hPhysicalMonitor } else { $null }
            $input = if ($IncludeCurrentInput) { Get-VcpValue $monitor.PhysicalMonitor.hPhysicalMonitor 0x60 } else { $null }
            [pscustomobject]@{
                Index = $index; Position = $null; StableId = Get-StableId $identity.StableMaterial; IdentityStatus = $identity.IdentityStatus
                Manufacturer = $identity.Manufacturer; ProductCode = $identity.ProductCode; Model = $identity.Model; Serial = $identity.Serial; DevicePath = $identity.DevicePath
                Description = $description; DisplayDevice = $monitor.DisplayDevice; MonitorLeft = $monitor.MonitorLeft; MonitorTop = $monitor.MonitorTop
                MonitorRight = $monitor.MonitorRight; MonitorBottom = $monitor.MonitorBottom; Handle = $monitor.PhysicalMonitor.hPhysicalMonitor
                Capabilities = $capabilities; AdvertisedInputs = if ($IncludeCapabilities) { @(Get-AdvertisedInputs $capabilities) } else { @() }
                CurrentInputCode = if ($null -ne $input) { [int]$input.Current } else { $null }; CurrentInputHex = if ($null -ne $input) { "0x{0:X2}" -f [int]$input.Current } else { $null }
                CurrentInputName = if ($null -ne $input) { Get-PrimaryInputName ([int]$input.Current) } else { $null }
            }; $index++
        })
        $labels = Get-PositionLabels $inventory; foreach ($monitor in $inventory) { $monitor.Position = $labels[$monitor.Index] }
        foreach ($group in @($inventory | Group-Object StableId | Where-Object Count -gt 1)) { foreach ($monitor in $group.Group) { $monitor.IdentityStatus = "ambiguous" } }
        return ,$inventory
    }
    catch { foreach ($monitor in $handles) { [DdcCiNativeV3]::DestroyPhysicalMonitor($monitor.PhysicalMonitor.hPhysicalMonitor) | Out-Null }; throw }
}
function Close-PhysicalMonitorInventory {
    param([object[]]$Inventory)
    foreach ($monitor in $Inventory) { if ($null -ne $monitor.Handle -and $monitor.Handle -ne [IntPtr]::Zero) { [DdcCiNativeV3]::DestroyPhysicalMonitor($monitor.Handle) | Out-Null } }
}
function Resolve-MonitorTarget {
    param([object[]]$Inventory, [Parameter(Mandatory = $true)][string]$Target)
    $matches = @($Inventory | Where-Object { $_.StableId -ieq $Target })
    if ($matches.Count -eq 0 -and $Target -match '^\d+$') { $matches = @($Inventory | Where-Object { $_.Index -eq [int]$Target }) }
    if ($matches.Count -eq 0) { $matches = @($Inventory | Where-Object { $_.Position -ieq $Target }) }
    if ($matches.Count -eq 0) { throw "Monitor target '$Target' was not found. Run with -List -PassThru to see active stable IDs, indexes, and positions." }
    if ($matches.Count -gt 1 -or $matches[0].IdentityStatus -eq "ambiguous") { throw "Monitor target '$Target' is ambiguous. Reconnect or rebind the monitor before switching; no writes were attempted." }
    return $matches[0]
}
function ConvertTo-Percent {
    param($Value, [string]$Name)
    [int]$number = 0
    if ($null -eq $Value -or -not [int]::TryParse([string]$Value, [ref]$number) -or $number -lt 0 -or $number -gt 100) { throw "$Name must be a whole number from 0 through 100." }
    return $number
}
function Get-AssignmentsFromProfile {
    param([string]$SelectedProfile, [string]$SelectedConfigPath)
    if (-not (Test-Path -LiteralPath $SelectedConfigPath -PathType Leaf)) { throw "Profile file '$SelectedConfigPath' was not found." }
    $config = if (Get-Command Read-MonitorToolsConfig -ErrorAction SilentlyContinue) { Read-MonitorToolsConfig -Path $SelectedConfigPath }
        else { Get-Content -LiteralPath $SelectedConfigPath -Raw | ConvertFrom-Json }
    $profiles = Get-JsonPropertyValue $config "profiles"
    if ($null -eq $profiles) { throw "Profile file '$SelectedConfigPath' does not contain a 'profiles' object." }
    $settings = Get-JsonPropertyValue $profiles $SelectedProfile
    if ($null -eq $settings) { throw "Profile '$SelectedProfile' was not found. Available profiles: $($profiles.PSObject.Properties.Name -join ', ')" }
    return ,@(foreach ($property in $settings.PSObject.Properties) {
        $input = $null; $brightness = $null; $volume = $null
        if ($property.Value -is [string] -or $property.Value -is [ValueType]) { $input = [string]$property.Value }
        else {
            foreach ($name in $property.Value.PSObject.Properties.Name) { if (@("input", "brightness", "volume") -notcontains $name) { throw "Profile '$SelectedProfile' monitor '$($property.Name)' has unknown scene setting '$name'." } }
            $input = Get-JsonPropertyValue $property.Value "input"; $brightness = Get-JsonPropertyValue $property.Value "brightness"; $volume = Get-JsonPropertyValue $property.Value "volume"
            if ($null -eq $input -and $null -eq $brightness -and $null -eq $volume) { throw "Profile '$SelectedProfile' monitor '$($property.Name)' has an empty scene." }
        }
        [pscustomobject]@{ Target = [string]$property.Name; Input = $input; Brightness = $brightness; Volume = $volume }
    })
}
function Get-AssignmentsFromArguments {
    param([string[]]$Entries)
    return ,@(foreach ($entry in $Entries) {
        if ($entry -notmatch '^\s*(all|[\w-]+)\s*=\s*(.+?)\s*$') { throw "Invalid assignment '$entry'. Use values like 'all=hdmi1', '2=displayport1', or 'id-abcd=hdmi1'." }
        [pscustomobject]@{ Target = $Matches[1]; Input = $Matches[2]; Brightness = $null; Volume = $null }
    })
}
function New-MonitorPlan {
    param([object[]]$Inventory, [object[]]$Assignments, [string]$FilterMonitorId)
    $filterMonitor = $null
    if (-not [string]::IsNullOrWhiteSpace($FilterMonitorId)) { $filterMonitor = Resolve-MonitorTarget $Inventory $FilterMonitorId }
    $resolved = @(foreach ($assignment in $Assignments) {
        if ($null -ne $filterMonitor -and $assignment.Target -ne "all" -and
            $assignment.Target -ine $filterMonitor.StableId -and $assignment.Target -ine [string]$filterMonitor.Index -and
            $assignment.Target -ine $filterMonitor.Position) { continue }
        $targets = if ($assignment.Target -eq "all") { if ($null -ne $filterMonitor) { @($filterMonitor) } else { $Inventory } }
            else { @(Resolve-MonitorTarget $Inventory $assignment.Target) }
        foreach ($monitor in $targets) { [pscustomobject]@{ Monitor = $monitor; Assignment = $assignment } }
    })
    if ($null -ne $filterMonitor -and $resolved.Count -eq 0) { throw "Monitor '$FilterMonitorId' is not included in profile '$Profile'." }
    foreach ($item in $resolved) {
        if ($item.Monitor.IdentityStatus -eq "ambiguous") { throw "Monitor target '$($item.Monitor.StableId)' is ambiguous. Reconnect or rebind the monitor before switching; no writes were attempted." }
    }
    $plan = New-Object Collections.Generic.List[object]
    foreach ($item in $resolved) {
        $monitor = $item.Monitor; $assignment = $item.Assignment
        if ($null -ne $assignment.Input -and -not [string]::IsNullOrWhiteSpace([string]$assignment.Input)) {
            $code = Resolve-InputCode ([string]$assignment.Input)
            $plan.Add([pscustomobject]@{ Monitor = $monitor; Feature = "input"; VcpCode = [byte]0x60; RawValue = [uint32]$code; Requested = Get-PrimaryInputName ([int]$code); RequestedCode = "0x{0:X2}" -f [int]$code })
        }
        foreach ($scene in @(@{ Name = "brightness"; Code = [byte]0x10; Value = $assignment.Brightness }, @{ Name = "volume"; Code = [byte]0x62; Value = $assignment.Volume })) {
            if ($null -ne $scene.Value) {
                $percent = ConvertTo-Percent $scene.Value $scene.Name; $range = Get-VcpValue $monitor.Handle $scene.Code
                if ($null -eq $range -or $range.Maximum -le 0) { throw "Monitor '$($monitor.StableId)' does not report a usable $($scene.Name) range; no writes were attempted." }
                $raw = [uint32][Math]::Round(([double]$range.Maximum * $percent) / 100.0)
                $plan.Add([pscustomobject]@{ Monitor = $monitor; Feature = $scene.Name; VcpCode = $scene.Code; RawValue = $raw; Requested = "$percent%"; RequestedCode = "$raw/$($range.Maximum)" })
            }
        }
    }
    return ,($plan.ToArray())
}
function Test-TransientDdcError { param([int]$ErrorCode) return @(21, 121, 170, 1460) -contains $ErrorCode }
function Invoke-DdcFeatureWrite {
    param($Operation, [string]$OperationId, [string]$Phase = "Apply")
    $monitor = $Operation.Monitor
    $result = [ordered]@{ OperationId = $OperationId; Phase = $Phase; StableId = $monitor.StableId; IdentityStatus = $monitor.IdentityStatus
        Index = $monitor.Index; Position = $monitor.Position; Model = $monitor.Model; Description = $monitor.Description; Feature = $Operation.Feature
        Requested = $Operation.Requested; RequestedCode = $Operation.RequestedCode; Status = "Preview"; ApiAccepted = $false; PhysicalVerified = $false
        Saved = $false; AttemptCount = 0; Error = $null }
    $action = "set $($Operation.Feature) on monitor $($monitor.Index) ($($monitor.Position)) [$($monitor.StableId)] to $($Operation.Requested)"
    if (-not $PSCmdlet.ShouldProcess($monitor.Description, $action)) { return [pscustomobject]$result }
    $errorCode = 0
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $result.AttemptCount = $attempt
        if ([DdcCiNativeV3]::SetVCPFeature($monitor.Handle, $Operation.VcpCode, $Operation.RawValue)) { $result.Status = "Accepted"; $result.ApiAccepted = $true; return [pscustomobject]$result }
        $errorCode = [DdcCiNativeV3]::GetLastError()
        if ($attempt -ge 3 -or -not (Test-TransientDdcError $errorCode)) { break }
        Start-Sleep -Milliseconds @(100, 250)[$attempt - 1]
    }
    $result.Status = "Failed"
    $result.Error = if ($Operation.Feature -eq "input") { "Failed to set input on monitor $($monitor.Index) [$($monitor.Description)] ($($monitor.StableId)). Win32 error: $errorCode" }
        else { "Failed to set $($Operation.Feature) on monitor $($monitor.Index) [$($monitor.Description)] ($($monitor.StableId)). Win32 error: $errorCode" }
    return [pscustomobject]$result
}
function Invoke-MonitorPlan {
    param([object[]]$Plan, [string]$OperationId, [string]$Phase = "Apply")
    $results = @(foreach ($operation in $Plan) { Invoke-DdcFeatureWrite $operation $OperationId $Phase }); $errors = New-Object Collections.Generic.List[string]
    foreach ($failed in @($results | Where-Object Status -in @("Failed", "SaveFailed"))) { $errors.Add($failed.Error) }
    if ($SaveCurrentSettings -and $Phase -eq "Apply") {
        foreach ($group in @($results | Group-Object StableId)) {
            $accepted = @($group.Group | Where-Object ApiAccepted); $failed = @($group.Group | Where-Object Status -eq "Failed")
            if ($accepted.Count -eq 0 -or $failed.Count -gt 0) { continue }
            $monitor = @($Plan | Where-Object { $_.Monitor.StableId -eq $group.Name })[0].Monitor
            if ([DdcCiNativeV3]::SaveCurrentSettings($monitor.Handle)) { foreach ($row in $accepted) { $row.Saved = $true } }
            else {
                $errorCode = [DdcCiNativeV3]::GetLastError(); $message = "Writes were accepted on monitor $($monitor.StableId), but saving current settings failed. Win32 error: $errorCode"
                foreach ($row in $accepted) { $row.Status = "SaveFailed"; $row.Error = $message }; $errors.Add($message)
            }
        }
    }
    return [pscustomobject]@{ Results = $results; Errors = $errors.ToArray() }
}
function New-SingleInputPlan {
    param($Monitor, [string]$InputName)
    $code = Resolve-InputCode $InputName
    return ,@([pscustomobject]@{ Monitor = $Monitor; Feature = "input"; VcpCode = [byte]0x60; RawValue = [uint32]$code; Requested = Get-PrimaryInputName ([int]$code); RequestedCode = "0x{0:X2}" -f [int]$code })
}
function Write-ResultOutput {
    param([object[]]$Results)
    if ($PassThru) { $Results } else { $Results | Format-Table Index, Position, StableId, Feature, Requested, Status, ApiAccepted, Saved -AutoSize }
}
function Get-MutexName {
    $identity = try { [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { [Environment]::UserName }
    return "Local\MonitorTools.Switch.$((Get-StableId $identity).Substring(3))"
}

$operationId = [Guid]::NewGuid().ToString("N"); $startedAt = [DateTime]::UtcNow; $inventory = @(); $operationResults = @()
$operationErrors = New-Object Collections.Generic.List[string]; $operationSucceeded = $false; $mutex = $null; $mutexOwned = $false
try {
    $mutex = New-Object Threading.Mutex($false, (Get-MutexName))
    try { $mutexOwned = $mutex.WaitOne([TimeSpan]::FromSeconds($MutexWaitSeconds)) } catch [Threading.AbandonedMutexException] { $mutexOwned = $true }
    if (-not $mutexOwned) { throw "Another monitor switch operation is still running. Try again after it completes." }
    $inventory = Get-PhysicalMonitorInventory -IncludeCapabilities:($PSCmdlet.ParameterSetName -eq "List" -and $IncludeCapabilities) -IncludeCurrentInput:($PSCmdlet.ParameterSetName -eq "List")
    if ($inventory.Count -eq 0) { throw "No DDC/CI-capable monitors were found." }
    switch ($PSCmdlet.ParameterSetName) {
        "List" {
            $operationResults = @($inventory | Select-Object Index, Position, StableId, IdentityStatus, Manufacturer, ProductCode, Model, Serial, DevicePath, DisplayDevice, Description, MonitorLeft, MonitorTop, MonitorRight, MonitorBottom, CurrentInputCode, CurrentInputHex, CurrentInputName, Capabilities, AdvertisedInputs)
            if ($PassThru) { $operationResults } else { $operationResults | Format-Table Index, Position, StableId, IdentityStatus, Model, CurrentInputName -AutoSize }
        }
        "SetAll" {
            $assignments = @([pscustomobject]@{ Target = "all"; Input = $SetAll; Brightness = $null; Volume = $null }); $plan = New-MonitorPlan $inventory $assignments
            $batch = Invoke-MonitorPlan $plan $operationId; $operationResults = @($batch.Results); foreach ($message in $batch.Errors) { $operationErrors.Add($message) }; Write-ResultOutput $operationResults
        }
        "SetMonitor" {
            $plan = New-MonitorPlan $inventory (Get-AssignmentsFromArguments $SetMonitor); $batch = Invoke-MonitorPlan $plan $operationId
            $operationResults = @($batch.Results); foreach ($message in $batch.Errors) { $operationErrors.Add($message) }; Write-ResultOutput $operationResults
        }
        "Profile" {
            $assignments = Get-AssignmentsFromProfile $Profile $ConfigPath; $plan = New-MonitorPlan $inventory $assignments $MonitorId; $batch = Invoke-MonitorPlan $plan $operationId
            $operationResults = @($batch.Results); foreach ($message in $batch.Errors) { $operationErrors.Add($message) }; Write-ResultOutput $operationResults
        }
        "Test" {
            $monitor = Resolve-MonitorTarget $inventory $TestMonitor; $testPlan = New-SingleInputPlan $monitor $TestInput; $returnPlan = New-SingleInputPlan $monitor $ReturnInput
            try {
                $batch = Invoke-MonitorPlan $testPlan $operationId "Test"; $operationResults += @($batch.Results); foreach ($message in $batch.Errors) { $operationErrors.Add($message) }
                if (-not $WhatIfPreference -and @($batch.Results | Where-Object ApiAccepted).Count -gt 0) { Start-Sleep -Seconds $ReturnAfterSeconds }
            }
            finally {
                $returnBatch = Invoke-MonitorPlan $returnPlan $operationId "Return"; $operationResults += @($returnBatch.Results); foreach ($message in $returnBatch.Errors) { $operationErrors.Add($message) }
            }
            Write-ResultOutput $operationResults
        }
        "TestProfile" {
            # Both plans are completely resolved before the first write so an
            # invalid return profile cannot strand monitors on the test inputs.
            $testAssignments = Get-AssignmentsFromProfile $TestProfile $ConfigPath
            $returnAssignments = Get-AssignmentsFromProfile $ReturnProfile $ConfigPath
            $testPlan = New-MonitorPlan $inventory $testAssignments
            $returnPlan = New-MonitorPlan $inventory $returnAssignments
            if ($testPlan.Count -eq 0) { throw "Test profile '$TestProfile' does not contain any monitor operations." }
            foreach ($testOperation in $testPlan) {
                $covered = @($returnPlan | Where-Object {
                    $_.Monitor.StableId -eq $testOperation.Monitor.StableId -and $_.VcpCode -eq $testOperation.VcpCode
                }).Count -gt 0
                if (-not $covered) {
                    throw "Return profile '$ReturnProfile' does not restore $($testOperation.Feature) on monitor $($testOperation.Monitor.StableId); no writes were attempted."
                }
            }
            try {
                $batch = Invoke-MonitorPlan $testPlan $operationId "Test"; $operationResults += @($batch.Results); foreach ($message in $batch.Errors) { $operationErrors.Add($message) }
                if (-not $WhatIfPreference -and @($batch.Results | Where-Object ApiAccepted).Count -gt 0) { Start-Sleep -Seconds $ReturnAfterSeconds }
            }
            finally {
                $returnBatch = Invoke-MonitorPlan $returnPlan $operationId "Return"; $operationResults += @($returnBatch.Results); foreach ($message in $returnBatch.Errors) { $operationErrors.Add($message) }
            }
            Write-ResultOutput $operationResults
        }
    }
    if ($operationErrors.Count -gt 0) { throw "Monitor operation $operationId completed with $($operationErrors.Count) failure(s): $($operationErrors -join ' | ')" }
    $operationSucceeded = $true
}
catch { if ($operationErrors.Count -eq 0 -or $operationErrors -notcontains $_.Exception.Message) { $operationErrors.Add($_.Exception.Message) }; throw }
finally {
    if ($inventory.Count -gt 0) { Close-PhysicalMonitorInventory $inventory }
    if ($mutexOwned -and $null -ne $mutex) { $mutex.ReleaseMutex() }; if ($null -ne $mutex) { $mutex.Dispose() }
    if (Get-Command Write-MonitorToolsOperation -ErrorAction SilentlyContinue) {
        try { Write-MonitorToolsOperation -Record ([pscustomobject]@{ OperationId = $operationId; StartedAtUtc = $startedAt.ToString("o"); CompletedAtUtc = [DateTime]::UtcNow.ToString("o")
            Command = $PSCmdlet.ParameterSetName; Profile = if ($PSCmdlet.ParameterSetName -eq 'Profile') { $Profile } elseif ($PSCmdlet.ParameterSetName -eq 'TestProfile') { $TestProfile } else { $null }
            ReturnProfile = if ($PSCmdlet.ParameterSetName -eq 'TestProfile') { $ReturnProfile } else { $null }
            ConfigPath = $ConfigPath; Succeeded = $operationSucceeded; Errors = $operationErrors.ToArray(); Results = @($operationResults) }) | Out-Null }
        catch { Write-Warning "Could not write the monitor operation log: $($_.Exception.Message)" }
    }
}
