<#
.SYNOPSIS
  qbraid-code installer for Windows — Claude Code, powered by the qBraid AI gateway.

.DESCRIPTION
  There is no proxy and no daemon. The qBraid gateway speaks the Anthropic
  Messages API natively at /api/v1/ai/v1/messages, so Claude Code talks to it
  directly through ANTHROPIC_BASE_URL.

  Everything this writes lives in %USERPROFILE%\.qbraid-code and
  %USERPROFILE%\.local\bin. Re-running is safe.

.EXAMPLE
  irm https://qbraid.com/code.ps1 | iex

.EXAMPLE
  & ([scriptblock]::Create((irm https://qbraid.com/code.ps1))) -Global
#>
param(
    [switch]$Global
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$GatewayHost = 'api-v2.qbraid.com'
$ApiBase     = "https://$GatewayHost/api/v1"
$GatewayUrl  = "$ApiBase/ai"
$McpName     = 'qbraid'
$McpUrl      = 'https://mcp.qbraid.com/mcp'
$KeysUrl     = 'https://account.qbraid.com/account/api-keys'
$RawBase     = 'https://raw.githubusercontent.com/qBraid/qbraid-code/main'
$GhContents  = '/repos/qBraid/qbraid-code/contents'

$HomeDir    = if ($env:QBRAID_CODE_HOME) { $env:QBRAID_CODE_HOME } else { Join-Path $env:USERPROFILE '.qbraid-code' }
$BinDir     = if ($env:QBRAID_CODE_BIN_DIR) { $env:QBRAID_CODE_BIN_DIR } else { Join-Path $env:USERPROFILE '.local\bin' }
$ClaudeDir  = Join-Path $env:USERPROFILE '.claude'
$Settings   = Join-Path $ClaudeDir 'settings.json'
$ClaudeJson = Join-Path $env:USERPROFILE '.claude.json'

function Say  { param($m) Write-Host "==> $m" -ForegroundColor White }
function Ok   { param($m) Write-Host "  + $m" -ForegroundColor Green }
function Warn { param($m) Write-Host "  ! $m" -ForegroundColor Yellow }
function Die  { param($m) Write-Host "`nerror: $m" -ForegroundColor Red; exit 1 }

# StrictMode prohibits references to non-existent properties, so every read of
# an API response goes through this instead of a direct dereference.
function Get-Prop {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties[$Name]
    if (-not $prop) { return $null }
    return $prop.Value
}

function Confirm-Step {
    param([string]$Question, [string]$Default = 'y')
    $hint = if ($Default -eq 'y') { '[Y/n]' } else { '[y/N]' }
    $reply = (Read-Host "$Question $hint").Trim().ToLower()
    if ([string]::IsNullOrEmpty($reply)) { $reply = $Default }
    return ($reply -eq 'y' -or $reply -eq 'yes')
}

# ---------------------------------------------------------------- 1. platform

if (-not [Environment]::Is64BitOperatingSystem) {
    Die '32-bit Windows is not supported.'
}
Say "Platform: windows/$($env:PROCESSOR_ARCHITECTURE.ToLower())"

New-Item -ItemType Directory -Force -Path $HomeDir, $BinDir, $ClaudeDir | Out-Null

# ------------------------------------------------------------ 2. claude code

Say 'Claude Code'
if (Get-Command claude -ErrorAction SilentlyContinue) {
    Ok 'already installed'
} else {
    Warn 'not installed — installing'
    # Anthropic's official installer: a native binary, no Node.js, no admin rights.
    try {
        & ([scriptblock]::Create((Invoke-RestMethod -Uri 'https://claude.ai/install.ps1')))
    } catch {
        Die "Claude Code install failed: $_"
    }
    $env:Path = "$BinDir;$env:Path"
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
        Die 'Claude Code installed but `claude` is not on PATH. Open a new terminal and re-run.'
    }
    Ok 'installed'
}

# ------------------------------------------------------------- 3. credential

function Get-Balance {
    param([string]$Key)
    try {
        return Invoke-RestMethod -Uri "$ApiBase/billing/credits/balance" `
            -Headers @{ 'X-API-Key' = $Key } -TimeoutSec 25
    } catch {
        return $null
    }
}

function Read-QbraidrcKey {
    $rc = Join-Path $env:USERPROFILE '.qbraid\qbraidrc'
    if (-not (Test-Path $rc)) { return $null }
    foreach ($line in Get-Content $rc) {
        if ($line -match '^\s*api-key\s*=\s*(.+?)\s*$') { return $Matches[1] }
    }
    return $null
}

Say 'qBraid account'
$ApiKey    = $env:QBRAID_API_KEY
$Balance   = $null
$KeySource = 'QBRAID_API_KEY'

if (-not $ApiKey) {
    $candidate = Read-QbraidrcKey
    if ($candidate) {
        $Balance = Get-Balance $candidate
        if ($Balance) {
            $ApiKey = $candidate
            $KeySource = '~\.qbraid\qbraidrc'
        } else {
            Warn 'the key in ~\.qbraid\qbraidrc is no longer valid — ignoring it'
        }
    }
}

if ($ApiKey -and -not $Balance) {
    $Balance = Get-Balance $ApiKey
    if (-not $Balance) { Die "the API key from $KeySource was rejected by qBraid." }
}

if (-not $ApiKey) {
    Write-Host ''
    Write-Host '  You need a qBraid API key. Opening the page where you can copy one:'
    Write-Host "    $KeysUrl" -ForegroundColor White
    Write-Host ''
    Write-Host '  Sign in, create a key if you do not have one, then copy it.'
    Write-Host ''
    Start-Process $KeysUrl -ErrorAction SilentlyContinue

    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $candidate = (Read-Host 'Paste your qBraid API key').Trim()
        if ($candidate) {
            $Balance = Get-Balance $candidate
            if ($Balance) { $ApiKey = $candidate; $KeySource = 'pasted'; break }
        }
        Warn 'qBraid did not accept that key. Check you copied all of it, then try again.'
    }
    if (-not $ApiKey) { Die 'too many invalid keys. Re-run once you have a working key.' }
}
Ok "key accepted (from $KeySource)"

# ------------------------------------------------------- 4. organization check

# StrictMode is on: probe rather than dereference, so a response missing these
# fields degrades instead of aborting the install.
$balanceData = Get-Prop $Balance 'data'
$OrgId   = Get-Prop $balanceData 'organizationId'
$Credits = Get-Prop $balanceData 'qbraidCredits'
if ($null -eq $Credits) { $Credits = 'unknown' }
# /organizations/current returns the organization document itself, so `name` is
# the organization's. /organizations/me returns *membership* details, whose
# name is the user's — labelling the confirmation with that would be worse than
# showing nothing. The id is printed alongside so a bad lookup cannot quietly
# point someone at the wrong organization.
$OrgName = $null
if ($OrgId) {
    try {
        $org = Invoke-RestMethod -Uri "$ApiBase/organizations/current" -TimeoutSec 20 `
            -Headers @{ 'X-API-Key' = $ApiKey; 'X-Organization-Id' = $OrgId }
        $OrgName = Get-Prop (Get-Prop $org 'data') 'name'
    } catch { }
}

Write-Host ''
if ($OrgName) {
    Write-Host "  Organization: $OrgName  ($OrgId)" -ForegroundColor White
} else {
    Write-Host "  Organization: $OrgId" -ForegroundColor White
}
Write-Host "  Credits:      $Credits" -ForegroundColor White
Write-Host ''

if (-not (Confirm-Step 'Is this the right organization?' 'y')) {
    Write-Host ''
    Write-Host '  Switch organization at https://account.qbraid.com, or create a key'
    Write-Host '  under the organization you want, then run this installer again.'
    Write-Host ''
    exit 1
}
Ok 'organization confirmed'

# ------------------------------------------------------------- 5. model choice

Say 'Model'
$Model = $env:QBRAID_CODE_MODEL
if (-not $Model) {
    $ids = @()
    try {
        # Fetched live so new gateway models appear without a release here.
        $models = Invoke-RestMethod -Uri "$GatewayUrl/v1/models" `
            -Headers @{ 'X-API-Key' = $ApiKey } -TimeoutSec 25
        $ids = @(Get-Prop $models 'data' | ForEach-Object { Get-Prop $_ 'id' }) | Where-Object { $_ }
    } catch { }

    if ($ids.Count -eq 0) {
        Warn 'could not list models — defaulting to claude-sonnet-4-6'
        $Model = 'claude-sonnet-4-6'
    } else {
        Write-Host ''
        Write-Host '  Available models:'
        Write-Host ''
        for ($i = 0; $i -lt $ids.Count; $i++) {
            Write-Host ('    {0,2}) {1}' -f ($i + 1), $ids[$i])
        }
        Write-Host ''
        $choice = (Read-Host 'Choose a default model [1]').Trim()
        if (-not $choice) { $choice = '1' }
        $index = 0
        if ([int]::TryParse($choice, [ref]$index) -and $index -ge 1 -and $index -le $ids.Count) {
            $Model = $ids[$index - 1]
        } else {
            $Model = $ids[0]
        }
    }
}
Ok "default model: $Model"

# ---------------------------------------------------------------- 6. env file

$envLines = @(
    "QBRAID_CODE_BASE_URL=$GatewayUrl",
    "QBRAID_CODE_API_BASE=$ApiBase",
    "QBRAID_CODE_TOKEN=$ApiKey",
    "QBRAID_CODE_MODEL=$Model"
)
$envPath = Join-Path $HomeDir 'env'
Set-Content -Path $envPath -Value $envLines -Encoding ASCII
Ok "config written to $envPath"

# ------------------------------------------------- 7. launcher and statusline

# When piped through `iex` there is no local checkout, so companion files are
# fetched over HTTP. `gh` covers the window where the repository is still
# private and raw.githubusercontent.com 404s.
$SrcDir = $null
if ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot 'qbraid-code.cmd'))) {
    $SrcDir = $PSScriptRoot
}

function Fetch-File {
    param([string]$Name, [string]$Dest)
    if ($SrcDir) { Copy-Item (Join-Path $SrcDir $Name) $Dest -Force; return }
    try {
        Invoke-WebRequest -Uri "$RawBase/$Name" -OutFile $Dest -TimeoutSec 30 -UseBasicParsing
        return
    } catch { }
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Die "could not download $Name. While this repository is private you need the GitHub CLI: https://cli.github.com"
    }
    gh api -H 'Accept: application/vnd.github.raw' "$GhContents/$Name" | Set-Content -Path $Dest -Encoding UTF8
    if ($LASTEXITCODE -ne 0) { Die "could not download $Name — is ``gh auth login`` done, and are you in the qBraid org?" }
}

$LauncherPath   = Join-Path $BinDir 'qbraid-code.cmd'
$StatuslinePath = Join-Path $HomeDir 'statusline.ps1'
$DoctorPath     = Join-Path $HomeDir 'doctor.ps1'
Fetch-File 'qbraid-code.cmd' $LauncherPath
Ok "launcher installed to $LauncherPath"
Fetch-File 'statusline.ps1' $StatuslinePath
Ok "statusline installed to $StatuslinePath"
# `qbraid-code --doctor` shells out to this; the .cmd cannot parse JSON itself.
Fetch-File 'doctor.ps1' $DoctorPath

# Put the launcher on PATH for future terminals.
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath -notlike "*$BinDir*") {
    [Environment]::SetEnvironmentVariable('Path', "$BinDir;$userPath", 'User')
    Ok "added $BinDir to your PATH (new terminals only)"
}

# --------------------------------------------------------- 8. first-run flags

Say 'Claude Code first run'
if (Confirm-Step "Skip Claude Code's introductory screens?" 'y') {
    if (Test-Path $ClaudeJson) {
        $cfg = Get-Content $ClaudeJson -Raw | ConvertFrom-Json
        $cfg | Add-Member -NotePropertyName hasCompletedOnboarding -NotePropertyValue $true -Force
        $cfg | ConvertTo-Json -Depth 100 | Set-Content $ClaudeJson -Encoding UTF8
    } else {
        '{"hasCompletedOnboarding":true}' | Set-Content $ClaudeJson -Encoding UTF8
    }
    Ok 'introductory screens will be skipped'
} else {
    Ok 'introductory screens left on'
}

# ------------------------------------------------------------ 9. settings.json

Say 'Statusline'
$statusCmd = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$StatuslinePath`""

if (Test-Path $Settings) {
    $cfg = Get-Content $Settings -Raw | ConvertFrom-Json
} else {
    $cfg = [pscustomobject]@{}
}
$cfg | Add-Member -NotePropertyName statusLine `
    -NotePropertyValue ([pscustomobject]@{ type = 'command'; command = $statusCmd }) -Force

if ($Global) {
    $envObj = Get-Prop $cfg 'env'
    if ($null -eq $envObj) { $envObj = [pscustomobject]@{} }
    $envObj | Add-Member -NotePropertyName ANTHROPIC_BASE_URL         -NotePropertyValue $GatewayUrl -Force
    $envObj | Add-Member -NotePropertyName ANTHROPIC_AUTH_TOKEN       -NotePropertyValue $ApiKey     -Force
    $envObj | Add-Member -NotePropertyName ANTHROPIC_MODEL            -NotePropertyValue $Model      -Force
    $envObj | Add-Member -NotePropertyName ANTHROPIC_SMALL_FAST_MODEL -NotePropertyValue $Model      -Force
    $cfg | Add-Member -NotePropertyName env -NotePropertyValue $envObj -Force
}
$cfg | ConvertTo-Json -Depth 100 | Set-Content $Settings -Encoding UTF8
Ok "statusline enabled in $Settings"
if ($Global) { Ok 'plain `claude` now uses qBraid too' }

# ------------------------------------------------------------------- 10. mcp

Say 'qBraid MCP'
claude mcp get $McpName *> $null
if ($LASTEXITCODE -eq 0) {
    Ok 'already registered'
} else {
    claude mcp add --transport http $McpName $McpUrl --scope user *> $null
    if ($LASTEXITCODE -ne 0) { Die 'could not register the qBraid MCP server.' }
    Ok "registered $McpUrl"
}

# The MCP endpoint is JWT-only (OAuth + dynamic client registration): the API
# key above cannot authorize it. Do the browser sign-in now, while the user is
# still here, rather than surprising them mid-session.
if (Confirm-Step 'Sign in to the qBraid MCP now? (opens a browser)' 'y') {
    claude mcp login $McpName
    if ($LASTEXITCODE -ne 0) { Warn "MCP sign-in did not complete. Run ``claude mcp login $McpName`` later." }
} else {
    Warn "skipped. Run ``claude mcp login $McpName`` when you want the qBraid tools."
}

# ------------------------------------------------------------ 11. smoke test

Say 'Verifying'
$body = @{
    model      = $Model
    max_tokens = 32
    messages   = @(@{ role = 'user'; content = 'Reply with exactly: OK' })
} | ConvertTo-Json -Depth 10

try {
    $reply = Invoke-RestMethod -Uri "$GatewayUrl/v1/messages" -Method Post -TimeoutSec 90 `
        -Headers @{
            'Authorization'     = "Bearer $ApiKey"
            'anthropic-version' = '2023-06-01'
        } -ContentType 'application/json' -Body $body
} catch {
    Die "the test request to the qBraid gateway failed: $_"
}
if (-not (Get-Prop $reply 'content')) { Die "unexpected reply from the gateway: $($reply | ConvertTo-Json -Compress)" }
Ok 'end-to-end request succeeded'

# ---------------------------------------------------------------- 12. finish

Write-Host ''
Write-Host 'qbraid-code is ready.' -ForegroundColor Green
Write-Host ''
Write-Host '  Open a new terminal, then run it from any folder:'
Write-Host ''
Write-Host '    qbraid-code                 start a session'
Write-Host '    qbraid-code -p "..."        ask one question and exit'
Write-Host '    qbraid-code --doctor        check your setup'
Write-Host ''
if ($Global) {
    Write-Host '  The plain claude command uses qBraid as well.'
} else {
    Write-Host '  Your own claude command is untouched.'
}
Write-Host ''
