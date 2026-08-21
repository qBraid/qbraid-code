<#
.SYNOPSIS
  qbraid-code installer for Windows — Claude Code, powered by the qBraid AI gateway.

.DESCRIPTION
  Claude models use the qBraid Anthropic Messages surface directly. GPT models
  use an on-demand loopback translation proxy. Each named profile owns its
  credential, proxy port, model facts, and credit cache.

  Everything this writes lives in %USERPROFILE%\.qbraid-code and
  %USERPROFILE%\.local\bin. Re-running is safe.

.EXAMPLE
  irm https://qbraid.com/code.ps1 | iex

.EXAMPLE
#>
param(
    [switch]$Global,
    [string]$Profile = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$null = [Windows.Security.Credentials.PasswordVault,Windows.Security.Credentials,ContentType=WindowsRuntime]
$null = [Windows.Security.Credentials.PasswordCredential,Windows.Security.Credentials,ContentType=WindowsRuntime]
if ($Global) { throw '-Global was removed because project settings can exfiltrate its credential. Use qbraid-code.' }
$ProgressPreference = 'SilentlyContinue'
$ActivateProfile = $true
$ProfileStage = $null
$SecretStaged = $false
$SecretRef = $null

$GatewayHost = 'api-v2.qbraid.com'
$ApiBase     = "https://$GatewayHost/api/v1"
$GatewayUrl  = "$ApiBase/ai"
$McpName     = 'qbraid'
$McpUrl      = 'https://mcp.qbraid.com/mcp'
$KeysUrl     = 'https://account.qbraid.com/account/api-keys'
$SiteBase    = 'https://qbraid.com/code'
$RawBase     = 'https://raw.githubusercontent.com/qBraid/qbraid-code/main'
$GhContents  = '/repos/qBraid/qbraid-code/contents'

$HomeDir     = if ($env:QBRAID_CODE_HOME) { $env:QBRAID_CODE_HOME } else { Join-Path $env:USERPROFILE '.qbraid-code' }
$ProfilesDir = Join-Path $HomeDir 'profiles'
$BinDir      = if ($env:QBRAID_CODE_BIN_DIR) { $env:QBRAID_CODE_BIN_DIR } else { Join-Path $env:USERPROFILE '.local\bin' }
$ClaudeDir   = Join-Path $env:USERPROFILE '.claude'
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

function Write-RawText {
    param([string]$Path, [string]$Text)
    if ($Path.EndsWith('.cmd')) {
        $Text = ($Text -replace "`r`n", "`n") -replace "`n", "`r`n"
    }
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding $false))
}

function Read-PidFile {
    param([string]$Path)
    $value = 0
    try { if (Test-Path $Path) { [void][int]::TryParse((Get-Content $Path -Raw).Trim(), [ref]$value) } } catch { }
    return $value
}

# ---------------------------------------------------------------- 1. platform

if (-not [Environment]::Is64BitOperatingSystem) {
    Die '32-bit Windows is not supported.'
}
Say "Platform: windows/$($env:PROCESSOR_ARCHITECTURE.ToLower())"

New-Item -ItemType Directory -Force -Path $HomeDir, $ProfilesDir, $BinDir, $ClaudeDir | Out-Null
if ($PSBoundParameters.ContainsKey('Profile') -and -not $Profile) { Die 'invalid empty profile' }
$InstallMutex = New-Object Threading.Mutex($false, "Local\qbraid-code-installer-$($env:USERNAME)")
if (-not $InstallMutex.WaitOne(0)) { Die 'another qbraid-code installer is running.' }
try { $InstallLockHandle = [IO.File]::Open((Join-Path $HomeDir '.install-lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
catch [IO.IOException] { Die 'another qbraid-code installer is running.' }
$profileMutex = $null
$updateHandle = $null
try {
if (-not $Profile) {
    $activePath = Join-Path $HomeDir 'active-profile'
    if (Test-Path $activePath) { $Profile = (Get-Content $activePath -Raw).Trim() }
}
if (-not $Profile) { $Profile = 'default' }
if ($Profile -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$') { Die "invalid profile '$Profile'" }
$ProfileRoot = Join-Path $ProfilesDir $Profile
$ProfileDir = $ProfileRoot
$legacyEnv = Join-Path $HomeDir 'env'
$defaultDir = Join-Path $ProfilesDir 'default'
if ((Test-Path $legacyEnv) -and -not (Test-Path $defaultDir)) {
    $migrationDir = Join-Path $ProfilesDir (".default.migrate.$PID.$([guid]::NewGuid().ToString('N'))")
    New-Item -ItemType Directory -Force -Path $migrationDir | Out-Null
    $legacyLines = @(Get-Content $legacyEnv)
    $legacyToken = ''
    $safeLines = @($legacyLines | Where-Object { if ($_ -match '^QBRAID_CODE_TOKEN=(.*)$') { $legacyToken = $Matches[1]; $false } else { $true } })
    if ($legacyToken) {
        $secretRef = 'qbraid-code:default'
        try {
            $vault = New-Object Windows.Security.Credentials.PasswordVault
            try { $old = $vault.Retrieve($secretRef, $env:USERNAME); $vault.Remove($old) } catch { }
            $credential = New-Object Windows.Security.Credentials.PasswordCredential -ArgumentList $secretRef, $env:USERNAME, $legacyToken
            $vault.Add($credential)
        } catch { Die 'could not migrate the default key into Windows Credential Locker' }
        $safeLines += 'QBRAID_CODE_SECRET_BACKEND=credential-locker'
        $safeLines += "QBRAID_CODE_SECRET_REF=$secretRef"
    }
    Write-RawText (Join-Path $migrationDir 'env') (($safeLines -join "`n") + "`n")
    foreach ($name in @('label','label-source','models.tsv','credits.cache','credits.updated','organization-id')) {
        $source = Join-Path $HomeDir $name
        if (Test-Path $source) { Copy-Item $source (Join-Path $migrationDir $name) -Recurse }
    }
    if (-not (Test-Path (Join-Path $migrationDir 'label'))) { Write-RawText (Join-Path $migrationDir 'label') "default`n" }
    if (-not (Test-Path (Join-Path $migrationDir 'label-source'))) { Write-RawText (Join-Path $migrationDir 'label-source') "local`n" }
    Move-Item $migrationDir $defaultDir
}
function Remove-LegacyPlaintextToken {
    if (-not (Test-Path $defaultDir)) { return }
    if (Test-Path $legacyEnv) {
        $legacyLines = @(Get-Content $legacyEnv)
        if (@($legacyLines | Where-Object { $_ -match '^QBRAID_CODE_TOKEN=' }).Count -gt 0) {
            $lines = @($legacyLines | Where-Object { $_ -notmatch '^QBRAID_CODE_TOKEN=' })
            $cleanEnv = "$legacyEnv.clean.$PID.$([guid]::NewGuid().ToString('N'))"
            Write-RawText $cleanEnv (($lines -join "`n") + "`n")
            Move-Item $cleanEnv $legacyEnv -Force
        }
    }
    $legacyConfig = Join-Path $HomeDir 'proxy-config.yaml'
    $legacyPidPath = Join-Path $HomeDir 'proxy.pid'
    $keepConfig = $false
    if (Test-Path $legacyPidPath) {
        $legacyPid = Read-PidFile $legacyPidPath
        $legacyProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$legacyPid" -ErrorAction SilentlyContinue
        $keepConfig = $legacyProcess -and $legacyProcess.CommandLine -and $legacyProcess.CommandLine.Contains($legacyConfig)
    }
    if (-not $keepConfig) { Remove-Item $legacyConfig -Force -ErrorAction SilentlyContinue }
}
New-Item -ItemType Directory -Force -Path $ProfileRoot | Out-Null
$currentPath = Join-Path $ProfileRoot 'current'
if (Test-Path $currentPath) {
    $currentGeneration = (Get-Content $currentPath -Raw).Trim()
    if (-not $currentGeneration -or $currentGeneration.Contains('/') -or $currentGeneration.Contains('\') -or $currentGeneration.StartsWith('.')) { Die "profile '$Profile' has an invalid generation pointer" }
    $candidateProfile = Join-Path (Join-Path $ProfileRoot 'generations') $currentGeneration
    if (-not (Test-Path (Join-Path $candidateProfile 'env'))) { Die "profile '$Profile' generation is incomplete" }
    $ProfileDir = $candidateProfile
}
foreach ($privateDir in @(Get-ChildItem $ProfilesDir -Directory -ErrorAction SilentlyContinue)) {
    try {
        $privateAcl = Get-Acl $privateDir.FullName
        $privateAcl.SetAccessRuleProtection($true, $false)
        $privateAcl.Access | ForEach-Object { $privateAcl.RemoveAccessRule($_) | Out-Null }
        $privateAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
            $env:USERNAME, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        Set-Acl -Path $privateDir.FullName -AclObject $privateAcl
    } catch { Die "could not restrict profile permissions at $($privateDir.FullName)" }
}
$profileMutex = New-Object Threading.Mutex($false, "Local\qbraid-code-profile-$($env:USERNAME)-$Profile")
if (-not $profileMutex.WaitOne(10000)) { Die "profile '$Profile' is busy" }
try {
    $updatePath = Join-Path $ProfileRoot '.update-lock'
    try { $updateHandle = [IO.File]::Open($updatePath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch [IO.IOException] { Die "profile '$Profile' has a running session. Update it after that session exits." }
    $sessionUsers = Join-Path $ProfileRoot 'session-users'
    New-Item -ItemType Directory -Force -Path $sessionUsers | Out-Null
    Get-ChildItem $sessionUsers -File -ErrorAction SilentlyContinue | ForEach-Object {
        if (Get-Process -Id ([int]$_.Name) -ErrorAction SilentlyContinue) { Die "profile '$Profile' has a running session. Update it after that session exits." }
        Remove-Item $_.FullName -Force
    }
} finally { $profileMutex.ReleaseMutex() }
$stalePidPath = Join-Path $ProfileDir 'proxy.pid'
if (Test-Path $stalePidPath) {
    $stalePid = Read-PidFile $stalePidPath
    $staleProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$stalePid" -ErrorAction SilentlyContinue
    if ($staleProcess -and $staleProcess.CommandLine -and $staleProcess.CommandLine.Contains((Join-Path $ProfileDir 'proxy-config.yaml'))) {
        Stop-Process -Id $stalePid -Force -ErrorAction SilentlyContinue
    }
    Remove-Item $stalePidPath -Force -ErrorAction SilentlyContinue
}
$ProxyPort = 8320
$existingEnv = Join-Path $ProfileDir 'env'
if (Test-Path $existingEnv) {
    foreach ($line in Get-Content $existingEnv) {
        if ($line -match '^QBRAID_CODE_PROXY_PORT=(\d+)$') { $ProxyPort = [int]$Matches[1]; break }
    }
} else {
    $used = @{}
    Get-ChildItem $ProfilesDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $candidateEnv = Join-Path $_.FullName 'env'
        if (Test-Path $candidateEnv) {
            foreach ($line in Get-Content $candidateEnv) {
                if ($line -match '^QBRAID_CODE_PROXY_PORT=(\d+)$') { $used[[int]$Matches[1]] = $true }
            }
        }
    }
    while ($used.ContainsKey($ProxyPort)) { $ProxyPort++ }
}
$globalProfilePath = Join-Path $HomeDir 'global-profile'
if (Test-Path $Settings) {
    try {
        $legacySettings = Get-Content $Settings -Raw | ConvertFrom-Json
        $legacyEnv = Get-Prop $legacySettings 'env'
        $legacyBase = Get-Prop $legacyEnv 'ANTHROPIC_BASE_URL'
        if ($legacyBase -like '*api-v2.qbraid.com*') {
            foreach ($key in @('ANTHROPIC_BASE_URL','ANTHROPIC_AUTH_TOKEN','ANTHROPIC_MODEL','ANTHROPIC_SMALL_FAST_MODEL','QBRAID_CODE_PROFILE','QBRAID_CODE_HOME')) {
                $legacyEnv.PSObject.Properties.Remove($key)
            }
            Write-RawText $Settings ($legacySettings | ConvertTo-Json -Depth 20)
            Warn 'removed unsafe legacy plain-Claude gateway settings; use qbraid-code'
        }
    } catch { Die "cannot safely remove legacy gateway settings from $Settings" }
}
Remove-Item $globalProfilePath -Force -ErrorAction SilentlyContinue

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

function Get-ProfileSecret {
    $existingEnv = Join-Path $ProfileDir 'env'
    if (-not (Test-Path $existingEnv)) { return $null }
    $secretRef = ''
    foreach ($line in Get-Content $existingEnv) { if ($line -match '^QBRAID_CODE_SECRET_REF=(.*)$') { $secretRef = $Matches[1] } }
    if (-not $secretRef) {
        foreach ($line in Get-Content $existingEnv) { if ($line -match '^QBRAID_CODE_TOKEN=(.*)$') { return $Matches[1] } }
        return $null
    }
    try {
        $vault = New-Object Windows.Security.Credentials.PasswordVault
        $credential = $vault.Retrieve($secretRef, $env:USERNAME)
        $credential.RetrievePassword()
        return $credential.Password
    } catch { return $null }
}

function Set-ProfileSecret {
    param([string]$Key)
    $script:SecretRef = "qbraid-code:${Profile}:$generation"
    try {
        $vault = New-Object Windows.Security.Credentials.PasswordVault
        try { $old = $vault.Retrieve($script:SecretRef, $env:USERNAME); $vault.Remove($old) } catch { }
        $credential = New-Object Windows.Security.Credentials.PasswordCredential -ArgumentList $script:SecretRef, $env:USERNAME, $Key
        $vault.Add($credential)
        $script:SecretStaged = $true
    } catch { Die 'could not store the profile key in Windows Credential Locker' }
}

function Remove-OldProfileGenerations {
    param([string]$CurrentGeneration)
    $generationsPath = Join-Path $ProfileRoot 'generations'
    $flatEnv = Join-Path $ProfileRoot 'env'
    if (Test-Path $flatEnv) {
        $flatSettings = Get-EnvMap $flatEnv
        $flatRef = $flatSettings['QBRAID_CODE_SECRET_REF']
        if ($flatSettings['QBRAID_CODE_SECRET_BACKEND'] -eq 'credential-locker' -and $flatRef -eq "qbraid-code:$Profile") {
            try { $flatVault = New-Object Windows.Security.Credentials.PasswordVault; $flatCredential = $flatVault.Retrieve($flatRef, $env:USERNAME); $flatVault.Remove($flatCredential) } catch { }
        }
        foreach ($flatName in @('env','proxy-template.yaml','label','label-source','models.tsv','credits.cache','credits.updated','organization-id')) { Remove-Item (Join-Path $ProfileRoot $flatName) -Force -ErrorAction SilentlyContinue }
    }
    Get-ChildItem $generationsPath -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -eq $CurrentGeneration -or $_.Name.StartsWith('.stage.')) { return }
        $oldSettings = Get-EnvMap (Join-Path $_.FullName 'env')
        $oldRef = $oldSettings['QBRAID_CODE_SECRET_REF']
        if ($oldSettings['QBRAID_CODE_SECRET_BACKEND'] -eq 'credential-locker' -and $oldRef -and $oldRef.StartsWith("qbraid-code:${Profile}:")) {
            try { $oldVault = New-Object Windows.Security.Credentials.PasswordVault; $oldCredential = $oldVault.Retrieve($oldRef, $env:USERNAME); $oldVault.Remove($oldCredential) } catch { }
        }
        Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Say 'qBraid account'
$ApiKey    = $env:QBRAID_API_KEY
$Balance   = $null
$KeySource = 'QBRAID_API_KEY'
if (-not $ApiKey) { $ApiKey = Get-ProfileSecret; if ($ApiKey) { $KeySource = 'profile secret store' } }

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
$orgIdPath = Join-Path $ProfileDir 'organization-id'
$oldOrgId = if (Test-Path $orgIdPath) { (Get-Content $orgIdPath -Raw).Trim() } else { '' }
if ($oldOrgId -and (-not $OrgId -or $oldOrgId -ne $OrgId)) { Die "profile '$Profile' belongs to another organization. Use a new profile name." }

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

$generation = "$(Get-Date -Format yyyyMMddHHmmss).$PID.$([guid]::NewGuid().ToString('N').Substring(0,8))"
$generationsDir = Join-Path $ProfileRoot 'generations'
New-Item -ItemType Directory -Force -Path $generationsDir | Out-Null
$ProfileStage = Join-Path $generationsDir (".stage.$PID.$([guid]::NewGuid().ToString('N'))")
New-Item -ItemType Directory -Path $ProfileStage | Out-Null
Set-ProfileSecret $ApiKey
$ProfileDir = $ProfileStage
$envLines = @(
    "QBRAID_CODE_BASE_URL=$GatewayUrl",
    "QBRAID_CODE_API_BASE=$ApiBase",
    "QBRAID_CODE_MODEL=$Model",
    "QBRAID_CODE_SECRET_BACKEND=credential-locker",
    "QBRAID_CODE_SECRET_REF=$SecretRef"
)
$envPath = Join-Path $ProfileDir 'env'
Remove-Item (Join-Path $ProfileDir 'proxy-config.yaml'), (Join-Path $ProfileDir 'proxy-template.yaml'), (Join-Path $ProfileDir 'proxy.key'), (Join-Path $ProfileDir 'proxy-auth') -Recurse -Force -ErrorAction SilentlyContinue
Write-RawText $envPath (($envLines -join "`n") + "`n")
$ProfileLabel = if ($env:QBRAID_CODE_PROFILE_LABEL) { $env:QBRAID_CODE_PROFILE_LABEL } elseif ($OrgName) { $OrgName } else { $Profile }
$ProfileLabel = ($ProfileLabel -replace '[\x00-\x1F\x7F]', '')
if (-not $ProfileLabel -or $ProfileLabel.Length -gt 40) { $ProfileLabel = $Profile }
Write-RawText (Join-Path $ProfileDir 'label') "$ProfileLabel`n"
Write-RawText (Join-Path $ProfileDir 'label-source') "$(if ($OrgName) { 'verified' } else { 'local' })`n"
if ($OrgId) { Write-RawText $orgIdPath "$OrgId`n" }
$modelFacts = @(
    "claude-haiku-4-5`t200000",
    "claude-opus-4-8`t1000000",
    "claude-opus-5`t1000000",
    "claude-sonnet-4-6`t1000000",
    "gpt-5.4`t400000",
    "gpt-5.4-mini`t400000",
    "gpt-5.4-nano`t400000",
    "gpt-5.6-sol`t1050000"
)
Write-RawText (Join-Path $ProfileDir 'models.tsv') (($modelFacts -join "`n") + "`n")
$creditValue = Get-Prop (Get-Prop $Balance 'data') 'qbraidCredits'
if ($null -ne $creditValue) {
    Write-RawText (Join-Path $ProfileDir 'credits.cache') ([string]$creditValue)
    Write-RawText (Join-Path $ProfileDir 'credits.updated') ([string][DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
}
Remove-Item (Join-Path $ProfileDir 'credits.attempt') -Force -ErrorAction SilentlyContinue
Ok "profile '$Profile' written to $ProfileDir"

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
function Fetch-File {
    param([string]$Name, [string]$Dest)
    if ($SrcDir) {
        $source = Join-Path $SrcDir $Name
        if ($Dest.EndsWith('.cmd')) { Write-RawText $Dest ([IO.File]::ReadAllText($source)) } else { Copy-Item $source $Dest -Force }
        return
    }

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
$LaunchHelperPath = Join-Path $BinDir 'qbraid-launch.ps1'
$StatuslinePath = Join-Path $HomeDir 'statusline.ps1'
$DoctorPath     = Join-Path $HomeDir 'doctor.ps1'
Fetch-File 'qbraid-code.cmd' $LauncherPath
Write-RawText (Join-Path $BinDir 'qbraid-code.home') $HomeDir
Fetch-File 'qbraid-launch.ps1' $LaunchHelperPath
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
    $claudeModels = @()
    try {
        $list = Invoke-RestMethod -Uri "$GatewayUrl/models" -Headers @{ 'X-API-Key' = $ApiKey } -TimeoutSec 25
        $facts = @{}
        foreach ($line in Get-Content (Join-Path $ProfileDir 'models.tsv')) {
            if ($line -match '^([^\t]+)\t(\d+)$') { $facts[$Matches[1]] = [int64]$Matches[2] }
        }
        foreach ($item in @(Get-Prop $list 'data')) {
            $id = Get-Prop $item 'id'
            $meta = Get-Prop $item '_qbraid'
            $context = Get-Prop $meta 'maxTokens'
            if ($null -eq $context) { $context = Get-Prop $item 'context_window' }
            if ($id -and $context) { $facts[$id] = [int64]$context }
        }
        $rows = @($facts.Keys | Sort-Object | ForEach-Object { "$_`t$($facts[$_])" })
        Write-RawText (Join-Path $ProfileDir 'models.tsv') (($rows -join "`n") + "`n")
        $gptModels = @(Get-Prop $list 'data' | ForEach-Object { Get-Prop $_ 'id' } | Where-Object { $_ -like 'gpt-*' })
        $claudeModels = @(Get-Prop $list 'data' | ForEach-Object { Get-Prop $_ 'id' } | Where-Object { $_ -like 'claude-*' })
    } catch { }
    if (($gptModels.Count + $claudeModels.Count) -eq 0) {
        Die 'could not list proxy models from the gateway; the profile was not changed.'
    } else {
        # One proxy, every model: Claude passthrough + GPT translation.
        $yaml = @()
        $yaml += '# Generated by the qbraid-code installer. Loopback only.'
        $yaml += 'host: "127.0.0.1"'
        $yaml += 'port: __PORT__'
        $yaml += 'tls:'
        $yaml += '  enable: false'
        $yaml += 'auth-dir: "__AUTH_DIR__"'
        $yaml += 'api-keys:'
        $yaml += '  - "__LOCAL_KEY__"'
        $yaml += 'remote-management:'
        $yaml += '  allow-remote: false'
        $yaml += '  disable-control-panel: true'
        $yaml += 'debug: false'
        $yaml += '# Keep model identifiers stable for explicit --model launches.'
        $yaml += 'claude-code:'
        $yaml += '  disable-cloaking-model-list: true'
        $yaml += 'claude-api-key:'
        $yaml += '  - api-key: "__QBRAID_KEY__"'
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
        $yaml += '      - api-key: "__QBRAID_KEY__"'
        $yaml += '    models:'
        foreach ($gm in $gptModels) {
            $yaml += "      - name: `"$gm`""
            $yaml += "        alias: `"$gm`""
        }
        Write-RawText (Join-Path $ProfileDir 'proxy-template.yaml') (($yaml -join "`n") + "`n")
        Ok "proxy configured: all $($gptModels.Count + $claudeModels.Count) models on one endpoint (starts on demand)"
    }
} else {
    Die 'CLIProxyAPI unavailable; the profile was not changed.'
}

# Appended after the env file exists.
Add-Content -Path $envPath -Value @("QBRAID_CODE_PROXY_PORT=$ProxyPort", "QBRAID_CODE_PROXY_BIN=$ProxyBin")
$finalGeneration = Join-Path $generationsDir $generation
Move-Item $ProfileStage $finalGeneration
$ProfileStage = $null
$currentTmp = Join-Path $ProfileRoot ("current.$PID.tmp")
Write-RawText $currentTmp "$generation`n"
Move-Item $currentTmp $currentPath -Force
$SecretStaged = $false
$ProfileDir = $finalGeneration
Remove-OldProfileGenerations $generation
Remove-LegacyPlaintextToken
Ok "profile '$Profile' metadata committed"

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

Write-RawText $Settings ($cfg | ConvertTo-Json -Depth 100)
Ok "statusline enabled in $Settings"
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
$activeTmp = Join-Path $HomeDir ("active-profile.$PID.$([guid]::NewGuid().ToString('N')).tmp")
Write-RawText $activeTmp "$Profile`n"
Move-Item $activeTmp (Join-Path $HomeDir 'active-profile') -Force
Write-Host 'qbraid-code is ready.' -ForegroundColor Green
Write-Host ''
Write-Host '  Open a new terminal, then run it from any folder:'
Write-Host ''
Write-Host '    qbraid-code                 start a session'
Write-Host '    qbraid-code -p "..."        ask one question and exit'
Write-Host '    qbraid-code --doctor        check your setup'
Write-Host ''
Write-Host '  Your own claude command is untouched.'
Write-Host ''

} finally {
    if ($SecretStaged -and $SecretRef) {
        try { $vault = New-Object Windows.Security.Credentials.PasswordVault; $orphan = $vault.Retrieve($SecretRef, $env:USERNAME); $vault.Remove($orphan) } catch { }
    }
    if ($ProfileStage -and (Test-Path $ProfileStage)) { Remove-Item $ProfileStage -Recurse -Force -ErrorAction SilentlyContinue }
    if ($updateHandle) { $updateHandle.Dispose() }
    if ($InstallLockHandle) { $InstallLockHandle.Dispose() }
    if ($profileMutex) { $profileMutex.Dispose() }
    try { $InstallMutex.ReleaseMutex() } catch { }
    $InstallMutex.Dispose()
}
