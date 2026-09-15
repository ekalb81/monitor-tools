[CmdletBinding()]
param([string]$OutputPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$compiler = Join-Path ([Environment]::GetFolderPath('Windows')) 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) {
    $compiler = Join-Path ([Environment]::GetFolderPath('Windows')) 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (-not (Test-Path -LiteralPath $compiler)) { throw 'The Windows .NET Framework C# compiler was not found.' }
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$buildDirectory = Join-Path $PSScriptRoot 'build'
$outputDirectory = Join-Path $PSScriptRoot 'dist'
[void][System.IO.Directory]::CreateDirectory($buildDirectory)
[void][System.IO.Directory]::CreateDirectory($outputDirectory)
$payloadPath = Join-Path $buildDirectory 'payload.zip'
$stream = [System.IO.File]::Open($payloadPath, [System.IO.FileMode]::Create)
$archive = [System.IO.Compression.ZipArchive]::new($stream, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    $names = @('Switch-MonitorInput.ps1', 'Run-Profile.ps1', 'Install-ProfileHotkeys.ps1', 'Install.ps1',
        'Setup.cmd', 'This-PC.cmd', 'Other-PC.cmd', 'Switch-To-This-PC.cmd', 'Switch-To-Other-PC.cmd',
        'README.md', 'AGENTS.md', 'TESTING-NOTES.md')
    $files = @($names | ForEach-Object { Get-Item -LiteralPath (Join-Path $PSScriptRoot $_) })
    foreach ($folder in @('docs', 'examples', 'tests')) {
        $files += @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot $folder) -Recurse -File)
    }
    foreach ($file in $files) {
        $relativePath = $file.FullName.Substring($PSScriptRoot.Length + 1).Replace('\', '/')
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, $relativePath)
    }
    [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,
        (Join-Path $PSScriptRoot 'installer\Detect-Monitors.ps1'), 'Detect-Monitors.ps1')
}
finally { $archive.Dispose(); $stream.Dispose() }
$executable = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    Join-Path $outputDirectory 'Setup.exe'
}
else {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
}
[void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $executable))
& $compiler /nologo /target:winexe /optimize+ /platform:anycpu "/out:$executable" `
    /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Web.Extensions.dll `
    /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll `
    "/win32manifest:$(Join-Path $PSScriptRoot 'installer\setup.manifest')" `
    "/resource:$payloadPath,MonitorTools.Payload.zip" (Join-Path $PSScriptRoot 'installer\Setup.cs')
if ($LASTEXITCODE -ne 0) { throw "Setup compilation failed ($LASTEXITCODE)." }
Get-Item -LiteralPath $executable | Select-Object FullName, Length
