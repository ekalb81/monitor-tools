[CmdletBinding()]
param([string]$ExecutablePath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ExecutablePath)) {
    $ExecutablePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'dist\Setup.exe'
}
$start = [Diagnostics.ProcessStartInfo]::new()
$start.FileName = [IO.Path]::GetFullPath($ExecutablePath)
$start.Arguments = '--verify-package'
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
$process = [Diagnostics.Process]::new()
$process.StartInfo = $start
try {
    if (-not $process.Start()) { throw 'Setup package verification could not start.' }
    if (-not $process.WaitForExit(30000)) {
        $process.Kill()
        $process.WaitForExit()
        throw 'Setup package verification timed out.'
    }
    if ($process.ExitCode -ne 0) { throw "Setup package verification failed ($($process.ExitCode))." }
    Write-Output 'PASS: packaged executable extracts and verifies its required runtime files without hardware discovery'
}
finally { $process.Dispose() }
