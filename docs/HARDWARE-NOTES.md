# Original Samsung Setup

These are historical observations from the original installation, not prerequisites or portable settings. Start with [the quick start](../README.md) for a new setup.

**Resolved on Twingo, 2026-09-15:** individual switching and return tests confirmed `0x05` for HDMI and `0x0F` for DisplayPort on all three monitors. HDMI leads to Twingo on the sides and to the other computer on the center monitor. See [the verified mapping](../TESTING-NOTES.md). The observations below retain the earlier investigation; examples use standard aliases for users of other hardware.

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
