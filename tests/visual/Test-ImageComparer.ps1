[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -cne $Expected) { throw "$Message -- expected '$Expected', received '$Actual'." }
}

function Assert-True {
    param($Value, [string]$Message)
    if (-not $Value) { throw $Message }
}

function New-SolidImage {
    param([string]$Path, [int]$Width, [int]$Height, [Drawing.Color]$Color)
    $bitmap = New-Object Drawing.Bitmap $Width, $Height
    try {
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        try { $graphics.Clear($Color) }
        finally { $graphics.Dispose() }
        $bitmap.Save($Path, [Drawing.Imaging.ImageFormat]::Png)
    }
    finally { $bitmap.Dispose() }
}

function New-ShapeImage {
    param([string]$Path, [int]$Width, [int]$Height, [scriptblock]$Draw)
    $bitmap = New-Object Drawing.Bitmap $Width, $Height
    try {
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.Clear([Drawing.Color]::White)
            & $Draw $graphics
        }
        finally { $graphics.Dispose() }
        $bitmap.Save($Path, [Drawing.Imaging.ImageFormat]::Png)
    }
    finally { $bitmap.Dispose() }
}

function Invoke-Comparison {
    param([string]$Name, [string]$Expected, [string]$Actual)
    $diff = Join-Path $testRoot "$Name-diff.png"
    $report = Join-Path $testRoot "$Name-report.json"
    $quote = { param([string]$Value) '"' + $Value.Replace('"', '\"') + '"' }
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $comparer
    $start.Arguments = ((& $quote $Expected), (& $quote $Actual), (& $quote $diff), (& $quote $report)) -join ' '
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($start)
    $outputTask = $process.StandardOutput.ReadToEndAsync()
    $errorTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(30000)) { try { $process.Kill() } catch { }; throw "$Name comparison timed out." }
    $outputTask.Wait(); $errorTask.Wait(); $exitCode = $process.ExitCode; $process.Dispose()
    Assert-True (Test-Path -LiteralPath $report -PathType Leaf) "$Name report was not written"
    $record = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
    return [pscustomobject]@{ ExitCode = $exitCode; Diff = $diff; Report = $record }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('monitor-tools-image-compare-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
try {
    $compiler = @(
        (Join-Path ([Environment]::GetFolderPath('Windows')) 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path ([Environment]::GetFolderPath('Windows')) 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if ($null -eq $compiler) { throw 'The Windows .NET Framework C# compiler was not found.' }
    $source = Join-Path $PSScriptRoot 'ImageComparer.cs'
    $comparer = Join-Path $testRoot 'ImageComparer.exe'
    & $compiler /nologo /target:exe /optimize+ "/out:$comparer" /reference:System.Drawing.dll $source
    if ($LASTEXITCODE -ne 0) { throw "Image comparer compilation failed ($LASTEXITCODE)." }

    $identicalExpected = Join-Path $testRoot 'identical-expected.png'
    $identicalActual = Join-Path $testRoot 'identical-actual.png'
    New-ShapeImage $identicalExpected 320 200 {
        param($graphics)
        $brush = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(30, 90, 160))
        try { $graphics.FillRectangle($brush, 20, 24, 120, 40); $graphics.FillEllipse($brush, 180, 80, 45, 45) }
        finally { $brush.Dispose() }
    }
    [IO.File]::Copy($identicalExpected, $identicalActual)
    $result = Invoke-Comparison identical $identicalExpected $identicalActual
    Assert-Equal $result.ExitCode 0 'Identical image exit code'
    Assert-Equal $result.Report.passed $true 'Identical image result'
    Assert-Equal ([int]$result.Report.changedPixels) 0 'Identical changed pixels'
    Assert-True (Test-Path -LiteralPath $result.Diff -PathType Leaf) 'Success diff was not written'

    $deltaExpected = Join-Path $testRoot 'delta-expected.png'
    $deltaActual = Join-Path $testRoot 'delta-actual.png'
    New-SolidImage $deltaExpected 96 64 ([Drawing.Color]::FromArgb(255, 120, 130, 140))
    New-SolidImage $deltaActual 96 64 ([Drawing.Color]::FromArgb(255, 140, 110, 160))
    $result = Invoke-Comparison channel-delta $deltaExpected $deltaActual
    Assert-Equal $result.ExitCode 0 'Per-channel delta boundary exit code'
    Assert-Equal ([int]$result.Report.tolerances.perChannelDelta) 20 'Reported channel tolerance'

    $shiftExpected = Join-Path $testRoot 'shift-expected.png'
    $shiftActual = Join-Path $testRoot 'shift-actual.png'
    New-ShapeImage $shiftExpected 160 96 {
        param($graphics)
        $graphics.FillRectangle([Drawing.Brushes]::Black, 50, 30, 5, 24)
        $graphics.FillRectangle([Drawing.Brushes]::Black, 50, 49, 14, 5)
    }
    New-ShapeImage $shiftActual 160 96 {
        param($graphics)
        $graphics.FillRectangle([Drawing.Brushes]::Black, 51, 30, 5, 24)
        $graphics.FillRectangle([Drawing.Brushes]::Black, 51, 49, 14, 5)
    }
    $result = Invoke-Comparison translated-glyph $shiftExpected $shiftActual
    Assert-Equal $result.ExitCode 0 'One-pixel translated glyph exit code'
    Assert-Equal ([int]$result.Report.tolerances.nearestNeighborRadius) 1 'Reported neighbor radius'

    $labelExpected = Join-Path $testRoot 'label-expected.png'
    $labelActual = Join-Path $testRoot 'label-actual.png'
    New-ShapeImage $labelExpected 320 200 { param($graphics) $graphics.FillRectangle([Drawing.Brushes]::Black, 40, 40, 8, 8) }
    New-SolidImage $labelActual 320 200 ([Drawing.Color]::White)
    $result = Invoke-Comparison removed-label $labelExpected $labelActual
    Assert-Equal $result.ExitCode 1 'Removed label exit code'
    Assert-Equal $result.Report.passed $false 'Removed label result'
    Assert-True ([double]$result.Report.changedRatio -le 0.001) 'Removed label should stay under the global ratio'
    Assert-True ([double]$result.Report.maxTileRatio -gt 0.05) 'Removed label should fail the local tile ratio'
    $diffBitmap = New-Object Drawing.Bitmap $result.Diff
    try {
        $highlight = $diffBitmap.GetPixel(42, 42)
        Assert-Equal $highlight.R 255 'Diff highlight red channel'
        Assert-Equal $highlight.G 0 'Diff highlight green channel'
        Assert-Equal $highlight.B 255 'Diff highlight blue channel'
    }
    finally { $diffBitmap.Dispose() }

    $buttonExpected = Join-Path $testRoot 'button-expected.png'
    $buttonActual = Join-Path $testRoot 'button-actual.png'
    New-ShapeImage $buttonExpected 320 200 { param($graphics) $graphics.FillRectangle([Drawing.Brushes]::SteelBlue, 30, 70, 80, 30) }
    New-ShapeImage $buttonActual 320 200 { param($graphics) $graphics.FillRectangle([Drawing.Brushes]::SteelBlue, 55, 70, 80, 30) }
    $result = Invoke-Comparison moved-button $buttonExpected $buttonActual
    Assert-Equal $result.ExitCode 1 'Moved button exit code'
    Assert-True ([double]$result.Report.changedRatio -gt 0.001) 'Moved button global difference'

    $sustainedExpected = Join-Path $testRoot 'sustained-expected.png'
    $sustainedActual = Join-Path $testRoot 'sustained-actual.png'
    New-SolidImage $sustainedExpected 128 128 ([Drawing.Color]::FromArgb(255, 100, 100, 100))
    New-SolidImage $sustainedActual 128 128 ([Drawing.Color]::FromArgb(255, 121, 100, 100))
    $result = Invoke-Comparison sustained-delta $sustainedExpected $sustainedActual
    Assert-Equal $result.ExitCode 1 'Sustained over-tolerance delta exit code'

    $dimensionActual = Join-Path $testRoot 'dimension-actual.png'
    New-SolidImage $dimensionActual 319 200 ([Drawing.Color]::White)
    $result = Invoke-Comparison dimensions $labelExpected $dimensionActual
    Assert-Equal $result.ExitCode 1 'Dimension mismatch exit code'
    Assert-True ([string]$result.Report.reason -like 'Dimensions differ*') 'Dimension mismatch reason'

    $corrupt = Join-Path $testRoot 'corrupt.png'
    [IO.File]::WriteAllText($corrupt, 'not a PNG')
    $result = Invoke-Comparison corrupt $labelExpected $corrupt
    Assert-Equal $result.ExitCode 2 'Corrupt image tool-error exit code'
    Assert-True ([string]$result.Report.reason -like 'Tool error:*') 'Corrupt image reason'

    Write-Output 'PASS: image comparison tolerance, localization, diff, dimension, and error behavior'
}
finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -notmatch '^monitor-tools-image-compare-[0-9a-f]{32}$') {
        throw 'Refusing to remove a path outside this test run.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
