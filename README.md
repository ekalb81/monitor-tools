# Monitor Tools

Switch a Windows desk between computers using monitor input controls. Save whole-desk or mixed-computer profiles, use keyboard shortcuts, and adjust supported brightness/volume settings. Monitor Tools uses DDC/CI; it does **not** transfer keyboard, mouse, USB devices, or files.

## Install and calibrate

1. Run **Setup.exe** from a [release](https://github.com/ekalb81/monitor-tools/releases), or build it using the commands below.
2. Identify your monitors, name your computers, and choose the input connected to each computer.
3. Test each monitor individually. Confirm the input currently showing this computer, run the timed test, and confirm whether it switched away and returned. A skipped test remains unverified.
4. Choose hotkeys and optional startup at login, then install. Open **Monitor Tools** from the Start Menu to use the tray menu and manage profiles.

Setup installs for your Windows account without administrator access. Ordinary installation and discovery do not change inputs. **Choosing a calibration test does switch the selected monitor** and attempts to return after the countdown. Return is best-effort: keep the physical input selector available until both directions work.

The documented Samsung Odyssey G60SD desk uses HDMI **`0x05`**, rather than standard HDMI 1 (`0x11`). The compatibility catalog supplies candidate mappings; a successful Windows API call or capability report does not verify that the picture changed. Confirm the visible result on your own hardware.

Requirements: Windows PowerShell 5.1 and .NET Framework 4.5 or later (included on Windows 11). PowerShell 7 can run the scripts. Check that DDC/CI is enabled in the monitor menu. Cable, dock, adapter, and inactive-input support vary.

## Everyday use

The tray menu provides saved profiles and individual monitor controls. The profile editor supports custom names, hotkeys, and leaving selected monitors unchanged. Hotkeys are registered by the running tray app; registration conflicts are reported. Optional login startup keeps them available after signing in.

For a three-monitor desk, useful profiles include:

| Profile | Left | Center | Right |
| --- | --- | --- | --- |
| Personal | This computer | This computer | This computer |
| Work | Other computer | Other computer | Other computer |
| Split desk | Other computer | This computer | Other computer |
| Center only | Unchanged | Other computer | Unchanged |

New setup profiles use physical monitor IDs. If an identity changes or cannot be distinguished, review the binding in setup rather than silently assigning it to another display. Older position-based profiles remain readable but depend on the current desktop arrangement.

## Commands

Run commands from the repository or installed application directory. In PowerShell, add `-ExecutionPolicy Bypass -File` when invoking a script through `powershell.exe` if needed; this affects only that process.

```powershell
# Read-only inventory; inspect hardware IDs as structured objects.
.\Switch-MonitorInput.ps1 -List
.\Switch-MonitorInput.ps1 -List -PassThru | Format-List

# Validate assignments without sending input changes.
.\Other-PC.cmd -WhatIf
.\This-PC.cmd -WhatIf
.\Run-Profile.ps1 -Profile split-desk -WhatIf

# Apply profiles when ready to switch.
.\Other-PC.cmd
.\This-PC.cmd
.\Run-Profile.ps1 -Profile split-desk
```

Inputs accept `hdmi1`, `hdmi2`, `displayport1`, `displayport2`, `dvi1`, `dvi2`, `vga1`, or a decimal/hexadecimal value from 0 to 255. Targets accept a discovered `StableId`, current position/index, or `all`.

```powershell
# Example: substitute an ID from your inventory and inputs already identified.
.\Switch-MonitorInput.ps1 -TestMonitor id-from-your-inventory `
    -TestInput displayport1 -ReturnInput 0x05 -ReturnAfterSeconds 5 -PassThru

# After individual tests, test a whole desk with a known return profile.
.\Switch-MonitorInput.ps1 -TestProfile other-pc -ReturnProfile this-pc `
    -ReturnAfterSeconds 5 -PassThru

# Retry a profile only on a selected monitor.
.\Run-Profile.ps1 -Profile other-pc -MonitorId id-from-your-inventory

# Optional deep discovery (capability reports can be slow or inaccurate).
.\Switch-MonitorInput.ps1 -List -IncludeCapabilities
```

All assignments are checked before the first write. Hardware failures can still leave a partially applied profile. Results identify the monitor and distinguish accepted commands from physical verification. Concurrent switching requests are coordinated. Retries are bounded, and completed input changes are not automatically undone.

Use `-ConfigPath` for another configuration file. `-SaveCurrentSettings` requests persistence on the monitor after a successful write; it is normally unnecessary. `Switch-To-This-PC.cmd` and `Switch-To-Other-PC.cmd` remain aliases for the shorter wrappers.

## Configuration, upgrades, and removal

Default locations:

- Application: `%LOCALAPPDATA%\Monitor Tools\app`
- Configuration: `%LOCALAPPDATA%\Monitor Tools\data\monitor-profiles.json`
- Operation logs: `%LOCALAPPDATA%\Monitor Tools\logs`

`config-path.txt` in the application directory resolves the active configuration. Source checkouts use the JSON file beside the scripts. Installation migrates existing configuration with backups, and stages application updates with rollback on deployment failure. Keep configuration backups until the upgraded app works on your desk.

Use **Monitor Tools** in Windows Installed Apps to repair or uninstall. Configuration is preserved by default. For manual deployment, `Setup.cmd` remains available. Custom installation directories receive a separate sibling data directory.

The standalone `Install-ProfileHotkeys.ps1` still supports legacy shortcut hotkeys. Avoid registering the same keys in both shortcuts and the tray app. Remove those shortcuts with `Install-ProfileHotkeys.ps1 -Uninstall` before using tray hotkeys.

During upgrades, setup clears the old shortcut bindings and notifies Windows before the tray takes ownership. The tray retries temporary registration conflicts before warning. If a conflict persists, close the app that owns those keys or change them in **Profiles and hotkeys**, then save to retry registration. A hotkey conflict does not erase input choices or completed calibration.

See [configuration reference](docs/CONFIGURATION.md) for schema 2, partial profiles, brightness/volume scenes, and diagnostic privacy. Scene controls must be supported by the monitor; HDR or monitor-specific modes can affect their behavior.

## Troubleshooting

| Symptom | Next step |
| --- | --- |
| Command accepted but picture unchanged | Test one monitor visibly; check the port and hardware-specific mapping. |
| Cannot return to this computer | Restore the input physically, then verify the return input and inactive-link DDC/CI support. |
| Missing or ambiguous monitor | Refresh discovery and review its binding in setup after identifying it. |
| Only some monitors changed | Inspect per-monitor results and retry the selected monitor once its cause is corrected. |
| Shortcut does nothing | Keep the tray app running, check shortcut conflicts, and verify which computer receives the keyboard. |
| Unsupported brightness or volume | Omit that scene setting; input switching can still be used independently. |

Export a read-only report from the tray or command line:

```powershell
.\Export-Diagnostics.ps1 -OutputPath "$env:USERPROFILE\Desktop\monitor-diagnostics.json"
```

Device identifiers are redacted by default. `-IncludeCapabilities` and `-IncludeIdentifiers` explicitly include deeper hardware information. Review reports before sharing. Recent operation records retain the newest 100 files for at most 30 days. The launcher's `last-error.log` retains its most recent failure, so check its timestamp.

## Build, test, and release

No package downloads are required by the build script. It uses the installed .NET Framework compiler:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Build-Setup.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-AllTests.ps1 -IncludeExecutable
pwsh -NoProfile -File .\tests\Run-AllTests.ps1
```

The build produces `dist\Setup.exe` and the tray executable. Tests use mock monitor calls and isolated installation files, never real input changes. `Setup.exe --verify-package` checks extraction without discovery; `Setup.exe --render-preview <absolute-png-path>` renders sample setup UI.

**Visual integration tests run automatically in CI** and with `-IncludeExecutable`. Nine screenshot baselines cover setup states, scrolling, compact windows, and editing/saving a profile. They check real compiled WinForms controls with synthetic data, without switching your monitors. Run just these tests with `powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Visual.ps1` after building. Open `build/visual-tests/index.html` for results; CI retains screenshots and highlighted differences on failure. See [visual test instructions](tests/visual/README.md) for coverage, rendering limits, and deliberate baseline updates.

`VERSION` controls release versioning. GitHub Actions tests Windows PowerShell 5.1, PowerShell 7, and the executable bridge. A matching `v<VERSION>` tag publishes the installer and its SHA-256 checksum. Signing uses `SIGNING_PFX_BASE64` and `SIGNING_PFX_PASSWORD` workflow secrets; without a certificate the installer is unsigned. Local signing uses `Build-Setup.ps1 -SigningCertificateThumbprint <thumbprint>`.

See [AGENTS.md](AGENTS.md) for contributor guidelines, [TESTING-NOTES.md](TESTING-NOTES.md) for physical outcomes, [hardware notes](docs/HARDWARE-NOTES.md) for the original investigation, and [PowerToys assessment](docs/POWERTOYS-INTEGRATION.md) for optional integration considerations.
