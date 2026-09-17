[CmdletBinding()]
param([switch]$UpdateBaselines)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($UpdateBaselines -and ($env:CI -or $env:GITHUB_ACTIONS)) { throw 'Baseline updates are disabled in CI. Review and commit them locally.' }
$root = Split-Path -Parent $PSScriptRoot
$sources = Join-Path $PSScriptRoot 'visual'
$baselines = Join-Path $sources 'baselines\classic-96dpi'
$output = [IO.Path]::GetFullPath((Join-Path $root 'build\visual-tests'))
$buildRoot = [IO.Path]::GetFullPath((Join-Path $root 'build')).TrimEnd('\') + '\'
if (-not $output.StartsWith($buildRoot, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $output) -ne 'visual-tests') { throw 'Unexpected visual artifact directory.' }
if (Test-Path -LiteralPath $output) { Remove-Item -LiteralPath $output -Recurse -Force }
foreach ($folder in @('', 'actual', 'expected', 'diff', 'tools')) { [void][IO.Directory]::CreateDirectory((Join-Path $output $folder)) }
$names = @('setup-default', 'setup-verified', 'setup-failure', 'setup-busy', 'setup-compact', 'setup-scroll', 'editor-default', 'editor-compact', 'editor-edited')
$failures = New-Object 'Collections.Generic.List[string]'
$comparisons = New-Object 'Collections.Generic.List[object]'
$renderReport = $null

function Invoke-BoundedProcess {
    param([string]$FilePath, [string[]]$Arguments, [int]$TimeoutSeconds = 60)
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $FilePath
    # These are filesystem paths or fixed switches, never shell commands.
    if (@($Arguments | Where-Object { $_.Contains('"') }).Count) { throw 'Unexpected quote in process argument.' }
    $start.Arguments = ($Arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) { $process.Kill(); throw "$([IO.Path]::GetFileName($FilePath)) exceeded ${TimeoutSeconds}s." }
        $stdout.Wait(); $stderr.Wait()
        if ($stdout.Result) { Write-Host $stdout.Result.TrimEnd() }
        if ($stderr.Result) { Write-Host $stderr.Result.TrimEnd() }
        return $process.ExitCode
    }
    finally { $process.Dispose() }
}

try {
    $setup = Join-Path $root 'dist\Setup.exe'
    $tray = Join-Path $root 'dist\MonitorTools.exe'
    foreach ($binary in @($setup, $tray)) {
        if (-not (Test-Path -LiteralPath $binary -PathType Leaf)) { throw 'Run .\Build-Setup.ps1 before visual tests.' }
    }
    $compiler = @(
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $compiler) { throw 'The .NET Framework C# compiler is required.' }
    $renderer = Join-Path $output 'tools\RenderFixtures.exe'
    $comparer = Join-Path $output 'tools\ImageComparer.exe'
    & $compiler /nologo /target:exe /optimize+ "/out:$renderer" /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.Web.Extensions.dll (Join-Path $sources 'RenderFixtures.cs')
    if ($LASTEXITCODE -ne 0) { throw 'Visual renderer compilation failed.' }
    & $compiler /nologo /target:exe /optimize+ "/out:$comparer" /reference:System.Drawing.dll (Join-Path $sources 'ImageComparer.cs')
    if ($LASTEXITCODE -ne 0) { throw 'Image comparer compilation failed.' }

    $hostExecutable = (Get-Process -Id $PID).Path
    $selfTestExit = Invoke-BoundedProcess $hostExecutable @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $sources 'Test-ImageComparer.ps1'))
    if ($selfTestExit -ne 0) { throw 'Image comparer self-tests failed.' }
    $renderExit = Invoke-BoundedProcess $renderer @($setup, $tray, (Join-Path $output 'actual'))
    $renderReport = Get-Content -LiteralPath (Join-Path $output 'actual\fixtures.json') -Raw | ConvertFrom-Json
    if ($renderReport.renderProfile -cne 'classic-96dpi') { throw 'Unexpected renderer profile.' }
    $renderNames = @($renderReport.fixtures | ForEach-Object { $_.name })
    if (($renderNames -join '|') -cne ($names -join '|')) { throw 'Renderer fixture inventory changed. Update the test inventory explicitly.' }
    foreach ($fixture in $renderReport.fixtures) {
        if (-not $fixture.passed) { $failures.Add("$($fixture.name): $($fixture.errors -join ' | ')") }
    }
    if ($renderExit -ne 0 -and $failures.Count -eq 0) { $failures.Add("Renderer failed with exit code $renderExit.") }

    $manifestPath = Join-Path $baselines 'manifest.json'
    if ($UpdateBaselines) {
        if ($failures.Count) { throw 'Cannot update baselines while layout or interaction assertions fail.' }
        [void][IO.Directory]::CreateDirectory($baselines)
        foreach ($name in $names) { Copy-Item -LiteralPath (Join-Path $output "actual\$name.png") -Destination (Join-Path $baselines "$name.png") -Force }
        [ordered]@{ renderProfile = 'classic-96dpi'; fixtures = $names } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
        Write-Host 'Baselines updated. Review all nine PNGs and commit intentional changes.'
    }
    if (-not (Test-Path -LiteralPath $manifestPath)) { throw 'Visual baselines are missing. Restore them from Git or explicitly run -UpdateBaselines and review the images.' }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.renderProfile -cne 'classic-96dpi' -or ($manifest.fixtures -join '|') -cne ($names -join '|')) { throw 'Baseline manifest does not match the expected visual fixture inventory.' }
    foreach ($name in $names) {
        $expected = Join-Path $baselines "$name.png"
        $actual = Join-Path $output "actual\$name.png"
        if (-not (Test-Path -LiteralPath $expected) -or -not (Test-Path -LiteralPath $actual)) {
            $failures.Add("${name}: expected or actual screenshot is missing.")
            continue
        }
        Copy-Item -LiteralPath $expected -Destination (Join-Path $output "expected\$name.png")
        $comparisonPath = Join-Path $output "diff\$name.json"
        $compareExit = Invoke-BoundedProcess $comparer @($expected, $actual, (Join-Path $output "diff\$name.png"), $comparisonPath) -TimeoutSeconds 30
        $comparison = Get-Content -LiteralPath $comparisonPath -Raw | ConvertFrom-Json
        $comparisons.Add([pscustomobject]@{ name = $name; exitCode = $compareExit; comparison = $comparison })
        if ($compareExit -ne 0 -or -not $comparison.passed) { $failures.Add("${name}: $($comparison.reason)") }
    }
}
catch { $failures.Add($_.Exception.Message) }
finally {
    $report = [ordered]@{ passed = ($failures.Count -eq 0); baselineUpdate = [bool]$UpdateBaselines; render = $renderReport; comparisons = @($comparisons.ToArray()); failures = @($failures.ToArray()) }
    $report | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath (Join-Path $output 'report.json') -Encoding UTF8
    $html = New-Object Text.StringBuilder
    [void]$html.AppendLine('<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Monitor Tools visual tests</title><style>body{font:16px system-ui;margin:2rem;background:#f4f5f7;color:#17202a}section{background:white;padding:1rem;margin:1rem 0}figure{margin:0;min-width:0}img{max-width:100%;border:1px solid #aaa} .images{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:1rem}pre{white-space:pre-wrap;color:#a11}a{color:#145da0}</style><h1>Monitor Tools visual tests</h1><p>Expected, actual, and highlighted differences. Classic controls at 96 DPI; synthetic monitor data.</p><p><a href="report.json">Machine-readable results</a></p>')
    [void]$html.AppendLine('<h2>' + $(if ($failures.Count) { 'FAIL' } else { 'PASS' }) + '</h2>')
    foreach ($failure in $failures) { [void]$html.AppendLine('<pre>' + [Net.WebUtility]::HtmlEncode($failure) + '</pre>') }
    foreach ($name in $names) {
        [void]$html.AppendLine("<section><h2>$name</h2><div class=`"images`">")
        foreach ($kind in @('expected', 'actual', 'diff')) { [void]$html.AppendLine("<figure><figcaption>$kind</figcaption><a href=`"$kind/$name.png`"><img alt=`"$kind $name`" src=`"$kind/$name.png`"></a></figure>") }
        [void]$html.AppendLine('</div></section>')
    }
    [void]$html.AppendLine('</html>')
    [IO.File]::WriteAllText((Join-Path $output 'index.html'), $html.ToString())
}
Write-Host "Visual report: $(Join-Path $output 'index.html')"
if ($failures.Count) { throw "Visual integration tests failed:`n$($failures -join "`n")" }
Write-Output "PASS: $($names.Count) visual integration fixtures, layout/interaction assertions, and image-comparison self-tests."
