@echo off
rem mailskill (Windows) — bin\mailskill.ps1 로 포워딩하는 얇은 shim.
rem 이 파일이 있는 bin\ 을 PATH 에 넣으면 `mailskill ...` 로 바로 부를 수 있다.
rem Windows PowerShell 5.1(항상 존재)로 실행한다 — 스크립트는 5.1 호환.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0mailskill.ps1" %*
exit /b %ERRORLEVEL%
