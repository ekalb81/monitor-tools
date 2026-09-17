[CmdletBinding()]
param([string]$RepoRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }

function Assert-True {
    param([bool]$Value, [string]$Message)
    if (-not $Value) { throw $Message }
}

$compiler = Join-Path ([Environment]::GetFolderPath('Windows')) 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) { $compiler = Join-Path ([Environment]::GetFolderPath('Windows')) 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) { throw 'The Windows .NET Framework compiler was not found.' }

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('monitor-tools-interface-test-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
try {
    $trayOutput = Join-Path $testRoot 'MonitorTools.exe'
    & $compiler /nologo /target:winexe /optimize+ /platform:anycpu "/out:$trayOutput" `
        /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Web.Extensions.dll `
        (Join-Path $RepoRoot 'app\Tray.cs')
    if ($LASTEXITCODE -ne 0) { throw "Tray compilation failed ($LASTEXITCODE)." }
    Assert-True (Test-Path -LiteralPath $trayOutput -PathType Leaf) 'Tray executable was not produced.'
    $trayAssembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($trayOutput))
    $hotkeyType = $trayAssembly.GetType('HotkeyWindow', $true)
    $hotkeyParser = $hotkeyType.GetMethod('TryParse', [Reflection.BindingFlags]'Static,NonPublic')
    $hotkeyArguments = [object[]]@('Ctrl+Alt+1', [uint32]0, [uint32]0)
    Assert-True ([bool]$hotkeyParser.Invoke($null, $hotkeyArguments)) 'Default tray hotkey did not parse.'
    Assert-True ([uint32]$hotkeyArguments[2] -eq [uint32][Windows.Forms.Keys]::D1) 'Ctrl+Alt+1 must register the D1 virtual key.'
    $invalidHotkey = [object[]]@('Ctrl+A+B', [uint32]0, [uint32]0)
    Assert-True (-not [bool]$hotkeyParser.Invoke($null, $invalidHotkey)) 'Hotkeys must contain exactly one base key.'

    $setupOutput = Join-Path $testRoot 'Setup-headless.exe'
    & $compiler /nologo /target:winexe /optimize+ /platform:anycpu "/out:$setupOutput" `
        /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Web.Extensions.dll `
        /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll `
        (Join-Path $RepoRoot 'installer\Setup.cs')
    if ($LASTEXITCODE -ne 0) { throw "Setup interface compilation failed ($LASTEXITCODE)." }

    [void][IO.Directory]::CreateDirectory((Join-Path $testRoot 'app'))
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'app\Invoke-TrayCommand.ps1') -Destination (Join-Path $testRoot 'app\Invoke-TrayCommand.ps1')
    [IO.File]::WriteAllText((Join-Path $testRoot 'config-path.txt'), (Join-Path $testRoot 'profiles.json'))
    [IO.File]::WriteAllText((Join-Path $testRoot 'profiles.json'), '{"schemaVersion":2,"profiles":{"work":{"id-test":"displayport1"}}}')
    [IO.File]::WriteAllText((Join-Path $testRoot 'Switch-MonitorInput.ps1'), @'
param([switch]$List,[switch]$PassThru,[string]$Profile,[string]$ConfigPath,[string]$MonitorId)
if ($List) { [pscustomobject]@{ StableId='id-test'; Position='center'; IdentityStatus='edid-serial' }; return }
[pscustomobject]@{ Profile=$Profile; MonitorId=$MonitorId; ConfigPath=$ConfigPath; Status='accepted' }
'@)
    [IO.File]::WriteAllText((Join-Path $testRoot 'MonitorTools.Common.ps1'), @'
function Get-MonitorToolsConfigPath { param([string]$Root) return (Join-Path $Root 'profiles.json') }
function Save-MonitorToolsConfig { param($Config,[string]$Path) [IO.File]::WriteAllText($Path, ($Config | ConvertTo-Json -Depth 20)) }
'@)

    $temporaryRoot = [IO.Path]::GetTempPath()
    $requestPath = Join-Path $temporaryRoot ('monitor-tools-request-' + [Guid]::NewGuid().ToString('N') + '.json')
    [IO.File]::WriteAllText($requestPath, '{"action":"profile","profile":"work","monitorId":"id-test"}')
    $profileOutput = & (Join-Path $testRoot 'app\Invoke-TrayCommand.ps1') -RequestPath $requestPath | ConvertFrom-Json
    Assert-True ($profileOutput.Success -and $profileOutput.Results[0].Profile -eq 'work' -and $profileOutput.Results[0].MonitorId -eq 'id-test') 'Tray bridge did not preserve the profile and monitor ID.'
    Assert-True (-not (Test-Path -LiteralPath $requestPath)) 'Tray bridge did not remove its temporary request.'

    $requestPath = Join-Path $temporaryRoot ('monitor-tools-request-' + [Guid]::NewGuid().ToString('N') + '.json')
    [IO.File]::WriteAllText($requestPath, '{"action":"saveConfig","config":{"schemaVersion":2,"profiles":{"split":{"id-test":"0x05"}},"settings":{"theme":"system"}}}')
    [void](& (Join-Path $testRoot 'app\Invoke-TrayCommand.ps1') -RequestPath $requestPath)
    $saved = Get-Content -LiteralPath (Join-Path $testRoot 'profiles.json') -Raw | ConvertFrom-Json
    Assert-True ($saved.profiles.split.'id-test' -eq '0x05' -and $saved.settings.theme -eq 'system') 'Tray configuration save did not preserve the schema data.'

    Write-Output 'PASS: setup/tray compilation, safe request bridge, and schema-2 saves'
}
finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -notmatch '^monitor-tools-interface-test-[0-9a-f]{32}$') {
        throw 'Unexpected interface test cleanup path.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
