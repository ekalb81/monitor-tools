[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$VerifyOnly,
    [switch]$Quiet,
    [Parameter(DontShow = $true)][string]$TestLaunchRecordPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$manifestPath = Join-Path $PSScriptRoot 'install-manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw 'The installation manifest is missing.' }
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
function Get-Sha256 {
    param([string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($algorithm.ComputeHash($stream)).Replace('-', '') }
    finally { $algorithm.Dispose(); $stream.Dispose() }
}
$problems = New-Object System.Collections.Generic.List[string]
foreach ($entry in $manifest.files) {
    $path = Join-Path $PSScriptRoot ([string]$entry.path)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $problems.Add("Missing: $($entry.path)")
        continue
    }
    $hash = Get-Sha256 -Path $path
    if (-not $hash.Equals([string]$entry.sha256, [StringComparison]::OrdinalIgnoreCase)) {
        $problems.Add("Changed: $($entry.path)")
    }
}
$setupPath = Join-Path $PSScriptRoot 'Setup.exe'
if (-not (Test-Path -LiteralPath $setupPath -PathType Leaf)) { $problems.Add('Missing: Setup.exe') }
if ($problems.Count -eq 0) {
    if (-not $Quiet) { Write-Host "Monitor Tools $($manifest.version) is intact." }
    return
}
$problems | Write-Warning
if ($VerifyOnly) { throw "$($problems.Count) installed file(s) failed verification." }
if (-not (Test-Path -LiteralPath $setupPath -PathType Leaf)) {
    throw 'Repair requires Setup.exe in the installed application directory. Download the same or a newer release and run it again.'
}
if ($PSCmdlet.ShouldProcess($PSScriptRoot, 'Repair Monitor Tools from the embedded setup payload')) {
    $workerDirectory = Join-Path ([IO.Path]::GetTempPath()) ('monitor-tools-repair-' + [Guid]::NewGuid().ToString('N'))
    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolvedWorker = [IO.Path]::GetFullPath($workerDirectory)
    if (-not $resolvedWorker.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolvedWorker) -notmatch '^monitor-tools-repair-[0-9a-f]{32}$') {
        throw 'Refusing to create an unexpected repair worker directory.'
    }
    try {
        [void][IO.Directory]::CreateDirectory($resolvedWorker)
        $workerSetup = Join-Path $resolvedWorker 'Setup.exe'
        Copy-Item -LiteralPath $setupPath -Destination $workerSetup -Force
        $arguments = '--repair-target "' + $PSScriptRoot.Replace('"', '\"') + '"'
        if (-not [string]::IsNullOrWhiteSpace($TestLaunchRecordPath)) {
            [IO.File]::WriteAllText($TestLaunchRecordPath, ([ordered]@{
                FilePath = $workerSetup; Arguments = $arguments; WorkerExisted = (Test-Path -LiteralPath $workerSetup)
            } | ConvertTo-Json))
        }
        else {
            $start = New-Object Diagnostics.ProcessStartInfo
            $start.FileName = $workerSetup
            $start.Arguments = $arguments
            $start.UseShellExecute = $false
            $start.CreateNoWindow = $true
            $start.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
            $process = [Diagnostics.Process]::Start($start)
            try {
                $process.WaitForExit()
                if ($process.ExitCode -ne 0) { throw "Setup repair failed with exit code $($process.ExitCode)." }
            }
            finally { $process.Dispose() }
        }
    }
    finally {
        if (Test-Path -LiteralPath $resolvedWorker) { Remove-Item -LiteralPath $resolvedWorker -Recurse -Force }
    }
}
