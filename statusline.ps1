<#
.SYNOPSIS
  qbraid-code statusline — folder, branch, model, context, qBraid credits.

.DESCRIPTION
  Claude Code runs this on every render and feeds it the session JSON on
  stdin. It must never block: the credit balance is served from a short-lived
  cache and refreshed in a detached process, so a slow network costs nothing.
#>
# Get-Nested probes PSObject.Properties rather than dereferencing, so StrictMode
# is safe here and is enabled for consistency with install.ps1 and doctor.ps1.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'

$HomeDir = if ($env:QBRAID_CODE_HOME) { $env:QBRAID_CODE_HOME } else { Join-Path $env:USERPROFILE '.qbraid-code' }
$Cache   = Join-Path $HomeDir 'credits.cache'
# Stamped before each refresh ATTEMPT, not after a success. Without it a failing
# balance call leaves the cache untouched, so every render decides a refresh is
# due and starts another powershell.exe — several a second, all session.
$Attempt = Join-Path $HomeDir 'credits.attempt'
$Ttl     = 60

$apiBase = 'https://api-v2.qbraid.com/api/v1'
$token   = ''
$envPath = Join-Path $HomeDir 'env'
if (Test-Path $envPath) {
    foreach ($line in Get-Content $envPath) {
        if ($line -match '^\s*QBRAID_CODE_API_BASE\s*=\s*(.*)$') { $apiBase = $Matches[1] }
        if ($line -match '^\s*QBRAID_CODE_TOKEN\s*=\s*(.*)$')    { $token   = $Matches[1] }
    }
}

$e    = [char]27
$dim  = "$e[2m"; $rst = "$e[0m"
$cyan = "$e[36m"; $grn = "$e[32m"; $ylw = "$e[33m"; $red = "$e[31m"

$raw = [Console]::In.ReadToEnd()
$data = $null
if ($raw) { try { $data = $raw | ConvertFrom-Json } catch { $data = $null } }

function Get-Nested {
    param($Object, [string[]]$Path)
    $node = $Object
    foreach ($key in $Path) {
        if ($null -eq $node) { return $null }
        $prop = $node.PSObject.Properties[$key]
        if (-not $prop) { return $null }
        $node = $prop.Value
    }
    return $node
}

$model = 'Claude'
$dir   = $PWD.Path
$remaining = $null

$v = Get-Nested $data @('model','display_name');    if ($v) { $model = $v }
$v = Get-Nested $data @('workspace','current_dir'); if ($v) { $dir   = $v }
$v = Get-Nested $data @('context_window','remaining_percentage')
if ($null -ne $v) { $remaining = [double]$v }

# ------------------------------------------------------------------ folder

$name = Split-Path $dir -Leaf
$branch = & git -C $dir rev-parse --abbrev-ref HEAD 2>$null
$place = "$cyan$name$rst"
if ($branch -and $branch -ne 'HEAD') {
    if ($branch.Length -gt 22) { $branch = $branch.Substring(0, 21) + [char]0x2026 }
    $place = "$place $dim$([char]0x2387) $branch$rst"
}

# ----------------------------------------------------------------- context

$bar = ''
if ($null -ne $remaining) {
    $used = [int][Math]::Round(100 - $remaining)
    if ($used -lt 0)   { $used = 0 }
    if ($used -gt 100) { $used = 100 }
    $filled = [int][Math]::Ceiling($used / 17.0)
    if ($filled -gt 6) { $filled = 6 }
    $blocks = ''
    for ($i = 0; $i -lt 6; $i++) {
        $blocks += if ($i -lt $filled) { [char]0x2588 } else { [char]0x2591 }
    }
    $colour = $grn
    if ($used -ge 60) { $colour = $ylw }
    if ($used -ge 85) { $colour = $red }
    $bar = "${dim}C$used$rst $colour$blocks$rst"
}

# ----------------------------------------------------------------- credits

function Start-CreditRefresh {
    if (-not $token) { return }
    # Stamp first: a refresh that fails must still back off for $Ttl seconds.
    Set-Content -Path $Attempt -Value ([string](Get-Date -UFormat %s)) -Encoding ASCII

    # The child reads the credential out of the env file itself. Passing it in
    # -ArgumentList would put a live API key on a process command line, which
    # every user on the machine can read from the process list.
    $envFile = Join-Path $HomeDir 'env'
    $script = @'
$home_dir = $env:QC_ENV_FILE
$base = ''; $tok = ''
foreach ($line in Get-Content $home_dir) {
  if ($line -match '^\s*QBRAID_CODE_API_BASE\s*=\s*(.*)$') { $base = $Matches[1] }
  if ($line -match '^\s*QBRAID_CODE_TOKEN\s*=\s*(.*)$')    { $tok  = $Matches[1] }
}
if (-not $tok) { exit }
try {
  $b = Invoke-RestMethod -Uri "$base/billing/credits/balance" -Headers @{ 'X-API-Key' = $tok } -TimeoutSec 15
  if ($null -ne $b.data.qbraidCredits) {
    Set-Content -Path $env:QC_CACHE -Value ([string]$b.data.qbraidCredits) -Encoding ASCII
  }
} catch { }
'@
    $env:QC_ENV_FILE = $envFile
    $env:QC_CACHE    = $Cache
    Start-Process -FilePath 'powershell' -WindowStyle Hidden `
        -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $script
}

$credits = $null
if (Test-Path $Cache) { $credits = (Get-Content $Cache -Raw).Trim() }

$due = $true
if (Test-Path $Attempt) {
    $due = ((Get-Date) - (Get-Item $Attempt).LastWriteTime).TotalSeconds -ge $Ttl
}
if ($due) { Start-CreditRefresh }

$creditSeg = ''
if ($credits) {
    $value = 0.0
    if ([double]::TryParse($credits, [ref]$value)) {
        $colour = $grn
        if ($value -lt 100) { $colour = $ylw }
        if ($value -lt 10)  { $colour = $red }
        $creditSeg = "$colour$([Math]::Round($value))$rst$dim credits$rst"
    }
}

# ------------------------------------------------------------------ render

$sep = "$dim $([char]0x2502) $rst"
$out = "$place$sep$dim$model$rst"
if ($bar)       { $out = "$out$sep$bar" }
if ($creditSeg) { $out = "$out$sep$creditSeg" }
Write-Output $out
