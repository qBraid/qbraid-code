<#
.SYNOPSIS
  qbraid-code statusline — folder, branch, model, context, qBraid credits.

.DESCRIPTION
  Claude Code runs this on every render and feeds it the session JSON on
  stdin. It must never block: the credit balance is served from a short-lived
  cache and refreshed in a detached process, so a slow network costs nothing.
#>
# No Set-StrictMode here on purpose: it prohibits references to non-existent
# properties, and a session payload that omits `model` or `context_window`
# would then throw on every keystroke. This script must always render something.
$ErrorActionPreference = 'SilentlyContinue'

$HomeDir = if ($env:QBRAID_CODE_HOME) { $env:QBRAID_CODE_HOME } else { Join-Path $env:USERPROFILE '.qbraid-code' }
$Cache   = Join-Path $HomeDir 'credits.cache'
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
    $script = @"
`$b = Invoke-RestMethod -Uri '$apiBase/billing/credits/balance' -Headers @{ 'X-API-Key' = '$token' } -TimeoutSec 15
if (`$b.data.qbraidCredits -ne `$null) {
  Set-Content -Path '$Cache' -Value ([string]`$b.data.qbraidCredits) -Encoding ASCII
}
"@
    Start-Process -FilePath 'powershell' -WindowStyle Hidden `
        -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $script
}

$credits = $null
if (Test-Path $Cache) {
    $credits = (Get-Content $Cache -Raw).Trim()
    $age = ((Get-Date) - (Get-Item $Cache).LastWriteTime).TotalSeconds
    if ($age -ge $Ttl) { Start-CreditRefresh }
} else {
    Start-CreditRefresh
}

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
