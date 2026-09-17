param([Parameter(Mandatory = $true)][string]$RepoRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-Host { param([string]$Prompt) throw "Unattended setup attempted to prompt: $Prompt" }
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('monitor-tools-install-' + [Guid]::NewGuid().ToString('N'))
$sourceRoot = Join-Path $testRoot 'Source Files'
$installedRoot = Join-Path $testRoot 'Installed App'
$dataRoot = "$installedRoot.data"
[void][IO.Directory]::CreateDirectory($sourceRoot)
[void][IO.Directory]::CreateDirectory((Join-Path $sourceRoot 'app'))
[IO.File]::WriteAllBytes((Join-Path $sourceRoot 'Setup.exe'), [byte[]](1, 2, 3))
[IO.File]::WriteAllBytes((Join-Path $sourceRoot 'app\MonitorTools.exe'), [byte[]](4, 5, 6))
try {
    foreach ($name in @(
            'Install.ps1', 'Setup.cmd', 'Run-Profile.ps1', 'Switch-MonitorInput.ps1',
            'Install-ProfileHotkeys.ps1', 'Repair.ps1', 'Uninstall.ps1', 'MonitorTools.Common.ps1',
            'VERSION', 'This-PC.cmd', 'Other-PC.cmd', 'Switch-To-This-PC.cmd',
            'Switch-To-Other-PC.cmd', 'README.md')) {
        Copy-Item -LiteralPath (Join-Path $RepoRoot $name) -Destination (Join-Path $sourceRoot $name)
    }
    $rawSwitchSource = Get-Content -LiteralPath (Join-Path $sourceRoot 'Switch-MonitorInput.ps1') -Raw
    if (-not $rawSwitchSource.Contains('public static class DdcCiNativeV3') -or -not $rawSwitchSource.Contains('public static class MonitorIdentityNativeV1')) {
        throw 'Mock injection markers changed; refusing to run setup tests.'
    }
    $mockSource = $rawSwitchSource.
        Replace('DdcCiNativeV3', 'MockDdcCiForTests').
        Replace('MonitorIdentityNativeV1', 'MockMonitorIdentityForTests')
    if ($mockSource.Contains('DdcCiNativeV3') -or $mockSource.Contains('MonitorIdentityNativeV1')) { throw 'Mock injection was incomplete; refusing to run setup tests.' }
    [IO.File]::WriteAllText((Join-Path $sourceRoot 'Switch-MonitorInput.ps1'), $mockSource)
    @'
param([switch]$Uninstall)
if (-not $Uninstall) { Set-Content -LiteralPath (Join-Path $PSScriptRoot 'hotkeys-requested.txt') -Value 'requested' }
'@ | Set-Content -LiteralPath (Join-Path $sourceRoot 'Install-ProfileHotkeys.ps1')

    $setup = Join-Path $sourceRoot 'Install.ps1'
    $richConfiguration = Join-Path $testRoot 'rich-configuration.json'
    $rich = Get-Content -LiteralPath (Join-Path $RepoRoot 'examples\two-monitors.json') -Raw | ConvertFrom-Json
    $rich | Add-Member -NotePropertyName schemaVersion -NotePropertyValue 2
    $rich | Add-Member -NotePropertyName settings -NotePropertyValue ([pscustomobject]@{ theme = 'system' })
    $rich | Add-Member -NotePropertyName hotkeys -NotePropertyValue ([pscustomobject]@{
        'this-pc' = 'Ctrl+Shift+F11'; diagnostics = 'Ctrl+Shift+F12'
    })
    [IO.File]::WriteAllText($richConfiguration, ($rich | ConvertTo-Json -Depth 10))
    [MockDdcCiForTests]::Reset(2)
    [MockMonitorIdentityForTests]::DuplicateIdentity = $false
    & $setup -Unattended -ConfigurationFile $richConfiguration `
        -InstallDirectory $installedRoot -EnableHotkeys -SkipRegistration | Out-Null
    $installedConfig = Join-Path $dataRoot 'monitor-profiles.json'
    $originalConfig = Get-Content -LiteralPath $installedConfig -Raw
    Assert-Equal (Test-Path -LiteralPath (Join-Path $installedRoot 'hotkeys-requested.txt')) $false 'Isolated setup creates no shortcuts'
    Assert-Equal (Test-Path -LiteralPath (Join-Path $installedRoot 'Run-Profile.ps1')) $true 'Setup copies runtime files'
    Assert-Equal (Test-Path -LiteralPath (Join-Path $installedRoot 'install-manifest.json')) $true 'Setup writes repair manifest'
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $installedRoot 'config-path.txt')).Trim()) $installedConfig 'Setup writes config pointer'
    Assert-Equal (($originalConfig | ConvertFrom-Json).schemaVersion) 2 'Legacy configuration migrates to schema 2'
    $installedObject = $originalConfig | ConvertFrom-Json
    Assert-Equal $installedObject.settings.theme 'system' 'Schema 2 settings survive installation'
    Assert-Equal $installedObject.hotkeys.'this-pc' 'Ctrl+Shift+F11' 'Custom hotkeys are preserved'
    Assert-Equal $installedObject.hotkeys.'other-pc' 'Ctrl+Alt+2' 'Missing default hotkey is added'
    Assert-Equal $installedObject.hotkeys.diagnostics 'Ctrl+Shift+F12' 'Additional hotkeys are preserved'
    Assert-Equal ([MockDdcCiForTests]::Writes.Count) 0 'Installation never switches inputs'
    Assert-HandlesReleased

    # A second move failure restores the old app before configuration changes.
    $priorVersion = [IO.File]::ReadAllText((Join-Path $installedRoot 'VERSION'))
    [IO.File]::WriteAllText((Join-Path $sourceRoot 'VERSION'), '2.0.1')
    [MockDdcCiForTests]::Reset(1)
    Assert-Throws {
        & $setup -Unattended -ConfigurationFile (Join-Path $RepoRoot 'examples\one-monitor.json') `
            -InstallDirectory $installedRoot -SkipRegistration -TestFailureBeforeActivation
    } '*Injected failure before application activation*'
    Assert-Equal ([IO.File]::ReadAllText((Join-Path $installedRoot 'VERSION'))) $priorVersion 'Move failure restores prior app'
    Assert-Equal (Get-Content -LiteralPath $installedConfig -Raw) $originalConfig 'Move failure preserves prior configuration'
    [IO.File]::WriteAllText((Join-Path $sourceRoot 'VERSION'), $priorVersion)
    Assert-HandlesReleased

    [MockDdcCiForTests]::Reset(1)
    & $setup -Unattended -ConfigurationFile (Join-Path $RepoRoot 'examples\one-monitor.json') `
        -InstallDirectory $installedRoot -SkipRegistration | Out-Null
    $backups = @(Get-ChildItem -LiteralPath $dataRoot -Filter '*.bak')
    Assert-Equal $backups.Count 1 'Replacing profiles creates one data backup'
    Assert-Equal (Get-Content -LiteralPath $backups[0].FullName -Raw) $originalConfig 'Backup retains original profile bytes'
    $updatedConfig = Get-Content -LiteralPath $installedConfig -Raw
    Assert-Equal (($updatedConfig | ConvertFrom-Json).profiles.'this-pc'.center) 'displayport1' 'Replacement configuration is installed'
    Assert-Equal ([MockDdcCiForTests]::Writes.Count) 0 'Upgrade never switches inputs'
    Assert-HandlesReleased

    [MockDdcCiForTests]::Reset(1)
    Assert-Throws {
        & $setup -Unattended -ConfigurationFile (Join-Path $RepoRoot 'examples\two-monitors.json') `
            -InstallDirectory $installedRoot -SkipRegistration
    } '*Profile preview failed*'
    Assert-Equal (Get-Content -LiteralPath $installedConfig -Raw) $updatedConfig 'Invalid assignments preserve installed profiles'
    Assert-Equal @(Get-ChildItem -LiteralPath $dataRoot -Filter '*.bak').Count 1 'Validation failure creates no new backups'
    Assert-HandlesReleased

    # Repair-style in-place setup follows the absolute configuration pointer.
    [MockDdcCiForTests]::Reset(1)
    & (Join-Path $installedRoot 'Install.ps1') -Unattended -InstallDirectory $installedRoot `
        -PreserveRegistration -SkipRegistration | Out-Null
    Assert-Equal (Get-Content -LiteralPath $installedConfig -Raw) $updatedConfig 'In-place setup preserves separate configuration'
    Assert-Equal (Test-Path -LiteralPath (Join-Path $installedRoot 'monitor-profiles.json')) $false 'Configuration does not return to app directory'
    Assert-HandlesReleased

    # Repair verification never changes external state.
    & (Join-Path $installedRoot 'Repair.ps1') -VerifyOnly -Quiet
    Add-Content -LiteralPath (Join-Path $installedRoot 'README.md') -Value 'tampered for repair test'
    Assert-Throws { & (Join-Path $installedRoot 'Repair.ps1') -VerifyOnly -Quiet } '*failed verification*'
    $repairRecordPath = Join-Path $testRoot 'repair-launch.json'
    & (Join-Path $installedRoot 'Repair.ps1') -Quiet -TestLaunchRecordPath $repairRecordPath
    $repairLaunch = [IO.File]::ReadAllText($repairRecordPath) | ConvertFrom-Json
    Assert-Equal $repairLaunch.WorkerExisted $true 'Repair launches a copied setup worker'
    Assert-Equal $repairLaunch.Arguments ('--repair-target "' + $installedRoot + '"') 'Repair worker receives explicit install target'
    Assert-Equal (Test-Path -LiteralPath (Split-Path -Parent $repairLaunch.FilePath)) $false 'Repair worker directory is cleaned'

    # WhatIf exercises uninstall targeting without touching files, shortcuts, or registry.
    & (Join-Path $installedRoot 'Uninstall.ps1') -RemoveConfiguration -SkipRegistration -Quiet -WhatIf
    Assert-Equal (Test-Path -LiteralPath $installedRoot) $true 'Uninstall preview preserves application'
    Assert-Equal (Test-Path -LiteralPath $installedConfig) $true 'Uninstall preview preserves configuration'
    $manifestPath = Join-Path $installedRoot 'install-manifest.json'
    $manifestText = [IO.File]::ReadAllText($manifestPath)
    $wrongManifest = $manifestText | ConvertFrom-Json
    $wrongManifest.installDirectory = $testRoot
    [IO.File]::WriteAllText($manifestPath, ($wrongManifest | ConvertTo-Json -Depth 10))
    Assert-Throws { & (Join-Path $installedRoot 'Uninstall.ps1') -SkipRegistration -Quiet -WhatIf } '*manifest does not own*'
    [IO.File]::WriteAllText($manifestPath, $manifestText)

    # A pre-2.0 installation migrates its in-app JSON to the separate data directory.
    $legacyRoot = Join-Path $testRoot 'Legacy App'
    [void][IO.Directory]::CreateDirectory($legacyRoot)
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'Install.ps1') -Destination $legacyRoot
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'Switch-MonitorInput.ps1') -Destination $legacyRoot
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'examples\one-monitor.json') -Destination (Join-Path $legacyRoot 'monitor-profiles.json')
    [MockDdcCiForTests]::Reset(1)
    & $setup -Unattended -InstallDirectory $legacyRoot -SkipRegistration | Out-Null
    $migratedPath = Join-Path ($legacyRoot + '.data') 'monitor-profiles.json'
    Assert-Equal (Test-Path -LiteralPath $migratedPath) $true 'Legacy configuration migrates outside the app directory'
    Assert-Equal @(Get-ChildItem -LiteralPath ($legacyRoot + '.data') -Filter '*.legacy-*.bak').Count 1 'Legacy migration retains an explicit backup'
    Assert-HandlesReleased
    [IO.File]::WriteAllText((Join-Path $legacyRoot 'user-note.txt'), 'preserve me')
    & (Join-Path $legacyRoot 'Uninstall.ps1') -SkipRegistration -Quiet
    Assert-Equal (Test-Path -LiteralPath (Join-Path $legacyRoot 'user-note.txt')) $true 'Uninstall preserves unowned files'
    Assert-Equal (Test-Path -LiteralPath $migratedPath) $true 'Uninstall retains configuration by default'
    Assert-Equal (Test-Path -LiteralPath (Join-Path $legacyRoot 'Switch-MonitorInput.ps1')) $false 'Uninstall removes manifest-owned files'
}
finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolved) -notmatch '^monitor-tools-install-[0-9a-f]{32}$') {
        throw 'Refusing to remove a directory outside this setup test.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Output 'PASS: staged setup, separate configuration, upgrades, backups, migration, and repair verification'
