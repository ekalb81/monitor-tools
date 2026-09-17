Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding
try {
    $monitors = @(& (Join-Path $PSScriptRoot 'Switch-MonitorInput.ps1') -List -PassThru)
    $commonPath = Join-Path $PSScriptRoot 'MonitorTools.Common.ps1'
    if (-not (Test-Path -LiteralPath $commonPath -PathType Leaf)) { $commonPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'MonitorTools.Common.ps1' }
    if (Test-Path -LiteralPath $commonPath -PathType Leaf) { . $commonPath }
    foreach ($monitor in $monitors) {
        $compatibility = if (Get-Command Get-MonitorToolsCompatibilityInfo -ErrorAction SilentlyContinue) {
            Get-MonitorToolsCompatibilityInfo -Model ([string]$monitor.Model)
        }
        else { [pscustomobject]@{ CandidateInputs = [pscustomobject]@{}; CompatibilityNotes = @(); CatalogVersion = $null } }
        $monitor | Add-Member -NotePropertyName CandidateInputs -NotePropertyValue $compatibility.CandidateInputs -Force
        $monitor | Add-Member -NotePropertyName CompatibilityNotes -NotePropertyValue @($compatibility.CompatibilityNotes) -Force
        $monitor | Add-Member -NotePropertyName CatalogVersion -NotePropertyValue $compatibility.CatalogVersion -Force
    }
    ConvertTo-Json -InputObject $monitors -Depth 8 -Compress
}
catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
}
