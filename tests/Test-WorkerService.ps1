[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$compiler = Join-Path ([Environment]::GetFolderPath('Windows')) 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not [IO.File]::Exists($compiler)) { $compiler = Join-Path ([Environment]::GetFolderPath('Windows')) 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
$outputDirectory = Join-Path $repo 'build\worker-service-tests'
[void][IO.Directory]::CreateDirectory($outputDirectory)
$sources = @(Get-ChildItem -LiteralPath (Join-Path $repo 'engine') -Filter '*.cs' -File | ForEach-Object FullName)
$worker = Join-Path $outputDirectory 'Worker.exe'
& $compiler /nologo /target:exe /optimize+ "/out:$worker" /reference:System.Web.Extensions.dll /reference:System.Core.dll $sources
if ($LASTEXITCODE -ne 0) { throw 'Worker compilation failed.' }
$test = Join-Path $outputDirectory 'WorkerServiceTests.exe'
& $compiler /nologo /target:exe /optimize+ /main:WorkerServiceTests "/out:$test" /reference:System.Web.Extensions.dll /reference:System.Core.dll $sources (Join-Path $PSScriptRoot 'WorkerServiceTests.cs')
if ($LASTEXITCODE -ne 0) { throw 'Worker service tests compilation failed.' }
& $test $worker
if ($LASTEXITCODE -ne 0) { throw 'Worker service tests failed.' }
