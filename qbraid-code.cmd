@echo off
rem qbraid-code - Claude Code, powered by the qBraid AI gateway.
rem Installed by install.ps1; reads its settings from %USERPROFILE%\.qbraid-code\env.
rem
rem This is a .cmd rather than a PowerShell function on purpose: a .cmd on PATH
rem works from cmd.exe, PowerShell and Windows Terminal with no profile edit and
rem no execution-policy change, which are the two things that fail quietly for
rem someone who just wants to start working.
rem
rem EnableDelayedExpansion is required: %ERRORLEVEL% inside a parenthesised
rem block is substituted when the block is PARSED, before the command in it has
rem run, so `exit /b %ERRORLEVEL%` there always reports the old value.
setlocal EnableExtensions EnableDelayedExpansion

set "QC_HOME=%USERPROFILE%\.qbraid-code"
if defined QBRAID_CODE_HOME set "QC_HOME=%QBRAID_CODE_HOME%"

if not exist "%QC_HOME%\env" (
  echo qbraid-code: not installed - no "%QC_HOME%\env" 1>&2
  echo Install it with: irm https://qbraid.com/code.ps1 ^| iex 1>&2
  exit /b 1
)

set "QBRAID_CODE_BASE_URL="
set "QBRAID_CODE_API_BASE="
set "QBRAID_CODE_TOKEN="
set "QBRAID_CODE_MODEL="
for /f "usebackq eol=# tokens=1,* delims==" %%a in ("%QC_HOME%\env") do set "%%a=%%b"

if /i "%~1"=="--stop" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%QC_HOME%\qbraid-proxy.ps1" stop
  exit /b !ERRORLEVEL!
)

if /i "%~1"=="--doctor" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%QC_HOME%\doctor.ps1"
  exit /b !ERRORLEVEL!
)

if /i "%~1"=="--help" goto :help
if /i "%~1"=="-h"     goto :help

if not defined QBRAID_CODE_TOKEN goto :incomplete
if not defined QBRAID_CODE_BASE_URL goto :incomplete
if not defined QBRAID_CODE_MODEL goto :incomplete

rem Determine the model actually requested: an explicit --model wins over the
rem configured default. Only the value matters; args still pass through whole.
set "RUNMODEL=%QBRAID_CODE_MODEL%"
set "PREV="
for %%a in (%*) do (
  if defined PREV set "RUNMODEL=%%~a" & set "PREV="
  if /i "%%~a"=="--model" set "PREV=1"
)

set "RUNBASE=%QBRAID_CODE_BASE_URL%"
set "RUNTOKEN=%QBRAID_CODE_TOKEN%"
rem Unified route: the proxy serves every model on one endpoint (Claude
rem passthrough, GPT translated). Fall back to the direct gateway for Claude
rem models when the proxy is unavailable; GPT models require it.
if not exist "%QC_HOME%\proxy-config.yaml" goto :noproxy
powershell -NoProfile -ExecutionPolicy Bypass -File "%QC_HOME%\qbraid-proxy.ps1" status | find "not running" >nul && set "QC_PROXY_STARTED=1"
powershell -NoProfile -ExecutionPolicy Bypass -File "%QC_HOME%\qbraid-proxy.ps1" ensure
if errorlevel 1 goto :noproxy
set /p RUNTOKEN=<"%QC_HOME%\proxy.key"
set "RUNBASE=http://127.0.0.1:8320"
rem Populate the /model picker from the proxy's model list at startup, and
rem remap the built-in Opus/Sonnet/Haiku rows to gateway ids so every picker
rem row actually routes (the defaults point at dated first-party ids).
set "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1"
set "ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-5"
set "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME=Opus 5 (qBraid)"
set "ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-4-6"
set "ANTHROPIC_DEFAULT_SONNET_MODEL_NAME=Sonnet 4.6 (qBraid)"
set "ANTHROPIC_DEFAULT_HAIKU_MODEL=claude-haiku-4-5"
set "ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME=Haiku 4.5 (qBraid)"
goto :routed
:noproxy
if /i "%RUNMODEL:~0,4%"=="gpt-" (
  echo qbraid-code: GPT models need the local proxy. Re-run: irm https://qbraid.com/code.ps1 ^| iex 1>&2
  exit /b 1
)
:routed

where claude >nul 2>&1
if errorlevel 1 (
  echo qbraid-code: Claude Code is not installed. 1>&2
  echo Re-run the installer: irm https://qbraid.com/code.ps1 ^| iex 1>&2
  exit /b 1
)

rem ANTHROPIC_AUTH_TOKEN sends `Authorization: Bearer <key>`, which the gateway
rem accepts. ANTHROPIC_API_KEY would work too, but it makes Claude Code ask the
rem user to approve a custom API key on first run - a prompt with no good answer
rem for someone who just wants to start working.
rem MAX_THINKING_TOKENS=0: recent Claude Code sends thinking type "adaptive",
rem which the gateway rejects (accepts enabled/disabled only) - every request
rem would 400. Forced: an inherited value re-enables thinking and breaks every
rem request. Remove once the gateway accepts adaptive.
set "MAX_THINKING_TOKENS=0"
set "ANTHROPIC_BASE_URL=%RUNBASE%"
set "ANTHROPIC_AUTH_TOKEN=%RUNTOKEN%"
set "ANTHROPIC_MODEL=%RUNMODEL%"
set "ANTHROPIC_SMALL_FAST_MODEL=%RUNMODEL%"
set "CLAUDE_CODE_SUBAGENT_MODEL=%RUNMODEL%"

rem If we started the proxy for this session, stop it when claude exits —
rem leaving a background process behind after the user quits is our bug.
rem A proxy that was already running belongs to someone else: leave it.
claude %*
set "CLAUDE_RC=!ERRORLEVEL!"
if defined QC_PROXY_STARTED powershell -NoProfile -ExecutionPolicy Bypass -File "%QC_HOME%\qbraid-proxy.ps1" stop >nul 2>&1
exit /b !CLAUDE_RC!

:incomplete
echo qbraid-code: "%QC_HOME%\env" is incomplete. 1>&2
echo Re-run the installer: irm https://qbraid.com/code.ps1 ^| iex 1>&2
exit /b 1

:help
echo qbraid-code - Claude Code, powered by the qBraid AI gateway.
echo.
echo   qbraid-code [claude args...]   start a session
echo   qbraid-code -p "..."           ask one question and exit
echo   qbraid-code --doctor           check your setup
echo.
echo Any other arguments are passed straight through to claude, so
echo -c, --allowedTools, --model, and the rest behave normally.
echo.
echo Default model: %QBRAID_CODE_MODEL%
echo Change it by editing "%QC_HOME%\env", or pass --model.
exit /b 0
