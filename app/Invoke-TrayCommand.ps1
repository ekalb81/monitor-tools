[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RequestPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding

$resolvedRequest = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RequestPath)
$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
if (-not $resolvedRequest.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase) -or
    (Split-Path -Leaf $resolvedRequest) -notmatch '^monitor-tools-request-[0-9a-f]{32}\.json$') {
    throw 'The tray request must be a Monitor Tools temporary request file.'
}

try {
    $request = [IO.File]::ReadAllText($resolvedRequest, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $root = Split-Path -Parent $PSScriptRoot
    $commonPath = Join-Path $root 'MonitorTools.Common.ps1'
    if (-not (Test-Path -LiteralPath $commonPath -PathType Leaf)) { throw 'MonitorTools.Common.ps1 is not installed.' }
    . $commonPath
    $configPath = Get-MonitorToolsConfigPath -Root $root
    $switchPath = Join-Path $root 'Switch-MonitorInput.ps1'

    function Get-RequestValue {
        param([string]$Name)
        $property = $request.PSObject.Properties[$Name]
        if ($null -eq $property) { return $null }
        return $property.Value
    }

    switch ([string](Get-RequestValue 'action')) {
        'profile' {
            $arguments = @{
                Profile = [string](Get-RequestValue 'profile')
                ConfigPath = $configPath
                PassThru = $true
            }
            $monitorId = [string](Get-RequestValue 'monitorId')
            if (-not [string]::IsNullOrWhiteSpace($monitorId)) {
                $arguments.MonitorId = $monitorId
            }
            $results = New-Object Collections.Generic.List[object]
            try {
                & $switchPath @arguments | ForEach-Object { $results.Add($_) }
                [pscustomobject]@{ Success = $true; Results = @($results | ForEach-Object { $_ }) } | ConvertTo-Json -Depth 8 -Compress
            }
            catch {
                [pscustomobject]@{ Success = $false; Results = @($results | ForEach-Object { $_ }); Error = $_.Exception.Message } | ConvertTo-Json -Depth 8 -Compress
                throw
            }
        }
        'list' {
            @(& $switchPath -List -PassThru -ConfigPath $configPath) | ConvertTo-Json -Depth 8 -Compress
        }
        'diagnostics' {
            $outputPath = [string](Get-RequestValue 'outputPath')
            if ([string]::IsNullOrWhiteSpace($outputPath)) { throw 'Choose a diagnostics output path.' }
            $exportPath = Join-Path $root 'Export-Diagnostics.ps1'
            if (-not (Test-Path -LiteralPath $exportPath -PathType Leaf)) { throw 'Export-Diagnostics.ps1 is not installed.' }
            $exportArguments = @{ OutputPath = $outputPath }
            if ([bool](Get-RequestValue 'includeCapabilities')) { $exportArguments.IncludeCapabilities = $true }
            & $exportPath @exportArguments | Out-String
        }
        'saveConfig' {
            $configuration = Get-RequestValue 'config'
            if ($null -eq $configuration) { throw 'The tray request did not contain configuration data.' }
            Save-MonitorToolsConfig -Config $configuration -Path $configPath
            [pscustomobject]@{ Status = 'saved'; ConfigPath = $configPath } | ConvertTo-Json -Compress
        }
        default { throw "Unknown tray action '$([string](Get-RequestValue 'action'))'." }
    }
}
finally {
    if (Test-Path -LiteralPath $resolvedRequest -PathType Leaf) {
        Remove-Item -LiteralPath $resolvedRequest -Force -ErrorAction SilentlyContinue
    }
}
