[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [string]$ConfigPath,
    [switch]$IncludeCapabilities,
    [switch]$IncludeIdentifiers,
    [string]$LogDirectory
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'MonitorTools.Common.ps1')
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Get-MonitorToolsConfigPath -Root $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($LogDirectory)) { $LogDirectory = Get-MonitorToolsLogDirectory }
$issues = [Collections.Generic.List[string]]::new()
$inventory = @()
$config = $null
try { $inventory = @(& (Join-Path $PSScriptRoot 'Switch-MonitorInput.ps1') -List -PassThru -IncludeCapabilities:$IncludeCapabilities) }
catch { $issues.Add('Discovery: ' + $_.Exception.Message) }
try { $config = Read-MonitorToolsConfig -Path $ConfigPath }
catch { $issues.Add('Configuration: ' + $_.Exception.Message) }
$operations = @()
if (Test-Path -LiteralPath $LogDirectory -PathType Container) {
    $files = @(Get-ChildItem -LiteralPath $LogDirectory -Filter 'operation-*.json' -File |
        Sort-Object Name -Descending | Select-Object -First 20)
    $operations = @(foreach ($file in $files) {
        try { [IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json }
        catch { $issues.Add('An operation log could not be read.') }
    })
}
$versionPath = Join-Path $PSScriptRoot 'VERSION'
$version = if ([IO.File]::Exists($versionPath)) { [IO.File]::ReadAllText($versionPath).Trim() } else { 'development' }
$document = [ordered]@{
    diagnosticSchemaVersion = 1
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    applicationVersion = $version
    windowsVersion = [Environment]::OSVersion.VersionString
    powerShellVersion = [string]$PSVersionTable.PSVersion
    capabilitiesRequested = $IncludeCapabilities.IsPresent
    identifiersIncluded = $IncludeIdentifiers.IsPresent
    note = 'API acceptance and reported inputs do not prove a visible switch. Calibration records describe earlier user observations.'
    monitors = $inventory
    configuration = $config
    recentOperations = $operations
    issues = @($issues.ToArray())
}

# Retain consistent anonymous monitor keys, allowing profiles and results to correlate.
$aliases = @{}
$privateValues = [Collections.Generic.List[string]]::new()
foreach ($value in @($ConfigPath, $env:USERPROFILE, $env:COMPUTERNAME)) {
    if (-not [string]::IsNullOrWhiteSpace($value)) { $privateValues.Add($value) }
}
foreach ($monitor in $inventory) {
    foreach ($field in @('Serial', 'DevicePath', 'IdentityKey', 'HardwareId')) {
        $value = [string](Get-MonitorToolsProperty $monitor $field)
        if (-not [string]::IsNullOrWhiteSpace($value)) { $privateValues.Add($value) }
    }
}
function Protect-DiagnosticValue {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) {
        $textValue = $Value
        $redact = [Text.RegularExpressions.MatchEvaluator]{ param($match) return '[redacted]' }
        $redactionOptions = [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant
        foreach ($secret in @($privateValues | Sort-Object Length -Descending)) {
            $textValue = [regex]::Replace($textValue, [regex]::Escape($secret), $redact, $redactionOptions)
        }
        foreach ($match in [regex]::Matches($textValue, '(?i)id-[a-f0-9]{8,64}')) {
            $key = $match.Value.ToLowerInvariant()
            if (-not $aliases.ContainsKey($key)) { $aliases[$key] = 'monitor-' + ($aliases.Count + 1) }
            $textValue = $textValue.Replace($match.Value, $aliases[$key])
        }
        return $textValue
    }
    if ($Value -is [ValueType]) { return $Value }
    if ($Value -is [System.Collections.IDictionary] -or $Value -is [pscustomobject]) {
        $result = [ordered]@{}
        $properties = if ($Value -is [System.Collections.IDictionary]) { @($Value.Keys) } else { @($Value.PSObject.Properties.Name) }
        foreach ($key in $properties) {
            if ($key -match '(?i)serial|devicepath|hardwareid|identitykey|configpath|displaydevice|handle') { continue }
            $child = Get-MonitorToolsProperty $Value $key
            $result[(Protect-DiagnosticValue ([string]$key))] = Protect-DiagnosticValue $child
        }
        return $result
    }
    if ($Value -is [Collections.IEnumerable]) {
        return ,@(foreach ($item in $Value) { Protect-DiagnosticValue $item })
    }
    return [string]$Value
}
if (-not $IncludeIdentifiers) { $document = Protect-DiagnosticValue $document }
$destination = [IO.Path]::GetFullPath($OutputPath)
[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
[IO.File]::WriteAllText($destination, ($document | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))
Get-Item -LiteralPath $destination | Select-Object FullName, Length
