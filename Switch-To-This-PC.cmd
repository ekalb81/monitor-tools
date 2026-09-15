@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Run-Profile.ps1" -Profile this-pc %*
