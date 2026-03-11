@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Switch-MonitorInput.ps1" -Profile this-pc %*
