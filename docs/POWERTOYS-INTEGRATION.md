# PowerToys integration assessment

Microsoft's [Power Display documentation](https://learn.microsoft.com/en-us/windows/powertoys/power-display) describes a CLI with monitor IDs, raw input codes, brightness and volume controls. Its CLI requires a running Power Display application. It could serve as an optional hardware backend, but would add a resident application dependency.

Monitor Tools keeps its direct Windows DDC/CI backend. The distinctive requirements here are visually confirmed input calibration, explicit return inputs, partial desk profiles, and useful results when only some screens respond. A successful call to either backend cannot establish that an image visibly changed.

Before enabling a Power Display backend on a particular desk:

1. Inspect its read-only `list` output and compare monitor identities across sleep and reconnection.
2. Explicitly test the G60SD's `0x05` HDMI mapping on one screen with a known return path.
3. Check whether the inactive connection remains controllable.
4. Confirm how failures and unsupported brightness/volume controls are reported.
5. Ensure one application owns each hotkey and serializes writes.

These interoperability tests have not been run on Twingo. No PowerToys installation or dependency is required, and no unverified backend is selected automatically. Supported brightness and volume scenes are available through the existing backend; broader controls can be considered after hardware testing.
