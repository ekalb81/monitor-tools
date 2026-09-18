[CmdletBinding()]
param(
    [string]$OutputPath,
    [string]$SigningCertificateThumbprint,
    [string]$TimestampServer = 'http://timestamp.digicert.com'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CompilerPath {
    foreach ($framework in @('Framework64', 'Framework')) {
        $candidate = Join-Path ([Environment]::GetFolderPath('Windows')) "Microsoft.NET\$framework\v4.0.30319\csc.exe"
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    throw 'The Windows .NET Framework C# compiler was not found.'
}

function Assert-BuildChild {
    param([string]$Path, [string]$BuildRoot)
    $resolved = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetFullPath($BuildRoot).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to modify a path outside the build directory: $resolved"
    }
}

function Sign-File {
    param([string]$Path, [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)
    $signature = Set-AuthenticodeSignature -FilePath $Path -Certificate $Certificate -HashAlgorithm SHA256 -TimestampServer $TimestampServer
    if ($signature.Status -ne 'Valid') { throw "Signing failed for '$Path': $($signature.StatusMessage)" }
}

function Get-Sha256 {
    param([string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($algorithm.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose(); $stream.Dispose() }
}

$compiler = Get-CompilerPath
$buildDirectory = Join-Path $PSScriptRoot 'build'
$outputDirectory = Join-Path $PSScriptRoot 'dist'
$payloadRoot = Join-Path $buildDirectory 'payload-root'
[void][IO.Directory]::CreateDirectory($buildDirectory)
[void][IO.Directory]::CreateDirectory($outputDirectory)
Assert-BuildChild $payloadRoot $buildDirectory
if (Test-Path -LiteralPath $payloadRoot) { Remove-Item -LiteralPath $payloadRoot -Recurse -Force }
[void][IO.Directory]::CreateDirectory($payloadRoot)

$version = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'VERSION') -Raw).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw "VERSION must contain a semantic version; received '$version'." }
$assemblyVersion = "$version.0"
$assemblyInfo = Join-Path $buildDirectory 'AssemblyInfo.cs'
$assemblySource = @"
using System.Reflection;
[assembly: AssemblyTitle("Monitor Tools")]
[assembly: AssemblyProduct("Monitor Tools")]
[assembly: AssemblyCompany("Monitor Tools")]
[assembly: AssemblyVersion("$assemblyVersion")]
[assembly: AssemblyFileVersion("$assemblyVersion")]
"@
[IO.File]::WriteAllText($assemblyInfo, $assemblySource)

$certificate = $null
if (-not [string]::IsNullOrWhiteSpace($SigningCertificateThumbprint)) {
    $normalizedThumbprint = $SigningCertificateThumbprint.Replace(' ', '').ToUpperInvariant()
    $certificate = Get-ChildItem Cert:\CurrentUser\My | Where-Object Thumbprint -eq $normalizedThumbprint | Select-Object -First 1
    if ($null -eq $certificate) { throw "Signing certificate '$normalizedThumbprint' was not found in Cert:\CurrentUser\My." }
    if (-not $certificate.HasPrivateKey) { throw 'The signing certificate does not have an accessible private key.' }
}

$traySource = Join-Path $PSScriptRoot 'app\Tray.cs'
if (-not (Test-Path -LiteralPath $traySource -PathType Leaf)) { throw 'app\Tray.cs is missing.' }
$trayDirectory = Join-Path $payloadRoot 'app'
[void][IO.Directory]::CreateDirectory($trayDirectory)
$trayExecutable = Join-Path $trayDirectory 'MonitorTools.exe'
& $compiler /nologo /target:winexe /optimize+ /platform:anycpu "/out:$trayExecutable" `
    /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Web.Extensions.dll `
    $assemblyInfo $traySource (Join-Path $PSScriptRoot 'app\WorkerClient.cs')
if ($LASTEXITCODE -ne 0) { throw "Tray compilation failed ($LASTEXITCODE)." }
if ($null -ne $certificate) { Sign-File $trayExecutable $certificate }

$workerExecutable = Join-Path $trayDirectory 'MonitorTools.Worker.exe'
$engineSources = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'engine') -Filter '*.cs' -File | ForEach-Object FullName)
& $compiler /nologo /target:exe /optimize+ /platform:anycpu "/out:$workerExecutable" `
    /reference:System.Web.Extensions.dll /reference:System.Core.dll $assemblyInfo $engineSources
if ($LASTEXITCODE -ne 0) { throw "Worker compilation failed ($LASTEXITCODE)." }
if ($null -ne $certificate) { Sign-File $workerExecutable $certificate }

$names = @(
    'Switch-MonitorInput.ps1', 'Run-Profile.ps1', 'Install-ProfileHotkeys.ps1', 'Install.ps1',
    'Repair.ps1', 'Uninstall.ps1', 'MonitorTools.Common.ps1', 'Export-Diagnostics.ps1',
    'monitor-compatibility.json', 'VERSION', 'Setup.cmd', 'This-PC.cmd', 'Other-PC.cmd',
    'Switch-To-This-PC.cmd', 'Switch-To-Other-PC.cmd', 'README.md', 'AGENTS.md', 'TESTING-NOTES.md',
    'app\Invoke-TrayCommand.ps1'
)
foreach ($name in $names) {
    $source = Join-Path $PSScriptRoot $name
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Build input '$name' is missing." }
    $destination = Join-Path $payloadRoot $name
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
    Copy-Item -LiteralPath $source -Destination $destination -Force
}
foreach ($folder in @('docs', 'examples', 'tests')) {
    $sourceFolder = Join-Path $PSScriptRoot $folder
    foreach ($file in @(Get-ChildItem -LiteralPath $sourceFolder -Recurse -File)) {
        $relative = $file.FullName.Substring($PSScriptRoot.Length).TrimStart('\', '/')
        $destination = Join-Path $payloadRoot $relative
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
        Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
    }
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'installer\Detect-Monitors.ps1') `
    -Destination (Join-Path $payloadRoot 'Detect-Monitors.ps1') -Force

if ($null -ne $certificate) {
    foreach ($script in @(Get-ChildItem -LiteralPath $payloadRoot -Recurse -File -Filter '*.ps1')) {
        Sign-File $script.FullName $certificate
    }
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$payloadPath = Join-Path $buildDirectory 'payload.zip'
$stream = [IO.File]::Open($payloadPath, [IO.FileMode]::Create)
$archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($file in @(Get-ChildItem -LiteralPath $payloadRoot -Recurse -File)) {
        $relative = $file.FullName.Substring($payloadRoot.Length + 1).Replace('\', '/')
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, $relative)
    }
}
finally { $archive.Dispose(); $stream.Dispose() }

$executable = if ([string]::IsNullOrWhiteSpace($OutputPath)) { Join-Path $outputDirectory 'Setup.exe' }
else { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath) }
[void][IO.Directory]::CreateDirectory((Split-Path -Parent $executable))
& $compiler /nologo /target:winexe /optimize+ /platform:anycpu "/out:$executable" `
    /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Web.Extensions.dll `
    /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll `
    "/win32manifest:$(Join-Path $PSScriptRoot 'installer\setup.manifest')" `
    "/resource:$payloadPath,MonitorTools.Payload.zip" $assemblyInfo (Join-Path $PSScriptRoot 'installer\Setup.cs')
if ($LASTEXITCODE -ne 0) { throw "Setup compilation failed ($LASTEXITCODE)." }
if ($null -ne $certificate) { Sign-File $executable $certificate }

$publishedTray = Join-Path (Split-Path -Parent $executable) 'MonitorTools.exe'
Copy-Item -LiteralPath $trayExecutable -Destination $publishedTray -Force
$publishedWorker = Join-Path (Split-Path -Parent $executable) 'MonitorTools.Worker.exe'
Copy-Item -LiteralPath $workerExecutable -Destination $publishedWorker -Force

$checksumPath = Join-Path (Split-Path -Parent $executable) 'SHA256SUMS.txt'
$setupHash = Get-Sha256 -Path $executable
$trayHash = Get-Sha256 -Path $publishedTray
$workerHash = Get-Sha256 -Path $publishedWorker
[IO.File]::WriteAllText($checksumPath,
    "$setupHash  $([IO.Path]::GetFileName($executable))`r`n$trayHash  $([IO.Path]::GetFileName($publishedTray))`r`n$workerHash  $([IO.Path]::GetFileName($publishedWorker))`r`n")
[pscustomobject]@{
    Setup = $executable
    Version = $version
    SHA256 = $setupHash
    Tray = $publishedTray
    Worker = $publishedWorker
    Signed = ($null -ne $certificate)
    Checksums = $checksumPath
}
