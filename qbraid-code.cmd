@echo off
setlocal EnableExtensions
if /I "%~1"=="--help" goto help
if /I "%~1"=="-h" goto help
set "LAUNCHER=%~dp0qbraid-launch.ps1"
if not exist "%LAUNCHER%" (
  echo qbraid-code: launcher helper is missing. Re-run the installer. 1>&2
  exit /b 1
)
set "UNINSTALL=0"
if /I "%~1"=="--uninstall" set "UNINSTALL=1"
powershell -NoProfile -ExecutionPolicy Bypass -File "%LAUNCHER%" %*
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" exit /b %RC%
if "%UNINSTALL%"=="1" (
  del /f /q "%LAUNCHER%" >nul 2>&1
  if exist "%LAUNCHER%" (
    echo qbraid-code: could not remove launcher helper. 1>&2
    exit /b 1
  )
  del /f /q "%~dp0qbraid-code.home" >nul 2>&1
  if exist "%~dp0qbraid-code.home" (
    echo qbraid-code: could not remove launcher binding. 1>&2
    exit /b 1
  )
  endlocal
  (goto) 2>nul & del /f /q "%~f0"
)
exit /b 0

:help
echo qbraid-code - Claude Code, powered by the qBraid AI gateway.
echo.
echo Sessions
echo   qbraid-code [claude arguments]                start a session
echo   qbraid-code --profile NAME [claude arguments] use NAME for one session
echo   qbraid-code --profile NAME --allow-profile-resume --resume SESSION_ID
echo                                                 confirm NAME before resuming
echo.
echo Profiles
echo   qbraid-code --profiles                        list installed profiles
echo   qbraid-code --use-profile NAME                select future sessions
echo   qbraid-code --profile NAME --update-key       replace an expired or revoked key
echo.
echo Maintenance
echo   qbraid-code [--profile NAME] --doctor         check setup and credentials
echo   qbraid-code [--profile NAME] --stop           stop orphaned local proxies
echo   qbraid-code --uninstall                       remove qbraid-code from this device
echo   qbraid-code --uninstall --yes                 uninstall without a prompt
echo.
echo Help
echo   qbraid-code --help                            show this help without network access
echo   claude --help                                 list arguments forwarded to Claude Code
echo.
echo Uninstall deletes local qbraid-code credentials and files. It does not revoke
echo API keys in your qBraid account.
exit /b 0
