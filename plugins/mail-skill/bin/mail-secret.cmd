@echo off
rem mail-secret (Windows) - thin shim forwarding to scripts\mail-secret.ps1
rem Himalaya auth.cmd = "mail-secret <name>" resolves this name on PATH.
rem Put this bin\ on PATH so live IMAP auth works.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\scripts\mail-secret.ps1" %*
exit /b %ERRORLEVEL%
