# Behavioral tests for the WinForms profile editor and setup configuration builder.
# Each scenario runs in a bounded STA child so an unexpected modal dialog cannot hang CI.
[CmdletBinding()]
param(
    [string]$Scenario,
    [string]$TrayAssembly,
    [string]$SetupAssembly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Web.Extensions
Add-Type -AssemblyName System.Windows.Forms

function Assert-True {
    param($Value, [string]$Message)
    if (-not $Value) { throw $Message }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -cne $Expected) { throw "$Message -- expected '$Expected', received '$Actual'." }
}

function Get-Flags {
    return [Reflection.BindingFlags]'Instance,Public,NonPublic'
}

function Get-Map {
    param([Collections.Generic.Dictionary[string, object]]$Parent, [string]$Name)
    return [Collections.Generic.Dictionary[string, object]]$Parent[$Name]
}

function ConvertFrom-TestJson {
    param([string]$Json)
    $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    return [Collections.Generic.Dictionary[string, object]]$serializer.DeserializeObject($Json)
}

function New-Editor {
    param([string]$Json, [hashtable]$Labels)
    $assembly = [Reflection.Assembly]::LoadFrom($TrayAssembly)
    $type = $assembly.GetType('ProfileEditor', $true)
    $config = ConvertFrom-TestJson $Json
    $labeler = [Func[string, string]]{ param($id) if ($Labels.ContainsKey($id)) { return [string]$Labels[$id] }; return $id }
    $hotkeys = New-Object 'Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    if ($config.ContainsKey('hotkeys')) {
        foreach ($pair in (Get-Map $config 'hotkeys').GetEnumerator()) { $hotkeys[[string]$pair.Key] = [string]$pair.Value }
    }
    $constructor = $type.GetConstructors((Get-Flags)) | Where-Object { $_.GetParameters().Count -eq 3 } | Select-Object -First 1
    $arguments = [object[]]@(
        $config.PSObject.BaseObject,
        $labeler.PSObject.BaseObject,
        $hotkeys.PSObject.BaseObject
    )
    return $constructor.Invoke([Reflection.BindingFlags]::Default, $null, $arguments, $null)
}

function Save-Editor {
    param($Editor)
    $method = $Editor.GetType().GetMethod('SaveClicked', (Get-Flags))
    [void]$method.Invoke($Editor, [object[]]@($null, [EventArgs]::Empty))
    $property = $Editor.GetType().GetProperty('Result', (Get-Flags))
    $result = $property.GetValue($Editor, $null)
    Assert-True ($null -ne $result) 'Profile editor did not produce a result.'
    return [Collections.Generic.Dictionary[string, object]]$result
}

function Get-EditorGrid {
    param($Editor)
    return [Windows.Forms.DataGridView]$Editor.GetType().GetField('grid', (Get-Flags)).GetValue($Editor)
}

function Invoke-EditorPreserve {
    $json = '{"schemaVersion":2,"monitors":{"id-a":{"label":"Left"}},"profiles":{"focus":{"id-a":{"input":"displayport1","brightness":42,"volume":17}}},"hotkeys":{"focus":"Ctrl+Alt+7"},"profileCalibration":{"status":"verified"}}'
    $editor = New-Editor $json @{ 'id-a' = 'Left' }
    try {
        $result = Save-Editor $editor
        $scene = Get-Map (Get-Map $result 'profiles') 'focus'
        $values = [Collections.Generic.Dictionary[string, object]]$scene['id-a']
        Assert-Equal ([string]$values['input']) 'displayport1' 'Scene input'
        Assert-Equal ([int]$values['brightness']) 42 'Scene brightness'
        Assert-Equal ([int]$values['volume']) 17 'Scene volume'
        Assert-Equal ([string](Get-Map $result 'hotkeys')['focus']) 'Ctrl+Alt+7' 'Profile hotkey'
    }
    finally { $editor.Dispose() }
}

function Invoke-EditorDuplicateLabels {
    $json = '{"schemaVersion":2,"monitors":{"id-a":{"label":"Same"},"id-b":{"label":"Same"}},"profiles":{"focus":{"id-a":"displayport1","id-b":"hdmi1"}},"hotkeys":{}}'
    $editor = New-Editor $json @{ 'id-a' = 'Same'; 'id-b' = 'Same' }
    try {
        $result = Save-Editor $editor
        $focus = Get-Map (Get-Map $result 'profiles') 'focus'
        Assert-Equal $focus.Count 2 'Duplicate friendly labels must retain both assignments'
        Assert-Equal ([string]$focus['id-a']) 'displayport1' 'First duplicate label target'
        Assert-Equal ([string]$focus['id-b']) 'hdmi1' 'Second duplicate label target'
    }
    finally { $editor.Dispose() }
}

function Invoke-EditorLegacyTargets {
    $json = '{"profiles":{"legacy":{"left":"displayport1","right":"hdmi1"}},"hotkeys":{"legacy":"Ctrl+Alt+8"}}'
    $editor = New-Editor $json @{ 'left' = 'Left legacy'; 'right' = 'Right legacy' }
    try {
        $result = Save-Editor $editor
        $legacy = Get-Map (Get-Map $result 'profiles') 'legacy'
        Assert-Equal ([string]$legacy['left']) 'displayport1' 'Legacy left target'
        Assert-Equal ([string]$legacy['right']) 'hdmi1' 'Legacy right target'
    }
    finally { $editor.Dispose() }
}

function Invoke-EditorInvalidatesCalibration {
    $json = '{"schemaVersion":2,"monitors":{"id-a":{"label":"Left","calibration":{"status":"verified","thisInput":"displayport1","otherInput":"hdmi1","verifiedAt":"2026-01-01T00:00:00Z"}}},"profiles":{"focus":{"id-a":"displayport1"}},"hotkeys":{},"profileCalibration":{"status":"verified","verifiedAt":"2026-01-01T00:00:00Z"}}'
    $editor = New-Editor $json @{ 'id-a' = 'Left' }
    try {
        $grid = Get-EditorGrid $editor
        $grid.Rows[0].Cells[2].Value = 'hdmi1'
        $result = Save-Editor $editor
        $profileCalibration = Get-Map $result 'profileCalibration'
        $monitor = Get-Map (Get-Map $result 'monitors') 'id-a'
        $monitorCalibration = Get-Map $monitor 'calibration'
        Assert-Equal ([string]$profileCalibration['status']) 'untested' 'Profile edit invalidates full-profile calibration'
        Assert-Equal ([string]$monitorCalibration['status']) 'untested' 'Profile edit invalidates monitor calibration'
    }
    finally { $editor.Dispose() }
}

function New-SetupWindow {
    $assembly = [Reflection.Assembly]::LoadFrom($SetupAssembly)
    $type = $assembly.GetType('SetupWindow', $true)
    $constructor = $type.GetConstructors((Get-Flags)) | Where-Object { $_.GetParameters().Count -eq 2 } | Select-Object -First 1
    $staging = Join-Path ([IO.Path]::GetTempPath()) 'monitor-tools-interface-behavior'
    return $constructor.Invoke([Reflection.BindingFlags]::Default, $null, [object[]]@([string]$staging, [bool]$true), $null)
}

function Invoke-SetupPreserve {
    $window = New-SetupWindow
    try {
        [void]$window.GetType().GetMethod('PreparePreview', (Get-Flags)).Invoke($window, @())
        $json = '{"schemaVersion":2,"computers":{"this-pc":"Twingo","other-pc":"Work"},"monitors":{"id-left":{"label":"Left","identityStatus":"edid-serial","model":"Samsung","serial":"S1","devicePath":"preview","calibration":{"status":"verified","thisInput":"displayport1","otherInput":"0x05","verifiedAt":"2026-01-01T00:00:00Z"}}},"profiles":{"this-pc":{"id-left":{"input":"displayport1","brightness":44,"volume":18}},"other-pc":{"id-left":{"input":"0x05","brightness":55}},"split":{"id-left":{"input":"hdmi1","brightness":66}}},"hotkeys":{"split":"Ctrl+Alt+9"},"settings":{"startAtLogin":false}}'
        $existing = ConvertFrom-TestJson $json
        $window.GetType().GetField('existing', (Get-Flags)).SetValue($window, $existing)
        $result = [Collections.Generic.Dictionary[string, object]]$window.GetType().GetMethod('BuildConfiguration', (Get-Flags)).Invoke($window, @())
        $profiles = Get-Map $result 'profiles'
        Assert-True ($profiles.ContainsKey('split')) 'Setup preserves custom profiles'
        $split = [Collections.Generic.Dictionary[string, object]](Get-Map $profiles 'split')['id-left']
        Assert-Equal ([int]$split['brightness']) 66 'Setup preserves custom scene values'
        Assert-Equal ([string](Get-Map $result 'hotkeys')['split']) 'Ctrl+Alt+9' 'Setup preserves custom hotkeys'
        $thisScene = [Collections.Generic.Dictionary[string, object]](Get-Map $profiles 'this-pc')['id-left']
        Assert-Equal ([int]$thisScene['brightness']) 44 'Setup preserves brightness while updating input'
        Assert-Equal ([int]$thisScene['volume']) 18 'Setup preserves volume while updating input'
    }
    finally { $window.Dispose() }
}

function Invoke-SetupIdentityChange {
    $window = New-SetupWindow
    try {
        $saved = ConvertFrom-TestJson '{"schemaVersion":2,"monitors":{"id-a":{"label":"Left","identityStatus":"edid-serial","model":"Samsung","serial":"S1","devicePath":"old-path","calibration":{"status":"verified","thisInput":"displayport1","otherInput":"hdmi1","verifiedAt":"2026-01-01T00:00:00Z"}}},"profiles":{"this-pc":{"id-a":"displayport1"},"other-pc":{"id-a":"hdmi1"}}}'
        $type = $window.GetType(); $type.GetField('existing', (Get-Flags)).SetValue($window, $saved)
        $addRow = $type.GetMethod('AddRow', (Get-Flags)); $reset = $type.GetMethod('ResetTable', (Get-Flags)); $rowsField = $type.GetField('rows', (Get-Flags))
        $liveChanged = ConvertFrom-TestJson '{"Position":"left","StableId":"id-a","IdentityStatus":"edid-serial","Model":"Samsung","Serial":"S1","DevicePath":"new-path","MonitorLeft":0,"MonitorTop":0,"MonitorRight":1920,"MonitorBottom":1080}'
        [void]$addRow.Invoke($window, [object[]]@($liveChanged, $saved))
        $rows = [Collections.IList]$rowsField.GetValue($window)
        Assert-Equal ([string]$rows[0].GetType().GetField('CalibrationStatus', (Get-Flags)).GetValue($rows[0])) 'untested' 'Changed device path invalidates calibration'
        [void]$reset.Invoke($window, @())
        $liveSame = ConvertFrom-TestJson '{"Position":"left","StableId":"id-a","IdentityStatus":"edid-serial","Model":"Samsung","Serial":"S1","DevicePath":"old-path","MonitorLeft":0,"MonitorTop":0,"MonitorRight":1920,"MonitorBottom":1080}'
        [void]$addRow.Invoke($window, [object[]]@($liveSame, $saved))
        $rows = [Collections.IList]$rowsField.GetValue($window)
        Assert-Equal ([string]$rows[0].GetType().GetField('CalibrationStatus', (Get-Flags)).GetValue($rows[0])) 'verified' 'Unchanged identity retains calibration'
    }
    finally { $window.Dispose() }
}

function Invoke-Scenario {
    switch ($Scenario) {
        'editor-preserve' { Invoke-EditorPreserve }
        'editor-duplicates' { Invoke-EditorDuplicateLabels }
        'editor-legacy' { Invoke-EditorLegacyTargets }
        'editor-invalidate' { Invoke-EditorInvalidatesCalibration }
        'setup-preserve' { Invoke-SetupPreserve }
        'setup-identity' { Invoke-SetupIdentityChange }
        default { throw "Unknown interface scenario '$Scenario'." }
    }
}

if (-not [string]::IsNullOrWhiteSpace($Scenario)) {
    try { Invoke-Scenario; Write-Output "PASS: $Scenario"; exit 0 }
    catch { [Console]::Error.WriteLine($_.Exception.ToString()); exit 1 }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('monitor-tools-interface-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
try {
    $compiler = @(
        (Join-Path ([Environment]::GetFolderPath('Windows')) 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path ([Environment]::GetFolderPath('Windows')) 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if ($null -eq $compiler) { throw 'The Windows .NET Framework C# compiler was not found.' }
    $trayLibrary = Join-Path $testRoot 'TrayBehavior.dll'
    $setupLibrary = Join-Path $testRoot 'SetupBehavior.dll'
    & $compiler /nologo /target:library /optimize+ "/out:$trayLibrary" /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Web.Extensions.dll (Join-Path $repoRoot 'app\Tray.cs') (Join-Path $repoRoot 'app\WorkerClient.cs')
    if ($LASTEXITCODE -ne 0) { throw 'Could not compile the tray behavior fixture.' }
    & $compiler /nologo /target:library /optimize+ "/out:$setupLibrary" /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Web.Extensions.dll /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll (Join-Path $repoRoot 'installer\Setup.cs')
    if ($LASTEXITCODE -ne 0) { throw 'Could not compile the setup behavior fixture.' }

    $failures = New-Object Collections.Generic.List[string]
    foreach ($name in @('editor-preserve', 'editor-duplicates', 'editor-legacy', 'editor-invalidate', 'setup-preserve', 'setup-identity')) {
        $stdout = Join-Path $testRoot "$name.out"; $stderr = Join-Path $testRoot "$name.err"
        $hostPath = (Get-Process -Id $PID).Path
        $quote = { param([string]$Value) '"' + $Value.Replace('"', '\"') + '"' }
        $arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File ' + (& $quote $PSCommandPath) + ' -Scenario ' + (& $quote $name) +
            ' -TrayAssembly ' + (& $quote $trayLibrary) + ' -SetupAssembly ' + (& $quote $setupLibrary)
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = $hostPath; $start.Arguments = $arguments; $start.UseShellExecute = $false; $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
        $process = [Diagnostics.Process]::Start($start)
        $outTask = $process.StandardOutput.ReadToEndAsync(); $errorTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(8000)) {
            try { $process.Kill() } catch { }
            $failures.Add("$name timed out; an unexpected modal dialog may be open.")
        }
        else {
            $outTask.Wait(); $errorTask.Wait()
            if ($process.ExitCode -ne 0) { $failures.Add("$name failed: $($errorTask.Result.Trim())") }
            else { Write-Output $outTask.Result.Trim() }
        }
        $process.Dispose()
    }
    if ($failures.Count -gt 0) { throw "Interface behavior failures:`n$($failures -join "`n")" }
    Write-Output 'All interface behavior tests passed.'
}
finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -notmatch '^monitor-tools-interface-[0-9a-f]{32}$') {
        throw 'Refusing to remove a path outside this test run.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
}
