# Repository Guidelines

## Project Structure & Module Organization

This Windows-only repository switches monitor inputs through DDC/CI:

- `Switch-MonitorInput.ps1`: monitor discovery, input parsing, profile application, and embedded C# interop with `user32.dll` and `Dxva2.dll`.
- `Install-ProfileHotkeys.ps1`: creates Start Menu shortcuts and profile hotkeys.
- `Run-Profile.ps1`: shared profile launcher; `MonitorTools.Common.ps1`: configuration, backups, and operation logs.
- `Install.ps1`, `Repair.ps1`, `Uninstall.ps1`, and `installer/`: installation lifecycle and setup interface.
- `app/`: tray application, profile editor, hotkeys, and asynchronous worker client.
- `engine/`: compiled C# control worker, Windows topology and DDC/CI interop, configuration, and diagnostics.
- `monitor-profiles.json`: legacy examples; new setup writes schema-2 profiles with physical monitor IDs.
- `monitor-compatibility.json` and `Export-Diagnostics.ps1`: hardware evidence and diagnostic export.
- `This-PC.cmd`, `Other-PC.cmd`, and `Switch-To-*.cmd`: profile launchers that forward additional arguments.
- `README.md` and `TESTING-NOTES.md`: usage, hardware findings, and observed test results.

`tests/` holds regression tests; `examples/` has sample profiles; `docs/` preserves hardware notes.

## Build, Test, and Development Commands

Scripts need no build. `Build-Setup.ps1` builds setup, tray, and worker executables using the .NET Framework compiler. Run from the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Switch-MonitorInput.ps1 -List
.\Other-PC.cmd -WhatIf
.\This-PC.cmd -WhatIf
.\Install-ProfileHotkeys.ps1
```

`-List` reads inventory; `-IncludeCapabilities` adds deeper queries. Previews validate assignments without changing inputs. The tray app owns installed hotkeys; the standalone shortcut installer supports legacy use. Only intentionally chosen calibration tests and profile applications switch inputs.

## Coding Style & Naming Conventions

Use four-space indentation in PowerShell/C# and two spaces in authored JSON. Follow existing `Verb-Noun` functions, PascalCase parameters, and camelCase locals. Keep C# compatible with the .NET Framework compiler. Use lowercase, hyphenated profile keys such as `other-pc`.

Preserve strict mode, terminating errors, `ShouldProcess` checks for script writes, and native-handle cleanup in `finally`. Acquire fresh handles per operation; validate complete plans before writes. Never replay unanswered switches automatically. Keep wrapper paths relative to `%~dp0`. No formatter or linter is configured.

## Testing Guidelines

Run `powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-AllTests.ps1 -IncludeExecutable` after building, and `pwsh -NoProfile -File .\tests\Run-AllTests.ps1`. Suites run in separate processes with mock hardware and isolated installation paths. No external framework or coverage threshold applies. Add regression cases to the relevant suite; test ambiguous identities, partial failures, and previews before hardware checks. Repeated invocation must not cause `Add-Type` collisions.

Test both engines when changing shared behavior: IDs, aliases, scenes, retries, and partial results must agree. Worker tests cover queuing, process lifetime, and recovery without real monitor writes. Executable tests include nine visual baselines. Inspect `build/visual-tests/index.html`; update screenshots only for reviewed UI changes using `tests/Test-Visual.ps1 -UpdateBaselines`. See `tests/visual/README.md` for rendering limits.

Record hardware, commands, and visible outcomes in `TESTING-NOTES.md`. Immediate input readback can be misleading; preserve the documented right-monitor `0x05` quirk unless new hardware evidence supports changing it.

## Commit & Pull Request Guidelines

The brief history uses concise subjects such as `Add profile hotkey installer`. Follow that action-oriented style and keep commits focused. PR descriptions should explain the behavior change, relevant hardware/profile assumptions, validation commands and outcomes, and linked issues when applicable. Update usage documentation when commands or profiles change.
