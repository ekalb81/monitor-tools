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

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('monitor-tools-hotkey-recovery-' + [Guid]::NewGuid().ToString('N'))
$resolved = [IO.Path]::GetFullPath($testRoot)
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
    (Split-Path -Leaf $resolved) -notmatch '^monitor-tools-hotkey-recovery-[a-f0-9]{32}$') {
    throw 'Unexpected hotkey recovery test path.'
}

try {
    [void][IO.Directory]::CreateDirectory($resolved)
    $executable = Join-Path $resolved 'HotkeyRecoveryTests.exe'
    & $compiler /nologo /target:exe /optimize+ /main:HotkeyRecoveryTests "/out:$executable" `
        /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Web.Extensions.dll `
        (Join-Path $root 'app\Tray.cs') (Join-Path $PSScriptRoot 'HotkeyRecovery.cs')
    if ($LASTEXITCODE -ne 0) { throw 'Hotkey recovery test compilation failed.' }
    & $executable
    if ($LASTEXITCODE -ne 0) { throw "Hotkey recovery tests failed with exit code $LASTEXITCODE." }
}
finally {
    if ([IO.Directory]::Exists($resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
