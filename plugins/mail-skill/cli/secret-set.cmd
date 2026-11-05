@echo off
rem secret-set (Windows) - thin shim forwarding to scripts\secret-set.ps1
rem   secret-set <name>            register app password via hidden prompt
rem   echo <value>| secret-set <name> --stdin
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\scripts\secret-set.ps1" %*
exit /b %ERRORLEVEL%
