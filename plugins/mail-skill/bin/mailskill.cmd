@echo off
rem mailskill (Windows) - thin shim forwarding to bin\mailskill.ps1
rem Put this bin\ on PATH to call `mailskill ...` directly.
rem Runs via Windows PowerShell 5.1 (always present); scripts are 5.1 compatible.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0mailskill.ps1" %*
exit /b %ERRORLEVEL%
