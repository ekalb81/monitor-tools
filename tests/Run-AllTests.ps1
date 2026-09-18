# Each suite runs in a fresh process so native mock types and function shims cannot leak.
[CmdletBinding()]
param([switch]$IncludeExecutable)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$hostExecutable = (Get-Process -Id $PID).Path
$suites = @('Run-Tests.ps1', 'Test-Engine.ps1', 'Test-Common.ps1', 'WorkerLifecycleTests.ps1')
if ($IncludeExecutable) {
    if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'Executable reflection tests require Windows PowerShell 5.1.' }
    $suites += @('Test-CompiledEngine.ps1', 'Test-Topology.ps1', 'Test-WorkerClient.ps1', 'Test-WorkerService.ps1',
        'Test-Interface.ps1', 'Test-InterfaceBehavior.ps1', 'Test-HotkeyRecovery.ps1', 'Test-Executable.ps1', 'Test-Package.ps1', 'Test-Visual.ps1')
}
$testLogs = Join-Path ([IO.Path]::GetTempPath()) ('monitor-tools-suite-' + [Guid]::NewGuid().ToString('N'))
$previousLogs = $env:MONITOR_TOOLS_LOG_DIRECTORY
try {
    $env:MONITOR_TOOLS_LOG_DIRECTORY = $testLogs
    foreach ($suite in $suites) {
        Write-Host "Running $suite on PowerShell $($PSVersionTable.PSVersion)..."
        & $hostExecutable -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $suite)
        if ($LASTEXITCODE -ne 0) { throw "$suite failed with exit code $LASTEXITCODE." }
    }
}
finally {
    $env:MONITOR_TOOLS_LOG_DIRECTORY = $previousLogs
    $resolved = [IO.Path]::GetFullPath($testLogs)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -notmatch '^monitor-tools-suite-[a-f0-9]{32}$') { throw 'Unexpected suite cleanup path.' }
    if ([IO.Directory]::Exists($resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
Write-Output 'All suites passed.'
