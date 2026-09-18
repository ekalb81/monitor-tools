# Run in a fresh PowerShell process; no Pester or physical monitors required.
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$switchPath = Join-Path $repoRoot "Switch-MonitorInput.ps1"
$installerPath = Join-Path $repoRoot "Install-ProfileHotkeys.ps1"
$launcherPath = Join-Path $repoRoot "Run-Profile.ps1"
$configPath = Join-Path $repoRoot "monitor-profiles.json"

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -cne $Expected) {
        throw "$Message -- expected '$Expected', received '$Actual'."
    }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern)
    try { & $Action | Out-Null }
    catch {
        if ($_.Exception.Message -notlike $Pattern) { throw }
        return
    }
    throw "Expected an error matching '$Pattern'."
}

function Assert-HandlesReleased {
    Assert-Equal ([MockDdcCiForTests]::Released -join ',') `
        ([MockDdcCiForTests]::Acquired -join ',') "Every acquired handle must be released exactly once"
}

foreach ($path in @($switchPath, $installerPath, $launcherPath)) {
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
    Assert-Equal @($parseErrors).Count 0 "Parse errors in $path"
}

Add-Type -Path (Join-Path $PSScriptRoot "MockDdcCi.cs")
# Exercise the entire production script, replacing only its native type in memory.
# Using a distinct type also prevents tests from replacing the real type in a session.
$rawSwitchSource = Get-Content -LiteralPath $switchPath -Raw
if (-not $rawSwitchSource.Contains('public static class DdcCiNativeV3') -or -not $rawSwitchSource.Contains('public static class MonitorIdentityNativeV1')) {
    throw 'Mock injection markers changed; refusing to run monitor tests.'
}
$source = $rawSwitchSource.Replace('DdcCiNativeV3', 'MockDdcCiForTests').Replace('MonitorIdentityNativeV1', 'MockMonitorIdentityForTests')
if ($source.Contains('DdcCiNativeV3') -or $source.Contains('MonitorIdentityNativeV1')) { throw 'Mock injection was incomplete; refusing to run monitor tests.' }
$switchScript = [scriptblock]::Create($source)

[MockDdcCiForTests]::Reset(0)
Assert-Throws { & $switchScript -List -ConfigPath $configPath } '*No DDC/CI-capable monitors were found*'
Assert-HandlesReleased

foreach ($count in @(1, 2, 3, 4)) {
    [MockDdcCiForTests]::Reset($count)
    $output = & $switchScript -List -ConfigPath $configPath | Out-String -Width 240
    $expectedLabels = switch ($count) {
        1 { @('center') }
        2 { @('left', 'right') }
        3 { @('left', 'center', 'right') }
        4 { @('position-1', 'position-2', 'position-3', 'position-4') }
    }
    foreach ($label in $expectedLabels) {
        Assert-Equal ($output -match "\b$label\b") $true "Missing position label for $count monitors"
    }
    Assert-Equal ([MockDdcCiForTests]::Acquired.Count) $count 'Monitor count'
    Assert-HandlesReleased
}
Write-Output 'PASS: zero, one, two, three, and four monitor inventories'

foreach ($invalidInput in @('typo', '256')) {
    [MockDdcCiForTests]::Reset(2)
    Assert-Throws {
        & $switchScript -SetMonitor @('left=hdmi1', "right=$invalidInput") -ConfigPath $configPath
    } '*input source*'
    Assert-Equal ([MockDdcCiForTests]::Writes.Count) 0 'Invalid later input must prevent every write'
    Assert-HandlesReleased
}
[MockDdcCiForTests]::Reset(2)
Assert-Throws {
    & $switchScript -SetMonitor @('left=hdmi1', 'center=hdmi1') -ConfigPath $configPath
} "*Monitor target 'center' was not found*"
Assert-Equal ([MockDdcCiForTests]::Writes.Count) 0 'Missing later target must prevent every write'
Assert-HandlesReleased

[MockDdcCiForTests]::Reset(2)
Assert-Throws { & $switchScript -Profile other-pc -ConfigPath $configPath } "*Monitor target 'center' was not found*"
Assert-Equal ([MockDdcCiForTests]::Writes.Count) 0 'Invalid profile must prevent every write'
Assert-HandlesReleased
Write-Output 'PASS: direct assignments and profiles validate before writing'

[MockDdcCiForTests]::Reset(3)
& $switchScript -Profile other-pc -ConfigPath $configPath | Out-Null
Assert-Equal ([MockDdcCiForTests]::Writes -join ',') '1:96:15,2:96:5,3:96:15' 'Twingo other-PC profile and Samsung HDMI input'
Assert-HandlesReleased

[MockDdcCiForTests]::Reset(3)
& $switchScript -Profile this-pc -ConfigPath $configPath | Out-Null
Assert-Equal ([MockDdcCiForTests]::Writes -join ',') '1:96:5,2:96:15,3:96:5' 'Twingo return profile uses Samsung HDMI on the side monitors'
Assert-HandlesReleased

[MockDdcCiForTests]::Reset(1)
& $switchScript -SetMonitor @('1=0x05') -SaveCurrentSettings -ConfigPath $configPath | Out-Null
Assert-Equal ([MockDdcCiForTests]::Writes -join ',') '1:96:5' 'Single-monitor numeric target'
Assert-Equal ([MockDdcCiForTests]::Saves -join ',') '1' 'Save after successful write'
Assert-HandlesReleased

[MockDdcCiForTests]::Reset(2)
& $switchScript -SetAll displayport1 -ConfigPath $configPath | Out-Null
Assert-Equal ([MockDdcCiForTests]::Writes -join ',') '1:96:15,2:96:15' 'SetAll writes'
Assert-HandlesReleased

foreach ($profile in @('this-pc', 'other-pc')) {
    [MockDdcCiForTests]::Reset(3)
    & $switchScript -Profile $profile -WhatIf -SaveCurrentSettings -ConfigPath $configPath | Out-Null
    Assert-Equal ([MockDdcCiForTests]::Writes.Count) 0 'WhatIf must prevent writes'
    Assert-Equal ([MockDdcCiForTests]::Saves.Count) 0 'WhatIf must prevent saves'
    Assert-HandlesReleased
}
Write-Output 'PASS: successful switches, saving, and profile previews'

[MockDdcCiForTests]::Reset(2)
[MockDdcCiForTests]::Capabilities = 'vcp(60(GG))'
Assert-Throws { & $switchScript -List -IncludeCapabilities -ConfigPath $configPath } '*recognizable digits*'
Assert-Equal ([MockDdcCiForTests]::Acquired.Count) 2 'Failure must occur after acquisition'
Assert-HandlesReleased

[MockDdcCiForTests]::Reset(2)
[MockDdcCiForTests]::FailWriteOn = 2
Assert-Throws { & $switchScript -SetAll hdmi1 -ConfigPath $configPath } '*Failed to set input on monitor 2*'
Assert-HandlesReleased
Write-Output 'PASS: handle cleanup after inventory and write failures'

foreach ($example in @(
    @{ Name = 'one-monitor.json'; Count = 1 },
    @{ Name = 'two-monitors.json'; Count = 2 },
    @{ Name = 'three-monitors.json'; Count = 3 },
    @{ Name = 'four-monitors.json'; Count = 4 }
)) {
    $examplePath = Join-Path $repoRoot "examples\$($example.Name)"
    foreach ($profile in @('this-pc', 'other-pc')) {
        [MockDdcCiForTests]::Reset($example.Count)
        & $switchScript -Profile $profile -ConfigPath $examplePath | Out-Null
        $expectedInput = if ($profile -eq 'this-pc') { 15 } else { 17 }
        $expectedWrites = (1..$example.Count | ForEach-Object { "${_}:96:$expectedInput" }) -join ','
        Assert-Equal ([MockDdcCiForTests]::Writes -join ',') $expectedWrites 'Example target and input assignments'
        Assert-HandlesReleased
    }
}
Write-Output 'PASS: example configurations for one through four monitors'

# Real launcher, isolated files, and a switch script whose only native type is mocked.
$testDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("monitor-tools-tests-" + [Guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($testDirectory)
try {
    $testLauncher = Join-Path $testDirectory 'Run-Profile.ps1'
    Copy-Item -LiteralPath $launcherPath -Destination $testLauncher
    Copy-Item -LiteralPath (Join-Path $repoRoot 'MonitorTools.Common.ps1') -Destination $testDirectory
    Copy-Item -LiteralPath $configPath -Destination (Join-Path $testDirectory 'monitor-profiles.json')
    [System.IO.File]::WriteAllText((Join-Path $testDirectory 'Switch-MonitorInput.ps1'), $source)
    $testLog = Join-Path $testDirectory 'logs\last-error.log'

    [MockDdcCiForTests]::Reset(3)
    & $testLauncher -Profile other-pc -WhatIf -SaveCurrentSettings -LogPath $testLog | Out-Null
    Assert-Equal ([MockDdcCiForTests]::Writes.Count) 0 'Launcher must forward WhatIf'
    Assert-Equal ([MockDdcCiForTests]::Saves.Count) 0 'Launcher preview must not save'
    Assert-Equal (Test-Path -LiteralPath $testLog) $false 'Success must not create an error log'
    Assert-HandlesReleased

    [MockDdcCiForTests]::Reset(2)
    Assert-Throws { & $testLauncher -Profile other-pc -WhatIf -LogPath $testLog } "*Monitor target 'center' was not found*"
    $log = Get-Content -LiteralPath $testLog -Raw
    Assert-Equal ($log.Contains('Profile: other-pc')) $true 'Log must identify profile'
    Assert-Equal ($log.Contains('Time (UTC):')) $true 'Log must identify time'
    Assert-Equal ($log.Contains("Monitor target 'center' was not found")) $true 'Log must include original error'
    Assert-Equal ([MockDdcCiForTests]::Writes.Count) 0 'Failed preview must not switch monitors'
    Assert-HandlesReleased

    [MockDdcCiForTests]::Reset(3)
    [MockDdcCiForTests]::FailWriteOn = 2
    Assert-Throws { & $testLauncher -Profile this-pc -LogPath $testLog } '*Failed to set input on monitor 2*'
    $latestLog = Get-Content -LiteralPath $testLog -Raw
    Assert-Equal ($latestLog.Contains('Failed to set input on monitor 2')) $true 'Latest failure must replace prior log'
    Assert-Equal ($latestLog.Contains("Monitor target 'center' was not found")) $false 'Old failure must not remain'
    Assert-HandlesReleased

    [MockDdcCiForTests]::Reset(1)
    & $testLauncher -Profile other-pc -ConfigPath (Join-Path $repoRoot 'examples\one-monitor.json') -SaveCurrentSettings -LogPath $testLog | Out-Null
    Assert-Equal ([MockDdcCiForTests]::Writes -join ',') '1:96:17' 'Launcher must forward custom configuration'
    Assert-Equal ([MockDdcCiForTests]::Saves -join ',') '1' 'Launcher must forward save option'
    Assert-Equal (Get-Content -LiteralPath $testLog -Raw) $latestLog 'Success preserves last failure timestamp'
    Assert-HandlesReleased

    [MockDdcCiForTests]::Reset(2)
    # A directory cannot be used as a log file. Preserve the switching error anyway.
    Assert-Throws { & $testLauncher -Profile other-pc -LogPath $testDirectory } "*Monitor target 'center' was not found*"
    Assert-HandlesReleased
}
finally {
    # Delete only this run's explicitly created temporary directory.
    $resolvedTestDirectory = [System.IO.Path]::GetFullPath($testDirectory)
    $temporaryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolvedTestDirectory.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolvedTestDirectory) -notmatch '^monitor-tools-tests-[0-9a-f]{32}$') {
        throw 'Refusing to remove a path outside this test run.'
    }
    Remove-Item -LiteralPath $resolvedTestDirectory -Recurse -Force
}
Write-Output 'PASS: launcher previews, configuration, saving, and failure logging'

& (Join-Path $PSScriptRoot 'Test-Setup.ps1') -RepoRoot $repoRoot

# Shadow shortcut and directory creation to run the actual installer without writes.
$shortcuts = New-Object System.Collections.Generic.List[object]
$shortcutState = [pscustomobject]@{ Shortcuts = $shortcuts; DirectoryCreates = 0; Removing = $false }
$fakeShell = [pscustomobject]@{}
$fakeShell | Add-Member -MemberType ScriptMethod -Name CreateShortcut -Value {
    param($path)
    $shortcut = [pscustomobject]@{
        Path = $path; TargetPath = ''; Arguments = ''; WorkingDirectory = ''
        Description = ''; IconLocation = ''; Hotkey = ''; Saved = $false
    }
    if ($shortcutState.Removing) { $shortcut.Hotkey = 'CTRL+ALT+1' }
    $shortcut | Add-Member -MemberType ScriptMethod -Name Save -Value {
        $this.Saved = $true
        if ($shortcutState.Removing) {
            Assert-Equal $this.Hotkey '' 'Clear the legacy binding before saving its shortcut'
            [MonitorToolsShortcutNotificationsV1]::Events.Add('save:' + $this.Path)
        }
    }
    $shortcutState.Shortcuts.Add($shortcut)
    return $shortcut
}
function New-Object {
    param([string]$ComObject)
    Assert-Equal $ComObject 'WScript.Shell' 'Unexpected COM object'
    return $fakeShell
}
function New-Item {
    param([string]$ItemType, [switch]$Force, [string]$Path)
    Assert-Equal $ItemType 'Directory' 'Unexpected filesystem mutation'
    $shortcutState.DirectoryCreates++
}
& $installerPath | Out-Null
$expectedExecutable = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'
Assert-Equal (Test-Path -LiteralPath $expectedExecutable -PathType Leaf) $true 'Shortcut executable must exist'
Assert-Equal $shortcuts.Count 2 'Shortcut count'
for ($i = 0; $i -lt $shortcuts.Count; $i++) {
    $shortcut = $shortcuts[$i]
    $profile = @('this-pc', 'other-pc')[$i]
    Assert-Equal $shortcut.TargetPath $expectedExecutable 'Shortcut target'
    Assert-Equal $shortcut.Arguments "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$launcherPath`" -Profile $profile" 'Shortcut arguments'
    Assert-Equal $shortcut.Hotkey "CTRL+ALT+$($i + 1)" 'Default hotkey'
    Assert-Equal $shortcut.Saved $true 'Shortcut must be saved'
}

$shortcuts.Clear()
$shortcutState.DirectoryCreates = 0
function Test-Path { param([string]$LiteralPath, [string]$PathType) return $false }
Assert-Throws { & $installerPath } '*Windows PowerShell executable was not found*'
Assert-Equal $shortcuts.Count 0 'Missing executable must prevent shortcut creation'
Assert-Equal $shortcutState.DirectoryCreates 0 'Missing executable must prevent directory creation'
Write-Output 'PASS: shortcut targets and missing-executable validation'

# Removal must touch only the two known shortcuts and must honor WhatIf.
Add-Type @'
using System.Collections.Generic;
public static class MonitorToolsShortcutNotificationsV1 {
    public static readonly List<string> Events = new List<string>();
    public static void Updated(string path) { Events.Add("update:" + path); }
    public static void Deleted(string path) { Events.Add("delete:" + path); }
}
'@
$shortcutState.Removing = $true
$removalState = [pscustomobject]@{ Paths = @() }
$shortcutDirectory = Join-Path ([Environment]::GetFolderPath('Programs')) 'Monitor Tools'
$expectedRemovals = @(
    (Join-Path $shortcutDirectory 'This PC Profile.lnk'),
    (Join-Path $shortcutDirectory 'Other PC Profile.lnk')
)
function Test-Path {
    param([string]$LiteralPath, [string]$PathType)
    return $expectedRemovals -contains $LiteralPath
}
function Remove-Item {
    param([string]$LiteralPath)
    Assert-Equal ($expectedRemovals -contains $LiteralPath) $true 'Unexpected shortcut removal'
    $removalState.Paths += $LiteralPath
    [MonitorToolsShortcutNotificationsV1]::Events.Add('remove:' + $LiteralPath)
}
& $installerPath -Uninstall -WhatIf | Out-Null
Assert-Equal $removalState.Paths.Count 0 'Uninstall preview must not remove shortcuts'
Assert-Equal $shortcuts.Count 0 'Uninstall preview must not open or save shortcuts'
Assert-Equal ([MonitorToolsShortcutNotificationsV1]::Events.Count) 0 'Uninstall preview must not notify Explorer'
& $installerPath -Uninstall | Out-Null
Assert-Equal ($removalState.Paths -join ',') ($expectedRemovals -join ',') 'Remove exactly the known shortcuts'
$expectedEvents = foreach ($path in $expectedRemovals) { "save:$path"; "update:$path"; "remove:$path"; "delete:$path" }
Assert-Equal ([MonitorToolsShortcutNotificationsV1]::Events -join '|') ($expectedEvents -join '|') 'Clear/save/notify before removal, then flush deletion notification'
Assert-Equal $shortcuts.Count 2 'Only the two legacy shortcuts may be opened'
Write-Output 'PASS: legacy hotkey handoff notifications and removal preview'
Write-Output "All regression tests passed on PowerShell $($PSVersionTable.PSVersion)."
