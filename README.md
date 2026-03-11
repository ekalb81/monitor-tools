# Samsung Monitor DDC/CI Notes

This folder contains the saved findings from the Samsung G60SD monitor driver inspection plus a PowerShell tool for switching inputs over DDC/CI.

## What is installed

- Samsung monitor INF package: `oem88.inf` (original name `s27dg60xs.inf`)
- Samsung monitor profile file: `C:\WINDOWS\system32\spool\drivers\color\S27DG60xS.icm`
- Active kernel driver: `C:\WINDOWS\System32\drivers\monitor.sys`
- Driver provider/version: Samsung `1.0.0.0` dated `2024-01-31`

The Samsung package does not install a Samsung-specific control DLL or service. Windows binds these displays to the standard Microsoft monitor class driver (`monitor.sys`), so input switching happens through the normal Windows DDC/CI path in `Dxva2.dll`.

## DDC/CI findings

The monitors reported MCCS `2.0` and advertised this VCP block:

```text
vcp(02 04 05 08 10 12 14(05 08 0B 0C) 16 18 1A 52 60(01 03 04 11 12 0F 10) 62 8D FF)
```

Relevant controls:

- `0x10` brightness
- `0x12` contrast
- `0x14` color preset
- `0x16`, `0x18`, `0x1A` RGB gain
- `0x52` active control
- `0x60` input source
- `0x62` speaker volume
- `0x8D` audio mute / screen blank

The probe also got valid replies from info/vendor codes `0xB6`, `0xC6`, `0xC8`, `0xC9`, `0xCA`, `0xCC`, `0xD6`, `0xDC`, `0xDF`, `0xE0`, `0xE5`, `0xE6`, `0xE9`, `0xF7`, and `0xFE`.

## Observed Samsung quirk

In inactive-link testing on the `right` monitor (`\\.\DISPLAY5`), the standard input-source write for `hdmi1` (`0x11`) did not visibly switch the monitor, even when followed by `SaveCurrentSettings`.

The command that did work was:

```powershell
.\Switch-MonitorInput.ps1 -SetMonitor @('right=0x05')
```

`SaveCurrentSettings` was not required in the follow-up test. So for this monitor and this test path, raw `0x05` appears to be the effective value for the desired input, even though the monitor advertises standard HDMI values in its capabilities string. Treat this as an observed monitor-specific quirk, not a universal Samsung rule.

The `right` monitor also remained readable from this PC while it was visually switched to the other computer, so inactive-link DDC/CI reads appear to work on this setup.

## Active monitor inventory at probe time

| Index | Position | Description | Current input | Notes |
| --- | --- | --- | --- | --- |
| `1` | `center` | `G60SD_S27DG60xS (DP VRR)` | `displayport1 [0x0F]` | Windows display device `\\.\DISPLAY1` |
| `2` | `right` | `G60SD_S27DG60xS (HDMI VRR)` | `0x05 [0x05]` | Windows display device `\\.\DISPLAY5` |
| `3` | `left` | `G60SD_S27DG60xS (HDMI VRR)` | `0x05 [0x05]` | Windows display device `\\.\DISPLAY2` |

Samsung input-source readback is a little quirky here, so the tool uses explicit profiles instead of trying to infer a safe toggle target from the current value.

## Files in this folder

- `Switch-MonitorInput.ps1`: the main tool
- `monitor-profiles.json`: starter profiles for `this-pc` and `other-pc`
- `Switch-To-This-PC.cmd`: wrapper that applies the `this-pc` profile
- `Switch-To-Other-PC.cmd`: wrapper that applies the `other-pc` profile
- `This-PC.cmd`: shorter wrapper for the `this-pc` profile
- `Other-PC.cmd`: shorter wrapper for the `other-pc` profile
- `TESTING-NOTES.md`: detailed observed behavior and test outcomes from this setup

## Input names the script understands

- `hdmi1`
- `hdmi2`
- `displayport1`
- `displayport2`
- `dvi1`
- `dvi2`
- `vga1`
- raw decimal or hex values such as `17` or `0x11`

Monitor targets can be:

- numeric indexes like `1`, `2`, and `3`
- position names like `left`, `center`, and `right`
- `all`

## Usage

List the active monitors and their current inputs:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Switch-MonitorInput.ps1 -List
```

Preview a profile before switching:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Switch-MonitorInput.ps1 -Profile other-pc -WhatIf
```

Switch every configured monitor to the other computer:

```powershell
.\Switch-To-Other-PC.cmd
```

Short form:

```powershell
.\Other-PC.cmd
```

Switch back to this computer:

```powershell
.\Switch-To-This-PC.cmd
```

Short form:

```powershell
.\This-PC.cmd
```

Set monitors directly without a profile:

```powershell
.\Switch-MonitorInput.ps1 -SetMonitor @('left=hdmi1','center=displayport1','right=hdmi1')
```

## Starter profile assumptions

`monitor-profiles.json` starts with the common setup where this PC uses `displayport1` and the other computer uses `hdmi1` on all three screens. Based on the observed Samsung quirk, the starter `other-pc` profile now uses raw `0x05` for the `right` monitor. The profile keys use `left`, `center`, and `right` so they stay readable. If one of your monitors uses `hdmi2` or `displayport2`, edit that file and change only that monitor's value.

With your current Windows layout, those positions line up like this:

- `left` = Windows display `2`
- `center` = Windows display `1`
- `right` = Windows display `3`
