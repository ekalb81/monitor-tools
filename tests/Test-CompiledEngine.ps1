[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$compiler = @(
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $compiler) { throw 'The .NET Framework C# compiler is required.' }

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('monitor-tools-compiled-engine-' + [Guid]::NewGuid().ToString('N'))
$resolved = [IO.Path]::GetFullPath($testRoot)
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
    (Split-Path -Leaf $resolved) -notmatch '^monitor-tools-compiled-engine-[a-f0-9]{32}$') {
    throw 'Unexpected compiled engine test path.'
}

try {
    [void][IO.Directory]::CreateDirectory($resolved)
    $executable = Join-Path $resolved 'EngineWorkerTests.exe'
    $sources = @(
        (Join-Path $root 'engine\NativeMethods.cs'),
        (Join-Path $root 'engine\DisplayTopology.cs'),
        (Join-Path $root 'engine\WorkerConfiguration.cs'),
        (Join-Path $root 'engine\MonitorEngine.cs'),
        (Join-Path $PSScriptRoot 'EngineWorkerTests.cs')
    )
    & $compiler /nologo /target:exe /optimize+ /main:EngineWorkerTests "/out:$executable" `
        /reference:System.Web.Extensions.dll /reference:System.Configuration.dll $sources
    if ($LASTEXITCODE -ne 0) { throw 'Compiled engine test compilation failed.' }
    & $executable
    if ($LASTEXITCODE -ne 0) { throw "Compiled engine tests failed with exit code $LASTEXITCODE." }
}
finally {
    if ([IO.Directory]::Exists($resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
