<#
.SYNOPSIS
  Manages the loopback CLIProxyAPI that gives qbraid-code its GPT models.

.DESCRIPTION
  Claude Code speaks the Anthropic Messages API; the qBraid gateway serves GPT
  models only on its OpenAI-compat surface. This proxy translates between the
  two on 127.0.0.1. Invoked by qbraid-code.cmd — ensure|status|stop.
#>
param(
    [Parameter(Position = 0)]
    [ValidateSet('ensure', 'status', 'stop')]
    [string]$Action = 'ensure'
)
$ErrorActionPreference = 'Stop'

$HomeDir = if ($env:QBRAID_CODE_HOME) { $env:QBRAID_CODE_HOME } else { Join-Path $env:USERPROFILE '.qbraid-code' }
$Port = 8320
$Bin = ''
$envPath = Join-Path $HomeDir 'env'
if (Test-Path $envPath) {
    foreach ($line in Get-Content $envPath) {
        if ($line -match '^\s*QBRAID_CODE_PROXY_PORT\s*=\s*(.*)$') { $Port = [int]$Matches[1] }
        if ($line -match '^\s*QBRAID_CODE_PROXY_BIN\s*=\s*(.*)$')  { $Bin  = $Matches[1] }
    }
}
$KeyFile = Join-Path $HomeDir 'proxy.key'
$Config  = Join-Path $HomeDir 'proxy-config.yaml'
$LogFile = Join-Path $HomeDir 'proxy.log'
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
        $procs = Get-CimInstance Win32_Process -Filter "Name like '%cliproxyapi%'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like "*$Config*" }
        if ($procs) {
            $procs | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
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
        Start-Process -FilePath $Bin -ArgumentList '-config', $Config `
            -WindowStyle Hidden -RedirectStandardOutput $LogFile -RedirectStandardError "$LogFile.err"
        for ($i = 0; $i -lt 40; $i++) {
            if (Test-Proxy) { exit 0 }
            Start-Sleep -Milliseconds 300
        }
        Write-Error "proxy failed to start - see $LogFile"
        exit 1
    }
}
