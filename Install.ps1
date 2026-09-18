[CmdletBinding()]
param(
    [string]$InstallDirectory,
    [switch]$Unattended,
    [string]$ConfigurationFile,
    [switch]$EnableHotkeys,
    [switch]$StartAtLogin,
    [switch]$PreserveRegistration,
    [switch]$SkipRegistration,
    [ValidateRange(1, 300)][int]$DeploymentMutexWaitSeconds = 60,
    [Parameter(DontShow = $true)][switch]$TestFailureAfterActivation,
    [Parameter(DontShow = $true)][switch]$TestFailureBeforeActivation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-YesNo {
    param([string]$Prompt, [bool]$Default = $false)
    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $answer = (Read-Host "$Prompt [$hint]").Trim().ToLowerInvariant()
        if ($answer -eq '') { return $Default }
        if ($answer -in @('y', 'yes')) { return $true }
        if ($answer -in @('n', 'no')) { return $false }
        Write-Host 'Enter y or n.'
    }
}

function Read-MonitorInput {
    param([string]$Prompt)
    $inputs = @('displayport1', 'hdmi1', 'hdmi2', 'displayport2', 'dvi1', 'dvi2', 'vga1')
    while ($true) {
        $answer = (Read-Host $Prompt).Trim().ToLowerInvariant()
        if ($answer -match '^[1-7]$') { return $inputs[[int]$answer - 1] }
        if ($inputs -contains $answer -or $answer -match '^0x[0-9a-f]{1,2}$') { return $answer }
        Write-Host 'Choose 1-7, enter an input name shown above, or enter a hardware-tested hex code (such as 0x05).'
    }
}

function ConvertTo-CurrentConfiguration {
    param([Parameter(Mandatory = $true)][string]$Json, [bool]$UseHotkeys)
    $config = $Json | ConvertFrom-Json
    # Validate before migration so a future schema is rejected rather than silently downgraded.
    Test-MonitorToolsConfig -Config $config | Out-Null
    if ($null -eq $config.PSObject.Properties['schemaVersion']) {
        $config | Add-Member -NotePropertyName schemaVersion -NotePropertyValue 2
    }
    else { $config.schemaVersion = 2 }
    if ($UseHotkeys) {
        if ($null -eq $config.PSObject.Properties['hotkeys']) {
            $config | Add-Member -NotePropertyName hotkeys -NotePropertyValue ([pscustomobject]@{})
        }
        foreach ($default in @{ 'this-pc' = 'Ctrl+Alt+1'; 'other-pc' = 'Ctrl+Alt+2' }.GetEnumerator()) {
            if ($null -eq $config.hotkeys.PSObject.Properties[$default.Key]) {
                $config.hotkeys | Add-Member -NotePropertyName $default.Key -NotePropertyValue $default.Value
            }
        }
    }
    elseif ($null -ne $config.PSObject.Properties['hotkeys']) {
        $config.PSObject.Properties.Remove('hotkeys')
    }
    return ($config | ConvertTo-Json -Depth 20)
}

function Assert-SafeSiblingPath {
    param([string]$Candidate, [string]$Parent, [string]$ExpectedPrefix)
    $resolvedCandidate = [IO.Path]::GetFullPath($Candidate)
    $resolvedParent = [IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
    if (-not $resolvedCandidate.StartsWith($resolvedParent, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolvedCandidate) -notlike "$ExpectedPrefix*") {
        throw "Refusing to modify unexpected staging path '$resolvedCandidate'."
    }
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($algorithm.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose(); $stream.Dispose() }
}

function Get-DeploymentMutexName {
    param([string]$Path)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $material = [Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($Path).ToUpperInvariant())
        $key = [BitConverter]::ToString($algorithm.ComputeHash($material)).Replace('-', '')
        return 'Local\MonitorTools.Install.' + $key
    }
    finally { $algorithm.Dispose() }
}

$requiredFiles = @(
    'Switch-MonitorInput.ps1', 'Run-Profile.ps1', 'Install-ProfileHotkeys.ps1',
    'Install.ps1', 'Repair.ps1', 'Uninstall.ps1', 'MonitorTools.Common.ps1', 'Setup.cmd',
    'This-PC.cmd', 'Other-PC.cmd', 'Switch-To-This-PC.cmd', 'Switch-To-Other-PC.cmd',
    'README.md', 'VERSION'
)
foreach ($name in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $name) -PathType Leaf)) {
        throw "Setup is missing '$name'. Extract the entire download before running Setup.cmd."
    }
}

$defaultInstallDirectory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Monitor Tools\app'
if ([string]::IsNullOrWhiteSpace($InstallDirectory)) { $InstallDirectory = $defaultInstallDirectory }
$InstallDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($InstallDirectory)
$installParent = Split-Path -Parent $InstallDirectory
$dataDirectory = if ($InstallDirectory.Equals($defaultInstallDirectory, [StringComparison]::OrdinalIgnoreCase)) {
    Join-Path $installParent 'data'
}
else { "$InstallDirectory.data" }
$configPath = Join-Path $dataDirectory 'monitor-profiles.json'

. (Join-Path $PSScriptRoot 'MonitorTools.Common.ps1')
if (Test-Path -LiteralPath (Join-Path $InstallDirectory 'config-path.txt') -PathType Leaf) {
    try {
        $existingPointer = Get-MonitorToolsConfigPath -Root $InstallDirectory
        if (-not [string]::IsNullOrWhiteSpace($existingPointer) -and (Test-Path -LiteralPath $existingPointer -PathType Leaf)) {
            $configPath = $existingPointer
            $dataDirectory = Split-Path -Parent $configPath
        }
    }
    catch { }
}
$legacyConfigPath = Join-Path $InstallDirectory 'monitor-profiles.json'
$legacyConfigBytes = if (Test-Path -LiteralPath $legacyConfigPath -PathType Leaf) {
    [IO.File]::ReadAllBytes($legacyConfigPath)
}
else { $null }
$switchPath = Join-Path $PSScriptRoot 'Switch-MonitorInput.ps1'

if (Test-Path -LiteralPath $InstallDirectory -PathType Container) {
    $existingItems = @(Get-ChildItem -LiteralPath $InstallDirectory -Force)
    if ($existingItems.Count -gt 0) {
        $manifestPath = Join-Path $InstallDirectory 'install-manifest.json'
        $recognized = $false
        if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
            try { $recognized = ((Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json).product -eq 'Monitor Tools') } catch { }
        }
        $legacyRecognized = (Test-Path -LiteralPath (Join-Path $InstallDirectory 'Switch-MonitorInput.ps1') -PathType Leaf) -and
            (Test-Path -LiteralPath (Join-Path $InstallDirectory 'Install.ps1') -PathType Leaf)
        if (-not $recognized -and -not $legacyRecognized) {
            throw "InstallDirectory '$InstallDirectory' is not empty and is not a recognized Monitor Tools installation. Choose a new folder."
        }
        $reparsePoint = Get-ChildItem -LiteralPath $InstallDirectory -Force -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } | Select-Object -First 1
        if ($null -ne $reparsePoint) { throw "InstallDirectory contains a reparse point and cannot be upgraded safely: $($reparsePoint.FullName)" }
    }
}

Write-Host "`nMonitor Tools Setup"
Write-Host "Application location: $InstallDirectory"
Write-Host "Configuration location: $configPath"
Write-Host 'Setup reads monitors and previews your choices. It does not switch inputs.'
$monitors = @()
if (-not $PreserveRegistration) {
    Write-Host "`nDetecting monitors..."
    $monitors = @(& $switchPath -List -PassThru)
    $monitors | Format-Table Index, Position, Description, CurrentInput -AutoSize | Out-Host
}

$existingConfigPath = if (Test-Path -LiteralPath $configPath -PathType Leaf) { $configPath }
elseif (Test-Path -LiteralPath $legacyConfigPath -PathType Leaf) { $legacyConfigPath }
else { $null }
$observedConfigPath = if ($null -ne $existingConfigPath) { $existingConfigPath } else { $configPath }
$observedConfigBytes = if ([IO.File]::Exists($observedConfigPath)) { [IO.File]::ReadAllBytes($observedConfigPath) } else { $null }
$keepProfiles = $false
if ($Unattended -and [string]::IsNullOrWhiteSpace($ConfigurationFile)) {
    if ($null -eq $existingConfigPath) { throw 'Unattended setup requires ConfigurationFile for a new installation.' }
    $keepProfiles = $true
}
elseif (-not $Unattended -and $null -ne $existingConfigPath) {
    Write-Host "Existing profiles found: $existingConfigPath"
    $keepProfiles = Read-YesNo 'Keep these profiles while updating the installed files?' -Default $true
}

if (-not [string]::IsNullOrWhiteSpace($ConfigurationFile)) {
    $configJson = [IO.File]::ReadAllText($ConfigurationFile)
}
elseif ($keepProfiles) {
    $configJson = [IO.File]::ReadAllText($existingConfigPath)
}
else {
    $thisPc = [ordered]@{}
    $otherPc = [ordered]@{}
    Write-Host "`nChoose the input connected to each computer, for each monitor:"
    foreach ($monitor in $monitors) {
        Write-Host "`n$($monitor.Position): $($monitor.Description) [$($monitor.DisplayDevice)]"
        $thisPc[$monitor.Position] = Read-MonitorInput 'Input connected to THIS computer'
        $otherPc[$monitor.Position] = Read-MonitorInput 'Input connected to the OTHER computer'
    }
    $configJson = [ordered]@{ profiles = [ordered]@{ 'this-pc' = $thisPc; 'other-pc' = $otherPc } } |
        ConvertTo-Json -Depth 5
}

$trayAvailable = Test-Path -LiteralPath (Join-Path $PSScriptRoot 'app\MonitorTools.exe') -PathType Leaf
if ($trayAvailable -and -not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'app\MonitorTools.Worker.exe') -PathType Leaf)) {
    throw 'Setup is missing app\MonitorTools.Worker.exe. Download the complete setup package.'
}
$installHotkeys = if ($PreserveRegistration) {
    ($configJson | ConvertFrom-Json).PSObject.Properties['hotkeys'] -ne $null
} elseif ($Unattended) { $EnableHotkeys.IsPresent } else {
    Read-YesNo 'Enable Ctrl+Alt+1 / Ctrl+Alt+2 after testing both directions?'
}
$existingStartup = $false
if ($PreserveRegistration -and -not $SkipRegistration) {
    $existingStartup = $null -ne (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name MonitorTools -ErrorAction SilentlyContinue)
}
$startTray = if ($PreserveRegistration) { $existingStartup } elseif ($Unattended) { $StartAtLogin.IsPresent } elseif ($trayAvailable) {
    Read-YesNo 'Start Monitor Tools automatically when you sign in?' -Default $true
}
else { $false }
$configJson = ConvertTo-CurrentConfiguration -Json $configJson -UseHotkeys ($installHotkeys -and $trayAvailable)
Test-MonitorToolsConfig -Config ($configJson | ConvertFrom-Json) | Out-Null

if (-not $PreserveRegistration) {
    Write-Host "`nReview profiles (no input changes):"
    $previewPath = [IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllText($previewPath, $configJson)
        $previewConfig = $configJson | ConvertFrom-Json
        foreach ($profile in @($previewConfig.profiles.PSObject.Properties.Name)) {
            try { & $switchPath -Profile $profile -ConfigPath $previewPath -WhatIf | Out-Host }
            catch { throw "Profile preview failed: $($_.Exception.Message) Installed files have not been changed." }
        }
    }
    finally { Remove-Item -LiteralPath $previewPath -Force -ErrorAction SilentlyContinue }
}

Write-Host 'A preview checks assignments, not physical switching or the return path.'
Write-Host "Install hotkeys: $installHotkeys"
Write-Host "Start at sign-in: $startTray"
if (-not $Unattended -and -not (Read-YesNo 'Install with these settings?' -Default $true)) {
    Write-Host 'Setup cancelled. Installed files and shortcuts were not changed.'
    return
}

[void][IO.Directory]::CreateDirectory($installParent)
$leaf = Split-Path -Leaf $InstallDirectory
$stagePath = Join-Path $installParent ('.' + $leaf + '.stage-' + [Guid]::NewGuid().ToString('N'))
$rollbackPath = Join-Path $installParent ('.' + $leaf + '.rollback-' + [Guid]::NewGuid().ToString('N'))
Assert-SafeSiblingPath $stagePath $installParent ('.' + $leaf + '.stage-')
Assert-SafeSiblingPath $rollbackPath $installParent ('.' + $leaf + '.rollback-')
$appActivated = $false
$oldMoved = $false
$installSucceeded = $false
$previousConfig = $null
$configurationMutex = $null
$configurationLocked = $false
$configurationWriteStarted = $false
$deploymentMutex = [Threading.Mutex]::new($false, (Get-DeploymentMutexName -Path $InstallDirectory))
$deploymentLocked = $false
try { $deploymentLocked = $deploymentMutex.WaitOne($DeploymentMutexWaitSeconds * 1000) }
catch [Threading.AbandonedMutexException] { $deploymentLocked = $true }
if (-not $deploymentLocked) {
    $deploymentMutex.Dispose()
    throw "Another Monitor Tools setup is updating '$InstallDirectory'. Try again after it finishes."
}

try {
    [void][IO.Directory]::CreateDirectory($stagePath)
    if (Test-Path -LiteralPath $InstallDirectory -PathType Container) {
        foreach ($existingItem in @(Get-ChildItem -LiteralPath $InstallDirectory -Force)) {
            Copy-Item -LiteralPath $existingItem.FullName -Destination $stagePath -Recurse -Force
        }
    }
    $managedPaths = New-Object System.Collections.Generic.List[string]
    $files = @($requiredFiles | ForEach-Object { Get-Item -LiteralPath (Join-Path $PSScriptRoot $_) })
    foreach ($name in @('AGENTS.md', 'TESTING-NOTES.md', 'Export-Diagnostics.ps1', 'monitor-compatibility.json',
            'Setup.exe', 'docs', 'examples', 'tests', 'app')) {
        $optionalPath = Join-Path $PSScriptRoot $name
        if (Test-Path -LiteralPath $optionalPath) {
            if ((Get-Item -LiteralPath $optionalPath) -is [IO.DirectoryInfo]) {
                $files += @(Get-ChildItem -LiteralPath $optionalPath -File -Recurse)
            }
            else { $files += @(Get-Item -LiteralPath $optionalPath) }
        }
    }
    foreach ($file in $files) {
        $relativePath = $file.FullName.Substring($PSScriptRoot.Length).TrimStart('\', '/')
        $destination = Join-Path $stagePath $relativePath
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
        Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
        $managedPaths.Add($relativePath.Replace('\', '/'))
    }
    [IO.File]::WriteAllText((Join-Path $stagePath 'config-path.txt'), [IO.Path]::GetFullPath($configPath))
    $managedPaths.Add('config-path.txt')
    $manifestFiles = @($managedPaths | Select-Object -Unique | ForEach-Object {
        $managedFile = Get-Item -LiteralPath (Join-Path $stagePath $_)
        [ordered]@{
            path = $_
            sha256 = Get-Sha256 -Path $managedFile.FullName
        }
    })
    [IO.File]::WriteAllText((Join-Path $stagePath 'install-manifest.json'), ([ordered]@{
        product = 'Monitor Tools'; version = (Get-Content -LiteralPath (Join-Path $stagePath 'VERSION') -Raw).Trim()
        installDirectory = [IO.Path]::GetFullPath($InstallDirectory)
        configPath = [IO.Path]::GetFullPath($configPath)
        installedAtUtc = [DateTime]::UtcNow.ToString('o'); files = $manifestFiles
    } | ConvertTo-Json -Depth 5))

    Stop-MonitorToolsProcesses -Root $InstallDirectory
    # Serialize deployment with editor/script saves and reject choices based on stale profiles.
    $configurationHash = [Security.Cryptography.SHA256]::Create()
    try {
        $configurationKey = [BitConverter]::ToString($configurationHash.ComputeHash(
            [Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($configPath).ToUpperInvariant()))).Replace('-', '')
    }
    finally { $configurationHash.Dispose() }
    $configurationMutex = [Threading.Mutex]::new($false, ('Local\MonitorTools.Config.' + $configurationKey))
    try { $configurationLocked = $configurationMutex.WaitOne(5000) }
    catch [Threading.AbandonedMutexException] { $configurationLocked = $true }
    if (-not $configurationLocked) { throw 'Another process is saving profiles. Run setup again after it completes.' }
    $currentConfigBytes = if ([IO.File]::Exists($observedConfigPath)) { [IO.File]::ReadAllBytes($observedConfigPath) } else { $null }
    $configurationChanged = ($null -eq $observedConfigBytes) -ne ($null -eq $currentConfigBytes)
    if (-not $configurationChanged -and $null -ne $observedConfigBytes) {
        $configurationChanged = [Convert]::ToBase64String($observedConfigBytes) -cne [Convert]::ToBase64String($currentConfigBytes)
    }
    if ($configurationChanged) { throw 'Profiles changed while setup was open. Run setup again to use the latest settings.' }
    $previousConfig = if ([IO.File]::Exists($configPath)) { [IO.File]::ReadAllBytes($configPath) } else { $null }
    if (Test-Path -LiteralPath $InstallDirectory) {
        Move-Item -LiteralPath $InstallDirectory -Destination $rollbackPath
        $oldMoved = $true
    }
    if ($TestFailureBeforeActivation) { throw 'Injected failure before application activation.' }
    Move-Item -LiteralPath $stagePath -Destination $InstallDirectory
    $appActivated = $true
    if ($TestFailureAfterActivation) { throw 'Injected failure after application activation.' }

    [void][IO.Directory]::CreateDirectory($dataDirectory)
    $configurationWriteStarted = $true
    Save-MonitorToolsConfig -Config ($configJson | ConvertFrom-Json) -Path $configPath | Out-Null
    if ($null -ne $legacyConfigBytes -and -not $legacyConfigPath.Equals($configPath, [StringComparison]::OrdinalIgnoreCase)) {
        $legacyBackup = "$configPath.legacy-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')).bak"
        [IO.File]::WriteAllBytes($legacyBackup, $legacyConfigBytes)
        Remove-Item -LiteralPath $legacyConfigPath -Force -ErrorAction SilentlyContinue
    }

    if (-not $SkipRegistration -and $installHotkeys -and -not $trayAvailable) {
        & (Join-Path $InstallDirectory 'Install-ProfileHotkeys.ps1') | Out-Host
    }
    elseif (-not $SkipRegistration) {
        & (Join-Path $InstallDirectory 'Install-ProfileHotkeys.ps1') -Uninstall -ErrorAction SilentlyContinue | Out-Null
    }

    if (-not $SkipRegistration) {
        $version = (Get-Content -LiteralPath (Join-Path $InstallDirectory 'VERSION') -Raw).Trim()
        $powerShellPath = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'
        $uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\MonitorTools'
        [void](New-Item -Path $uninstallKey -Force)
        $uninstallCommand = '"' + $powerShellPath + '" -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $InstallDirectory 'Uninstall.ps1') + '"'
        $repairCommand = '"' + $powerShellPath + '" -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $InstallDirectory 'Repair.ps1') + '"'
        foreach ($property in ([ordered]@{
                DisplayName = 'Monitor Tools'; DisplayVersion = $version; Publisher = 'Monitor Tools'
                InstallLocation = $InstallDirectory; DisplayIcon = (Join-Path $InstallDirectory 'app\MonitorTools.exe')
                UninstallString = $uninstallCommand; QuietUninstallString = $uninstallCommand + ' -Quiet'
                ModifyPath = $repairCommand
            }).GetEnumerator()) {
            [void](New-ItemProperty -Path $uninstallKey -Name $property.Key -Value $property.Value -PropertyType String -Force)
        }
        [void](New-ItemProperty -Path $uninstallKey -Name NoModify -Value 0 -PropertyType DWord -Force)
        [void](New-ItemProperty -Path $uninstallKey -Name NoRepair -Value 0 -PropertyType DWord -Force)
        $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        if ($startTray -and (Test-Path -LiteralPath (Join-Path $InstallDirectory 'app\MonitorTools.exe'))) {
            [void](New-Item -Path $runKey -Force)
            [void](New-ItemProperty -Path $runKey -Name MonitorTools -Value ('"' + (Join-Path $InstallDirectory 'app\MonitorTools.exe') + '"') -PropertyType String -Force)
        }
        else { Remove-ItemProperty -Path $runKey -Name MonitorTools -ErrorAction SilentlyContinue }

        if (Test-Path -LiteralPath (Join-Path $InstallDirectory 'app\MonitorTools.exe')) {
            $shortcutDirectory = Join-Path ([Environment]::GetFolderPath('Programs')) 'Monitor Tools'
            [void][IO.Directory]::CreateDirectory($shortcutDirectory)
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut((Join-Path $shortcutDirectory 'Monitor Tools.lnk'))
            $shortcut.TargetPath = Join-Path $InstallDirectory 'app\MonitorTools.exe'
            $shortcut.WorkingDirectory = $InstallDirectory
            $shortcut.Description = 'Open Monitor Tools.'
            $shortcut.Save()
        }
    }
    $installSucceeded = $true
}
catch {
    $failure = $_
    try {
        if ($appActivated -and (Test-Path -LiteralPath $InstallDirectory)) { Remove-Item -LiteralPath $InstallDirectory -Recurse -Force }
        if ($oldMoved -and (Test-Path -LiteralPath $rollbackPath) -and -not (Test-Path -LiteralPath $InstallDirectory)) {
            Move-Item -LiteralPath $rollbackPath -Destination $InstallDirectory
        }
    }
    catch {
        throw "Installation failed: $($failure.Exception.Message) Rollback is preserved at '$rollbackPath' because restoration also failed: $($_.Exception.Message)"
    }
    if ($configurationWriteStarted -and $null -ne $previousConfig) {
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $configPath))
        [IO.File]::WriteAllBytes($configPath, $previousConfig)
    }
    elseif ($configurationWriteStarted -and (Test-Path -LiteralPath $configPath)) { Remove-Item -LiteralPath $configPath -Force }
    throw $failure
}
finally {
    try {
        foreach ($temporaryPath in @($stagePath)) {
            if (Test-Path -LiteralPath $temporaryPath) {
                Assert-SafeSiblingPath $temporaryPath $installParent ('.' + $leaf + '.')
                Remove-Item -LiteralPath $temporaryPath -Recurse -Force
            }
        }
        if ($installSucceeded -and (Test-Path -LiteralPath $rollbackPath)) {
            Assert-SafeSiblingPath $rollbackPath $installParent ('.' + $leaf + '.rollback-')
            Remove-Item -LiteralPath $rollbackPath -Recurse -Force
        }
    }
    finally {
        if ($configurationLocked) { $configurationMutex.ReleaseMutex() }
        if ($null -ne $configurationMutex) { $configurationMutex.Dispose() }
        if ($deploymentLocked) { $deploymentMutex.ReleaseMutex() }
        $deploymentMutex.Dispose()
    }
}

Write-Host "`nMonitor Tools $((Get-Content -LiteralPath (Join-Path $InstallDirectory 'VERSION') -Raw).Trim()) installed."
Write-Host "Application: $InstallDirectory"
Write-Host "Configuration: $configPath"
Write-Host 'Setup did not physically switch the monitors. Use guided verification before relying on automatic return.'
