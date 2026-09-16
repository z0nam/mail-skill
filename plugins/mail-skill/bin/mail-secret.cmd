@echo off
rem mail-secret (Windows) — scripts\mail-secret.ps1 로 포워딩하는 얇은 shim.
rem Himalaya 의 auth.cmd = "mail-secret <name>" 이 이 이름을 PATH 에서 찾는다.
rem 따라서 이 파일이 있는 bin\ 을 PATH 에 넣어야 라이브 IMAP 인증이 동작한다.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\scripts\mail-secret.ps1" %*
exit /b %ERRORLEVEL%
