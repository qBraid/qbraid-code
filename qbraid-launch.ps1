Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$null = [Windows.Security.Credentials.PasswordVault,Windows.Security.Credentials,ContentType=WindowsRuntime]
$null = [Windows.Security.Credentials.PasswordCredential,Windows.Security.Credentials,ContentType=WindowsRuntime]

$homeFile = Join-Path $PSScriptRoot 'qbraid-code.home'
$HomeDir = if ($env:QBRAID_CODE_HOME) { $env:QBRAID_CODE_HOME } elseif (Test-Path $homeFile) { (Get-Content $homeFile -Raw -Encoding UTF8).Trim() } else { Join-Path $env:USERPROFILE '.qbraid-code' }
function Read-PidFile {
    param([string]$Path)
    $value = 0
    try { if (Test-Path $Path) { [void][int]::TryParse((Get-Content $Path -Raw).Trim(), [ref]$value) } } catch { }
    return $value
}
$legacyDefault = Join-Path (Join-Path $HomeDir 'profiles') 'default'
if (Test-Path $legacyDefault) {
    $legacyEnv = Join-Path $HomeDir 'env'
    if (Test-Path $legacyEnv) {
        $legacyLines = @(Get-Content $legacyEnv)
        if (@($legacyLines | Where-Object { $_ -match '^QBRAID_CODE_TOKEN=' }).Count -gt 0) {
            $safeLines = @($legacyLines | Where-Object { $_ -notmatch '^QBRAID_CODE_TOKEN=' })
            $cleanEnv = "$legacyEnv.clean.$PID.$([guid]::NewGuid().ToString('N'))"
            [IO.File]::WriteAllText($cleanEnv, (($safeLines -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
            Move-Item $cleanEnv $legacyEnv -Force
        }
    }
    $legacyConfig = Join-Path $HomeDir 'proxy-config.yaml'; $keepLegacyConfig = $false
    $legacyPidPath = Join-Path $HomeDir 'proxy.pid'
    if (Test-Path $legacyPidPath) {
        $legacyPid = Read-PidFile $legacyPidPath
        $legacyProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$legacyPid" -ErrorAction SilentlyContinue
        $keepLegacyConfig = $legacyProcess -and $legacyProcess.CommandLine -and $legacyProcess.CommandLine.Contains($legacyConfig)
    }
    if (-not $keepLegacyConfig) { Remove-Item $legacyConfig -Force -ErrorAction SilentlyContinue }
}
Get-ChildItem $HomeDir -Directory -Filter 'session.*' -ErrorAction SilentlyContinue | ForEach-Object {
    $ownerPath = Join-Path $_.FullName 'owner.pid'
    $owner = Read-PidFile $ownerPath
    if (-not $owner -or -not (Get-Process -Id $owner -ErrorAction SilentlyContinue)) { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
}
[object[]]$claudeArgs = @($args)
$explicitProfile = ''
$profileOption = $false
if ($claudeArgs.Count -gt 0 -and $claudeArgs[0] -eq '--profile') {
    if ($claudeArgs.Count -lt 2) { Write-Error '--profile needs a name'; exit 1 }
    $profileOption = $true
    $explicitProfile = [string]$claudeArgs[1]
    if ($claudeArgs.Count -gt 2) { [object[]]$claudeArgs = @($claudeArgs[2..($claudeArgs.Count - 1)]) } else { [object[]]$claudeArgs = @() }
}
$allowResume = $false
if ($claudeArgs.Count -gt 0 -and $claudeArgs[0] -eq '--allow-profile-resume') {
    $allowResume = $true
    if ($claudeArgs.Count -gt 1) { [object[]]$claudeArgs = @($claudeArgs[1..($claudeArgs.Count - 1)]) } else { [object[]]$claudeArgs = @() }
}
$activePath = Join-Path $HomeDir 'active-profile'
$active = if (Test-Path $activePath) { (Get-Content $activePath -Raw).Trim() } else { '' }

function Resolve-ProfileDir {
    param([string]$Name)
    $root = Join-Path $HomeDir "profiles\$Name"
    $current = Join-Path $root 'current'
    if (Test-Path $current) {
        $generation = (Get-Content $current -Raw).Trim()
        if (-not $generation -or $generation.Contains('/') -or $generation.Contains('\') -or $generation.StartsWith('.')) { return $null }
        $candidate = Join-Path (Join-Path $root 'generations') $generation
        if (Test-Path (Join-Path $candidate 'env')) { return $candidate }
        return $null
    }
    if (Test-Path (Join-Path $root 'env')) { return $root }
    return $null
}

if ($claudeArgs.Count -gt 0 -and $claudeArgs[0] -eq '--profiles') {
    Get-ChildItem (Join-Path $HomeDir 'profiles') -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $resolved = Resolve-ProfileDir $_.Name
        if ($resolved) {
            $mark = if ($_.Name -eq $active) { '*' } else { ' ' }
            $labelPath = Join-Path $resolved 'label'
            $label = if (Test-Path $labelPath) { (Get-Content $labelPath -Raw -Encoding UTF8).Trim() } else { $_.Name }
            Write-Output ("{0} {1,-32} {2}" -f $mark, $_.Name, $label)
        }
    }
    exit 0
}
if ($claudeArgs.Count -gt 0 -and $claudeArgs[0] -eq '--use-profile') {
    if ($claudeArgs.Count -lt 2) { Write-Error '--use-profile needs a name'; exit 1 }
    $next = [string]$claudeArgs[1]
    if ($next -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$' -or -not (Resolve-ProfileDir $next)) { Write-Error "invalid profile '$next'"; exit 1 }
    $activeTmp = "$activePath.$PID.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($activeTmp, "$next`n", (New-Object Text.UTF8Encoding $false))
    Move-Item $activeTmp $activePath -Force
    Write-Output "qbraid-code: active profile is now $next"
    exit 0
}

$profile = if ($profileOption) { $explicitProfile } elseif ($env:QBRAID_CODE_PROFILE) { $env:QBRAID_CODE_PROFILE } elseif ($active) { $active } else { 'default' }
if ($profile -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$') { Write-Error "invalid profile '$profile'"; exit 1 }
$profileRoot = Join-Path $HomeDir "profiles\$profile"
$profileDir = Resolve-ProfileDir $profile
if (-not $profileDir -and $profile -eq 'default' -and (Test-Path (Join-Path $HomeDir 'env'))) { $profileRoot = $HomeDir; $profileDir = $HomeDir }
$envPath = Join-Path $profileDir 'env'
if (-not (Test-Path $envPath)) { Write-Error "profile '$profile' is not installed"; exit 1 }
$settings = @{}
foreach ($line in Get-Content $envPath) { if ($line -match '^([A-Z_]+)=(.*)$') { $settings[$Matches[1]] = $Matches[2] } }
if (-not $settings['QBRAID_CODE_TOKEN'] -and $settings['QBRAID_CODE_SECRET_BACKEND'] -eq 'credential-locker') {
    try {
        $vault = New-Object Windows.Security.Credentials.PasswordVault
        $credential = $vault.Retrieve($settings['QBRAID_CODE_SECRET_REF'], $env:USERNAME)
        $credential.RetrievePassword()
        $settings['QBRAID_CODE_TOKEN'] = $credential.Password
    } catch { }
}
$env:QBRAID_CODE_PROFILE = $profile
$env:QBRAID_CODE_PROFILE_HOME = $profileDir

if ($claudeArgs.Count -gt 0 -and $claudeArgs[0] -eq '--stop') {
    Get-ChildItem $HomeDir -Directory -Filter 'runtime.*' -ErrorAction SilentlyContinue | ForEach-Object {
        $pidPath = Join-Path $_.FullName 'proxy.pid'
        if (Test-Path $pidPath) {
            $runtimePid = Read-PidFile $pidPath
            $process = Get-CimInstance Win32_Process -Filter "ProcessId=$runtimePid" -ErrorAction SilentlyContinue
            if ($process -and $process.CommandLine -and $process.CommandLine.Contains((Join-Path $_.FullName 'proxy-config.yaml'))) {
                Stop-Process -Id $runtimePid -Force -ErrorAction SilentlyContinue
                Wait-Process -Id $runtimePid -Timeout 5 -ErrorAction SilentlyContinue
            }
        }
        $ownerPath = Join-Path $_.FullName 'owner.pid'
        $owner = Read-PidFile $ownerPath
        if (-not $owner -or -not (Get-Process -Id $owner -ErrorAction SilentlyContinue)) { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Write-Output 'qbraid-code: local proxies stopped'
    exit 0
}
if ($claudeArgs.Count -gt 0 -and $claudeArgs[0] -eq '--doctor') {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $HomeDir 'doctor.ps1')
    exit $LASTEXITCODE
}
if ($claudeArgs.Count -gt 0 -and @('--help','-h') -contains $claudeArgs[0]) {
    @"
qbraid-code - Claude Code, powered by the qBraid AI gateway.

  qbraid-code [claude args...]        start a session
  qbraid-code --profile NAME [...]    use one profile for this session
  qbraid-code --profiles              list profiles
  qbraid-code --use-profile NAME      select future default
  qbraid-code --doctor                check the selected profile

Default profile: $profile
Default model: $($settings['QBRAID_CODE_MODEL'])
"@
    exit 0
}
if (@($claudeArgs | Where-Object { $_ -eq '--global' }).Count -gt 0) { Write-Error '--global was removed because project settings can exfiltrate its credential. Use qbraid-code.'; exit 1 }
foreach ($key in @('QBRAID_CODE_BASE_URL','QBRAID_CODE_API_BASE','QBRAID_CODE_TOKEN','QBRAID_CODE_MODEL')) {
    if (-not $settings[$key]) { Write-Error "$envPath is missing $key"; exit 1 }
}
if (-not $allowResume) {
    foreach ($argument in $claudeArgs) {
        if ($argument -in @('-c','--continue','--resume') -or $argument -like '--resume=*') { Write-Error 'resuming may cross profile billing history. Add --allow-profile-resume after --profile to confirm.'; exit 1 }
    }
}
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { Write-Error 'Claude Code is not installed'; exit 1 }
$sessionMutex = New-Object Threading.Mutex($false, "Local\qbraid-code-profile-$($env:USERNAME)-$profile")
$sessionLeased = $false
for ($attempt = 0; $attempt -lt 200 -and -not $sessionLeased; $attempt++) {
    if (-not $sessionMutex.WaitOne(10000)) { continue }
    try {
        try {
            $sessionLeaseHandle = [IO.File]::Open((Join-Path $profileRoot '.update-lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
            $sessionUsers = Join-Path $profileRoot 'session-users'
            New-Item -ItemType Directory -Force -Path $sessionUsers | Out-Null
            [IO.File]::WriteAllText((Join-Path $sessionUsers ([string]$PID)), '', (New-Object Text.UTF8Encoding $false))
            $sessionLeased = $true
        } catch [IO.IOException] { Start-Sleep -Milliseconds 300 }
    } finally { $sessionMutex.ReleaseMutex() }
}
if (-not $sessionLeased) { Write-Error "profile '$profile' is being updated. Try again shortly."; exit 1 }
$settings.Clear()
foreach ($line in Get-Content $envPath) { if ($line -match '^([A-Z_]+)=(.*)$') { $settings[$Matches[1]] = $Matches[2] } }
if (-not $settings['QBRAID_CODE_TOKEN'] -and $settings['QBRAID_CODE_SECRET_BACKEND'] -eq 'credential-locker') {
    try {
        $vault = New-Object Windows.Security.Credentials.PasswordVault
        $credential = $vault.Retrieve($settings['QBRAID_CODE_SECRET_REF'], $env:USERNAME)
        $credential.RetrievePassword()
        $settings['QBRAID_CODE_TOKEN'] = $credential.Password
    } catch { }
}

$runModel = $settings['QBRAID_CODE_MODEL']
$explicitModel = $false
for ($i = 0; $i -lt $claudeArgs.Count; $i++) {
    if ($claudeArgs[$i] -eq '--model' -and $i + 1 -lt $claudeArgs.Count) { $runModel = [string]$claudeArgs[$i + 1]; $explicitModel = $true; break }
    if ([string]$claudeArgs[$i] -like '--model=*') { $runModel = ([string]$claudeArgs[$i]).Substring(8); $explicitModel = $true; break }
}
$modelId = ($runModel -replace '^anthropic-compat/', '') -replace '\[1m\]$', ''
$context = $null
$modelPath = Join-Path $profileDir 'models.tsv'
if (Test-Path $modelPath) {
    foreach ($line in Get-Content $modelPath) { if ($line -match '^([^\t]+)\t(\d+)$' -and $Matches[1] -eq $modelId) { $context = [int64]$Matches[2]; break } }
}
if ($null -eq $context) { $context = 200000 }
$boundContext = if ($context -ge 1000000) { 1000000 } else { $context }
if ($context -ge 1000000 -and -not $explicitModel) { $runModel = ($runModel -replace '\[1m\]$', '') + '[1m]' }
$env:MAX_THINKING_TOKENS = $null
$env:CLAUDE_CODE_DISABLE_THINKING = $null
try {
    $balance = Invoke-RestMethod -Uri "$($settings['QBRAID_CODE_API_BASE'])/billing/credits/balance" -Headers @{ 'X-API-Key' = $settings['QBRAID_CODE_TOKEN'] } -TimeoutSec 8
    if ($null -ne $balance.data.qbraidCredits) {
        [IO.File]::WriteAllText((Join-Path $profileDir 'credits.cache'), [string]$balance.data.qbraidCredits, (New-Object Text.UTF8Encoding $false))
        [IO.File]::WriteAllText((Join-Path $profileDir 'credits.updated'), [string][DateTimeOffset]::UtcNow.ToUnixTimeSeconds(), (New-Object Text.UTF8Encoding $false))
    }
} catch { }
$runBase = $settings['QBRAID_CODE_BASE_URL']
$runToken = $settings['QBRAID_CODE_TOKEN']
$proxyAcquired = $false
$runtimeDir = $null
$portLock = $null
$templatePath = Join-Path $profileDir 'proxy-template.yaml'
$proxyBin = $settings['QBRAID_CODE_PROXY_BIN']
if (-not $proxyBin -or -not (Test-Path $proxyBin) -or -not (Test-Path $templatePath)) {
    Write-Error 'The credential-isolating local proxy is not configured. Re-run the installer.'
    exit 1
}
Get-ChildItem $HomeDir -Directory -Filter 'runtime.*' -ErrorAction SilentlyContinue | ForEach-Object {
    $ownerPath = Join-Path $_.FullName 'owner.pid'
    $owner = Read-PidFile $ownerPath
    if (-not $owner -or -not (Get-Process -Id $owner -ErrorAction SilentlyContinue)) {
        $pidPath = Join-Path $_.FullName 'proxy.pid'
        if (Test-Path $pidPath) {
            $orphanPid = Read-PidFile $pidPath
            $orphan = Get-CimInstance Win32_Process -Filter "ProcessId=$orphanPid" -ErrorAction SilentlyContinue
            if ($orphan -and $orphan.CommandLine -and $orphan.CommandLine.Contains((Join-Path $_.FullName 'proxy-config.yaml'))) {
                Stop-Process -Id $orphanPid -Force -ErrorAction SilentlyContinue
                Wait-Process -Id $orphanPid -Timeout 5 -ErrorAction SilentlyContinue
            }
        }
        Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}
$portsDir = Join-Path $HomeDir 'ports'
New-Item -ItemType Directory -Force -Path $portsDir | Out-Null
$runtimePort = [int]$settings['QBRAID_CODE_PROXY_PORT']
function Test-LocalPort {
    param([int]$Number)
    $client = New-Object Net.Sockets.TcpClient
    try { $task = $client.ConnectAsync('127.0.0.1', $Number); return ($task.Wait(150) -and $client.Connected) } catch { return $false } finally { $client.Dispose() }
}
while ($runtimePort -le 8999 -and -not $portLock) {
    if (Test-LocalPort $runtimePort) { $runtimePort++; continue }
    $candidate = Join-Path $portsDir ([string]$runtimePort)
    try {
        New-Item -ItemType Directory -Path $candidate -ErrorAction Stop | Out-Null
        [IO.File]::WriteAllText((Join-Path $candidate 'pid'), [string]$PID, (New-Object Text.UTF8Encoding $false))
        $portLock = $candidate
    } catch {
        $ownerPath = Join-Path $candidate 'pid'
        $owner = Read-PidFile $ownerPath
        if (-not $owner -or -not (Get-Process -Id $owner -ErrorAction SilentlyContinue)) { Remove-Item $candidate -Recurse -Force -ErrorAction SilentlyContinue } else { $runtimePort++ }
    }
}
if (-not $portLock) { Write-Error 'No local proxy port is available.'; exit 1 }
$runtimeDir = Join-Path $HomeDir ("runtime.$profile.$PID.$([guid]::NewGuid().ToString('N'))")
New-Item -ItemType Directory -Path $runtimeDir | Out-Null
[IO.File]::WriteAllText((Join-Path $runtimeDir 'owner.pid'), [string]$PID, (New-Object Text.UTF8Encoding $false))
try {
    $runtimeAcl = Get-Acl $runtimeDir
    $runtimeAcl.SetAccessRuleProtection($true, $false)
    $runtimeAcl.Access | ForEach-Object { $runtimeAcl.RemoveAccessRule($_) | Out-Null }
    $runtimeAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($env:USERNAME, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    Set-Acl -Path $runtimeDir -AclObject $runtimeAcl
} catch { Remove-Item $runtimeDir, $portLock -Recurse -Force -ErrorAction SilentlyContinue; throw 'cannot protect proxy runtime files' }
$bytes = New-Object byte[] 24
[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$localKey = ($bytes | ForEach-Object { $_.ToString('x2') }) -join ''
$keyFile = Join-Path $runtimeDir 'proxy.key'
[IO.File]::WriteAllText($keyFile, $localKey, (New-Object Text.UTF8Encoding $false))
$runtimeConfig = Join-Path $runtimeDir 'proxy-config.yaml'
$authDir = ((Join-Path $runtimeDir 'auth') -replace '\\','/') -replace '"','\"'
$yamlToken = $runToken.Replace('\', '\\').Replace('"', '\"')
$template = Get-Content $templatePath -Raw
$template = $template.Replace('__PORT__', [string]$runtimePort).Replace('__AUTH_DIR__', $authDir).Replace('__LOCAL_KEY__', $localKey).Replace('__QBRAID_KEY__', $yamlToken)
[IO.File]::WriteAllText($runtimeConfig, $template, (New-Object Text.UTF8Encoding $false))
$env:QBRAID_CODE_RUNTIME_CONFIG = $runtimeConfig
$env:QBRAID_CODE_RUNTIME_KEY_FILE = $keyFile
$env:QBRAID_CODE_RUNTIME_PORT = [string]$runtimePort
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $HomeDir 'qbraid-proxy.ps1') ensure
if ($LASTEXITCODE -ne 0) { Remove-Item $runtimeDir, $portLock -Recurse -Force -ErrorAction SilentlyContinue; exit 1 }
$proxyAcquired = $true
$runToken = $localKey
$runBase = "http://127.0.0.1:$runtimePort"

$sessionDir = Join-Path $HomeDir ("session.$profile.$PID.$([guid]::NewGuid().ToString('N'))")
New-Item -ItemType Directory -Force -Path $sessionDir | Out-Null
[IO.File]::WriteAllText((Join-Path $sessionDir 'owner.pid'), [string]$PID, (New-Object Text.UTF8Encoding $false))
try {
    $sessionAcl = Get-Acl $sessionDir
    $sessionAcl.SetAccessRuleProtection($true, $false)
    $sessionAcl.Access | ForEach-Object { $sessionAcl.RemoveAccessRule($_) | Out-Null }
    $sessionAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
        $env:USERNAME, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    Set-Acl -Path $sessionDir -AclObject $sessionAcl
} catch {
    if ($proxyAcquired) {
        $env:QBRAID_CODE_RUNTIME_CONFIG = $runtimeConfig
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $HomeDir 'qbraid-proxy.ps1') stop *> $null
    }
    Remove-Item (Join-Path $profileRoot "session-users\$PID") -Force -ErrorAction SilentlyContinue
    Remove-Item $sessionDir, $runtimeDir, $portLock -Recurse -Force -ErrorAction SilentlyContinue
    throw "cannot protect the session snapshot at $sessionDir"
}
foreach ($name in @('label','label-source','organization-id','credits.cache','credits.updated')) { $source = Join-Path $profileDir $name; if (Test-Path $source) { Copy-Item $source (Join-Path $sessionDir $name) } }
if (-not (Test-Path (Join-Path $sessionDir 'label'))) { [IO.File]::WriteAllText((Join-Path $sessionDir 'label'), "$profile`n", (New-Object Text.UTF8Encoding $false)) }
$boundSettings = Join-Path $sessionDir 'settings.json'
$boundEnv = [ordered]@{
    ANTHROPIC_BASE_URL = $runBase
    ANTHROPIC_AUTH_TOKEN = $runToken
    ANTHROPIC_MODEL = $runModel
    ANTHROPIC_SMALL_FAST_MODEL = $runModel
    CLAUDE_CODE_SUBAGENT_MODEL = $runModel
    ANTHROPIC_DEFAULT_OPUS_MODEL = $runModel
    ANTHROPIC_DEFAULT_SONNET_MODEL = $runModel
    ANTHROPIC_DEFAULT_HAIKU_MODEL = $runModel
    CLAUDE_CODE_MAX_CONTEXT_TOKENS = [string]$boundContext
    QBRAID_CODE_PROFILE = $profile
    QBRAID_CODE_PROFILE_HOME = $sessionDir
}
[IO.File]::WriteAllText($boundSettings, (@{ env = $boundEnv } | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
$effectiveArgs = @($claudeArgs) + @('--settings', $boundSettings, '--setting-sources', 'user')
$env:QBRAID_CODE_PROFILE_HOME = $sessionDir
$env:ANTHROPIC_BASE_URL = $runBase
$env:ANTHROPIC_AUTH_TOKEN = $runToken
$env:ANTHROPIC_MODEL = $runModel
$env:ANTHROPIC_SMALL_FAST_MODEL = $runModel
$env:CLAUDE_CODE_SUBAGENT_MODEL = $runModel
$env:CLAUDE_CODE_MAX_CONTEXT_TOKENS = [string]$boundContext
try {
    & claude @effectiveArgs
    $rc = $LASTEXITCODE
} finally {
    if ($proxyAcquired) {
        $env:QBRAID_CODE_RUNTIME_CONFIG = $runtimeConfig
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $HomeDir 'qbraid-proxy.ps1') stop *> $null
    }
    if ($runtimeDir) { Remove-Item $runtimeDir -Recurse -Force -ErrorAction SilentlyContinue }
    if ($portLock) { Remove-Item $portLock -Recurse -Force -ErrorAction SilentlyContinue }
    if ($sessionLeaseHandle) { $sessionLeaseHandle.Dispose() }
    Remove-Item (Join-Path $profileRoot "session-users\$PID") -Force -ErrorAction SilentlyContinue
    Remove-Item $sessionDir -Recurse -Force -ErrorAction SilentlyContinue
    $sessionMutex.Dispose()
}
exit $rc
