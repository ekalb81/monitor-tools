# Focused tests for stable identities, scenes, retries, filtering, and calibration.
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$switchPath = Join-Path $repoRoot "Switch-MonitorInput.ps1"
$commonPath = Join-Path $repoRoot "MonitorTools.Common.ps1"

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -cne $Expected) { throw "$Message -- expected '$Expected', received '$Actual'." }
}
function Assert-True { param($Value, [string]$Message) if (-not $Value) { throw $Message } }
function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern)
    try { & $Action | Out-Null }
    catch { if ($_.Exception.Message -notlike $Pattern) { throw }; return }
    throw "Expected an error matching '$Pattern'."
}
function Assert-Released {
    Assert-Equal ([MockDdcCiForTests]::Released -join ',') ([MockDdcCiForTests]::Acquired -join ',') 'Every acquired handle must be released'
}

$tokens = $null; $parseErrors = $null
[void][Management.Automation.Language.Parser]::ParseFile($switchPath, [ref]$tokens, [ref]$parseErrors)
Assert-Equal @($parseErrors).Count 0 'Engine parse errors'

. $commonPath
Add-Type -Path (Join-Path $PSScriptRoot "MockDdcCi.cs")
$rawSource = [IO.File]::ReadAllText($switchPath)
if (-not $rawSource.Contains('public static class DdcCiNativeV3') -or -not $rawSource.Contains('public static class MonitorIdentityNativeV1')) { throw 'Mock injection markers changed; refusing to run engine tests.' }
$source = $rawSource.Replace('DdcCiNativeV3', 'MockDdcCiForTests').Replace('MonitorIdentityNativeV1', 'MockMonitorIdentityForTests')
if ($source.Contains('DdcCiNativeV3') -or $source.Contains('MonitorIdentityNativeV1')) { throw 'Mock injection was incomplete; refusing to run engine tests.' }
$engine = [scriptblock]::Create($source)
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("monitor-tools-engine-" + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$oldLogDirectory = $env:MONITOR_TOOLS_LOG_DIRECTORY
$env:MONITOR_TOOLS_LOG_DIRECTORY = Join-Path $testRoot 'logs'

try {
    [MockMonitorIdentityForTests]::DuplicateIdentity = $false
    [MockDdcCiForTests]::Reset(2)
    $inventory = @(& $engine -List -PassThru -ConfigPath (Join-Path $repoRoot 'monitor-profiles.json'))
    Assert-Equal $inventory.Count 2 'Inventory count'
    Assert-Equal ([MockDdcCiForTests]::CapabilityRequests) 0 'Default list must not request capabilities'
    Assert-True ($inventory[0].StableId -match '^id-[0-9a-f]{20}$') 'Stable ID shape'
    Assert-Equal $inventory[0].IdentityStatus 'edid-serial' 'Identity status'
    Assert-Equal $inventory[0].Model 'Mock Model 1' 'Friendly model'
    Assert-Equal $inventory[0].Serial 'SERIAL-1' 'EDID serial'
    Assert-Released

    [MockDdcCiForTests]::Reset(1)
    & $engine -List -PassThru -IncludeCapabilities -ConfigPath (Join-Path $repoRoot 'monitor-profiles.json') | Out-Null
    Assert-Equal ([MockDdcCiForTests]::CapabilityRequests) 1 'Capabilities are opt-in'
    Assert-Released

    [MockDdcCiForTests]::Reset(1)
    [MockDdcCiForTests]::CapabilityLengthOverride = 100000
    $bounded = @(& $engine -List -PassThru -IncludeCapabilities -ConfigPath (Join-Path $repoRoot 'monitor-profiles.json'))
    Assert-Equal $bounded[0].Capabilities $null 'Unreasonable capability allocation is rejected'
    Assert-Equal ([MockDdcCiForTests]::Writes.Count) 0 'Capability bounds never write'
    Assert-Released
    Write-Output 'PASS: lightweight inventory and deterministic stable identities'

    [MockDdcCiForTests]::Reset(2)
    $ids = @(& $engine -List -PassThru -ConfigPath (Join-Path $repoRoot 'monitor-profiles.json') | ForEach-Object StableId)
    $sceneConfig = Join-Path $testRoot 'scene.json'
    $sceneJson = [ordered]@{
        schemaVersion = 2
        profiles = [ordered]@{
            focus_mode = [ordered]@{
                $ids[0] = [ordered]@{ input = 'displayport1'; brightness = 50; volume = 25 }
                $ids[1] = 'hdmi1'
            }
        }
    }
    Save-MonitorToolsConfig -Config $sceneJson -Path $sceneConfig

    [MockDdcCiForTests]::Reset(2)
    $result = @(& $engine -Profile focus_mode -ConfigPath $sceneConfig -PassThru)
    Assert-Equal ([MockDdcCiForTests]::Writes -join ',') '1:96:15,1:16:100,1:98:25,2:96:17' 'Scene writes and normalized ranges'
    Assert-Equal ($result | Where-Object ApiAccepted).Count 4 'Structured accepted results'
    Assert-Equal @($result | Where-Object PhysicalVerified).Count 0 'API acceptance must not claim physical verification'
    Assert-True (-not ($result | Where-Object Saved | Select-Object -First 1)) 'Scenes do not save without explicit request'
    Assert-Released

    [MockDdcCiForTests]::Reset(2)
    $filtered = @(& $engine -Profile focus_mode -MonitorId $ids[1] -ConfigPath $sceneConfig -PassThru)
    Assert-Equal ([MockDdcCiForTests]::Writes -join ',') '2:96:17' 'Stable-ID profile filter'
    Assert-Equal $filtered[0].StableId $ids[1] 'Filtered structured result'
    Assert-Released

    $retryConfig = Join-Path $testRoot 'retry.json'
    $retryJson = [ordered]@{ schemaVersion = 2; profiles = [ordered]@{ partial = [ordered]@{
        'id-00000000000000000000' = 'displayport1'; $ids[1] = 'hdmi1'
    } } }
    Save-MonitorToolsConfig -Config $retryJson -Path $retryConfig
    [MockDdcCiForTests]::Reset(2)
    & $engine -Profile partial -MonitorId $ids[1] -ConfigPath $retryConfig -PassThru | Out-Null
    Assert-Equal ([MockDdcCiForTests]::Writes -join ',') '2:96:17' 'Selected retry ignores an unrelated disconnected target'
    Assert-Released
    Write-Output 'PASS: stable-key profiles, arbitrary names, scenes, and selected retries'

    function Start-Sleep { param([int]$Seconds, [int]$Milliseconds) }
    foreach ($count in @(2, 3)) {
        [MockDdcCiForTests]::Reset($count)
        $profileIds = @(& $engine -List -PassThru -ConfigPath $sceneConfig | ForEach-Object StableId)
        $away = [ordered]@{}; $returnSettings = [ordered]@{}
        foreach ($id in $profileIds) { $away[$id] = 'displayport1'; $returnSettings[$id] = 'hdmi1' }
        $roundTripConfig = Join-Path $testRoot "roundtrip-$count.json"
        Save-MonitorToolsConfig -Config ([ordered]@{ schemaVersion = 2; profiles = [ordered]@{ away = $away; home = $returnSettings } }) -Path $roundTripConfig
        [MockDdcCiForTests]::Reset($count)
        $roundTrip = @(& $engine -TestProfile away -ReturnProfile home -ReturnAfterSeconds 3 -ConfigPath $roundTripConfig -PassThru)
        Assert-Equal $roundTrip.Count ($count * 2) "$count-monitor profile round trip result count"
        Assert-Equal (($roundTrip | Select-Object -ExpandProperty Phase) -join ',') ((@('Test') * $count + @('Return') * $count) -join ',') "$count-monitor profile phases"
        Assert-Equal ([MockDdcCiForTests]::Writes.Count) ($count * 2) "$count-monitor profile writes"
        Assert-Released
    }
    Remove-Item Function:\Start-Sleep

    [MockDdcCiForTests]::Reset(2)
    $validIds = @(& $engine -List -PassThru -ConfigPath $sceneConfig | ForEach-Object StableId)
    $invalidReturnConfig = Join-Path $testRoot 'invalid-return.json'
    Save-MonitorToolsConfig -Config ([ordered]@{ schemaVersion = 2; profiles = [ordered]@{
        away = [ordered]@{ $validIds[0] = 'displayport1'; $validIds[1] = 'displayport1' }
        broken_home = [ordered]@{ $validIds[0] = 'hdmi1'; 'id-00000000000000000000' = 'hdmi1' }
    } }) -Path $invalidReturnConfig
    [MockDdcCiForTests]::Reset(2)
    Assert-Throws { & $engine -TestProfile away -ReturnProfile broken_home -ReturnAfterSeconds 3 -ConfigPath $invalidReturnConfig -PassThru } '*was not found*'
    Assert-Equal ([MockDdcCiForTests]::Writes.Count) 0 'Invalid return profile prevents every test write'
    Assert-Released

    $missingMonitorConfig = Join-Path $testRoot 'missing-return-monitor.json'
    Save-MonitorToolsConfig -Config ([ordered]@{ schemaVersion = 2; profiles = [ordered]@{
        away = [ordered]@{ $validIds[0] = 'displayport1'; $validIds[1] = 'displayport1' }
        incomplete_home = [ordered]@{ $validIds[0] = 'hdmi1' }
    } }) -Path $missingMonitorConfig
    [MockDdcCiForTests]::Reset(2)
    Assert-Throws { & $engine -TestProfile away -ReturnProfile incomplete_home -ReturnAfterSeconds 3 -ConfigPath $missingMonitorConfig -PassThru } '*does not restore input*'
    Assert-Equal ([MockDdcCiForTests]::Writes.Count) 0 'Return plan missing a monitor prevents every test write'
    Assert-Released

    $missingFeatureConfig = Join-Path $testRoot 'missing-return-feature.json'
    Save-MonitorToolsConfig -Config ([ordered]@{ schemaVersion = 2; profiles = [ordered]@{
        away = [ordered]@{ $validIds[0] = [ordered]@{ input = 'displayport1'; brightness = 50 } }
        incomplete_home = [ordered]@{ $validIds[0] = 'hdmi1' }
    } }) -Path $missingFeatureConfig
    [MockDdcCiForTests]::Reset(2)
    Assert-Throws { & $engine -TestProfile away -ReturnProfile incomplete_home -ReturnAfterSeconds 3 -ConfigPath $missingFeatureConfig -PassThru } '*does not restore brightness*'
    Assert-Equal ([MockDdcCiForTests]::Writes.Count) 0 'Return plan missing a scene feature prevents every test write'
    Assert-Released
    Write-Output 'PASS: complete multi-monitor profile round trips prevalidate the return plan'

    [MockDdcCiForTests]::Reset(1)
    [MockDdcCiForTests]::TransientFailuresRemaining = 2
    $retried = @(& $engine -SetAll hdmi1 -ConfigPath $sceneConfig -PassThru)
    Assert-Equal $retried[0].AttemptCount 3 'Transient retry count'
    Assert-Equal $retried[0].Status 'Accepted' 'Transient retry outcome'
    Assert-Released

    [MockDdcCiForTests]::Reset(3)
    [MockDdcCiForTests]::FailWriteOn = 2
    Assert-Throws { & $engine -SetAll hdmi1 -ConfigPath $sceneConfig -PassThru } '*completed with 1 failure*'
    Assert-Equal ([MockDdcCiForTests]::Writes -join ',') '1:96:17,3:96:17' 'A permanent failure must not prevent later planned writes'
    Assert-Released
    $latestLog = @(Get-ChildItem -LiteralPath $env:MONITOR_TOOLS_LOG_DIRECTORY -Filter 'operation-*.json' | Sort-Object Name -Descending)[0]
    $record = Get-Content -LiteralPath $latestLog.FullName -Raw | ConvertFrom-Json
    Assert-Equal @($record.Results).Count 3 'Partial results are retained in the operation log'
    Assert-Equal $record.Succeeded $false 'Partial operation log status'
    Write-Output 'PASS: bounded transient retries and complete partial-failure records'

    [MockDdcCiForTests]::Reset(1)
    $preview = @(& $engine -SetAll hdmi1 -SaveCurrentSettings -WhatIf -ConfigPath $sceneConfig -PassThru)
    Assert-Equal $preview[0].Saved $false 'Preview must report saved=false'
    Assert-Equal ([MockDdcCiForTests]::Saves.Count) 0 'Preview must not call save'
    Assert-Released

    [MockDdcCiForTests]::Reset(1)
    $single = @(& $engine -List -PassThru -ConfigPath $sceneConfig)[0]
    function Start-Sleep { param([int]$Seconds, [int]$Milliseconds) }
    $calibration = @(& $engine -TestMonitor $single.StableId -TestInput displayport1 -ReturnInput hdmi1 -ReturnAfterSeconds 3 -ConfigPath $sceneConfig -PassThru)
    Remove-Item Function:\Start-Sleep
    Assert-Equal ([MockDdcCiForTests]::Writes -join ',') '1:96:15,1:96:17' 'Calibration test and explicit return use one handle session'
    Assert-Equal ($calibration.Phase -join ',') 'Test,Return' 'Calibration phases'
    Assert-Equal @($calibration | Where-Object PhysicalVerified).Count 0 'Calibration primitive requires user confirmation'
    Assert-Released

    [MockDdcCiForTests]::Reset(1)
    [MockDdcCiForTests]::PermanentFailuresRemaining = 1
    Assert-Throws { & $engine -TestMonitor $single.StableId -TestInput displayport1 -ReturnInput hdmi1 -ReturnAfterSeconds 3 -ConfigPath $sceneConfig -PassThru } '*completed with 1 failure*'
    Assert-Equal ([MockDdcCiForTests]::Writes -join ',') '1:96:17' 'Return must still be attempted after the test write fails'
    Assert-Released
    $calibrationLog = @(Get-ChildItem -LiteralPath $env:MONITOR_TOOLS_LOG_DIRECTORY -Filter 'operation-*.json' | Sort-Object Name -Descending)[0]
    $calibrationRecord = Get-Content -LiteralPath $calibrationLog.FullName -Raw | ConvertFrom-Json
    Assert-Equal ($calibrationRecord.Results.Phase -join ',') 'Test,Return' 'Failed calibration records both phases'

    [MockDdcCiForTests]::Reset(1)
    $accepted = @(& $engine -SetAll hdmi1 -ConfigPath $sceneConfig -PassThru)
    $stale = @(& $engine -List -PassThru -ConfigPath $sceneConfig)
    Assert-Equal $accepted[0].ApiAccepted $true 'Mock accepts the write'
    Assert-Equal $accepted[0].PhysicalVerified $false 'Accepted write is not visual proof'
    Assert-Equal $stale[0].CurrentInputName 'displayport1' 'Stale readback simulation remains unchanged after accepted write'
    Assert-Released
    Write-Output 'PASS: truthful previews, stale readback, and best-effort calibration return'

    [MockMonitorIdentityForTests]::DuplicateIdentity = $true
    [MockDdcCiForTests]::Reset(2)
    $ambiguous = @(& $engine -List -PassThru -ConfigPath $sceneConfig)
    Assert-Equal ($ambiguous.IdentityStatus -join ',') 'ambiguous,ambiguous' 'Duplicate identity status'
    [MockDdcCiForTests]::Reset(2)
    Assert-Throws { & $engine -SetAll hdmi1 -ConfigPath $sceneConfig } '*is ambiguous*'
    Assert-Equal ([MockDdcCiForTests]::Writes.Count) 0 'Ambiguous identity must fail closed'
    Assert-Released
    Write-Output 'PASS: ambiguous identities fail closed'

    # Hold the exact per-user mutex in this process and verify a fresh process
    # times out before it can enumerate even the mocked monitors.
    $userIdentity = try { [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { [Environment]::UserName }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $mutexHash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($userIdentity)), 0, 10)).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
    $heldMutex = [Threading.Mutex]::new($false, "Local\MonitorTools.Switch.$mutexHash")
    $ownsMutex = $heldMutex.WaitOne(1000)
    Assert-True $ownsMutex 'Test must acquire the monitor mutex'
    $childPath = Join-Path $testRoot 'mutex-child.ps1'
    $childScript = @'
$ErrorActionPreference = 'Stop'
Add-Type -Path '__MOCK__'
$rawSource = [IO.File]::ReadAllText('__SWITCH__')
if (-not $rawSource.Contains('public static class DdcCiNativeV3') -or -not $rawSource.Contains('public static class MonitorIdentityNativeV1')) { exit 5 }
$source = $rawSource.Replace('DdcCiNativeV3', 'MockDdcCiForTests').Replace('MonitorIdentityNativeV1', 'MockMonitorIdentityForTests')
if ($source.Contains('DdcCiNativeV3') -or $source.Contains('MonitorIdentityNativeV1')) { exit 6 }
$engine = [scriptblock]::Create($source)
[MockDdcCiForTests]::Reset(1)
try { & $engine -List -PassThru -MutexWaitSeconds 1 -ConfigPath '__CONFIG__' | Out-Null; exit 2 }
catch { if ($_.Exception.Message -notlike '*still running*') { Write-Error $_; exit 3 } }
if ([MockDdcCiForTests]::Acquired.Count -ne 0) { exit 4 }
Write-Output 'MUTEX_OK'
'@
    $childScript = $childScript.Replace('__MOCK__', (Join-Path $PSScriptRoot 'MockDdcCi.cs')).Replace('__SWITCH__', $switchPath).Replace('__CONFIG__', $sceneConfig)
    [IO.File]::WriteAllText($childPath, $childScript)
    try {
        $childOutput = (& (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File $childPath 2>&1 | Out-String)
        Assert-Equal $LASTEXITCODE 0 'Mutex child exit code'
        Assert-True ($childOutput -match 'MUTEX_OK') 'A competing process must time out before enumeration'
    }
    finally { if ($ownsMutex) { $heldMutex.ReleaseMutex() }; $heldMutex.Dispose() }
    Write-Output 'PASS: cross-process per-user mutex prevents interleaving'

    # Compile only the production identity helper in a fresh process, then feed
    # synthetic strings and EDID bytes. No monitor or registry call is made.
    $identityChildPath = Join-Path $testRoot 'identity-child.ps1'
    $identityChild = @'
$ErrorActionPreference = 'Stop'
$source = [IO.File]::ReadAllText('__SWITCH__')
$marker = 'if (-not ("MonitorIdentityNativeV1"'
$block = $source.IndexOf($marker)
$start = $source.IndexOf('@"', $block) + 2
$end = $source.IndexOf('"@', $start)
Add-Type -Language CSharp -TypeDefinition $source.Substring($start, $end - $start)
$hardware = $null; $instance = $null
if (-not [MonitorIdentityNativeV1]::ParseDeviceInterface('\\?\DISPLAY#SAM1234#5&abc&0&UID1#{guid}', [ref]$hardware, [ref]$instance)) { exit 10 }
if ($hardware -ne 'SAM1234' -or $instance -ne '5&abc&0&UID1') { exit 11 }
$edid = New-Object byte[] 128
$word = (19 -shl 10) -bor (1 -shl 5) -bor 13
$edid[8] = ($word -shr 8); $edid[9] = ($word -band 255); $edid[10] = 0x34; $edid[11] = 0x12
$edid[54] = 0; $edid[55] = 0; $edid[56] = 0; $edid[57] = 0xFC; $edid[58] = 0
[Text.Encoding]::ASCII.GetBytes('G60SD        ').CopyTo($edid, 59)
$edid[72] = 0; $edid[73] = 0; $edid[74] = 0; $edid[75] = 0xFF; $edid[76] = 0
[Text.Encoding]::ASCII.GetBytes('SN123        ').CopyTo($edid, 77)
$identity = [MonitorIdentityNativeV1]::DecodeEdid($edid, 'device-path', 'display', 'fallback')
if ($identity.Manufacturer -ne 'SAM' -or $identity.ProductCode -ne '1234' -or $identity.Model -ne 'G60SD' -or $identity.Serial -ne 'SN123') { exit 12 }
Write-Output 'IDENTITY_OK'
'@
    [IO.File]::WriteAllText($identityChildPath, $identityChild.Replace('__SWITCH__', $switchPath))
    $identityOutput = (& (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File $identityChildPath 2>&1 | Out-String)
    Assert-Equal $LASTEXITCODE 0 'Identity parser child exit code'
    Assert-True ($identityOutput -match 'IDENTITY_OK') 'Native interface and EDID parsing'
    Write-Output 'PASS: native identity parsing with synthetic data'
}
finally {
    $env:MONITOR_TOOLS_LOG_DIRECTORY = $oldLogDirectory
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -notmatch '^monitor-tools-engine-[0-9a-f]{32}$') {
        throw 'Refusing to remove a path outside this test run.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Output "All engine tests passed on PowerShell $($PSVersionTable.PSVersion)."
