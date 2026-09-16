@echo off
rem secret-set (Windows) — scripts\secret-set.ps1 로 포워딩하는 얇은 shim.
rem   secret-set <name>            숨김 프롬프트로 앱비번 등록
rem   echo <값>| secret-set <name> --stdin
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\scripts\secret-set.ps1" %*
exit /b %ERRORLEVEL%
