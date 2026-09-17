# Profiles and monitor identity

Installed configuration lives outside the application directory. `app/config-path.txt` points to it; source checkouts fall back to `monitor-profiles.json`. Scripts also accept `-ConfigPath`.

The original format remains readable. Its `left`, `center`, `right`, numeric indexes, and `position-N` keys depend on the current desktop arrangement. New setup binds assignments to discovered `id-...` monitor keys. Use **Identify** and explicitly bind a changed connection in setup if a saved monitor cannot be matched. Do not substitute a missing monitor by position without checking it.

## Schema 2

The following is illustrative: replace the monitor keys with IDs from your own inventory.

```json
{
  "schemaVersion": 2,
  "computers": { "this-pc": "Twingo", "other-pc": "Work" },
  "monitors": {
    "id-aabbccdd": {
      "label": "Left Samsung",
      "identityStatus": "connection",
      "calibration": { "status": "untested" }
    }
  },
  "profiles": {
    "this-pc": { "id-aabbccdd": "0x05" },
    "other-pc": { "id-aabbccdd": "displayport1" },
    "evening": {
      "id-aabbccdd": { "input": "0x05", "brightness": 30, "volume": 20 }
    }
  },
  "hotkeys": { "this-pc": "Ctrl+Alt+1", "other-pc": "Ctrl+Alt+2" }
}
```

- Profile names use 1–64 letters, digits, hyphens, or underscores, beginning with a letter or digit.
- An omitted monitor is unchanged. This makes mixed-computer and single-screen profiles possible.
- Assignments may be an input name/raw code, or an object containing `input`, `brightness`, and/or `volume`.
- Brightness and volume are integer percentages, 0–100. They require readable, supported VCP controls; values are normalized to the reported range.
- `0x05` is a visually tested HDMI mapping on the documented G60SD desk, not a general HDMI standard.
- Calibration records describe earlier visual observations, not live monitor state. Changing ports, inputs, or bindings requires another test.
- Unknown future schema versions are rejected to avoid silently discarding newer settings.

## Diagnostics

```powershell
.\Export-Diagnostics.ps1 -OutputPath "$env:USERPROFILE\Desktop\monitor-diagnostics.json"
```

This reads inventory, configuration, and the latest 20 operation records. Device identifiers are omitted or consistently anonymized by default. `-IncludeCapabilities` requests the slower capability query; `-IncludeIdentifiers` includes device identifiers when needed for investigation. Review the file before sharing; it still contains your profile labels and error descriptions.

Operation records retain the newest 100 files for at most 30 days under `%LOCALAPPDATA%\Monitor Tools\logs`. They separate command acceptance from physical verification. Configuration saves retain timestamped backups beside the configuration file.
