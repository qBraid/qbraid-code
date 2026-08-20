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

if (Get-Command claude -ErrorAction SilentlyContinue) {
    $version = (& claude --version 2>$null)
    if (-not $version) { $version = 'present' }
    Write-Host "claude:   $version"
} else {
    Write-Host 'claude:   NOT INSTALLED'
}

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

& claude mcp get qbraid *> $null
if ($LASTEXITCODE -eq 0) {
    Write-Host "mcp:      registered (run 'claude mcp login qbraid' if tools are missing)"
} else {
    Write-Host 'mcp:      NOT REGISTERED'
}

Write-Host "model:    $model"

$proxyBin = $settings['QBRAID_CODE_PROXY_BIN']
if ($proxyBin -and (Test-Path $proxyBin)) {
    $st = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $HomeDir 'qbraid-proxy.ps1') status 2>$null
    Write-Host "gpt:      proxy $st"
} else {
    Write-Host 'gpt:      NOT AVAILABLE - re-run the installer to add GPT models'
}
