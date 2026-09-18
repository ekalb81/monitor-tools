# Control worker architecture

## Runtime

`app/Tray.cs` owns hotkeys and WinForms controls. `app/WorkerClient.cs` launches one hidden `app/MonitorTools.Worker.exe` child on demand. The compiled engine in `engine/` executes tray discovery and profile requests directly through Windows DDC/CI. There is no PowerShell startup or runtime C# compilation on that path.

The worker uses inherited standard-input/output pipes with newline-delimited JSON. Requests carry a correlation `id`, `action`, and action fields. Responses carry the same `id`, `success`, a serialized `payload`, and an optional `error`. Supported actions are `ping`, `list`, `profile`, `saveConfig`, and `diagnostics`. The executable has no public listening port or service registration.

## Scheduling and recovery

The client dispatches one request at a time. Profiles take priority over queued maintenance work, and repeated background scans coalesce. The tray keeps only the latest requested profile while another switch is active. A running native call is not interrupted to reorder work. Saving and diagnostics are asynchronous from the UI, although hardware diagnostics share the same queue.

Each dispatched request has a timeout. On a timeout, broken pipe, or invalid response, the client terminates the child and cancels waiting commands. A switch whose reply was lost has an **unknown hardware outcome** and is never replayed automatically. A subsequent request creates a new worker. Closing the tray stops the worker; an additional parent-lifetime check handles an orphan blocked in native code. Install and uninstall stop both executables by their exact installed paths before changing files.

## Hardware and compatibility

Physical handles are acquired fresh for each operation, collected before writes, and released in `finally`. The existing per-user switch mutex also coordinates the PowerShell scripts. The complete requested profile is resolved before any write. Existing EDID-based IDs, schema 1/2 assignments, tested `0x05` input values, scene ranges, bounded transient retries, and partial failure results are preserved. API acceptance is not physical verification.

Background inventory omits current-input VCP reads. Detailed diagnostics opt into input reads and optional capabilities. Windows `QueryDisplayConfig` and `DisplayConfigGetDeviceInfo` add active connection and GPU metadata; they do not select monitor inputs or replace persistent EDID identity. Ambiguous topology is not used to select a control backend.

The backend interface permits future NVIDIA/AMD integrations. This version uses the Windows backend. Vendor-specific control needs separate hardware evidence; changing language cannot remove monitor firmware delays.

The installer and command-line scripts retain their existing PowerShell engine, including `-WhatIf` and guided return tests. Their behavior is tested separately from the new compiled engine. Profile edits use the same configuration mutex, atomic replacement, and backups. Unknown metadata such as calibration records survives saves.

## Validation and measurements

Run `tests/Run-AllTests.ps1 -IncludeExecutable` on Windows PowerShell 5.1 after building. Deterministic tests inject hardware and transport failures; process tests use `ping` and temporary configuration without changing monitor inputs. Screenshot tests continue to exercise the compiled setup and editor.

Measure cold startup separately from warm requests and from the visible monitor transition. Mock timings measure software overhead only. They do not establish real DDC/CI latency or inactive-input reliability.

API references: [QueryDisplayConfig](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-querydisplayconfig), [DisplayConfigGetDeviceInfo](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-displayconfiggetdeviceinfo), and [SetVCPFeature](https://learn.microsoft.com/en-us/windows/win32/api/lowlevelmonitorconfigurationapi/nf-lowlevelmonitorconfigurationapi-setvcpfeature).
