[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$compiler = @(
    (Join-Path ([Environment]::GetFolderPath('Windows')) 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
    (Join-Path ([Environment]::GetFolderPath('Windows')) 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if ($null -eq $compiler) { throw 'The Windows .NET Framework compiler was not found.' }

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('monitor-tools-worker-client-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
try {
    $executable = Join-Path $testRoot 'WorkerClientTests.exe'
    & $compiler /nologo /target:exe /main:WorkerClientTests /optimize+ "/out:$executable" /reference:System.Web.Extensions.dll `
        (Join-Path $repo 'app\WorkerClient.cs') (Join-Path $PSScriptRoot 'WorkerClientTests.cs')
    if ($LASTEXITCODE -ne 0) { throw "Worker client test compilation failed ($LASTEXITCODE)." }
    $appDirectory = Join-Path $testRoot 'app'
    [void][IO.Directory]::CreateDirectory($appDirectory)
    $stub = Join-Path $appDirectory 'MonitorTools.Worker.exe'
    & $compiler /nologo /target:exe /main:WorkerStub /optimize+ "/out:$stub" /reference:System.Web.Extensions.dll `
        (Join-Path $repo 'app\WorkerClient.cs') (Join-Path $PSScriptRoot 'WorkerClientTests.cs')
    if ($LASTEXITCODE -ne 0) { throw "Worker transport stub compilation failed ($LASTEXITCODE)." }
    & $executable --transport $testRoot
    if ($LASTEXITCODE -ne 0) { throw "Worker client tests failed ($LASTEXITCODE)." }
}
finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolved) -notmatch '^monitor-tools-worker-client-[0-9a-f]{32}$') {
        throw 'Unexpected worker client test cleanup path.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
