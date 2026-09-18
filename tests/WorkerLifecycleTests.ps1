[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:events = New-Object System.Collections.Generic.List[string]
$script:processes = @{}

function Assert-WorkerLifecycle {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function New-FakeMonitorToolsProcess {
    param(
        [string]$Label,
        [string]$Path,
        [bool]$WaitResult = $true,
        [bool]$KillThrows = $false,
        [bool]$ExitDuringKill = $false
    )
    $process = [pscustomobject]@{
        Label = $Label
        Id = 4242
        Path = $Path
        HasExited = $false
        WaitResult = $WaitResult
        KillThrows = $KillThrows
        ExitDuringKill = $ExitDuringKill
    }
    $process | Add-Member -MemberType ScriptMethod -Name Kill -Value {
        $script:events.Add("kill:$($this.Label)")
        if ($this.KillThrows) {
            if ($this.ExitDuringKill) { $this.HasExited = $true }
            throw [InvalidOperationException]::new('Injected termination race or failure.')
        }
        $this.HasExited = $true
    }
    $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {
        param([int]$Milliseconds)
        $script:events.Add("wait:$($this.Label):$Milliseconds")
        return $this.WaitResult
    }
    $process | Add-Member -MemberType ScriptMethod -Name Dispose -Value {
        $script:events.Add("dispose:$($this.Label)")
    }
    return $process
}

# This mock prevents the test from enumerating or touching any real process.
function Get-Process {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)
    $script:events.Add("get:$Name")
    if ($script:processes.ContainsKey($Name)) { return @($script:processes[$Name]) }
    return @()
}

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'MonitorTools.Common.ps1')

$root = Join-Path ([IO.Path]::GetTempPath()) ('monitor-tools-lifecycle-root-' + [Guid]::NewGuid().ToString('N'))
$trayPath = Join-Path $root 'app\MonitorTools.exe'
$workerPath = Join-Path $root 'app\MonitorTools.Worker.exe'
$foreignPath = Join-Path ($root + '-sibling') 'app\MonitorTools.exe'

$foreign = New-FakeMonitorToolsProcess -Label foreign -Path $foreignPath
$tray = New-FakeMonitorToolsProcess -Label tray -Path $trayPath.ToUpperInvariant()
$worker = New-FakeMonitorToolsProcess -Label worker -Path $workerPath
$script:processes = @{ MonitorTools = @($foreign, $tray); 'MonitorTools.Worker' = @($worker) }
Stop-MonitorToolsProcesses -Root $root -Confirm:$false

$joined = $script:events -join ','
Assert-WorkerLifecycle ($joined -notmatch 'kill:foreign') 'A same-name process outside the installation was stopped.'
Assert-WorkerLifecycle ($joined -match 'dispose:foreign') 'A nonmatching process object was not disposed.'
Assert-WorkerLifecycle ($joined -match 'kill:tray,wait:tray:5000,dispose:tray') 'The installed tray was not stopped and disposed.'
Assert-WorkerLifecycle ($joined -match 'kill:worker,wait:worker:5000,dispose:worker') 'The installed worker was not stopped and disposed.'
Assert-WorkerLifecycle ($joined.IndexOf('kill:tray', [StringComparison]::Ordinal) -lt
    $joined.IndexOf('get:MonitorTools.Worker', [StringComparison]::Ordinal)) 'The worker was enumerated before the tray stopped.'

$script:events.Clear()
$preview = New-FakeMonitorToolsProcess -Label preview -Path $trayPath
$script:processes = @{ MonitorTools = @($preview); 'MonitorTools.Worker' = @() }
Stop-MonitorToolsProcesses -Root $root -WhatIf
Assert-WorkerLifecycle (($script:events -join ',') -notmatch 'kill:preview') 'WhatIf stopped a process.'
Assert-WorkerLifecycle (($script:events -join ',') -match 'dispose:preview') 'WhatIf did not dispose the process object.'

$script:events.Clear()
$blocked = New-FakeMonitorToolsProcess -Label blocked -Path $trayPath -WaitResult $false
$script:processes = @{ MonitorTools = @($blocked); 'MonitorTools.Worker' = @() }
$failed = $false
try { Stop-MonitorToolsProcesses -Root $root -Confirm:$false }
catch { $failed = $_.Exception.Message -match 'did not stop' }
Assert-WorkerLifecycle $failed 'A process that remained active did not block deployment.'
Assert-WorkerLifecycle (($script:events -join ',') -match 'dispose:blocked') 'A failed stop did not dispose the process object.'

$script:events.Clear()
$exited = New-FakeMonitorToolsProcess -Label exited -Path $trayPath -KillThrows $true -ExitDuringKill $true
$script:processes = @{ MonitorTools = @($exited); 'MonitorTools.Worker' = @() }
Stop-MonitorToolsProcesses -Root $root -Confirm:$false
Assert-WorkerLifecycle (($script:events -join ',') -match 'kill:exited,wait:exited:5000,dispose:exited') 'An ordinary exit during Kill was not tolerated.'

$script:events.Clear()
$denied = New-FakeMonitorToolsProcess -Label denied -Path $trayPath -KillThrows $true
$script:processes = @{ MonitorTools = @($denied); 'MonitorTools.Worker' = @() }
$failed = $false
try { Stop-MonitorToolsProcesses -Root $root -Confirm:$false }
catch { $failed = $_.Exception.Message -match 'Injected termination' }
Assert-WorkerLifecycle $failed 'A real process termination failure was suppressed.'
Assert-WorkerLifecycle (($script:events -join ',') -match 'dispose:denied') 'A failed termination did not dispose the process object.'

Write-Host 'PASS: exact-path shutdown order, exit race, real failure, preview behavior, and bounded wait'
