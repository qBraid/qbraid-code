<#
.SYNOPSIS
  Manages one launch-owned loopback CLIProxyAPI process.

.DESCRIPTION
  Claude models pass through unchanged. GPT models use the gateway's
  OpenAI-compatible surface. Invoked by qbraid-code.cmd: ensure|status|stop.
#>
param(
    [Parameter(Position = 0)]
    [ValidateSet('ensure', 'status', 'stop')]
    [string]$Action = 'ensure'
)
$ErrorActionPreference = 'Stop'
function Read-PidFile {
    param([string]$Path)
    $value = 0
    try { if (Test-Path $Path) { [void][int]::TryParse((Get-Content $Path -Raw).Trim(), [ref]$value) } } catch { }
    return $value
}

$HomeDir = if ($env:QBRAID_CODE_HOME) { $env:QBRAID_CODE_HOME } else { Join-Path $env:USERPROFILE '.qbraid-code' }
$ProfileDir = $env:QBRAID_CODE_PROFILE_HOME
if (-not $ProfileDir) {
    $profile = $env:QBRAID_CODE_PROFILE
    if (-not $profile -and (Test-Path (Join-Path $HomeDir 'active-profile'))) {
        $profile = (Get-Content (Join-Path $HomeDir 'active-profile') -Raw).Trim()
    }
    if (-not $profile) { $profile = 'default' }
    $ProfileDir = Join-Path (Join-Path $HomeDir 'profiles') $profile
    if (-not (Test-Path (Join-Path $ProfileDir 'env')) -and $profile -eq 'default') { $ProfileDir = $HomeDir }
}
$Port = 8320
$Bin = ''
$envPath = Join-Path $ProfileDir 'env'
if (Test-Path $envPath) {
    foreach ($line in Get-Content $envPath) {
        if ($line -match '^\s*QBRAID_CODE_PROXY_PORT\s*=\s*(.*)$') { $Port = [int]$Matches[1] }
        if ($line -match '^\s*QBRAID_CODE_PROXY_BIN\s*=\s*(.*)$')  { $Bin  = $Matches[1] }
    }
}
$Config = if ($env:QBRAID_CODE_RUNTIME_CONFIG) { $env:QBRAID_CODE_RUNTIME_CONFIG } else { Join-Path $ProfileDir 'proxy-config.yaml' }
$RuntimeDir = Split-Path $Config -Parent
$KeyFile = if ($env:QBRAID_CODE_RUNTIME_KEY_FILE) { $env:QBRAID_CODE_RUNTIME_KEY_FILE } else { Join-Path $ProfileDir 'proxy.key' }
$LogFile = Join-Path $RuntimeDir 'proxy.log'
if ($env:QBRAID_CODE_RUNTIME_PORT) { $Port = [int]$env:QBRAID_CODE_RUNTIME_PORT }
$BaseUrl = "http://127.0.0.1:$Port"

function Test-Proxy {
    if (-not (Test-Path $KeyFile)) { return $false }
    try {
        $key = (Get-Content $KeyFile -Raw).Trim()
        Invoke-RestMethod -Uri "$BaseUrl/v1/models" -TimeoutSec 3 `
            -Headers @{ Authorization = "Bearer $key" } | Out-Null
        return $true
    } catch { return $false }
}

switch ($Action) {
    'status' {
        if (Test-Proxy) { Write-Output "running on $BaseUrl" } else { Write-Output 'not running' }
        exit 0
    }
    'stop' {
        $pidFile = Join-Path $RuntimeDir 'proxy.pid'
        $proxyPid = Read-PidFile $pidFile
        $owned = $null
        if ($proxyPid) {
            $owned = Get-CimInstance Win32_Process -Filter "ProcessId=$proxyPid" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -and $_.CommandLine.Contains($Config) }
        }
        if ($owned) {
            Stop-Process -Id $proxyPid -Force -ErrorAction SilentlyContinue
            Wait-Process -Id $proxyPid -Timeout 5 -ErrorAction SilentlyContinue
            if (-not (Get-Process -Id $proxyPid -ErrorAction SilentlyContinue)) {
                Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
            }
            Write-Output 'proxy stopped'
        } else {
            Write-Output 'proxy was not running'
        }
        exit 0
    }
    'ensure' {
        if (Test-Proxy) { exit 0 }
        if (-not $Bin -or -not (Test-Path $Bin)) {
            Write-Error 'GPT models need the local proxy, which is not installed. Re-run: irm https://qbraid.com/code.ps1 | iex'
            exit 1
        }
        if (-not (Test-Path $Config)) {
            Write-Error 'proxy config missing - re-run the installer.'
            exit 1
        }
        $process = Start-Process -FilePath $Bin -ArgumentList "-config `"$Config`"" `
            -WindowStyle Hidden -RedirectStandardOutput $LogFile -RedirectStandardError "$LogFile.err" -PassThru
        [IO.File]::WriteAllText((Join-Path $RuntimeDir 'proxy.pid'), [string]$process.Id, (New-Object Text.UTF8Encoding $false))
        for ($i = 0; $i -lt 40; $i++) {
            if (Test-Proxy) { exit 0 }
            Start-Sleep -Milliseconds 300
        }
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        Wait-Process -Id $process.Id -Timeout 5 -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $RuntimeDir 'proxy.pid') -Force -ErrorAction SilentlyContinue
        Write-Error "proxy failed to start - see $LogFile"
        exit 1
    }
}
