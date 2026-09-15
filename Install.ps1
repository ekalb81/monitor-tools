[CmdletBinding()]
param(
    [string]$InstallDirectory,
    [switch]$Unattended,
    [string]$ConfigurationFile,
    [switch]$EnableHotkeys
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

$requiredFiles = @(
    'Switch-MonitorInput.ps1', 'Run-Profile.ps1', 'Install-ProfileHotkeys.ps1',
    'Install.ps1', 'Setup.cmd', 'This-PC.cmd', 'Other-PC.cmd',
    'Switch-To-This-PC.cmd', 'Switch-To-Other-PC.cmd', 'README.md'
)
foreach ($name in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $name) -PathType Leaf)) {
        throw "Setup is missing '$name'. Extract the entire download before running Setup.cmd."
    }
}
if ([string]::IsNullOrWhiteSpace($InstallDirectory)) {
    $InstallDirectory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Monitor Tools\app'
}
$InstallDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($InstallDirectory)
$configPath = Join-Path $InstallDirectory 'monitor-profiles.json'
$switchPath = Join-Path $PSScriptRoot 'Switch-MonitorInput.ps1'

Write-Host "`nMonitor Tools Setup"
Write-Host "Install location: $InstallDirectory"
Write-Host 'Setup reads monitors and previews your choices. It does not switch inputs.'
Write-Host 'Connect both computers to the monitors. Check the input labels on the monitor ports.'
Write-Host 'This PC means the computer running setup. Keyboard and mouse connections do not move with the picture.'
Write-Host "`nDetecting monitors..."
$monitors = @(& $switchPath -List -PassThru)
$monitors | Format-Table Index, Position, Description, CurrentInput -AutoSize | Out-Host

$keepProfiles = $false
if ($Unattended -and [string]::IsNullOrWhiteSpace($ConfigurationFile)) {
    throw 'Unattended setup requires a ConfigurationFile containing both profiles.'
}
if (-not $Unattended -and (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    Write-Host "Existing profiles found: $configPath"
    $keepProfiles = Read-YesNo 'Keep these profiles while updating the installed files?' -Default $true
}

if ($Unattended) {
    $configJson = Get-Content -LiteralPath $ConfigurationFile -Raw
    [void]($configJson | ConvertFrom-Json)
}
elseif ($keepProfiles) {
    $configJson = Get-Content -LiteralPath $configPath -Raw
    # Parsing here provides an immediate error before any installed file changes.
    [void]($configJson | ConvertFrom-Json)
}
else {
    $thisPc = [ordered]@{}
    $otherPc = [ordered]@{}
    Write-Host "`nChoose the input connected to each computer, for each monitor:"
    Write-Host '1 = DisplayPort 1    2 = HDMI 1    3 = HDMI 2    4 = DisplayPort 2'
    Write-Host '5 = DVI 1           6 = DVI 2     7 = VGA 1'
    Write-Host 'You can also enter an input name or a hex code you have already verified on this hardware.'
    foreach ($monitor in $monitors) {
        Write-Host "`n$($monitor.Position): $($monitor.Description) [$($monitor.DisplayDevice)]"
        $thisPc[$monitor.Position] = Read-MonitorInput 'Input connected to THIS computer'
        $otherPc[$monitor.Position] = Read-MonitorInput 'Input connected to the OTHER computer'
    }
    $configJson = [ordered]@{ profiles = [ordered]@{ 'this-pc' = $thisPc; 'other-pc' = $otherPc } } |
        ConvertTo-Json -Depth 5
}

Write-Host "`nReview both profiles (no input changes):"
$previewPath = [System.IO.Path]::GetTempFileName()
try {
    [System.IO.File]::WriteAllText($previewPath, $configJson)
    foreach ($profile in @('this-pc', 'other-pc')) {
        Write-Host "`n$profile"
        try {
            & $switchPath -Profile $profile -ConfigPath $previewPath -WhatIf | Out-Host
        }
        catch {
            throw "Profile preview failed: $($_.Exception.Message) Re-run setup and configure inputs again. Installed files have not been changed."
        }
    }
}
finally {
    Remove-Item -LiteralPath $previewPath -Force
}

Write-Host 'A preview checks assignments, not physical switching or the return path.'
$installHotkeys = if ($Unattended) { $EnableHotkeys.IsPresent } else {
    Read-YesNo 'Have you already tested both directions and want Ctrl+Alt+1 / Ctrl+Alt+2 hotkeys now?'
}
Write-Host "`nFiles and profiles will be installed in: $InstallDirectory"
Write-Host "Install hotkeys: $installHotkeys"
if (-not $Unattended -and -not (Read-YesNo 'Install with these settings?' -Default $true)) {
    Write-Host 'Setup cancelled. Installed files and shortcuts were not changed.'
    return
}

[void][System.IO.Directory]::CreateDirectory($InstallDirectory)
$files = @($requiredFiles | ForEach-Object { Get-Item -LiteralPath (Join-Path $PSScriptRoot $_) })
foreach ($name in @('AGENTS.md', 'TESTING-NOTES.md', 'docs', 'examples', 'tests')) {
    $optionalPath = Join-Path $PSScriptRoot $name
    if (Test-Path -LiteralPath $optionalPath) {
        $files += @(Get-ChildItem -LiteralPath $optionalPath -File -Recurse)
    }
}
foreach ($file in $files) {
    $relativePath = $file.FullName.Substring($PSScriptRoot.Length).TrimStart('\', '/')
    $destination = Join-Path $InstallDirectory $relativePath
    if (-not $file.FullName.Equals($destination, [StringComparison]::OrdinalIgnoreCase)) {
        [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
        Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
    }
}

if (-not $keepProfiles) {
    # Stage beside the destination, then atomically replace and back up existing profiles.
    $stagedConfig = Join-Path $InstallDirectory ('.profiles-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [System.IO.File]::WriteAllText($stagedConfig, $configJson)
        if (Test-Path -LiteralPath $configPath -PathType Leaf) {
            $backupPath = "$configPath.$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))-$([Guid]::NewGuid().ToString('N')).bak"
            [System.IO.File]::Replace($stagedConfig, $configPath, $backupPath)
            Write-Host "Previous profiles backed up to: $backupPath"
        }
        else {
            [System.IO.File]::Move($stagedConfig, $configPath)
        }
    }
    finally {
        if (Test-Path -LiteralPath $stagedConfig) { Remove-Item -LiteralPath $stagedConfig -Force }
    }
}

Write-Host "`nFiles and profiles saved to: $InstallDirectory"
if ($installHotkeys) {
    & (Join-Path $InstallDirectory 'Install-ProfileHotkeys.ps1') | Out-Host
}
Write-Host "`nSetup complete. Open README.md in the installed folder for the one-monitor return-path test."
Write-Host 'Keep the monitor input selector available when testing. Neither direction has been physically verified by setup.'
Write-Host 'Use This-PC.cmd and Other-PC.cmd in the installed folder. You may delete the original download.'
if (-not $installHotkeys) {
    Write-Host 'After testing both directions, run Setup.cmd in the installed folder again, keep the profiles, and choose hotkeys.'
}
