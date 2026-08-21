<#
.SYNOPSIS
  qbraid-code installer for Windows - Claude Code, powered by the qBraid AI gateway.

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
    [string]$Profile = '',
    [switch]$UpdateKey
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
$ClaudeReleasesUrl = 'https://downloads.claude.ai/claude-code-releases'
$script:ClaudeMinVersion = '2.1.186'
$script:ClaudeTestedMax  = '2.1.238'
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
function Test-InteractiveConsole {
    try { return -not [Console]::IsInputRedirected } catch { return $false }
}
function Die {
    param($m)
    Write-Host "`nerror: $m" -ForegroundColor Red
    # Under `irm | iex` in a fresh window, exiting closes the window with the
    # message still on screen for a fraction of a second. Hold it open.
    if ((Test-InteractiveConsole) -and $Host.UI.RawUI) {
        try { Read-Host 'Press Enter to close' | Out-Null } catch { }
    }
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
    $reply = Read-Host "$Question $hint"
    if ($null -eq $reply) { Warn "cannot confirm '$Question' without interactive input"; return $false }
    $reply = $reply.Trim().ToLower()
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

function Invoke-NativeQuietly {
    param([string]$FilePath, [string[]]$ArgumentList)
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $FilePath @ArgumentList *> $null
        return $LASTEXITCODE
    } finally { $ErrorActionPreference = $savedPreference }
}
function Get-EnvMap {
    param([string]$Path)
    $values = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $values }
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^\s*([A-Z_]+)\s*=\s*(.*)$') { $values[$Matches[1]] = $Matches[2] }
    }
    return $values
}

function Read-PidFile {
    param([string]$Path)
    $value = 0
    try { if (Test-Path $Path) { [void][int]::TryParse((Get-Content $Path -Raw).Trim(), [ref]$value) } } catch { }
    return $value
}

function Stop-VerifiedProxyProcess {
    param([int]$ProxyProcessId, [string]$ConfigPath, [string[]]$ExpectedExecutables)
    if (-not $ProxyProcessId -or -not (Get-Process -Id $ProxyProcessId -ErrorAction SilentlyContinue)) { return }
    $record = Get-CimInstance Win32_Process -Filter "ProcessId=$ProxyProcessId" -ErrorAction SilentlyContinue
    if (-not $record -or -not $record.CommandLine) { Die "cannot verify ownership of stale proxy process $ProxyProcessId" }
    $configPattern = '(?i)(?:^|\s)-config\s+(?:"' + [regex]::Escape($ConfigPath) + '"|' + [regex]::Escape($ConfigPath) + ')(?:\s|$)'
    if ($record.CommandLine -notmatch $configPattern) { return }
    $owned = $false
    foreach ($expected in $ExpectedExecutables) {
        if ($record.ExecutablePath -and $expected -and [StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetFullPath($record.ExecutablePath), [IO.Path]::GetFullPath($expected))) { $owned = $true; break }
    }
    if (-not $owned) { Die "stale process $ProxyProcessId uses the proxy config but is not an owned executable" }
    Stop-Process -Id $ProxyProcessId -Force -ErrorAction Stop
    Wait-Process -Id $ProxyProcessId -Timeout 5 -ErrorAction SilentlyContinue
    if (Get-Process -Id $ProxyProcessId -ErrorAction SilentlyContinue) { Die "could not stop owned stale proxy process $ProxyProcessId" }
}

function Find-QbraidPathReparsePoint {
    param([string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    $current = $root
    foreach ($segment in @($full.Substring($root.Length) -split '[\\/]' | Where-Object { $_ })) {
        $current = Join-Path $current $segment
        if (Test-Path $current) {
            $item = Get-Item $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $item }
        }
    }
    return $null
}
function Find-QbraidManagedReparsePoint {
    param([string]$Path)
    if (-not (Test-Path $Path -PathType Container)) { return $null }
    $pending = New-Object Collections.Generic.Stack[string]
    $pending.Push([IO.Path]::GetFullPath($Path))
    while ($pending.Count -gt 0) {
        foreach ($item in @(Get-ChildItem $pending.Pop() -Force -ErrorAction Stop)) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $item }
            if ($item.PSIsContainer) { $pending.Push($item.FullName) }
        }
    }
    return $null
}

# ------------------------------------------------------ Claude compatibility

function ConvertFrom-ClaudeVersionString {
    param([string]$Text)
    if ($Text -match '(\d+\.\d+\.\d+)') { return $Matches[1] }
    return $null
}

function Compare-ClaudeVersion {
    param([string]$Left, [string]$Right)
    return ([version]$Left).CompareTo([version]$Right)
}

function Test-ClaudeUpgradeSafe {
    param([string]$Installed, [string]$Target)
    return -not $Installed -or (Compare-ClaudeVersion $Installed $Target) -le 0
}

function Get-ClaudeVersionStatus {
    param([string]$Version)
    if (-not $Version) { return 'unknown' }
    if ((Compare-ClaudeVersion $Version $script:ClaudeMinVersion) -lt 0) {
        return 'below-minimum'
    }
    if ((Compare-ClaudeVersion $Version $script:ClaudeTestedMax) -gt 0) {
        return 'newer-than-tested'
    }
    return 'tested'
}

function Get-ClaudePolicyAction {
    param([string]$Policy, [bool]$Interactive)
    switch ($Policy) {
        'upgrade' { return 'upgrade' }
        'fail' { return 'fail' }
        'continue' { return 'continue' }
        'prompt' { if ($Interactive) { return 'prompt' } else { return 'fail' } }
        default { return 'invalid' }
    }
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

function Install-ClaudeStable {
    $installed = $null
    $installedVariable = Get-Variable ClaudeVersion -Scope Script -ErrorAction SilentlyContinue
    if ($installedVariable) { $installed = $installedVariable.Value }
    try {
        $rawTarget = (Invoke-RestMethod -Uri "$ClaudeReleasesUrl/stable").ToString().Trim()
        $target = ConvertFrom-ClaudeVersionString $rawTarget
        if (-not $target -or $target -ne $rawTarget) {
            Die "Anthropic's stable Claude Code version was invalid."
        }
        if (-not (Test-ClaudeUpgradeSafe $installed $target)) {
            Die "Claude Code $installed is newer than stable $target. Refusing to downgrade it; update Claude Code manually or set QBRAID_CODE_CLAUDE_POLICY=continue."
        }
        Warn "installing Claude Code $target from Anthropic's stable channel"
        $installer = [scriptblock]::Create(
            (Invoke-RestMethod -Uri 'https://claude.ai/install.ps1'))
        & $installer $target
    } catch {
        Die "Claude Code stable-channel install failed: $_"
    }
    $env:Path = "$(Join-Path $env:USERPROFILE '.local\bin');$BinDir;$env:Path"
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
        Die 'Claude Code installed but `claude` is not on PATH. Open a new terminal and re-run.'
    }
}

function Update-ClaudeState {
    $output = (& claude --version 2>$null | Out-String).Trim()
    $script:ClaudeVersion = ConvertFrom-ClaudeVersionString $output
    $script:ClaudeVersionStatus = Get-ClaudeVersionStatus $script:ClaudeVersion
    $script:ClaudeMcpAdd = Test-ClaudeMcpCommand 'add'
    $script:ClaudeMcpGet = Test-ClaudeMcpCommand 'get'
    $script:ClaudeMcpLogin = Test-ClaudeMcpCommand 'login'
    $script:ClaudeMcpHttp = Test-ClaudeMcpHttp
    $script:ClaudeMcpUserScope = Test-ClaudeMcpUserScope
}

function Test-ClaudeRequiredCapabilities {
    return $script:ClaudeMcpAdd -and $script:ClaudeMcpGet -and
        $script:ClaudeMcpHttp -and $script:ClaudeMcpUserScope
}

function Confirm-ClaudeCompatibility {
    $policy = if ($env:QBRAID_CODE_CLAUDE_POLICY) {
        $env:QBRAID_CODE_CLAUDE_POLICY.ToLower()
    } else {
        'prompt'
    }
    if ($policy -notin @('prompt', 'upgrade', 'fail', 'continue')) {
        Die 'QBRAID_CODE_CLAUDE_POLICY must be prompt, upgrade, fail, or continue.'
    }
    $interactive = Test-InteractiveConsole

    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
        $action = Get-ClaudePolicyAction $policy $interactive
        if ($action -eq 'upgrade') {
            Install-ClaudeStable
        } elseif ($action -eq 'prompt') {
            if (Confirm-Step 'Claude Code is not installed. Install the stable channel now?' 'y') {
                Install-ClaudeStable
            } else {
                Die 'Claude Code is required. Re-run with QBRAID_CODE_CLAUDE_POLICY=upgrade to install it.'
            }
        } else {
            Die 'Claude Code is not installed. Re-run with QBRAID_CODE_CLAUDE_POLICY=upgrade.'
        }
    }

    Update-ClaudeState
    $issue = $null
    if ($script:ClaudeVersionStatus -eq 'unknown') {
        $issue = 'could not determine its version'
    } elseif ($script:ClaudeVersionStatus -eq 'below-minimum') {
        $issue = "version $($script:ClaudeVersion) is below the supported minimum $script:ClaudeMinVersion"
    }
    if (-not (Test-ClaudeRequiredCapabilities)) {
        if ($issue) { $issue += '; ' }
        $issue += 'required HTTP MCP commands are unavailable'
    }

    $upgraded = $false
    if ($issue) {
        $action = Get-ClaudePolicyAction $policy $interactive
        if ($script:ClaudeVersionStatus -eq 'newer-than-tested') {
            if ($action -in @('continue', 'prompt')) {
                Warn "Claude Code $($script:ClaudeVersion) is newer than tested and lacks required capabilities; refusing to downgrade it and continuing with reduced compatibility."
                $action = 'handled'
            } else {
                Die "Claude Code $($script:ClaudeVersion) is newer than tested and lacks required capabilities. Refusing to downgrade it; set QBRAID_CODE_CLAUDE_POLICY=continue to skip unavailable features."
            }
        } elseif ($script:ClaudeVersionStatus -eq 'unknown') {
            if ($action -in @('continue', 'prompt')) {
                Warn "Claude Code's version is unknown; refusing to replace it with stable because that could downgrade it, and continuing with reduced compatibility."
                $action = 'handled'
            } else {
                Die "Claude Code's version is unknown. Refusing to replace it with stable because that could downgrade it; update Claude Code manually or set QBRAID_CODE_CLAUDE_POLICY=continue."
            }
        }
        if ($action -eq 'upgrade') {
            Warn "the installed Claude Code is incompatible: $issue"
            Install-ClaudeStable
            $upgraded = $true
        } elseif ($action -eq 'prompt') {
            Warn "the installed Claude Code is incompatible: $issue"
            if (Confirm-Step 'Upgrade Claude Code to the stable channel now?' 'y') {
                Install-ClaudeStable
                $upgraded = $true
            } else {
                Warn 'continuing with reduced compatibility at your request'
            }
        } elseif ($action -eq 'continue') {
            Warn "continuing with an unsupported Claude Code: $issue"
        } elseif ($action -eq 'handled') {
            # The newer-version branch above already reported the safe fallback.
        } else {
            Die "the installed Claude Code is incompatible: $issue. Upgrade it, or explicitly set QBRAID_CODE_CLAUDE_POLICY=continue."
        }
    }

    if ($upgraded) {
        Update-ClaudeState
        if ($script:ClaudeVersionStatus -in @('unknown', 'below-minimum') -or
            -not (Test-ClaudeRequiredCapabilities)) {
            Die "Claude Code was upgraded, but version $script:ClaudeMinVersion+ with HTTP MCP support is still unavailable."
        }
    }

    if ($script:ClaudeVersionStatus -eq 'newer-than-tested') {
        Warn "Claude Code $($script:ClaudeVersion) is newer than the latest tested version ($script:ClaudeTestedMax); continuing without downgrading."
    } elseif ($script:ClaudeVersionStatus -eq 'tested') {
        Ok "Claude Code $($script:ClaudeVersion)"
    } else {
        $displayVersion = if ($script:ClaudeVersion) { $script:ClaudeVersion } else { 'present' }
        Warn "Claude Code $displayVersion remains outside the supported range; unavailable features will be skipped."
    }
}

# ---------------------------------------------------------------- 1. platform

if (-not [Environment]::Is64BitOperatingSystem) {
    Die '32-bit Windows is not supported.'
}
Say "Platform: windows/$($env:PROCESSOR_ARCHITECTURE.ToLower())"

if ($PSBoundParameters.ContainsKey('Profile') -and -not $Profile) { Die 'invalid empty profile' }
$InstallMutex = New-Object Threading.Mutex($false, "Local\qbraid-code-installer-$($env:USERNAME)")
if (-not $InstallMutex.WaitOne(0)) { Die 'another qbraid-code installer is running.' }
$InstallLockHandle = $null
$profileMutex = $null
$updateHandle = $null
try {
$defaultHomeDir = [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.qbraid-code')).TrimEnd('\')
$normalizedHomeDir = [IO.Path]::GetFullPath($HomeDir).TrimEnd('\')
if (-not [StringComparer]::OrdinalIgnoreCase.Equals($HomeDir.TrimEnd('\'), $normalizedHomeDir)) { Die 'install directory contains relative or dot segments.' }
$pathReparsePoint = Find-QbraidPathReparsePoint $HomeDir
if ($null -ne $pathReparsePoint) { Die "install directory uses reparse point '$($pathReparsePoint.FullName)'." }
$managedReparsePoint = Find-QbraidManagedReparsePoint $HomeDir
if ($null -ne $managedReparsePoint) { Die "install directory contains reparse point '$($managedReparsePoint.FullName)'." }
if (-not [StringComparer]::OrdinalIgnoreCase.Equals($HomeDir.TrimEnd('\'), $defaultHomeDir) -and (Test-Path $HomeDir -PathType Container)) {
    $existingMarker = Join-Path $HomeDir '.qbraid-code-install'
    $markerOwned = (Test-Path $existingMarker -PathType Leaf) -and ((Get-Content $existingMarker -Raw -Encoding UTF8).Trim() -eq 'qbraid-code')
    if (-not $markerOwned -and @(Get-ChildItem $HomeDir -Force -ErrorAction Stop).Count -gt 0) {
        $sidecarPath = Join-Path $BinDir 'qbraid-code.home'
        $sidecarBound = (Test-Path $sidecarPath -PathType Leaf) -and [StringComparer]::OrdinalIgnoreCase.Equals(
            [IO.Path]::GetFullPath((Get-Content $sidecarPath -Raw -Encoding UTF8).Trim()).TrimEnd('\'), $HomeDir.TrimEnd('\'))
        $managedNames = @('profiles', 'secrets', 'ports', 'active-profile', 'global-profile', 'env', 'label', 'label-source', 'models.tsv', 'credits.cache', 'credits.updated', 'credits.attempt', 'organization-id', 'statusline.ps1', 'doctor.ps1', 'qbraid-proxy.ps1', 'cliproxyapi.exe', 'proxy-config.yaml', 'proxy-template.yaml', 'proxy.key', 'proxy-auth', 'proxy.pid', 'session-users', '.install-lock', '.coord-lock', '.update-lock')
        $unexpected = @(Get-ChildItem $HomeDir -Force | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or ($managedNames -notcontains $_.Name -and $_.Name -notlike 'runtime.*' -and $_.Name -notlike 'session.*' -and $_.Name -notlike '.qbraid-code-install.*.tmp') })
        if (-not $sidecarBound -or $unexpected.Count -gt 0) {
            Die "custom install directory '$HomeDir' is nonempty and not exclusively owned by qbraid-code. Choose an empty directory."
        }
    }
}
New-Item -ItemType Directory -Force -Path $HomeDir, $ProfilesDir, $BinDir, $ClaudeDir | Out-Null
try { $InstallLockHandle = [IO.File]::Open((Join-Path $HomeDir '.install-lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
catch [IO.IOException] { Die 'another qbraid-code installer is running.' }
Get-ChildItem $HomeDir -Force -File -Filter '.qbraid-code-install.*.tmp' -ErrorAction SilentlyContinue | Remove-Item -Force
$markerTmp = Join-Path $HomeDir ('.qbraid-code-install.' + [guid]::NewGuid().ToString('N') + '.tmp')
Write-RawText $markerTmp "qbraid-code`n"
Move-Item $markerTmp (Join-Path $HomeDir '.qbraid-code-install') -Force
if (-not $Profile) {
    $activePath = Join-Path $HomeDir 'active-profile'
    if (Test-Path $activePath) { $Profile = (Get-Content $activePath -Raw).Trim() }
}
if (-not $Profile) { $Profile = 'default' }
if ($Profile -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$') { Die "invalid profile '$Profile'" }
$ProfileRoot = Join-Path $ProfilesDir $Profile
$ProfileDir = $ProfileRoot
$legacyEnvPath = Join-Path $HomeDir 'env'
$defaultDir = Join-Path $ProfilesDir 'default'
if ((Test-Path $legacyEnvPath) -and -not (Test-Path $defaultDir)) {
    $migrationDir = Join-Path $ProfilesDir (".default.migrate.$PID.$([guid]::NewGuid().ToString('N'))")
    New-Item -ItemType Directory -Force -Path $migrationDir | Out-Null
    $legacyLines = @(Get-Content $legacyEnvPath)
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
    foreach ($name in @('label','label-source','models.tsv','credits.cache','credits.updated','credits.attempt','organization-id','proxy-template.yaml')) {
        $source = Join-Path $HomeDir $name
        if (Test-Path $source) { Copy-Item $source (Join-Path $migrationDir $name) -Recurse }
    }
    if (-not (Test-Path (Join-Path $migrationDir 'label'))) { Write-RawText (Join-Path $migrationDir 'label') "default`n" }
    if (-not (Test-Path (Join-Path $migrationDir 'label-source'))) { Write-RawText (Join-Path $migrationDir 'label-source') "local`n" }
    Move-Item $migrationDir $defaultDir
}
function Remove-LegacyPlaintextToken {
    if (-not (Test-Path $defaultDir)) { return }
    if (Test-Path $legacyEnvPath) {
        $legacyLines = @(Get-Content $legacyEnvPath)
        if (@($legacyLines | Where-Object { $_ -match '^QBRAID_CODE_TOKEN=' }).Count -gt 0) {
            $lines = @($legacyLines | Where-Object { $_ -notmatch '^QBRAID_CODE_TOKEN=' })
            $cleanEnv = "$legacyEnvPath.clean.$PID.$([guid]::NewGuid().ToString('N'))"
            Write-RawText $cleanEnv (($lines -join "`n") + "`n")
            Move-Item $cleanEnv $legacyEnvPath -Force
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
if ($UpdateKey -and -not (Test-Path (Join-Path $ProfileRoot 'current')) -and -not (Test-Path (Join-Path $ProfileRoot 'env'))) {
    Die "profile '$Profile' is not installed. Create it without -UpdateKey first."
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
$oldEnvPath = Join-Path $ProfileDir 'env'
$oldModel = ''
if (Test-Path $oldEnvPath) {
    $oldModelLine = (Get-Content $oldEnvPath | Where-Object { $_ -like 'QBRAID_CODE_MODEL=*' } | Select-Object -First 1)
    if ($oldModelLine) { $oldModel = $oldModelLine.Substring('QBRAID_CODE_MODEL='.Length) }
}
$oldLabelPath = Join-Path $ProfileDir 'label'
$oldLabelSourcePath = Join-Path $ProfileDir 'label-source'
$oldProfileLabel = if (Test-Path $oldLabelPath) { (Get-Content $oldLabelPath -Raw).Trim() } else { '' }
$oldProfileLabelSource = if (Test-Path $oldLabelSourcePath) { (Get-Content $oldLabelSourcePath -Raw).Trim() } else { 'local' }
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
    $oldProxySettings = Get-EnvMap (Join-Path $ProfileDir 'env')
    $expectedProxyBinaries = @((Join-Path $HomeDir 'cliproxyapi.exe'))
    if ($oldProxySettings['QBRAID_CODE_PROXY_BIN']) { $expectedProxyBinaries += $oldProxySettings['QBRAID_CODE_PROXY_BIN'] }
    Stop-VerifiedProxyProcess $stalePid (Join-Path $ProfileDir 'proxy-config.yaml') $expectedProxyBinaries
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
        $legacyClaudeEnv = Get-Prop $legacySettings 'env'
        $legacyBase = Get-Prop $legacyClaudeEnv 'ANTHROPIC_BASE_URL'
        if ($legacyBase -like '*api-v2.qbraid.com*') {
            foreach ($key in @('ANTHROPIC_BASE_URL','ANTHROPIC_AUTH_TOKEN','ANTHROPIC_MODEL','ANTHROPIC_SMALL_FAST_MODEL','QBRAID_CODE_PROFILE','QBRAID_CODE_HOME')) {
                $legacyClaudeEnv.PSObject.Properties.Remove($key)
            }
            Write-RawText $Settings ($legacySettings | ConvertTo-Json -Depth 20)
            Warn 'removed unsafe legacy plain-Claude gateway settings; use qbraid-code'
        }
    } catch { Die "cannot safely remove legacy gateway settings from $Settings" }
}
Remove-Item $globalProfilePath -Force -ErrorAction SilentlyContinue

# ------------------------------------------------------------ 2. claude code

Say 'Claude Code'
Confirm-ClaudeCompatibility

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

function Remove-CredentialLockerItem {
    param([string]$Reference)
    $vault = New-Object Windows.Security.Credentials.PasswordVault
    try { $credential = $vault.Retrieve($Reference, $env:USERNAME) }
    catch {
        if ($_.Exception.HResult -eq -2147023728) { return }
        throw
    }
    $vault.Remove($credential)
    try {
        $remaining = $vault.Retrieve($Reference, $env:USERNAME)
        if ($remaining) { throw "Credential Locker item '$Reference' remains after removal" }
    } catch {
        if ($_.Exception.HResult -ne -2147023728) { throw }
    }
}

function Remove-OldProfileGenerations {
    param([string]$CurrentGeneration)
    $generationsPath = Join-Path $ProfileRoot 'generations'
    $flatEnv = Join-Path $ProfileRoot 'env'
    if (Test-Path $flatEnv) {
        $flatSettings = Get-EnvMap $flatEnv
        $flatRef = $flatSettings['QBRAID_CODE_SECRET_REF']
        if ($flatSettings['QBRAID_CODE_SECRET_BACKEND'] -eq 'credential-locker' -and $flatRef -eq "qbraid-code:$Profile") {
            Remove-CredentialLockerItem $flatRef
        } elseif ($flatRef) { throw 'cannot safely prune an unknown flat-profile credential' }
        foreach ($flatName in @('env','proxy-template.yaml','label','label-source','models.tsv','credits.cache','credits.updated','organization-id')) {
            $flatPath = Join-Path $ProfileRoot $flatName
            if (Test-Path $flatPath) { Remove-Item $flatPath -Force -ErrorAction Stop }
        }
    }
    Get-ChildItem $generationsPath -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name -eq $CurrentGeneration -or $_.Name.StartsWith('.stage.')) { return }
        $oldSettings = Get-EnvMap (Join-Path $_.FullName 'env')
        $oldRef = $oldSettings['QBRAID_CODE_SECRET_REF']
        if ($oldSettings['QBRAID_CODE_SECRET_BACKEND'] -eq 'credential-locker' -and $oldRef -and $oldRef.StartsWith("qbraid-code:${Profile}:")) {
            Remove-CredentialLockerItem $oldRef
        } elseif ($oldRef) { throw "cannot safely prune credential metadata in $($_.FullName)" }
        Remove-Item $_.FullName -Recurse -Force -ErrorAction Stop
    }
}

Say 'qBraid account'
$ApiKey    = $env:QBRAID_API_KEY
$Balance   = $null
$KeySource = 'QBRAID_API_KEY'
if (-not $ApiKey -and -not $UpdateKey) { $ApiKey = Get-ProfileSecret; if ($ApiKey) { $KeySource = 'profile secret store' } }

if (-not $ApiKey -and -not $UpdateKey) {
    $candidate = Read-QbraidrcKey
    if ($candidate) {
        $Balance = Get-Balance $candidate
        if ($Balance) {
            $ApiKey = $candidate
            $KeySource = '~\.qbraid\qbraidrc'
        } else {
            Warn 'the key in ~\.qbraid\qbraidrc is no longer valid - ignoring it'
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
# name is the user's - labelling the confirmation with that would be worse than
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
$oldOrgIdPath = Join-Path $ProfileDir 'organization-id'
$oldOrgId = if (Test-Path $oldOrgIdPath) { (Get-Content $oldOrgIdPath -Raw).Trim() } else { '' }
if ($UpdateKey -and -not $oldOrgId) { Die "profile '$Profile' has no verified organization ID. Create a new profile for the replacement key." }
if ($oldOrgId -and (-not $OrgId -or $oldOrgId -ne $OrgId)) { Die "profile '$Profile' belongs to another organization. Use a new profile name." }

# ------------------------------------------------------------- 5. model choice

Say 'Model'
$Model = $env:QBRAID_CODE_MODEL
if ($UpdateKey -and -not $Model) { $Model = $oldModel }
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
        Warn 'could not list models - defaulting to claude-sonnet-4-6'
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
$ProfileLabel = if ($env:QBRAID_CODE_PROFILE_LABEL) { $env:QBRAID_CODE_PROFILE_LABEL } elseif ($UpdateKey -and $oldProfileLabel) { $oldProfileLabel } elseif ($OrgName) { $OrgName } else { $Profile }
$ProfileLabelSource = if ($env:QBRAID_CODE_PROFILE_LABEL) { 'local' } elseif ($UpdateKey -and $oldProfileLabel) { $oldProfileLabelSource } elseif ($OrgName) { 'verified' } else { 'local' }
$ProfileLabel = ($ProfileLabel -replace '[\x00-\x1F\x7F]', '')
if (-not $ProfileLabel -or $ProfileLabel.Length -gt 40) { $ProfileLabel = $Profile; $ProfileLabelSource = 'local' }
Write-RawText (Join-Path $ProfileDir 'label') "$ProfileLabel`n"
Write-RawText (Join-Path $ProfileDir 'label-source') "$ProfileLabelSource`n"
if ($OrgId) { Write-RawText (Join-Path $ProfileDir 'organization-id') "$OrgId`n" }
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
    $temp = "$Dest.$PID.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $content = $null
        if ($SrcDir) {
            $content = [IO.File]::ReadAllText((Join-Path $SrcDir $Name))
        } else {
            foreach ($base in @($SiteBase, $RawBase)) {
                try {
                    $response = Invoke-WebRequest -Uri "$base/$Name" -TimeoutSec 30 -UseBasicParsing
                    if ($response.StatusCode -eq 200 -and $response.Content) { $content = $response.Content; break }
                } catch { }
            }
            if (-not $content) {
                if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
                    Die "could not download $Name from qbraid.com or GitHub. Check your connection and re-run."
                }
                $content = (gh api -H 'Accept: application/vnd.github.raw' "$GhContents/$Name" | Out-String)
                if ($LASTEXITCODE -ne 0 -or -not $content) {
                    Die "could not download $Name - is ``gh auth login`` done, and are you in the qBraid org?"
                }
            }
        }
        if (-not $content) { Die "downloaded $Name but it is empty." }
        if ($Dest.EndsWith('.cmd')) { $content = ($content -replace "`r`n", "`n") -replace "`n", "`r`n" }
        [IO.File]::WriteAllText($temp, $content, (New-Object Text.UTF8Encoding $false))
        Move-Item $temp $Dest -Force -ErrorAction Stop
    } finally {
        if (Test-Path $temp) { Remove-Item $temp -Force -ErrorAction SilentlyContinue }
    }
}

$ProxyHelperPath = Join-Path $HomeDir 'qbraid-proxy.ps1'
$LauncherPath   = Join-Path $BinDir 'qbraid-code.cmd'
$LaunchHelperPath = Join-Path $BinDir 'qbraid-launch.ps1'
$StatuslinePath = Join-Path $HomeDir 'statusline.ps1'
$DoctorPath     = Join-Path $HomeDir 'doctor.ps1'
Fetch-File 'qbraid-code.cmd' $LauncherPath
$sidecarPath = Join-Path $BinDir 'qbraid-code.home'
$sidecarTemp = "$sidecarPath.$PID.$([guid]::NewGuid().ToString('N')).tmp"
try {
    Write-RawText $sidecarTemp $HomeDir
    Move-Item $sidecarTemp $sidecarPath -Force -ErrorAction Stop
} finally { Remove-Item $sidecarTemp -Force -ErrorAction SilentlyContinue }
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
$mcpRegistered = $false
if ($script:ClaudeMcpGet) {
    if ((Invoke-NativeQuietly 'claude' @('mcp', 'get', $McpName)) -eq 0) {
        $mcpRegistered = $true
        Ok 'already registered'
    }
}
if (-not $mcpRegistered -and (Test-ClaudeRequiredCapabilities)) {
    $mcpAddExitCode = Invoke-NativeQuietly 'claude' @('mcp', 'add', '--transport', 'http', $McpName, $McpUrl, '--scope', 'user')
    if ($mcpAddExitCode -ne 0) { Die 'could not register the qBraid MCP server.' }
    $mcpRegistered = $true
    Ok "registered $McpUrl"
} elseif (-not $mcpRegistered) {
    Warn 'this Claude Code version cannot register an HTTP MCP server from the command line.'
    Warn "Start Claude Code, run /mcp, and add $McpUrl manually; or upgrade Claude Code."
}

# The MCP endpoint is JWT-only (OAuth + dynamic client registration): the API
# key above cannot authorize it. Do the browser sign-in now, while the user is
# still here, rather than surprising them mid-session.
if (-not $mcpRegistered) {
    Warn 'MCP sign-in was skipped because registration is incomplete.'
} elseif (-not $script:ClaudeMcpLogin) {
    Warn 'this Claude Code version authenticates MCP servers through its interactive menu.'
    Warn "Start Claude Code, run /mcp, select '$McpName', and choose Authenticate."
} elseif (Confirm-Step 'Sign in to the qBraid MCP now? (opens a browser)' 'y') {
    # Unlike the piped bash path, `iex` keeps the console attached, so the
    # OAuth prompt can read the redirect URL directly.
    $savedPreference = $ErrorActionPreference
    $mcpLoginExitCode = 1
    try {
        $ErrorActionPreference = 'Continue'
        claude mcp login $McpName
        $mcpLoginExitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $savedPreference }
    if ($mcpLoginExitCode -ne 0) { Warn "MCP sign-in did not complete. Run ``claude mcp login $McpName`` later." }
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

$finalGeneration = Join-Path $generationsDir $generation
Move-Item $ProfileStage $finalGeneration -ErrorAction Stop
$ProfileStage = $finalGeneration
$currentTmp = Join-Path $ProfileRoot ("current.$PID.tmp")
try {
    Write-RawText $currentTmp "$generation`n"
    Move-Item $currentTmp $currentPath -Force -ErrorAction Stop
} catch {
    Remove-Item $currentTmp -Force -ErrorAction SilentlyContinue
    throw
}
$ProfileStage = $null
$SecretStaged = $false
$ProfileDir = $finalGeneration
try { Remove-OldProfileGenerations $generation } catch { Warn 'could not prune every retired profile generation.' }
try { Remove-LegacyPlaintextToken } catch { Warn 'could not remove every legacy credential artifact.' }
Ok "profile '$Profile' metadata committed"

if (-not $UpdateKey) {
    $activeTmp = Join-Path $HomeDir ("active-profile.$PID.$([guid]::NewGuid().ToString('N')).tmp")
    try {
        Write-RawText $activeTmp "$Profile`n"
        Move-Item $activeTmp (Join-Path $HomeDir 'active-profile') -Force -ErrorAction Stop
    } catch {
        Remove-Item $activeTmp -Force -ErrorAction SilentlyContinue
        Warn "could not select '$Profile' for future sessions. Run qbraid-code --use-profile $Profile."
    }
}
Write-Host ''
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
    $stageCommitted = $false
    if ($ProfileStage -and (Test-Path (Join-Path $ProfileRoot 'current'))) {
        $selectedGeneration = (Get-Content (Join-Path $ProfileRoot 'current') -Raw -ErrorAction SilentlyContinue).Trim()
        $stageCommitted = $selectedGeneration -and $selectedGeneration -eq (Split-Path $ProfileStage -Leaf) -and (Test-Path (Join-Path $ProfileStage 'env'))
    }
    if ($stageCommitted) { $SecretStaged = $false; $ProfileStage = $null }
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
