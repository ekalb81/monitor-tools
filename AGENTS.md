# Repository Guidelines

## Project Structure & Module Organization

This Windows-only repository switches monitor inputs through DDC/CI. Runtime files live in the repository root:

- `Switch-MonitorInput.ps1`: monitor discovery, input parsing, profile application, and embedded C# interop with `user32.dll` and `Dxva2.dll`.
- `Install-ProfileHotkeys.ps1`: creates Start Menu shortcuts and profile hotkeys.
- `Run-Profile.ps1`: shared launcher with error logging for wrappers and hotkeys.
- `Install.ps1` and `installer/`: installation backend and Windows setup interface.
- `monitor-profiles.json`: named `this-pc` and `other-pc` input assignments.
- `This-PC.cmd`, `Other-PC.cmd`, and `Switch-To-*.cmd`: profile launchers that forward additional arguments.
- `README.md` and `TESTING-NOTES.md`: usage, hardware findings, and observed test results.

`tests/` holds regression tests; `examples/` has sample profiles; `docs/` preserves hardware notes.

## Build, Test, and Development Commands

Scripts need no build. `Build-Setup.ps1` creates `dist/Setup.exe` using the .NET Framework compiler. Run from the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Switch-MonitorInput.ps1 -List
.\Other-PC.cmd -WhatIf
.\This-PC.cmd -WhatIf
.\Install-ProfileHotkeys.ps1
```

`-List` reads monitor inventory and inputs. The wrapper previews validate assignments without writing input changes; they still enumerate hardware. The installer creates shortcuts with default hotkeys `Ctrl+Alt+1` and `Ctrl+Alt+2`. Omit `-WhatIf` to apply a profile during intentional hardware testing.

## Coding Style & Naming Conventions

Use four-space indentation in PowerShell and embedded C#, and two spaces in JSON. Follow existing `Verb-Noun` function names, PascalCase parameters, and camelCase local variables. Keep profile keys lowercase and hyphenated, such as `other-pc`.

Preserve strict mode, terminating errors, `ShouldProcess` checks for monitor writes, and native-handle cleanup in `finally`. Keep wrapper paths relative to `%~dp0`. No formatter or linter is configured.

## Testing Guidelines

Run `powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1` and repeat with `pwsh -NoProfile -File .\tests\Run-Tests.ps1` when PowerShell 7 is available. Tests mock hardware and shortcut creation; no external framework or coverage threshold applies. Add regression cases to this runner. Preview both profiles and manually verify affected switching paths on suitable hardware. After interop changes, rerun in the same session to check for `Add-Type` collisions.

Record hardware, commands, and visible outcomes in `TESTING-NOTES.md`. Immediate input readback can be misleading; preserve the documented right-monitor `0x05` quirk unless new hardware evidence supports changing it.

## Commit & Pull Request Guidelines

The brief history uses concise subjects such as `Add profile hotkey installer`. Follow that action-oriented style and keep commits focused. PR descriptions should explain the behavior change, relevant hardware/profile assumptions, validation commands and outcomes, and linked issues when applicable. Update usage documentation when commands or profiles change.
