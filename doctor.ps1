<#
.SYNOPSIS
  Health check for qbraid-code on Windows. Invoked by `qbraid-code --doctor`.
#>
# No Set-StrictMode: this command exists to report a broken setup, so a missing
# field must print a diagnosis rather than a PowerShell exception.
$ErrorActionPreference = 'Continue'

$HomeDir = if ($env:QBRAID_CODE_HOME) { $env:QBRAID_CODE_HOME } else { Join-Path $env:USERPROFILE '.qbraid-code' }
$envPath = Join-Path $HomeDir 'env'

if (-not (Test-Path $envPath)) {
    Write-Host "qbraid-code: not installed - no $envPath"
    exit 1
}

$settings = @{}
foreach ($line in Get-Content $envPath) {
    if ($line -match '^\s*([A-Z_]+)\s*=\s*(.*)$') { $settings[$Matches[1]] = $Matches[2] }
}

$apiBase = $settings['QBRAID_CODE_API_BASE']
$baseUrl = $settings['QBRAID_CODE_BASE_URL']
$token   = $settings['QBRAID_CODE_TOKEN']
$model   = $settings['QBRAID_CODE_MODEL']
$claudeMinVersion = '2.1.186'
$claudeTestedMax  = '2.1.238'

function ConvertFrom-ClaudeVersionString {
    param([string]$Text)
    if ($Text -match '(\d+\.\d+\.\d+)') { return $Matches[1] }
    return $null
}

function Test-ClaudeMcpCommand {
    param([string]$Command)
    $help = (& claude mcp --help 2>$null | Out-String)
    return $help -match "(?m)^\s+$([regex]::Escape($Command))(?:\s|$)"
}

function Test-ClaudeMcpHttp {
    $help = (& claude mcp add --help 2>$null | Out-String)
    return $help -match '(?s)--transport.*\bhttp\b'
}

function Test-ClaudeMcpUserScope {
    $help = (& claude mcp add --help 2>$null | Out-String)
    return $help -match '(?s)--scope.*\buser\b'
}

$claudePresent = $false
$claudeVersion = $null
$mcpAdd = $false
$mcpGet = $false
$mcpLogin = $false
$mcpHttp = $false
$mcpUserScope = $false
if (Get-Command claude -ErrorAction SilentlyContinue) {
    $claudePresent = $true
    $version = (& claude --version 2>$null)
    if (-not $version) { $version = 'present' }
    Write-Host "claude:   $version"
    $claudeVersion = ConvertFrom-ClaudeVersionString ($version | Out-String)
    $mcpAdd = Test-ClaudeMcpCommand 'add'
    $mcpGet = Test-ClaudeMcpCommand 'get'
    $mcpLogin = Test-ClaudeMcpCommand 'login'
    $mcpHttp = Test-ClaudeMcpHttp
    $mcpUserScope = Test-ClaudeMcpUserScope
} else {
    Write-Host 'claude:   NOT INSTALLED'
}
if (-not $claudeVersion) {
    Write-Host "claude-min: UNKNOWN (requires $claudeMinVersion+)"
    Write-Host 'claude-tested: unknown'
} elseif ([version]$claudeVersion -lt [version]$claudeMinVersion) {
    Write-Host "claude-min: FAIL (requires $claudeMinVersion+, found $claudeVersion)"
    Write-Host 'claude-tested: unsupported'
} elseif ([version]$claudeVersion -gt [version]$claudeTestedMax) {
    Write-Host "claude-min: PASS (requires $claudeMinVersion+)"
    Write-Host "claude-tested: NEWER than tested $claudeTestedMax (not blocked)"
} else {
    Write-Host "claude-min: PASS (requires $claudeMinVersion+)"
    Write-Host "claude-tested: within tested range through $claudeTestedMax"
}
$claudePolicy = if ($env:QBRAID_CODE_CLAUDE_POLICY) { $env:QBRAID_CODE_CLAUDE_POLICY } else { 'prompt' }
Write-Host "claude-policy: $claudePolicy"
Write-Host "capabilities: mcp-add=$($mcpAdd.ToString().ToLower()) mcp-get=$($mcpGet.ToString().ToLower()) mcp-login=$($mcpLogin.ToString().ToLower()) mcp-http=$($mcpHttp.ToString().ToLower()) mcp-user-scope=$($mcpUserScope.ToString().ToLower())"

# Separate transport failure from rejection. Reporting "REJECTED" for a dropped
# connection sent people off to make a new key for no reason.
try {
    $balance = Invoke-RestMethod -Uri "$apiBase/billing/credits/balance" `
        -Headers @{ 'X-API-Key' = $token } -TimeoutSec 20
    Write-Host 'key:      valid'
    $raw = $balance.data.qbraidCredits
    if ($null -ne $raw) {
        Write-Host "credits:  $([Math]::Round([double]$raw))"
    } else {
        Write-Host 'credits:  unknown'
    }
} catch {
    $status = $null
    if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
    if ($status -eq 401 -or $status -eq 403) {
        Write-Host 'key:      REJECTED - make a new one at https://account.qbraid.com/account/api-keys'
    } elseif ($status) {
        Write-Host "key:      UNKNOWN - qBraid returned HTTP $status"
    } else {
        Write-Host 'key:      UNKNOWN - could not reach qBraid (check your connection)'
    }
    Write-Host 'credits:  unknown'
}

try {
    Invoke-RestMethod -Uri "$baseUrl/v1/models" -Headers @{ 'X-API-Key' = $token } -TimeoutSec 20 | Out-Null
    Write-Host 'gateway:  reachable'
} catch {
    Write-Host 'gateway:  UNREACHABLE'
}

if (-not $claudePresent -or -not $mcpGet) {
    Write-Host 'mcp:      UNAVAILABLE - upgrade Claude Code or configure it through /mcp'
} else {
    & claude mcp get qbraid *> $null
    if ($LASTEXITCODE -eq 0) {
        if ($mcpLogin) {
            Write-Host "mcp:      registered (run 'claude mcp login qbraid' if tools are missing)"
        } else {
            Write-Host 'mcp:      registered (run /mcp inside Claude Code to authenticate)'
        }
    } else {
        if ($mcpLogin) {
            Write-Host 'mcp:      NOT REGISTERED - re-run the installer'
        } else {
            Write-Host 'mcp:      NOT REGISTERED - configure and authenticate through /mcp'
        }
    }
}

Write-Host "model:    $model"

$proxyBin = $settings['QBRAID_CODE_PROXY_BIN']
if ($proxyBin -and (Test-Path $proxyBin)) {
    $st = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $HomeDir 'qbraid-proxy.ps1') status 2>$null
    Write-Host "gpt:      proxy $st"
} else {
    Write-Host 'gpt:      NOT AVAILABLE - re-run the installer to add GPT models'
}
