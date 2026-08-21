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
$SiteBase    = 'https://qbraid.com/code'
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
function Die {
    param($m)
    Write-Host "`nerror: $m" -ForegroundColor Red
    # Under `irm | iex` in a fresh window, exiting closes the window with the
    # message still on screen for a fraction of a second. Hold it open.
    if ($Host.UI.RawUI) { try { Read-Host 'Press Enter to close' | Out-Null } catch { } }
    exit 1
}

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
    # Anthropic's installer always writes to %USERPROFILE%\.local\bin; $BinDir is
    # overridable and may be somewhere else entirely.
    $env:Path = "$(Join-Path $env:USERPROFILE '.local\bin');$BinDir;$env:Path"
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
        $secure = Read-Host 'Paste your qBraid API key' -AsSecureString
        $candidate = ([Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))).Trim()
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
$CreditsRaw = Get-Prop $balanceData 'qbraidCredits'
$Credits = if ($null -eq $CreditsRaw) { 'unknown' } else { [Math]::Round([double]$CreditsRaw) }
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
        # @() must wrap the WHOLE pipeline: a one-element pipeline unrolls back
        # to a scalar, and $ids[0] on a String returns a single character.
        $ids = @(Get-Prop $models 'data' | ForEach-Object { Get-Prop $_ 'id' } | Where-Object { $_ })
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
Write-RawText $envPath (($envLines -join "`n") + "`n")
Ok "config written to $envPath"

# ------------------------------------------------- 7. launcher and statusline

# When piped through `iex` there is no local checkout, so companion files are
# fetched over HTTP. `gh` covers the window where the repository is still
# unreachable; `gh` is a last resort.
$SrcDir = $null
if ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot 'qbraid-code.cmd'))) {
    $SrcDir = $PSScriptRoot
}

# Set-Content -Encoding UTF8 emits a BOM on Windows PowerShell 5.1, and a BOM
# on a .cmd makes cmd.exe fail to parse its first line. Write bytes directly.
function Write-RawText {
    param([string]$Path, [string]$Text)
    if ($Path.EndsWith('.cmd')) {
        $Text = ($Text -replace "`r`n", "`n") -replace "`n", "`r`n"
    }
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding $false))
}

function Fetch-File {
    param([string]$Name, [string]$Dest)
    if ($SrcDir) { Copy-Item (Join-Path $SrcDir $Name) $Dest -Force; return }

    # qbraid.com first: that is the point of the proxy, on networks where
    # raw.githubusercontent.com is blocked but qbraid.com is not.
    foreach ($base in @($SiteBase, $RawBase)) {
        try {
            $r = Invoke-WebRequest -Uri "$base/$Name" -TimeoutSec 30 -UseBasicParsing
            if ($r.StatusCode -eq 200 -and $r.Content) {
                Write-RawText $Dest $r.Content
                return
            }
        } catch { }
    }

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Die "could not download $Name from qbraid.com or GitHub. Check your connection and re-run."
    }
    $text = (gh api -H 'Accept: application/vnd.github.raw' "$GhContents/$Name" | Out-String)
    if ($LASTEXITCODE -ne 0 -or -not $text) {
        Die "could not download $Name - is ``gh auth login`` done, and are you in the qBraid org?"
    }
    Write-RawText $Dest $text
}

$ProxyHelperPath = Join-Path $HomeDir 'qbraid-proxy.ps1'
$LauncherPath   = Join-Path $BinDir 'qbraid-code.cmd'
$StatuslinePath = Join-Path $HomeDir 'statusline.ps1'
$DoctorPath     = Join-Path $HomeDir 'doctor.ps1'
Fetch-File 'qbraid-code.cmd' $LauncherPath
Ok "launcher installed to $LauncherPath"
Fetch-File 'statusline.ps1' $StatuslinePath
Ok "statusline installed to $StatuslinePath"
# `qbraid-code --doctor` shells out to this; the .cmd cannot parse JSON itself.
Fetch-File 'doctor.ps1' $DoctorPath
Fetch-File 'qbraid-proxy.ps1' $ProxyHelperPath

# Put the launcher on PATH for future terminals.
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath -notlike "*$BinDir*") {
    [Environment]::SetEnvironmentVariable('Path', "$BinDir;$userPath", 'User')
    Ok "added $BinDir to your PATH (new terminals only)"
}

# ------------------------------------------------ 7b. GPT models (local proxy)

# Non-fatal: Claude models work without any of this.
Say 'GPT models'
$ProxyBin = ''
$existing = Join-Path $HomeDir 'cliproxyapi.exe'
if (Test-Path $existing) {
    $ProxyBin = $existing
    Ok "using existing $ProxyBin"
} else {
    try {
        $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/router-for-me/CLIProxyAPI/releases/latest' -TimeoutSec 20
        $tag = $rel.tag_name; $ver = $tag.TrimStart('v')
        $url = "https://github.com/router-for-me/CLIProxyAPI/releases/download/$tag/CLIProxyAPI_${ver}_windows_amd64.zip"
        $zip = Join-Path $env:TEMP 'cpa.zip'
        Invoke-WebRequest -Uri $url -OutFile $zip -TimeoutSec 180 -UseBasicParsing
        $tmp = Join-Path $env:TEMP 'cpa-extract'
        if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
        Expand-Archive -Path $zip -DestinationPath $tmp
        $exe = Get-ChildItem $tmp -Recurse -Filter 'cli-proxy-api*.exe' | Select-Object -First 1
        if ($exe) {
            Copy-Item $exe.FullName $existing -Force
            $ProxyBin = $existing
            Ok "proxy installed to $ProxyBin"
        }
        Remove-Item $zip, $tmp -Recurse -Force -ErrorAction SilentlyContinue
    } catch {
        Warn "could not install CLIProxyAPI: $($_.Exception.Message)"
    }
}

if ($ProxyBin) {
    $gptModels = @()
    try {
        $list = Invoke-RestMethod -Uri "$GatewayUrl/models" -Headers @{ 'X-API-Key' = $ApiKey } -TimeoutSec 25
        $gptModels = @(Get-Prop $list 'data' | ForEach-Object { Get-Prop $_ 'id' } | Where-Object { $_ -like 'gpt-*' })
    } catch { }
    if ($gptModels.Count -eq 0) {
        Warn 'could not list GPT models from the gateway - skipping proxy config'
    } else {
        $keyFile = Join-Path $HomeDir 'proxy.key'
        if (-not (Test-Path $keyFile)) {
            $bytes = New-Object byte[] 24
            [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
            Write-RawText $keyFile (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
        }
        $localKey = (Get-Content $keyFile -Raw).Trim()
        # One proxy, every model: Claude passthrough + GPT translation, so one
        # endpoint lists and serves all of them.
        $claudeModels = @(Get-Prop $list 'data' | ForEach-Object { Get-Prop $_ 'id' } | Where-Object { $_ -like 'claude-*' })
        $yaml = @()
        $yaml += '# Generated by the qbraid-code installer. Loopback only.'
        $yaml += 'host: "127.0.0.1"'
        $yaml += 'port: 8320'
        $yaml += 'tls:'
        $yaml += '  enable: false'
        $yaml += "auth-dir: `"$($HomeDir -replace '\\','/')/proxy-auth`""
        $yaml += 'api-keys:'
        $yaml += "  - `"$localKey`""
        $yaml += 'remote-management:'
        $yaml += '  allow-remote: false'
        $yaml += '  disable-control-panel: true'
        $yaml += 'debug: false'
        $yaml += '# Model-list cloaking would rewrite ids into reversed pseudo-claude names;'
        $yaml += '# our anthropic-compat/ aliases pass the picker filter with readable names.'
        $yaml += 'claude-code:'
        $yaml += '  disable-cloaking-model-list: true'
        $yaml += 'claude-api-key:'
        $yaml += "  - api-key: `"$ApiKey`""
        $yaml += "    base-url: `"$GatewayUrl`""
        $yaml += '    models:'
        foreach ($cm in $claudeModels) {
            $yaml += "      - name: `"$cm`""
            $yaml += "        alias: `"$cm`""
        }
        $yaml += 'openai-compatibility:'
        $yaml += '  - name: "qbraid-gateway-gpt"'
        $yaml += "    base-url: `"$GatewayUrl`""
        $yaml += '    api-key-entries:'
        $yaml += "      - api-key: `"$ApiKey`""
        $yaml += '    models:'
        foreach ($gm in $gptModels) {
            # Plain alias for the command line, prefixed alias so the /model
            # picker's discovery filter (claude|anthropic substring) shows it.
            $yaml += "      - name: `"$gm`""
            $yaml += "        alias: `"$gm`""
            $yaml += "      - name: `"$gm`""
            $yaml += "        alias: `"anthropic-compat/$gm`""
        }
        Write-RawText (Join-Path $HomeDir 'proxy-config.yaml') (($yaml -join "`n") + "`n")
        New-Item -ItemType Directory -Force -Path (Join-Path $HomeDir 'proxy-auth') | Out-Null
        Ok "proxy configured: all $($gptModels.Count + $claudeModels.Count) models on one endpoint (starts on demand)"
    }
} else {
    Warn 'CLIProxyAPI unavailable - GPT models will not work; Claude models are unaffected.'
}

# Appended after the env file exists.
Add-Content -Path $envPath -Value @("QBRAID_CODE_PROXY_PORT=8320", "QBRAID_CODE_PROXY_BIN=$ProxyBin")

# --------------------------------------------------------- 8. first-run flags

Say 'Claude Code first run'
if (Confirm-Step "Skip Claude Code's introductory screens?" 'y') {
    if (Test-Path $ClaudeJson) {
        $cfg = Get-Content $ClaudeJson -Raw | ConvertFrom-Json
        $cfg | Add-Member -NotePropertyName hasCompletedOnboarding -NotePropertyValue $true -Force
        Write-RawText $ClaudeJson ($cfg | ConvertTo-Json -Depth 100)
    } else {
        Write-RawText $ClaudeJson '{"hasCompletedOnboarding":true}'
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
    # The gateway rejects Claude Code's adaptive-thinking parameter; see the
    # launcher for the full note. Remove when the gateway accepts "adaptive".
    $envObj | Add-Member -NotePropertyName MAX_THINKING_TOKENS         -NotePropertyValue '0'        -Force
    $cfg | Add-Member -NotePropertyName env -NotePropertyValue $envObj -Force
}
Write-RawText $Settings ($cfg | ConvertTo-Json -Depth 100)
Ok "statusline enabled in $Settings"
if ($Global) {
    # settings.json now holds a live credential. Windows has no chmod; restrict
    # the ACL to the current user so other accounts on the machine cannot read it.
    try {
        $acl = Get-Acl $Settings
        $acl.SetAccessRuleProtection($true, $false)
        $acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
            $env:USERNAME, 'FullControl', 'Allow')))
        Set-Acl -Path $Settings -AclObject $acl
    } catch {
        Warn "could not restrict permissions on $Settings - it contains your API key"
    }
    Ok 'plain `claude` now uses qBraid too'
}

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
    # Unlike the piped bash path, `iex` keeps the console attached, so the
    # OAuth prompt can read the redirect URL directly.
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
    if (Get-Prop $reply 'content') {
        Ok 'end-to-end request succeeded'
    } else {
        Warn 'the gateway replied but not with a message. Run `qbraid-code --doctor`.'
    }
} catch {
    # Everything is installed by this point; the commonest cause is an empty
    # wallet, which is not a broken setup.
    Warn "could not verify the gateway: $($_.Exception.Message)"
    Warn 'Everything is installed. Run `qbraid-code --doctor` to check again.'
}

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
