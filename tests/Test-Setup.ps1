param([Parameter(Mandatory = $true)][string]$RepoRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Called by Run-Tests.ps1, which provides assertions and the native mock.
function Read-Host { param([string]$Prompt) throw "Unattended setup attempted to prompt: $Prompt" }
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('monitor-tools-install-' + [Guid]::NewGuid().ToString('N'))
$sourceRoot = Join-Path $testRoot 'Source Files'
$installedRoot = Join-Path $testRoot 'Installed App'
[void][System.IO.Directory]::CreateDirectory($sourceRoot)
try {
    foreach ($name in @('Install.ps1', 'Setup.cmd', 'Run-Profile.ps1', 'Switch-MonitorInput.ps1',
        'This-PC.cmd', 'Other-PC.cmd', 'Switch-To-This-PC.cmd', 'Switch-To-Other-PC.cmd', 'README.md')) {
        Copy-Item -LiteralPath (Join-Path $RepoRoot $name) -Destination (Join-Path $sourceRoot $name)
    }
    $mockSource = (Get-Content -LiteralPath (Join-Path $sourceRoot 'Switch-MonitorInput.ps1') -Raw).Replace('DdcCiNativeV2', 'MockDdcCiForTests')
    [System.IO.File]::WriteAllText((Join-Path $sourceRoot 'Switch-MonitorInput.ps1'), $mockSource)
    @'
Set-Content -LiteralPath (Join-Path $PSScriptRoot 'hotkeys-requested.txt') -Value 'requested'
'@ | Set-Content -LiteralPath (Join-Path $sourceRoot 'Install-ProfileHotkeys.ps1')

    $setup = Join-Path $sourceRoot 'Install.ps1'
    [MockDdcCiForTests]::Reset(2)
    & $setup -Unattended -ConfigurationFile (Join-Path $RepoRoot 'examples\two-monitors.json') -InstallDirectory $installedRoot -EnableHotkeys | Out-Null
    $installedConfig = Join-Path $installedRoot 'monitor-profiles.json'
    $originalConfig = Get-Content -LiteralPath $installedConfig -Raw
    Assert-Equal (Test-Path -LiteralPath (Join-Path $installedRoot 'hotkeys-requested.txt')) $true 'Setup requests chosen hotkeys'
    Assert-Equal (Test-Path -LiteralPath (Join-Path $installedRoot 'Run-Profile.ps1')) $true 'Setup copies runtime files'
    Assert-Equal ([MockDdcCiForTests]::Writes.Count) 0 'Installation never switches inputs'
    Assert-HandlesReleased

    [MockDdcCiForTests]::Reset(1)
    & $setup -Unattended -ConfigurationFile (Join-Path $RepoRoot 'examples\one-monitor.json') -InstallDirectory $installedRoot | Out-Null
    $backups = @(Get-ChildItem -LiteralPath $installedRoot -Filter '*.bak')
    Assert-Equal $backups.Count 1 'Replacing profiles creates one backup'
    Assert-Equal (Get-Content -LiteralPath $backups[0].FullName -Raw) $originalConfig 'Backup retains original profile bytes'
    $updatedConfig = Get-Content -LiteralPath $installedConfig -Raw
    Assert-Equal (($updatedConfig | ConvertFrom-Json).profiles.'this-pc'.center) 'displayport1' 'Replacement configuration is installed'
    Assert-Equal ([MockDdcCiForTests]::Writes.Count) 0 'Upgrade never switches inputs'
    Assert-HandlesReleased

    [MockDdcCiForTests]::Reset(1)
    Assert-Throws {
        & $setup -Unattended -ConfigurationFile (Join-Path $RepoRoot 'examples\two-monitors.json') -InstallDirectory $installedRoot
    } '*Profile preview failed*'
    Assert-Equal (Get-Content -LiteralPath $installedConfig -Raw) $updatedConfig 'Invalid assignments preserve installed profiles'
    Assert-Equal @(Get-ChildItem -LiteralPath $installedRoot -Filter '*.bak').Count 1 'Validation failure creates no new backups'
    Assert-HandlesReleased

    # Reconfigure using the installed copy, exercising identical source/destination paths.
    [MockDdcCiForTests]::Reset(1)
    & (Join-Path $installedRoot 'Install.ps1') -Unattended -ConfigurationFile $installedConfig -InstallDirectory $installedRoot | Out-Null
    Assert-Equal (Get-Content -LiteralPath $installedConfig -Raw) $updatedConfig 'In-place setup preserves chosen configuration'
    Assert-HandlesReleased
}
finally {
    $resolved = [System.IO.Path]::GetFullPath($testRoot)
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolved) -notmatch '^monitor-tools-install-[0-9a-f]{32}$') {
        throw 'Refusing to remove a directory outside this setup test.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Output 'PASS: unattended setup, upgrades, backups, and invalid-configuration preservation'
