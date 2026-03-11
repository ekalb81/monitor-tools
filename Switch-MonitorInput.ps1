[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = "List")]
param(
    [Parameter(ParameterSetName = "List")]
    [switch]$List,

    [Parameter(ParameterSetName = "SetAll", Mandatory = $true)]
    [string]$SetAll,

    [Parameter(ParameterSetName = "SetMonitor", Mandatory = $true, Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$SetMonitor,

    [Parameter(ParameterSetName = "Profile", Mandatory = $true)]
    [string]$Profile,

    [switch]$SaveCurrentSettings,

    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $scriptDirectory = Split-Path -Parent $PSCommandPath
    $ConfigPath = Join-Path $scriptDirectory "monitor-profiles.json"
}

$script:InputAliases = @{
    "vga1"         = 0x01
    "dvi1"         = 0x03
    "dvi2"         = 0x04
    "dp1"          = 0x0F
    "displayport"  = 0x0F
    "displayport1" = 0x0F
    "dp2"          = 0x10
    "displayport2" = 0x10
    "hdmi"         = 0x11
    "hdmi1"        = 0x11
    "hdmi2"        = 0x12
}

$script:PrimaryInputNames = @{
    0x01 = "vga1"
    0x03 = "dvi1"
    0x04 = "dvi2"
    0x0F = "displayport1"
    0x10 = "displayport2"
    0x11 = "hdmi1"
    0x12 = "hdmi2"
}

if (-not ("DdcCiNativeV2" -as [type])) {
Add-Type -Language CSharp -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class DdcCiNativeV2
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    public struct MONITORINFOEX
    {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string szDevice;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    public struct PHYSICAL_MONITOR
    {
        public IntPtr hPhysicalMonitor;

        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string szPhysicalMonitorDescription;
    }

    public delegate bool MonitorEnumProc(
        IntPtr hMonitor,
        IntPtr hdcMonitor,
        IntPtr lprcMonitor,
        IntPtr dwData);

    [DllImport("user32.dll")]
    public static extern bool EnumDisplayMonitors(
        IntPtr hdc,
        IntPtr lprcClip,
        MonitorEnumProc lpfnEnum,
        IntPtr dwData);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern bool GetMonitorInfo(
        IntPtr hMonitor,
        ref MONITORINFOEX monitorInfo);

    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(
        IntPtr hMonitor,
        out uint count);

    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool GetPhysicalMonitorsFromHMONITOR(
        IntPtr hMonitor,
        uint arraySize,
        [Out] PHYSICAL_MONITOR[] physicalMonitorArray);

    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool DestroyPhysicalMonitor(
        IntPtr hMonitor);

    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool GetCapabilitiesStringLength(
        IntPtr hMonitor,
        out uint length);

    [DllImport("dxva2.dll", SetLastError = true, CharSet = CharSet.Ansi)]
    public static extern bool CapabilitiesRequestAndCapabilitiesReply(
        IntPtr hMonitor,
        StringBuilder capabilitiesString,
        uint length);

    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool GetVCPFeatureAndVCPFeatureReply(
        IntPtr hMonitor,
        byte vcpCode,
        out uint featureType,
        out uint currentValue,
        out uint maximumValue);

    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool SetVCPFeature(
        IntPtr hMonitor,
        byte vcpCode,
        uint newValue);

    [DllImport("dxva2.dll", SetLastError = true)]
    public static extern bool SaveCurrentSettings(
        IntPtr hMonitor);
}
"@
}

function Get-PrimaryInputName {
    param([int]$Code)

    if ($script:PrimaryInputNames.ContainsKey($Code)) {
        return $script:PrimaryInputNames[$Code]
    }

    return ("0x{0:X2}" -f $Code)
}

function Get-PositionLabels {
    param([Parameter(Mandatory = $true)][object[]]$Inventory)

    $ordered = $Inventory |
        Sort-Object `
            @{ Expression = { $_.MonitorLeft } }, `
            @{ Expression = { $_.MonitorTop } }, `
            @{ Expression = { $_.Index } }

    $count = $ordered.Count
    if ($count -eq 1) {
        return @{ $ordered[0].Index = "center" }
    }

    if ($count -eq 2) {
        return @{
            $ordered[0].Index = "left"
            $ordered[1].Index = "right"
        }
    }

    if ($count -eq 3) {
        return @{
            $ordered[0].Index = "left"
            $ordered[1].Index = "center"
            $ordered[2].Index = "right"
        }
    }

    $labels = @{}
    for ($i = 0; $i -lt $count; $i++) {
        $labels[$ordered[$i].Index] = "position-$($i + 1)"
    }

    return $labels
}

function Resolve-InputCode {
    param([Parameter(Mandatory = $true)][string]$InputName)

    if ($InputName -match '^\s*0x([0-9a-fA-F]{1,2})\s*$') {
        return [Convert]::ToByte($Matches[1], 16)
    }

    if ($InputName -match '^\s*(\d{1,3})\s*$') {
        $value = [int]$Matches[1]
        if ($value -lt 0 -or $value -gt 255) {
            throw "Numeric input source values must be between 0 and 255."
        }

        return [byte]$value
    }

    $normalized = $InputName.Trim().ToLowerInvariant()
    if (-not $script:InputAliases.ContainsKey($normalized)) {
        $validNames = ($script:InputAliases.Keys | Sort-Object -Unique) -join ", "
        throw "Unknown input source '$InputName'. Use one of: $validNames, a decimal value, or a hex value like 0x11."
    }

    return [byte]$script:InputAliases[$normalized]
}

function Get-JsonPropertyValue {
    param(
        [Parameter(Mandatory = $false)]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Get-AdvertisedInputs {
    param([string]$Capabilities)

    if ([string]::IsNullOrWhiteSpace($Capabilities)) {
        return @()
    }

    $match = [regex]::Match($Capabilities, '60\(([^)]*)\)', 'IgnoreCase')
    if (-not $match.Success) {
        return @()
    }

    $tokens = $match.Groups[1].Value -split '\s+' | Where-Object { $_ }
    $inputs = foreach ($token in $tokens) {
        $code = [Convert]::ToInt32($token, 16)
        Get-PrimaryInputName -Code $code
    }

    return $inputs
}

function Get-CapabilitiesString {
    param([IntPtr]$Handle)

    [uint32]$length = 0
    if (-not [DdcCiNativeV2]::GetCapabilitiesStringLength($Handle, [ref]$length)) {
        return $null
    }

    if ($length -le 0) {
        return $null
    }

    $buffer = New-Object System.Text.StringBuilder ([int]$length)
    if (-not [DdcCiNativeV2]::CapabilitiesRequestAndCapabilitiesReply($Handle, $buffer, $length)) {
        return $null
    }

    return $buffer.ToString()
}

function Get-VcpValue {
    param(
        [IntPtr]$Handle,
        [byte]$Code
    )

    [uint32]$featureType = 0
    [uint32]$currentValue = 0
    [uint32]$maximumValue = 0

    if (-not [DdcCiNativeV2]::GetVCPFeatureAndVCPFeatureReply($Handle, $Code, [ref]$featureType, [ref]$currentValue, [ref]$maximumValue)) {
        return $null
    }

    return [pscustomobject]@{
        FeatureType = $featureType
        Current     = $currentValue
        Maximum     = $maximumValue
    }
}

function Get-PhysicalMonitorInventory {
    param(
        [switch]$IncludeCapabilities,
        [switch]$IncludeCurrentInput
    )

    $handles = New-Object System.Collections.Generic.List[object]
    $callback = [DdcCiNativeV2+MonitorEnumProc]{
        param($hMonitor, $hdcMonitor, $lprcMonitor, $dwData)

        $monitorInfo = New-Object DdcCiNativeV2+MONITORINFOEX
        $monitorInfo.cbSize = [Runtime.InteropServices.Marshal]::SizeOf([type][DdcCiNativeV2+MONITORINFOEX])
        $hasMonitorInfo = [DdcCiNativeV2]::GetMonitorInfo($hMonitor, [ref]$monitorInfo)

        [uint32]$count = 0
        if ([DdcCiNativeV2]::GetNumberOfPhysicalMonitorsFromHMONITOR($hMonitor, [ref]$count) -and $count -gt 0) {
            $physicalMonitors = New-Object "DdcCiNativeV2+PHYSICAL_MONITOR[]" $count
            if ([DdcCiNativeV2]::GetPhysicalMonitorsFromHMONITOR($hMonitor, $count, $physicalMonitors)) {
                foreach ($monitor in $physicalMonitors) {
                    [void]$handles.Add([pscustomobject]@{
                        PhysicalMonitor = $monitor
                        DisplayDevice   = if ($hasMonitorInfo) { $monitorInfo.szDevice } else { $null }
                        MonitorLeft     = if ($hasMonitorInfo) { $monitorInfo.rcMonitor.Left } else { 0 }
                        MonitorTop      = if ($hasMonitorInfo) { $monitorInfo.rcMonitor.Top } else { 0 }
                        MonitorRight    = if ($hasMonitorInfo) { $monitorInfo.rcMonitor.Right } else { 0 }
                        MonitorBottom   = if ($hasMonitorInfo) { $monitorInfo.rcMonitor.Bottom } else { 0 }
                    })
                }
            }
        }

        return $true
    }

    [DdcCiNativeV2]::EnumDisplayMonitors([IntPtr]::Zero, [IntPtr]::Zero, $callback, [IntPtr]::Zero) | Out-Null

    $index = 1
    $inventory = foreach ($monitor in $handles) {
        $capabilities = $null
        if ($IncludeCapabilities) {
            $capabilities = Get-CapabilitiesString -Handle $monitor.PhysicalMonitor.hPhysicalMonitor
        }

        $inputVcp = $null
        if ($IncludeCurrentInput) {
            $inputVcp = Get-VcpValue -Handle $monitor.PhysicalMonitor.hPhysicalMonitor -Code 0x60
        }

        [pscustomobject]@{
            Index              = $index
            Position           = $null
            Description        = $monitor.PhysicalMonitor.szPhysicalMonitorDescription
            DisplayDevice      = $monitor.DisplayDevice
            MonitorLeft        = $monitor.MonitorLeft
            MonitorTop         = $monitor.MonitorTop
            MonitorRight       = $monitor.MonitorRight
            MonitorBottom      = $monitor.MonitorBottom
            Handle             = $monitor.PhysicalMonitor.hPhysicalMonitor
            Capabilities       = $capabilities
            AdvertisedInputs   = if ($IncludeCapabilities) { @(Get-AdvertisedInputs -Capabilities $capabilities) } else { @() }
            CurrentInputCode   = if ($null -ne $inputVcp) { [int]$inputVcp.Current } else { $null }
            CurrentInputHex    = if ($null -ne $inputVcp) { "0x{0:X2}" -f [int]$inputVcp.Current } else { $null }
            CurrentInputName   = if ($null -ne $inputVcp) { Get-PrimaryInputName -Code ([int]$inputVcp.Current) } else { $null }
        }

        $index++
    }

    $positionLabels = Get-PositionLabels -Inventory $inventory
    foreach ($monitor in $inventory) {
        $monitor.Position = $positionLabels[$monitor.Index]
    }

    return ,@($inventory)
}

function Close-PhysicalMonitorInventory {
    param([object[]]$Inventory)

    foreach ($monitor in $Inventory) {
        if ($null -ne $monitor.Handle -and $monitor.Handle -ne [IntPtr]::Zero) {
            [DdcCiNativeV2]::DestroyPhysicalMonitor($monitor.Handle) | Out-Null
        }
    }
}

function Get-AssignmentObjectsFromProfile {
    param(
        [Parameter(Mandatory = $true)][string]$SelectedProfile,
        [Parameter(Mandatory = $true)][string]$SelectedConfigPath
    )

    if (-not (Test-Path -LiteralPath $SelectedConfigPath)) {
        throw "Profile file '$SelectedConfigPath' was not found."
    }

    $config = Get-Content -LiteralPath $SelectedConfigPath -Raw | ConvertFrom-Json
    $profiles = Get-JsonPropertyValue -Object $config -Name "profiles"
    if ($null -eq $profiles) {
        throw "Profile file '$SelectedConfigPath' does not contain a 'profiles' object."
    }

    $profileSettings = Get-JsonPropertyValue -Object $profiles -Name $SelectedProfile
    if ($null -eq $profileSettings) {
        $availableProfiles = $profiles.PSObject.Properties.Name -join ", "
        throw "Profile '$SelectedProfile' was not found. Available profiles: $availableProfiles"
    }

    $assignments = foreach ($property in $profileSettings.PSObject.Properties) {
        [pscustomobject]@{
            TargetIndex = [string]$property.Name
            Input       = [string]$property.Value
        }
    }

    return ,@($assignments)
}

function Get-AssignmentObjectsFromArguments {
    param([string[]]$Entries)

    $assignments = foreach ($entry in $Entries) {
        if ($entry -notmatch '^\s*(all|[\w-]+)\s*=\s*(.+?)\s*$') {
            throw "Invalid assignment '$entry'. Use values like 'all=hdmi1', '2=displayport1', or 'left=hdmi1'."
        }

        [pscustomobject]@{
            TargetIndex = $Matches[1]
            Input       = $Matches[2]
        }
    }

    return ,@($assignments)
}

function Invoke-MonitorAssignment {
    param(
        [Parameter(Mandatory = $true)][object[]]$Inventory,
        [Parameter(Mandatory = $true)][object[]]$Assignments
    )

    foreach ($assignment in $Assignments) {
        $targetMonitors = if ($assignment.TargetIndex -eq "all") {
            $Inventory
        }
        else {
            $targetKey = [string]$assignment.TargetIndex
            if ($targetKey -match '^\d+$') {
                $monitor = $Inventory | Where-Object { $_.Index -eq [int]$targetKey }
            }
            else {
                $monitor = $Inventory | Where-Object { $_.Position -ieq $targetKey }
            }

            if ($null -eq $monitor) {
                throw "Monitor target '$targetKey' was not found. Run with -List to see the active indexes and positions."
            }

            @($monitor)
        }

        $targetCode = Resolve-InputCode -InputName $assignment.Input
        $targetName = Get-PrimaryInputName -Code ([int]$targetCode)

        foreach ($monitor in $targetMonitors) {
            $action = "set input on monitor $($monitor.Index) ($($monitor.Position)) [$($monitor.Description)] to $targetName"
            if ($PSCmdlet.ShouldProcess($monitor.Description, $action)) {
                if (-not [DdcCiNativeV2]::SetVCPFeature($monitor.Handle, 0x60, [uint32]$targetCode)) {
                    $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                    throw "Failed to set input on monitor $($monitor.Index) [$($monitor.Description)]. Win32 error: $errorCode"
                }

                if ($SaveCurrentSettings) {
                    if (-not [DdcCiNativeV2]::SaveCurrentSettings($monitor.Handle)) {
                        $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                        throw "Set the input on monitor $($monitor.Index) [$($monitor.Description)] but failed to save current settings. Win32 error: $errorCode"
                    }
                }
            }

            [pscustomobject]@{
                Index        = $monitor.Index
                Position     = $monitor.Position
                Description  = $monitor.Description
                Requested    = $targetName
                RequestedCode= "0x{0:X2}" -f [int]$targetCode
                Saved        = $SaveCurrentSettings.IsPresent
            }
        }
    }
}

$inventory = @()

try {
    switch ($PSCmdlet.ParameterSetName) {
        "List" {
            $inventory = Get-PhysicalMonitorInventory -IncludeCapabilities -IncludeCurrentInput
            if ($inventory.Count -eq 0) {
                throw "No DDC/CI-capable monitors were found."
            }

            $inventory |
                Select-Object Index, Position, DisplayDevice, Description,
                @{ Name = "CurrentInput"; Expression = { "$($_.CurrentInputName) [$($_.CurrentInputHex)]" } },
                @{ Name = "AdvertisedInputs"; Expression = { ($_.AdvertisedInputs -join ", ") } } |
                Format-Table -AutoSize
        }

        "SetAll" {
            $inventory = Get-PhysicalMonitorInventory
            if ($inventory.Count -eq 0) {
                throw "No DDC/CI-capable monitors were found."
            }

            Invoke-MonitorAssignment -Inventory $inventory -Assignments @(
                [pscustomobject]@{
                    TargetIndex = "all"
                    Input       = $SetAll
                }
            ) | Format-Table -AutoSize
        }

        "SetMonitor" {
            $inventory = Get-PhysicalMonitorInventory
            if ($inventory.Count -eq 0) {
                throw "No DDC/CI-capable monitors were found."
            }

            $assignments = Get-AssignmentObjectsFromArguments -Entries $SetMonitor
            Invoke-MonitorAssignment -Inventory $inventory -Assignments $assignments | Format-Table -AutoSize
        }

        "Profile" {
            $inventory = Get-PhysicalMonitorInventory
            if ($inventory.Count -eq 0) {
                throw "No DDC/CI-capable monitors were found."
            }

            $assignments = Get-AssignmentObjectsFromProfile -SelectedProfile $Profile -SelectedConfigPath $ConfigPath
            Invoke-MonitorAssignment -Inventory $inventory -Assignments $assignments | Format-Table -AutoSize
        }

        default {
            throw "Unsupported parameter set '$($PSCmdlet.ParameterSetName)'."
        }
    }
}
finally {
    if ($inventory.Count -gt 0) {
        Close-PhysicalMonitorInventory -Inventory $inventory
    }
}
