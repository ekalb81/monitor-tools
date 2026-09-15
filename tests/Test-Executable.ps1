# Run with Windows PowerShell 5.1 after Build-Setup.ps1, from a repository checkout.
param([string]$ExecutablePath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ExecutablePath)) { $ExecutablePath = Join-Path $repo 'dist\Setup.exe' }
$ExecutablePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ExecutablePath)
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('monitor-tools-exe-test-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$window = $null
try {
    foreach ($name in @('Install.ps1', 'Setup.cmd', 'Run-Profile.ps1', 'This-PC.cmd', 'Other-PC.cmd',
        'Switch-To-This-PC.cmd', 'Switch-To-Other-PC.cmd', 'README.md')) {
        Copy-Item -LiteralPath (Join-Path $repo $name) -Destination (Join-Path $testRoot $name)
    }
    Copy-Item -LiteralPath (Join-Path $repo 'installer\Detect-Monitors.ps1') -Destination $testRoot
    Set-Content -LiteralPath (Join-Path $testRoot 'Install-ProfileHotkeys.ps1') -Value 'throw "Hotkeys must be disabled in this smoke test."'
    $switchSource = (Get-Content -LiteralPath (Join-Path $repo 'Switch-MonitorInput.ps1') -Raw).Replace('DdcCiNativeV2', 'MockDdcCiForTests')
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($switchSource, [ref]$tokens, [ref]$errors)
    $nativeString = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value.Contains('public static class MockDdcCiForTests')
    }, $true)
    if ($null -eq $nativeString) { throw 'Mock injection failed.' }
    $switchSource = $switchSource.Replace($nativeString.Value, (Get-Content -LiteralPath (Join-Path $repo 'tests\MockDdcCi.cs') -Raw))
    $switchSource = $switchSource.Replace('function Get-PrimaryInputName {', '[MockDdcCiForTests]::Reset(2)' + [Environment]::NewLine + 'function Get-PrimaryInputName {')
    [IO.File]::WriteAllText((Join-Path $testRoot 'Switch-MonitorInput.ps1'), $switchSource)

    Add-Type -AssemblyName System.Windows.Forms
    $assembly = [Reflection.Assembly]::LoadFrom($ExecutablePath)
    $windowType = $assembly.GetType('SetupWindow')
    $flags = [Reflection.BindingFlags]'Instance,NonPublic'
    $constructor = $windowType.GetConstructor($flags, $null, [type[]]@([string], [bool]), $null)
    $window = $constructor.Invoke([object[]]@([string]$testRoot, $true))
    $runScript = $windowType.GetMethod('RunScript', $flags)
    $output = $runScript.Invoke($window, [object[]]@('Detect-Monitors.ps1', ''))
    $monitors = ConvertFrom-Json -InputObject $output
    if ($monitors.Count -ne 2 -or $monitors[0].Position -ne 'left') { throw "Executable detection bridge returned an unexpected inventory: $output" }

    $installedPath = Join-Path $testRoot 'Installed Files'
    $configuration = Join-Path $repo 'examples\two-monitors.json'
    $arguments = '-Unattended -ConfigurationFile "' + $configuration + '" -InstallDirectory "' + $installedPath + '"'
    [void]$runScript.Invoke($window, [object[]]@('Install.ps1', $arguments))
    if (-not (Test-Path -LiteralPath (Join-Path $installedPath 'monitor-profiles.json'))) { throw 'Executable installation bridge did not save profiles.' }

    $readInput = $windowType.GetMethod('ReadInput', $flags)
    $box = New-Object Windows.Forms.ComboBox
    foreach ($pair in @(@('HDMI 1', 'hdmi1'), @('HDMI (Samsung 0x05)', '0x05'), @('0x05', '0x05'), @('17', '17'), @('dp1', 'displayport1'))) {
        $box.Text = $pair[0]
        $actual = $readInput.Invoke($window, [object[]]@($box.PSObject.BaseObject, 'left'))
        if ($actual -ne $pair[1]) { throw 'Executable input conversion failed.' }
    }
    $box.Dispose()
    'PASS: executable detection, installation bridge, paths with spaces, and input conversion (mock hardware).'
}
finally {
    if ($null -ne $window) { $window.Dispose() }
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolved) -notmatch '^monitor-tools-exe-test-[0-9a-f]{32}$') { throw 'Unexpected cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
