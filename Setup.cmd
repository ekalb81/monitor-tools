@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1" %*
set "setupExitCode=%ERRORLEVEL%"
echo.
if not "%setupExitCode%"=="0" echo Setup could not finish. Read the error above before closing this window.
pause
exit /b %setupExitCode%
