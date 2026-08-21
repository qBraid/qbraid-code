@echo off
setlocal EnableExtensions
set "LAUNCHER=%~dp0qbraid-launch.ps1"
if not exist "%LAUNCHER%" (
  echo qbraid-code: launcher helper is missing. Re-run the installer. 1>&2
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%LAUNCHER%" %*
exit /b %ERRORLEVEL%
