[CmdletBinding(SupportsShouldProcess = $true)]
param([switch]$RemoveConfiguration, [switch]$Quiet, [switch]$SkipRegistration)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$installDirectory = [IO.Path]::GetFullPath($PSScriptRoot)
$manifestPath = Join-Path $installDirectory 'install-manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw 'Refusing to uninstall because install-manifest.json is missing.'
}
$manifestText = [IO.File]::ReadAllText($manifestPath)
$manifest = $manifestText | ConvertFrom-Json
if ([string]$manifest.product -ne 'Monitor Tools') { throw 'Refusing to uninstall an unrecognized application directory.' }
if ($null -eq $manifest.PSObject.Properties['installDirectory'] -or
    -not ([IO.Path]::GetFullPath([string]$manifest.installDirectory)).Equals($installDirectory, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Refusing to uninstall because the manifest does not own this directory.'
}
$forbidden = @(
    [IO.Path]::GetPathRoot($installDirectory),
    [Environment]::GetFolderPath('UserProfile'),
    [Environment]::GetFolderPath('LocalApplicationData')
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') }
if ($forbidden -contains $installDirectory.TrimEnd('\')) { throw "Refusing to uninstall protected path '$installDirectory'." }
if ((Get-Item -LiteralPath $installDirectory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
    throw "Refusing to uninstall through reparse point '$installDirectory'."
}
. (Join-Path $installDirectory 'MonitorTools.Common.ps1')
$configPath = Get-MonitorToolsConfigPath -Root $installDirectory
$manifestConfigPath = if ($null -ne $manifest.PSObject.Properties['configPath']) {
    [IO.Path]::GetFullPath([string]$manifest.configPath)
}
else { $configPath }
$rootPrefix = $installDirectory.TrimEnd('\') + '\'
$ownedPaths = New-Object System.Collections.Generic.List[string]
foreach ($entry in @($manifest.files)) {
    $ownedPath = [IO.Path]::GetFullPath((Join-Path $installDirectory ([string]$entry.path)))
    if (-not $ownedPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove unsafe manifest path '$($entry.path)'."
    }
    $relative = $ownedPath.Substring($rootPrefix.Length)
    $cursor = $installDirectory
    foreach ($segment in $relative.Split([char[]]'\/', [StringSplitOptions]::RemoveEmptyEntries)) {
        $cursor = Join-Path $cursor $segment
        if ((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Refusing to traverse reparse point '$cursor'."
        }
    }
    $ownedPaths.Add($ownedPath)
}
if ($RemoveConfiguration) {
    if (-not ([IO.Path]::GetFullPath($configPath)).Equals($manifestConfigPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to remove configuration because config-path.txt does not match the installation manifest.'
    }
    $customDataPrefix = [IO.Path]::GetFullPath($installDirectory + '.data').TrimEnd('\') + '\'
    $defaultDataPrefix = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $installDirectory) 'data')).TrimEnd('\') + '\'
    if (-not $manifestConfigPath.StartsWith($customDataPrefix, [StringComparison]::OrdinalIgnoreCase) -and
        -not $manifestConfigPath.StartsWith($defaultDataPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove configuration outside a Monitor Tools data directory: '$manifestConfigPath'."
    }
}

$removed = $false
$mutexHash = [Security.Cryptography.SHA256]::Create()
try {
    $mutexMaterial = [Text.Encoding]::UTF8.GetBytes($installDirectory.ToUpperInvariant())
    $mutexKey = [BitConverter]::ToString($mutexHash.ComputeHash($mutexMaterial)).Replace('-', '')
}
finally { $mutexHash.Dispose() }
$deploymentMutex = [Threading.Mutex]::new($false, ('Local\MonitorTools.Install.' + $mutexKey))
$deploymentLocked = $false
try {
    try { $deploymentLocked = $deploymentMutex.WaitOne(30000) }
    catch [Threading.AbandonedMutexException] { $deploymentLocked = $true }
    if (-not $deploymentLocked) { throw 'Monitor Tools setup is still running. Try uninstalling again after it finishes.' }
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf) -or
        -not [IO.File]::ReadAllText($manifestPath).Equals($manifestText, [StringComparison]::Ordinal)) {
        throw 'The installation changed while uninstall was waiting. Run uninstall again.'
    }
    if ($PSCmdlet.ShouldProcess($installDirectory, 'Uninstall Monitor Tools')) {
    Get-Process -Name MonitorTools -ErrorAction SilentlyContinue | Where-Object {
        try {
            $processPath = [IO.Path]::GetFullPath($_.Path)
            $processPath.StartsWith($installDirectory.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
        }
        catch { $false }
    } | Stop-Process -Force -ErrorAction SilentlyContinue
    if (-not $SkipRegistration) {
        & (Join-Path $installDirectory 'Install-ProfileHotkeys.ps1') -Uninstall -ErrorAction SilentlyContinue | Out-Null
        $shortcutDirectory = Join-Path ([Environment]::GetFolderPath('Programs')) 'Monitor Tools'
        Remove-Item -LiteralPath (Join-Path $shortcutDirectory 'Monitor Tools.lnk') -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $shortcutDirectory) { Remove-Item -LiteralPath $shortcutDirectory -ErrorAction SilentlyContinue }
        Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name MonitorTools -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\MonitorTools' -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($RemoveConfiguration -and (Test-Path -LiteralPath $configPath)) {
        $configDirectory = Split-Path -Parent $configPath
        Remove-Item -LiteralPath $configPath -Force
        if ((Test-Path -LiteralPath $configDirectory) -and @(Get-ChildItem -LiteralPath $configDirectory -Force).Count -eq 0) {
            Remove-Item -LiteralPath $configDirectory
        }
    }
    foreach ($ownedPath in $ownedPaths) {
        Remove-Item -LiteralPath $ownedPath -Force -ErrorAction SilentlyContinue
    }
    foreach ($ownedName in @('Setup.exe', 'install-manifest.json')) {
        Remove-Item -LiteralPath (Join-Path $installDirectory $ownedName) -Force -ErrorAction SilentlyContinue
    }
    $directories = @(Get-ChildItem -LiteralPath $installDirectory -Directory -Recurse -ErrorAction SilentlyContinue |
        Sort-Object { $_.FullName.Length } -Descending)
    foreach ($directory in $directories) {
        if (@(Get-ChildItem -LiteralPath $directory.FullName -Force).Count -eq 0) {
            Remove-Item -LiteralPath $directory.FullName
        }
    }
    if (@(Get-ChildItem -LiteralPath $installDirectory -Force).Count -eq 0) { Remove-Item -LiteralPath $installDirectory }
    elseif (-not $Quiet) { Write-Warning "Unrecognized files remain in '$installDirectory'; they were preserved." }
        $removed = $true
    }
    if ($removed -and -not $Quiet) {
        Write-Host 'Monitor Tools was removed.'
        if (-not $RemoveConfiguration) { Write-Host "Configuration retained at: $configPath" }
    }
}
finally {
    if ($deploymentLocked) { $deploymentMutex.ReleaseMutex() }
    $deploymentMutex.Dispose()
}
