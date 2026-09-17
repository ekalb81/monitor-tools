[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'MonitorTools.Common.ps1')
function Assert { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
$root = Join-Path ([IO.Path]::GetTempPath()) ('monitor-tools-common-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
try {
    $known = Get-MonitorToolsCompatibilityInfo -Model 'Odyssey G60SD' -CatalogPath (Join-Path $repo 'monitor-compatibility.json')
    Assert ($known.CandidateInputs['HDMI (tested G60SD variant)'] -eq '0x05') 'Catalog matches the documented model'
    $unknown = Get-MonitorToolsCompatibilityInfo -Model 'Samsung unrelated model' -CatalogPath (Join-Path $repo 'monitor-compatibility.json')
    Assert ($unknown.CandidateInputs.Count -eq 0) 'Catalog does not generalize a quirk to the entire manufacturer'
    $path = Join-Path $root 'profiles.json'
    $config = '{"schemaVersion":2,"profiles":{"split-desk":{"id-aabbccdd":"0x05","id-11223344":{"brightness":35,"volume":0}}}}' | ConvertFrom-Json
    Save-MonitorToolsConfig -Config $config -Path $path
    Assert ((Read-MonitorToolsConfig $path).profiles.'split-desk'.'id-aabbccdd' -eq '0x05') 'Schema2 input round trip'
    $original = [IO.File]::ReadAllText($path)
    $config.profiles.'split-desk'.'id-aabbccdd' = 'displayport1'
    Save-MonitorToolsConfig -Config $config -Path $path
    $backup = @(Get-ChildItem -LiteralPath $root -Filter '*.bak')
    Assert ($backup.Count -eq 1) 'Atomic save creates backup'
    Assert ([IO.File]::ReadAllText($backup[0].FullName) -ceq $original) 'Backup preserves exact original'
    foreach ($invalid in @('{"schemaVersion":99,"profiles":{"a":{}}}', '{"profiles":{"a":{"left":{"brightness":101}}}}', '{"profiles":{"a":{"left":"garbage"}}}')) {
        $thrown = $false
        try { Save-MonitorToolsConfig ($invalid | ConvertFrom-Json) $path } catch { $thrown = $true }
        Assert $thrown 'Invalid configuration must fail'
    }
    Assert ((Read-MonitorToolsConfig $path).profiles.'split-desk'.'id-aabbccdd' -eq 'displayport1') 'Validation failures preserve config'
    [IO.File]::WriteAllText((Join-Path $root 'config-path.txt'), $path)
    Assert ((Get-MonitorToolsConfigPath -Root $root) -eq $path) 'Installed pointer resolves'
    $logs = Join-Path $root 'logs'
    [void][IO.Directory]::CreateDirectory($logs)
    [IO.File]::WriteAllText((Join-Path $logs 'keep-me.json'), '{}')
    for ($i = 0; $i -lt 103; $i++) { Write-MonitorToolsOperation -Record @{ operationId = $i; results = @() } -Directory $logs }
    Assert (@(Get-ChildItem -LiteralPath $logs -Filter 'operation-*.json').Count -eq 100) 'Operation log retention'
    Assert ([IO.File]::Exists((Join-Path $logs 'keep-me.json'))) 'Rotation preserves unrelated files'

    Copy-Item -LiteralPath (Join-Path $repo 'Export-Diagnostics.ps1') -Destination $root
    Copy-Item -LiteralPath (Join-Path $repo 'MonitorTools.Common.ps1') -Destination $root
    @'
param([switch]$List, [switch]$PassThru, [switch]$IncludeCapabilities)
[pscustomobject]@{ StableId = 'id-aabbccdd'; Model = 'Test Display'; Serial = 'sensitive-serial'; DevicePath = 'sensitive-path'; Capabilities = if ($IncludeCapabilities) { 'vcp(60(05 0F))' } else { $null } }
'@ | Set-Content -LiteralPath (Join-Path $root 'Switch-MonitorInput.ps1')
    $report = Join-Path $root 'report.json'
    & (Join-Path $root 'Export-Diagnostics.ps1') -OutputPath $report -LogDirectory $logs | Out-Null
    $raw = [IO.File]::ReadAllText($report)
    Assert (-not $raw.Contains('sensitive-serial') -and -not $raw.Contains('sensitive-path') -and -not $raw.Contains('id-aabbccdd')) 'Export redacts device identifiers'
    $diagnostic = $raw | ConvertFrom-Json
    Assert ($diagnostic.configuration.profiles.'split-desk'.'monitor-1' -eq 'displayport1') 'Anonymous profile mapping stays correlated'
    Assert (-not $diagnostic.capabilitiesRequested) 'Capabilities are opt-in'
    & (Join-Path $root 'Export-Diagnostics.ps1') -OutputPath $report -LogDirectory $logs -IncludeCapabilities -IncludeIdentifiers | Out-Null
    $raw = [IO.File]::ReadAllText($report)
    Assert ($raw.Contains('sensitive-serial') -and $raw.Contains('vcp(60')) 'Explicit diagnostics includes requested hardware detail'
    Write-Output 'PASS: shared configuration, atomic backups, schema validation, log retention, and diagnostics privacy'
}
finally {
    $resolved = [IO.Path]::GetFullPath($root)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -notmatch '^monitor-tools-common-[a-f0-9]{32}$') { throw 'Unexpected test cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
