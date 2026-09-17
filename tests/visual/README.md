# Visual integration tests

Run from the repository root on Windows:

```powershell
.\Build-Setup.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Visual.ps1
# Also included in the complete Windows PowerShell suite:
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-AllTests.ps1 -IncludeExecutable
```

No additional packages are required. The runner compiles its helpers with the Windows .NET Framework compiler, loads the actual `dist/Setup.exe` and `dist/MonitorTools.exe` UI classes, and uses synthetic configuration. Build first so the tests exercise your current code.

## Coverage

Nine checked-in client-area screenshots cover:

- Setup: default, individually verified, failed return, busy, minimum window size, and six-monitor scrolling.
- Profile editor: default, minimum window size, and an edited brightness scene.

The renderer also checks layout overlap, clipped controls and headings, verification-dependent buttons, busy-state locking, scroll behavior, and saving an edited brightness value without losing volume. The edit uses the real grid editor and Save button. Setup return states are supplied as fixtures; no calibration buttons are clicked. No tray host, monitor discovery, DDC/CI, installation, or global hotkey registration runs.

`DrawToBitmap` captures real WinForms controls offscreen. These tests cover rendering and selected UI interactions; they do not replace physical monitor tests or desktop automation of the complete installation flow.

## Automatic runs and reports

GitHub Actions runs the suite on pull requests, pushes to `main`, version tags, and manual workflow dispatch. The runner is pinned to `windows-2022` rather than the moving `windows-latest` alias. Each renderer process has a 60-second timeout; comparisons have 30 seconds.

Open `build/visual-tests/index.html` for expected, actual, and highlighted differences. JSON results and control bounds accompany the PNGs. CI uploads the directory as `visual-test-results` even on failure, with 14-day retention. The release job uploads a separate report. Each run clears this generated directory to prevent stale results.

## Reviewing intentional changes

```powershell
.\Build-Setup.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Visual.ps1 -UpdateBaselines
```

Review every changed PNG and the HTML report, then commit the intended images in `baselines/classic-96dpi/` with the UI change. Updates are rejected in CI and when layout/interaction assertions fail. Missing images or an unexpected fixture inventory fail the normal test run; baselines are never silently created.

## Rendering profile and tolerances

Snapshots use English text, Segoe UI, classic native controls, logical 96 DPI, and no OS window border. High contrast is rejected. The harness changes no desktop settings. OS/runtime and font-smoothing settings are recorded in `actual/fixtures.json` for diagnosis. Windows image/font updates can still cause differences: inspect the report before accepting a new baseline. Native Windows themes and higher-DPI rendering are outside this baseline profile.

The comparer permits a per-channel difference of 20 and a symmetric one-pixel neighbor match for text antialiasing. At most 0.1% of pixels may differ overall, and no 32×32 tile may exceed 5%, so small missing labels cannot hide in a large window. Changed dimensions always fail. Magenta pixels mark differences. Self-tests verify tolerated changes, removed content, moved controls, dimension mismatches, and corrupt images on every run.
