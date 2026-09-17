# Testing Notes

This file captures the important observed behaviors from interactive testing so they are not lost.

## Version 2 implementation checks: 2026-09-17

Read-only discovery on Twingo identified all three monitors as **Odyssey G60SD**, with distinct `edid-serial` identities for left, center, and right. No input, brightness, or volume writes were performed during this implementation session. This confirms identity discovery on the current connections; it does not establish persistence across cable changes or another graphics driver.

Automated suites use separate native mocks for monitor control and identity. They exercise named/partial profiles, scene normalization, preview behavior, partial failures, return attempts, configuration backups, diagnostics, and isolated installation files. Run `tests/Run-AllTests.ps1` on Windows PowerShell 5.1 and PowerShell 7, and add `-IncludeExecutable` on 5.1 after building for the executable/UI bridge tests.

Observed implementation validation: `Run-AllTests.ps1 -IncludeExecutable` passed on Windows PowerShell **5.1.26100.9444**; `Run-AllTests.ps1` passed on PowerShell **7.6.5**. The six headless editor/setup behavior cases passed, including duplicate friendly labels, scene/hotkey preservation, legacy targets, and calibration invalidation. Version **2.0.0** compiled successfully; embedded-package verification and sample setup rendering passed. `git diff --check` passed. The produced installer is unsigned; signing and remote release publication were not exercised.

The new guided calibration flow, brightness/volume scenes, and tray hotkeys still need user-observed testing on the actual desk. Earlier confirmed `0x05`/`0x0F` input results below remain the hardware evidence; software test passes are not visual switching verification.

## Automated visual integration (September 17, 2026)

Nine client-area fixtures render the compiled setup and profile editor with synthetic data at 96 DPI. They cover default/verified/failed/busy setup states, compact sizes, six-monitor scrolling, and editing/saving a brightness scene. Initial layout assertions caught the editor grid covering its instructions and clipped column headings; docking order and automatic heading height were corrected. Reviewed PNG baselines and repeated local comparisons pass. Comparator self-tests also reject missing content, moved controls, dimension changes, and corrupt inputs.

These tests run with `Run-AllTests.ps1 -IncludeExecutable` and in the Windows workflow. Reports live in `build/visual-tests/`; baseline updates are explicit and disabled in CI. Local verification used Windows 11; the pinned `windows-2022` hosted workflow has not yet been run for this change. Classic control rendering reduces theme differences but does not establish high-DPI or physical DDC/CI coverage.

## Verified Twingo setup: 2026-09-15

Host: Windows 11 personal desktop, AMD motherboard, called **Twingo**. WMI identifies all three monitors as Odyssey G60SD; the DDC inventory describes them as Generic PnP Monitor.

The standard `hdmi1` code (`0x11`) did not visibly switch the center monitor to the other computer or return the side monitors to Twingo. DisplayPort selection (`0x0F`) worked. There was no launcher error log, and all three monitors remained readable.

Each monitor was then tested separately, with an automatic return using the same acquired monitor handle. The user visually confirmed that **each monitor showed the other computer and returned to Twingo**. No `SaveCurrentSettings` call was used.

| Position | Device at this test | Twingo (`this-pc`) | Other computer (`other-pc`) |
| --- | --- | --- | --- |
| left | `\\.\DISPLAY5` | HDMI: `0x05` | DisplayPort: `0x0F` |
| center | `\\.\DISPLAY1` | DisplayPort: `0x0F` | HDMI: `0x05` |
| right | `\\.\DISPLAY2` | HDMI: `0x05` | DisplayPort: `0x0F` |

This resolves the old destination ambiguity: `0x05` selects the tested HDMI connection. Its destination depends on each monitor's wiring. The repository and installed profiles now use this verified mapping. Setup offers **HDMI (Samsung 0x05)** as an explicit option; standard HDMI aliases remain unchanged for other hardware.

After updating the installed profiles (with a backup of the old file), both complete profiles were exercised through the installed `Run-Profile.ps1` launcher, with a six-second interval and automatic return. The user confirmed that all three monitors showed the other computer and returned to Twingo. The existing hotkeys target that same launcher and reload the corrected configuration on each invocation.

The device/position mapping differs from the earlier snapshot below. Do not treat `DISPLAY` identifiers or position labels as permanent identities. These results apply to the tested wiring and monitors, not every Samsung monitor or HDMI port.

## Historical environment snapshot

- Model family reported by Windows: `G60SD_S27DG60xS`
- Windows layout during testing:
  - `left` = Windows display `2`
  - `center` = Windows display `1`
  - `right` = Windows display `3`
- Script position mapping:
  - `left` = `\\.\DISPLAY2`
  - `center` = `\\.\DISPLAY1`
  - `right` = `\\.\DISPLAY5`

## DDC/CI reachability

- The Samsung monitors enumerate through the standard Windows `Dxva2.dll` low-level monitor APIs.
- The `right` monitor remained readable from this PC even while its visible picture was on the other computer's input.
- Successful read operations on the inactive-link test path included:
  - capabilities-length query
  - capabilities-string query
  - VCP `0x60` input-source read

## Input switching observations

- Standard alias-based `hdmi1` switching did not behave reliably for the `right` monitor on the inactive-link path.
- The following command was observed to work for switching the `right` monitor from the other input back to this PC:

```powershell
.\Switch-MonitorInput.ps1 -SetMonitor @('right=0x05')
```

- `-SaveCurrentSettings` was tested and is not required for that observed working command.
- `right=hdmi1` and `right=hdmi1 -SaveCurrentSettings` did not produce the same visible result in testing.
- Immediate VCP source readback should not be treated as the source of truth after a write. The on-screen switch behavior is more trustworthy than the immediate `GetVCPFeature(0x60)` value.

## Historical profile assumption

The old test described `right=0x05` as returning to this PC, but the old `other-pc` profile assigned it to the other computer. The September 15 tests above resolve that ambiguity for Twingo's current wiring. The following values document the superseded assumptions; new users should verify their own wiring and both directions.

- `this-pc` profile:
  - `left` = `displayport1`
  - `center` = `displayport1`
  - `right` = `displayport1`
- `other-pc` profile:
  - `left` = `hdmi1`
  - `center` = `hdmi1`
  - `right` = `0x05`

## Script notes

- The script was optimized so the fast switch paths do not fetch the full capabilities string before sending a source-switch command.
- The embedded native type was updated to avoid `Add-Type` collisions when rerunning the script in the same PowerShell session.
