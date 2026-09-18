# Shared configuration and diagnostics helpers. Dot-sourcing never touches hardware.
Set-StrictMode -Version Latest

function Get-MonitorToolsProperty {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Get-MonitorToolsConfigPath {
    param([string]$Root = $PSScriptRoot)
    $pointer = Join-Path $Root 'config-path.txt'
    if (Test-Path -LiteralPath $pointer -PathType Leaf) {
        $path = [IO.File]::ReadAllText($pointer).Trim()
        if (-not [IO.Path]::IsPathRooted($path)) { throw 'The installed configuration path must be absolute. Run Repair.' }
        return [IO.Path]::GetFullPath($path)
    }
    return Join-Path $Root 'monitor-profiles.json'
}

function Stop-MonitorToolsProcesses {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory = $true)][string]$Root)
    # Stop the tray first so it cannot create another worker during deployment.
    foreach ($name in @('MonitorTools', 'MonitorTools.Worker')) {
        $expected = [IO.Path]::GetFullPath((Join-Path $Root "app\$name.exe"))
        foreach ($process in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            $matchesPath = $false
            try { $matchesPath = [IO.Path]::GetFullPath($process.Path).Equals($expected, [StringComparison]::OrdinalIgnoreCase) }
            catch { }
            if ($matchesPath -and $PSCmdlet.ShouldProcess($expected, 'Stop running application process')) {
                try {
                    if (-not $process.HasExited) {
                        try { $process.Kill() }
                        catch {
                            # A process can exit normally after enumeration but before Kill. Suppress only
                            # that verified race; access-denied and other termination failures must block deployment.
                            $exitedDuringKill = $false
                            try { $exitedDuringKill = $process.HasExited } catch { }
                            if (-not $exitedDuringKill) { throw }
                        }
                    }
                    if (-not $process.WaitForExit(5000)) { throw "Process $($process.Id) did not stop. Close Monitor Tools and try again." }
                }
                finally { $process.Dispose() }
            }
            else { $process.Dispose() }
        }
    }
}

function Get-MonitorToolsCompatibilityInfo {
    param([string]$Model, [string]$CatalogPath = (Join-Path $PSScriptRoot 'monitor-compatibility.json'))
    $candidates = [ordered]@{}
    $notes = @()
    if (-not [IO.File]::Exists($CatalogPath) -or [string]::IsNullOrWhiteSpace($Model)) {
        return [pscustomobject]@{ CandidateInputs = $candidates; CompatibilityNotes = $notes; CatalogVersion = $null }
    }
    $catalog = [IO.File]::ReadAllText($CatalogPath) | ConvertFrom-Json
    if ((Get-MonitorToolsProperty $catalog 'schemaVersion') -ne 1) { throw 'Unsupported compatibility catalog version.' }
    foreach ($entry in $catalog.models) {
        $matchesModel = $false
        foreach ($pattern in $entry.modelPatterns) {
            if ($Model.IndexOf([string]$pattern, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $matchesModel = $true; break }
        }
        if (-not $matchesModel) { continue }
        foreach ($candidate in $entry.candidateInputs.PSObject.Properties) { $candidates[$candidate.Name] = [string]$candidate.Value }
        $notes += [string]$entry.evidence
        $notes += @($entry.limitations)
    }
    return [pscustomobject]@{ CandidateInputs = $candidates; CompatibilityNotes = $notes; CatalogVersion = $catalog.catalogVersion }
}

function Test-MonitorToolsConfig {
    param([Parameter(Mandatory = $true)]$Config)
    # Normalize dictionaries and PSCustomObjects without changing the caller's object.
    $value = $Config | ConvertTo-Json -Depth 30 | ConvertFrom-Json
    $version = Get-MonitorToolsProperty $value 'schemaVersion' 1
    if ($version -notin @(1, 2)) { throw "Unsupported configuration schema version '$version'. Upgrade Monitor Tools before editing this file." }
    $profiles = Get-MonitorToolsProperty $value 'profiles'
    if ($null -eq $profiles -or $profiles -isnot [pscustomobject]) { throw "Configuration requires a 'profiles' object." }
    $names = @($profiles.PSObject.Properties)
    if ($names.Count -eq 0) { throw 'Configuration must contain at least one profile.' }
    foreach ($profile in $names) {
        if ($profile.Name -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$') { throw "Invalid profile name '$($profile.Name)'. Use 1-64 letters, digits, hyphens, or underscores." }
        if ($profile.Value -isnot [pscustomobject]) { throw "Profile '$($profile.Name)' must contain monitor assignments." }
        foreach ($assignment in $profile.Value.PSObject.Properties) {
            if ($assignment.Name -notmatch '^[\w-]+$') { throw "Invalid monitor key '$($assignment.Name)'." }
            $setting = $assignment.Value
            if ($setting -is [string] -or $setting -is [ValueType]) {
                $inputs = @([string]$setting)
            }
            elseif ($setting -is [pscustomobject]) {
                $inputs = @()
                $fields = @($setting.PSObject.Properties)
                if ($fields.Count -eq 0) { throw 'A scene assignment must contain input, brightness, or volume.' }
                foreach ($field in $fields) {
                    switch ($field.Name) {
                        'input' { $inputs += [string]$field.Value }
                        { $_ -in @('brightness', 'volume') } {
                            $number = 0
                            if (-not [int]::TryParse([string]$field.Value, [ref]$number) -or $number -lt 0 -or $number -gt 100) {
                                throw "$($field.Name) must be an integer percentage from 0 to 100."
                            }
                        }
                        default { throw "Unknown scene setting '$($field.Name)'." }
                    }
                }
            }
            else { throw "Invalid assignment for '$($assignment.Name)'." }
            foreach ($inputValue in $inputs) {
                $inputNumber = 0
                $validNumber = [int]::TryParse($inputValue, [ref]$inputNumber) -and $inputNumber -ge 0 -and $inputNumber -le 255
                if (-not $validNumber -and $inputValue -notmatch '^(?i:0x[0-9a-f]{1,2}|vga1|dvi[12]|dp[12]|displayport[12]?|hdmi[12]?)$') {
                    throw "Unknown input source '$inputValue'."
                }
            }
        }
    }
    return $true
}

function Read-MonitorToolsConfig {
    param([string]$Path = (Get-MonitorToolsConfigPath))
    $config = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
    [void](Test-MonitorToolsConfig $config)
    return $config
}

function Save-MonitorToolsConfig {
    param([Parameter(Mandatory = $true)]$Config, [Parameter(Mandatory = $true)][string]$Path)
    [void](Test-MonitorToolsConfig $Config)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $directory = [IO.Path]::GetDirectoryName($fullPath)
    [void][IO.Directory]::CreateDirectory($directory)
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $key = [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($fullPath.ToUpperInvariant()))).Replace('-', '') }
    finally { $hash.Dispose() }
    $mutex = [Threading.Mutex]::new($false, ('Local\MonitorTools.Config.' + $key))
    $locked = $false
    $staged = Join-Path $directory ('.profiles-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        try { $locked = $mutex.WaitOne(5000) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Another process is saving profiles. Try again.' }
        [IO.File]::WriteAllText($staged, ($Config | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($fullPath)) {
            $backup = $fullPath + '.' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N') + '.bak'
            [IO.File]::Replace($staged, $fullPath, $backup)
        }
        else { [IO.File]::Move($staged, $fullPath) }
    }
    finally {
        if ([IO.File]::Exists($staged)) { [IO.File]::Delete($staged) }
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Get-MonitorToolsLogDirectory {
    if (-not [string]::IsNullOrWhiteSpace($env:MONITOR_TOOLS_LOG_DIRECTORY)) { return $env:MONITOR_TOOLS_LOG_DIRECTORY }
    return Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Monitor Tools\logs'
}

function Write-MonitorToolsOperation {
    param([Parameter(Mandatory = $true)]$Record, [string]$Directory = (Get-MonitorToolsLogDirectory))
    try {
        [void][IO.Directory]::CreateDirectory($Directory)
        $name = 'operation-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffff') + '-' + [Guid]::NewGuid().ToString('N') + '.json'
        $path = Join-Path $Directory $name
        [IO.File]::WriteAllText($path, ($Record | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
        # Only rotate our own records, retaining the newest 100 and at most 30 days.
        $records = @(Get-ChildItem -LiteralPath $Directory -Filter 'operation-*.json' -File |
            Where-Object { $_.Name -match '^operation-\d{8}T\d{13}-[0-9a-f]{32}\.json$' } |
            Sort-Object Name -Descending)
        for ($i = 0; $i -lt $records.Count; $i++) {
            if ($i -ge 100 -or $records[$i].LastWriteTimeUtc -lt [DateTime]::UtcNow.AddDays(-30)) {
                [IO.File]::Delete($records[$i].FullName)
            }
        }
    }
    catch { Write-Warning "Could not save operation details: $($_.Exception.Message)" }
}
