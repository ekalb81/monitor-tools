# Repository Guidelines

## Project Structure & Module Organization

This Windows-only repository switches monitor inputs through DDC/CI. Runtime files live in the repository root:

- `Switch-MonitorInput.ps1`: monitor discovery, input parsing, profile application, and embedded C# interop with `user32.dll` and `Dxva2.dll`.
- `Install-ProfileHotkeys.ps1`: creates Start Menu shortcuts and profile hotkeys.
- `Run-Profile.ps1`: shared profile launcher; `MonitorTools.Common.ps1`: configuration, backups, and operation logs.
- `Install.ps1`, `Repair.ps1`, `Uninstall.ps1`, and `installer/`: installation lifecycle and setup interface.
- `app/`: tray application, profile editor, and JSON command bridge.
- `monitor-profiles.json`: legacy examples; new setup writes schema-2 profiles with physical monitor IDs.
- `monitor-compatibility.json` and `Export-Diagnostics.ps1`: hardware evidence and diagnostic export.
- `This-PC.cmd`, `Other-PC.cmd`, and `Switch-To-*.cmd`: profile launchers that forward additional arguments.
- `README.md` and `TESTING-NOTES.md`: usage, hardware findings, and observed test results.

`tests/` holds regression tests; `examples/` has sample profiles; `docs/` preserves hardware notes.

## Build, Test, and Development Commands

Scripts need no build. `Build-Setup.ps1` builds the setup and tray executables using the .NET Framework compiler. Run from the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Switch-MonitorInput.ps1 -List
.\Other-PC.cmd -WhatIf
.\This-PC.cmd -WhatIf
.\Install-ProfileHotkeys.ps1
```

`-List` reads inventory; `-IncludeCapabilities` adds deeper queries. Previews validate assignments without changing inputs. The tray app owns installed hotkeys; the standalone shortcut installer supports legacy use. Only intentionally chosen calibration tests and profile applications switch inputs.

## Coding Style & Naming Conventions

Use four-space indentation in PowerShell and embedded C#, and two spaces in JSON. Follow existing `Verb-Noun` function names, PascalCase parameters, and camelCase local variables. Keep profile keys lowercase and hyphenated, such as `other-pc`.

Preserve strict mode, terminating errors, `ShouldProcess` checks for monitor writes, and native-handle cleanup in `finally`. Keep wrapper paths relative to `%~dp0`. No formatter or linter is configured.

## Testing Guidelines

Run `powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-AllTests.ps1 -IncludeExecutable` after building, and `pwsh -NoProfile -File .\tests\Run-AllTests.ps1`. Suites run in separate processes with mock hardware and isolated installation paths. No external framework or coverage threshold applies. Add regression cases to the relevant suite; test ambiguous identities, partial failures, and previews before hardware checks. Repeated invocation must not cause `Add-Type` collisions.

Executable tests include nine visual baselines and layout/interaction assertions. Inspect `build/visual-tests/index.html`; update screenshots only for reviewed UI changes using `tests/Test-Visual.ps1 -UpdateBaselines`. See `tests/visual/README.md` for rendering limits.

Record hardware, commands, and visible outcomes in `TESTING-NOTES.md`. Immediate input readback can be misleading; preserve the documented right-monitor `0x05` quirk unless new hardware evidence supports changing it.

## Commit & Pull Request Guidelines

The brief history uses concise subjects such as `Add profile hotkey installer`. Follow that action-oriented style and keep commits focused. PR descriptions should explain the behavior change, relevant hardware/profile assumptions, validation commands and outcomes, and linked issues when applicable. Update usage documentation when commands or profiles change.
