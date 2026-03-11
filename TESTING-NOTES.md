# Testing Notes

This file captures the important observed behaviors from interactive testing so they are not lost.

## Environment snapshot

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

## Current profile assumption

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
