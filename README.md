# Monitor Tools

Switch monitors between two computers with a command or keyboard shortcut. The tool selects monitor inputs using DDC/CI, a monitor control protocol. It does **not** transfer keyboard, mouse, USB devices, or files.

## Install with Setup.exe

1. Open **Setup.exe**. It contains the application files; no extraction or terminal commands are needed.
2. Choose the input connected to **This PC** and **Other PC** for each detected monitor. Existing installed settings are prefilled. For the verified Twingo/G60SD setup, use **HDMI (Samsung 0x05)** for HDMI connections. You can also type a previously verified raw code for unusual hardware.
3. Leave **Install hotkeys** selected for `Ctrl+Alt+1` / `Ctrl+Alt+2`, then click **Install**.
4. Click **Finish**. Test one monitor in both directions before switching all screens.

Setup installs for your Windows account in `%LOCALAPPDATA%\Monitor Tools\app`, validates both profiles, and backs up replaced settings. It does not need administrator access or switch inputs during installation. You can delete the downloaded executable afterward. Reopen `Setup.exe` in the installed folder to change inputs or update hotkeys. Leaving the hotkey box unchecked skips shortcut installation; it does not remove existing shortcuts.

The executable requires Windows with .NET Framework 4.5 or newer and Windows PowerShell. This project's locally built executable is unsigned. Building it from source is documented below; `Setup.cmd` is an alternative guided console installer when using the source folder.

## Before you start

- Use Windows with Windows PowerShell 5.1. PowerShell 7 can also run the scripts; launchers and hotkeys use Windows PowerShell.
- Connect the computers to the monitors and check each monitor's on-screen menu for a DDC/CI setting. Input switching and control through your cables, docks, and adapters require testing.
- No build, package installation, or Samsung driver installation is required. The [Samsung hardware notes](docs/HARDWARE-NOTES.md) describe one tested setup, not a compatibility guarantee.
- Decide which computer will receive your commands and keyboard input. A hotkey runs on the computer receiving the keystroke; switching the picture does not move the keyboard connection.

## Manual setup and troubleshooting reference

Users of `Setup.exe` can skip the manual installation steps. The discovery commands and one-monitor test below are also useful for diagnosing an installed copy; run them from `%LOCALAPPDATA%\Monitor Tools\app`.

### 1. Save the files and open PowerShell

On the repository page, choose **Code > Download ZIP** and extract it, or clone the repository if you use Git. Keep the entire folder in a permanent location before installing hotkeys.

Open **Windows PowerShell** from Start. Change to the extracted folder, replacing this path with yours:

```powershell
cd "$HOME\Documents\monitor-tools"
```

Run the following commands in that window. `-ExecutionPolicy Bypass` applies to that invocation, without changing your saved execution policy. If your organization blocks script execution, follow its policy.

### 2. Discover your monitors

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Switch-MonitorInput.ps1 -List
```

| Output column | Meaning |
| --- | --- |
| `Index` | Target number for this enumeration; it may differ from Windows Settings display numbers. |
| `Position` | Target name calculated from the current display arrangement. |
| `DisplayDevice` / `Description` | Identifies the display in this inventory. |
| `CurrentInput` | Reported input; some monitors return stale or unexpected values. |
| `AdvertisedInputs` | Reported input names; these do not prove switching will work. |

One monitor is `center`; two are `left` and `right`; three are `left`, `center`, and `right`. Four or more use `position-1`, `position-2`, etc. Ordering uses horizontal position, then vertical position. Re-run `-List` after connecting, disconnecting, or rearranging displays: names and indexes are not permanent hardware identities.

### 3. Configure both destinations

The bundled `monitor-profiles.json` matches the verified three-monitor Twingo setup: HDMI `0x05` on the sides and DisplayPort on the center for this PC; the reverse for the other computer. This is a hardware-specific configuration. **Choose and edit an example before running either launcher on a different setup.**

| Monitors | Starting configuration |
| --- | --- |
| 1 | [one-monitor.json](examples/one-monitor.json) |
| 2 | [two-monitors.json](examples/two-monitors.json) |
| 3 | [three-monitors.json](examples/three-monitors.json) |
| 4 | [four-monitors.json](examples/four-monitors.json) |

For **two monitors**, copy the example and edit it:

```powershell
Copy-Item .\examples\two-monitors.json .\monitor-profiles.json
notepad .\monitor-profiles.json
```

This replaces the bundled configuration. Back up an existing customized configuration before replacing it. For more than four monitors, extend the four-monitor example using names from `-List`.

Examples assume this computer uses DisplayPort 1 and the other computer uses HDMI 1 on every monitor. Change each value to match the cable's actual **monitor input port**. Different monitors can have different wiring:

```json
{
  "profiles": {
    "this-pc": { "left": "displayport1", "right": "hdmi2" },
    "other-pc": { "left": "hdmi1", "right": "displayport1" }
  }
}
```

Save valid JSON: double quotes, no comments, and no trailing commas. `this-pc` and `other-pc` are labels for your configured inputs, not automatic computer detection. If installing on the second computer too, configure destinations from that computer's perspective.

### 4. Preview both profiles

```powershell
.\This-PC.cmd -WhatIf
.\Other-PC.cmd -WhatIf
```

A preview enumerates monitors and validates targets and input values without changing inputs. It does **not** verify cable routing, visible switching, or whether the monitor remains reachable afterward. Resolve configuration errors before continuing.

### 5. Test one monitor and its return path

Keep the monitor's physical input selector available. This example uses `center`, with this computer on DisplayPort 1 and the other on HDMI 1. **Replace the target and inputs with your own values.**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Switch-MonitorInput.ps1 -SetMonitor center=hdmi1
powershell -NoProfile -ExecutionPolicy Bypass -File .\Switch-MonitorInput.ps1 -SetMonitor center=displayport1
```

Check the visible picture in each direction. The return command must run on a computer that still has a DDC/CI connection to the monitor. If you cannot see the terminal, send keyboard input to that computer or restore the input using the monitor's physical controls. Inactive-input control worked on the original setup; it is not established for yours.

Repeat for the remaining monitors, then apply the complete profiles:

```powershell
.\Other-PC.cmd
.\This-PC.cmd
```

All assignments are validated before the first write. A hardware failure can still leave earlier monitors switched; completed writes are not rolled back.

### 6. Install hotkeys after both directions work

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-ProfileHotkeys.ps1
```

- `Ctrl+Alt+1`: apply `this-pc`.
- `Ctrl+Alt+2`: apply `other-pc`.

Shortcuts appear under **Monitor Tools** in your Start Menu Programs folder. They run without a visible window and record profile errors. To change keys, rerun the installer with `-ThisPcHotkey "CTRL+ALT+3" -OtherPcHotkey "CTRL+ALT+4"`.

## Troubleshooting

Run `-List`, then `.\Other-PC.cmd -WhatIf` or `.\This-PC.cmd -WhatIf` from an open PowerShell window so errors stay visible. Omit `-WhatIf` only when ready to test a real switch.

| Symptom | Next step |
| --- | --- |
| No monitors, blank capabilities, or failed write | Check connections, monitor power, DDC/CI settings, and the cable/dock path. Record the error and monitor model. |
| Missing monitor target | Re-run `-List`; update both profiles with current targets and remove absent monitors. |
| Invalid JSON or input source | Check JSON syntax and supported input names below. |
| Command completes but picture stays the same | Check physical ports and test one monitor. Input readback alone is not proof of switching. |
| Samsung G60SD switches to DisplayPort but HDMI selection does nothing | Standard HDMI 1 sends `0x11`. The tested Twingo setup needs **HDMI (Samsung 0x05)**. See the verified mapping in `TESTING-NOTES.md`; test your own hardware before using this override. |
| Hotkey does nothing | Run its profile visibly, check the error log and keyboard destination, and try different keys if another application uses them. |
| Hotkeys fail after moving the project | Rerun the installer from the new folder. |
| Cannot switch back | Restore the input with monitor controls. Recheck keyboard routing and inactive-input DDC/CI support. |

Launchers and installed hotkeys save the **most recent failure** in `%LOCALAPPDATA%\Monitor Tools\last-error.log`. Read it with:

```powershell
Get-Content "$env:LOCALAPPDATA\Monitor Tools\last-error.log"
```

The log includes UTC time, profile, configuration path, PowerShell version, and error. Success does not clear it; check its timestamp. A missing log means no failure was recorded, or the launcher could not start or write the log. Direct `Switch-MonitorInput.ps1` calls show errors in the terminal without creating this log. Reinstall older hotkeys to enable logging.

## Move or remove hotkeys

Keep the project folder in place while using shortcuts. After moving or updating the project, rerun the installer from its current location.

Preview removal, then remove the two shortcuts:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-ProfileHotkeys.ps1 -Uninstall -WhatIf
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-ProfileHotkeys.ps1 -Uninstall
```

Removal leaves profiles, logs, and other Start Menu items in place. You can also manually delete **This PC Profile** and **Other PC Profile** from the Start Menu's **Monitor Tools** folder.

## Command reference

- Inputs: `hdmi1`, `hdmi2`, `displayport1`, `displayport2`, `dvi1`, `dvi2`, `vga1`, or decimal/hex codes from 0 to 255. Raw codes such as `0x05` require hardware-specific verification.
- Targets: an `Index` or `Position` from `-List`, or `all`.
- Alternative configuration: `.\Other-PC.cmd -ConfigPath .\my-profiles.json -WhatIf`. Hotkeys use `monitor-profiles.json` beside the scripts.
- `-SaveCurrentSettings` requests persistence after a write. It was not required for the original observed switch.
- `Switch-To-This-PC.cmd` and `Switch-To-Other-PC.cmd` are aliases for the shorter launchers.

## Development and hardware evidence

From a repository checkout, build the single-file Windows installer using the Windows .NET Framework compiler:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Build-Setup.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Executable.ps1
```

Output: `dist\Setup.exe`. It embeds the scripts, documentation, examples, and tests. `installer\Setup.cs` contains the Windows Forms interface; `Install.ps1` handles profile validation, copying, and backups. Generated `build/` and `dist/` files are ignored by Git. No package downloads are required by the build script.

`Setup.exe --verify-package` checks embedded-file extraction without displaying a window or contacting monitors. Developers can render a sample window with `Setup.exe --render-preview <absolute-png-path>`; that mode uses sample monitors and performs no installation.

Run the hardware-free regression suite in fresh processes:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
pwsh -NoProfile -File .\tests\Run-Tests.ps1
```

The second command requires PowerShell 7. Tests mock monitor calls and shortcut creation and use temporary files for logging checks. No external test framework is required.

See [AGENTS.md](AGENTS.md) for contributor guidelines, [TESTING-NOTES.md](TESTING-NOTES.md) for physical outcomes, and [HARDWARE-NOTES.md](docs/HARDWARE-NOTES.md) for the original driver and capability investigation.
