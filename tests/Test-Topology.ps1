[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$compiler = Join-Path ([Environment]::GetFolderPath('Windows')) 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) {
    $compiler = Join-Path ([Environment]::GetFolderPath('Windows')) 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) { throw 'The Windows .NET Framework C# compiler was not found.' }

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('monitor-tools-topology-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
try {
    foreach ($platform in @('x86', 'x64')) {
        $executable = Join-Path $testRoot ("TopologyTests-{0}.exe" -f $platform)
        & $compiler /nologo /target:exe /optimize+ "/platform:$platform" "/out:$executable" `
            (Join-Path $repoRoot 'engine\DisplayTopology.cs') (Join-Path $PSScriptRoot 'TopologyTests.cs')
        if ($LASTEXITCODE -ne 0) { throw "Topology test compilation failed for $platform ($LASTEXITCODE)." }
        & $executable
        if ($LASTEXITCODE -ne 0) { throw "Topology tests failed for $platform ($LASTEXITCODE)." }
    }
}
finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolved) -notmatch '^monitor-tools-topology-[0-9a-f]{32}$') {
        throw 'Unexpected topology test cleanup path.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
