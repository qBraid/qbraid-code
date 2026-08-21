<#
.SYNOPSIS
  qbraid-code statusline - folder, branch, model, context, qBraid credits.

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
$ProfileDir = $env:QBRAID_CODE_PROFILE_HOME
if (-not $ProfileDir) {
    $profile = $env:QBRAID_CODE_PROFILE
    if (-not $profile -and (Test-Path (Join-Path $HomeDir 'env'))) {
        $ProfileDir = $HomeDir
    } else {
        if (-not $profile -and (Test-Path (Join-Path $HomeDir 'active-profile'))) { $profile = (Get-Content (Join-Path $HomeDir 'active-profile') -Raw).Trim() }
        if (-not $profile) { $profile = 'default' }
        $ProfileDir = Join-Path (Join-Path $HomeDir 'profiles') $profile
        $currentPath = Join-Path $ProfileDir 'current'
        if (Test-Path $currentPath) {
            $generation = (Get-Content $currentPath -Raw).Trim()
            if ($generation -and -not $generation.Contains('/') -and -not $generation.Contains('\') -and -not $generation.StartsWith('.')) { $ProfileDir = Join-Path (Join-Path $ProfileDir 'generations') $generation }
        }
        if (-not (Test-Path (Join-Path $ProfileDir 'env')) -and $profile -eq 'default') { $ProfileDir = $HomeDir }
    }
}
$Cache = Join-Path $ProfileDir 'credits.cache'
$Updated = Join-Path $ProfileDir 'credits.updated'

$e    = [char]27
$dim  = "$e[2m"; $rst = "$e[0m"
$violet = "$e[38;2;168;85;247m"; $grn = "$e[32m"; $ylw = "$e[33m"; $red = "$e[31m"

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
$place = $name
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

$credits = $null
if (Test-Path $Cache) { $credits = (Get-Content $Cache -Raw).Trim() }
$stale = 'stale'
if (Test-Path $Updated) {
    $updatedValue = 0L
    if ([long]::TryParse((Get-Content $Updated -Raw).Trim(), [ref]$updatedValue)) {
        $age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $updatedValue
        if ($age -le 300) { $stale = '' } else { $stale = "stale $([Math]::Floor($age / 60))m" }
    }
}
$label = $env:QBRAID_CODE_PROFILE
$labelPath = Join-Path $ProfileDir 'label'
if (Test-Path $labelPath) { $label = (Get-Content $labelPath -Raw -Encoding UTF8).Trim() }
if (-not $label) { $label = 'default' }
$label = $label -replace '[\x00-\x1F\x7F]', ''
if ($label.Length -gt 40) { $label = $env:QBRAID_CODE_PROFILE; if (-not $label) { $label = 'default' } }
$sourcePath = Join-Path $ProfileDir 'label-source'
$labelSource = if (Test-Path $sourcePath) { (Get-Content $sourcePath -Raw).Trim() } else { 'local' }
if ($labelSource -eq 'local') {
    $orgPath = Join-Path $ProfileDir 'organization-id'
    $orgId = if (Test-Path $orgPath) { (Get-Content $orgPath -Raw).Trim() } else { '' }
    if ($orgId -match '^[A-Za-z0-9._-]+$') { $shortOrg = $orgId.Substring(0, [Math]::Min(8, $orgId.Length)); $label = "$label (local $([char]0x00B7) org $shortOrg$([char]0x2026))" } else { $label = "$label (local)" }
}
$accountSeg = "${violet}qBraid$rst $label"
if ($credits) {
    $value = 0.0
    if ([double]::TryParse($credits, [ref]$value)) {
        $colour = $grn
        if ($value -lt 100) { $colour = $ylw }
        if ($value -lt 10)  { $colour = $red }
        $staleSuffix = if ($stale) { " $([char]0x00B7) $stale" } else { '' }
        $accountSeg = "$accountSeg$dim $([char]0x00B7) $rst$colour$([Math]::Round($value))$rst$dim credits$staleSuffix$rst"
    }
}

# ------------------------------------------------------------------ render

$sep = "$dim $([char]0x2502) $rst"
$out = "$place$sep$dim$model$rst"
if ($bar)       { $out = "$out$sep$bar" }
$out = "$out$sep$accountSeg"
Write-Output $out
