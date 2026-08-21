Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[object[]]$claudeArgs = @($args)
if (@($claudeArgs | Where-Object { $_ -in @('--help','-h') }).Count -gt 0) {
    @'
qbraid-code - Claude Code, powered by the qBraid AI gateway.

Sessions
  qbraid-code [claude arguments]               start a session
  qbraid-code --profile NAME [claude arguments] use NAME for one session
  qbraid-code --profile NAME --allow-profile-resume --resume SESSION_ID
                                                confirm NAME before resuming

Profiles
  qbraid-code --profiles                       list installed profiles
  qbraid-code --use-profile NAME               select future sessions
  qbraid-code --profile NAME --update-key      replace an expired or revoked key

Maintenance
  qbraid-code [--profile NAME] --doctor        check setup and credentials
  qbraid-code [--profile NAME] --stop          stop orphaned local proxies
  qbraid-code --uninstall                      remove qbraid-code from this device
  qbraid-code --uninstall --yes                uninstall without a prompt

Help
  qbraid-code --help                           show this help without network access
  claude --help                                list arguments forwarded to Claude Code

Uninstall deletes local qbraid-code credentials and files. It does not revoke
API keys in your qBraid account.
'@
    exit 0
}
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

$explicitProfile = ''
$profileOption = $false
if ($claudeArgs.Count -gt 0 -and $claudeArgs[0] -eq '--profile') {
    if ($claudeArgs.Count -lt 2) { Write-Error '--profile needs a name'; exit 1 }
    $profileOption = $true
    $explicitProfile = [string]$claudeArgs[1]
    if ($claudeArgs.Count -gt 2) { [object[]]$claudeArgs = @($claudeArgs[2..($claudeArgs.Count - 1)]) } else { [object[]]$claudeArgs = @() }
}

function Test-InstalledProfile {
    param([string]$Name)
    $root = Join-Path $HomeDir "profiles\$Name"
    $current = Join-Path $root 'current'
    if (Test-Path $current) {
        $generation = (Get-Content $current -Raw).Trim()
        if (-not $generation -or $generation.Contains('/') -or $generation.Contains('\') -or $generation.StartsWith('.')) { return $false }
        return (Test-Path (Join-Path (Join-Path (Join-Path $root 'generations') $generation) 'env'))
    }
    if (Test-Path (Join-Path $root 'env')) { return $true }
    return $Name -eq 'default' -and (Test-Path (Join-Path $HomeDir 'env'))
}

function Invoke-QbraidKeyUpdate {
    param([string]$Name)
    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$') { throw "invalid profile '$Name'" }
    if (-not (Test-InstalledProfile $Name)) { throw "profile '$Name' is not installed" }
    Write-Output "qbraid-code: updating the key for profile '$Name'"
    Write-Output 'The replacement key must belong to the same qBraid organization.'
    $source = Invoke-RestMethod -Uri 'https://qbraid.com/code.ps1'
    $installer = [scriptblock]::Create([string]$source)
    $previousHome = $env:QBRAID_CODE_HOME
    $previousBin = $env:QBRAID_CODE_BIN_DIR
    try {
        $env:QBRAID_CODE_HOME = $HomeDir
        $env:QBRAID_CODE_BIN_DIR = $PSScriptRoot
        & $installer -Profile $Name -UpdateKey
    } finally {
        if ($null -eq $previousHome) { Remove-Item Env:QBRAID_CODE_HOME -ErrorAction SilentlyContinue } else { $env:QBRAID_CODE_HOME = $previousHome }
        if ($null -eq $previousBin) { Remove-Item Env:QBRAID_CODE_BIN_DIR -ErrorAction SilentlyContinue } else { $env:QBRAID_CODE_BIN_DIR = $previousBin }
    }
}

function Get-QbraidEnvFiles {
    $result = New-Object Collections.Generic.List[string]
    $legacy = Join-Path $HomeDir 'env'
    if (Test-Path $legacy -PathType Leaf) { [void]$result.Add($legacy) }
    $profiles = Join-Path $HomeDir 'profiles'
    foreach ($profileDirectory in @(Get-ChildItem $profiles -Directory -ErrorAction SilentlyContinue)) {
        $flat = Join-Path $profileDirectory.FullName 'env'
        if (Test-Path $flat -PathType Leaf) { [void]$result.Add($flat) }
        $generations = Join-Path $profileDirectory.FullName 'generations'
        foreach ($generationDirectory in @(Get-ChildItem $generations -Directory -ErrorAction SilentlyContinue)) {
            $candidate = Join-Path $generationDirectory.FullName 'env'
            if (Test-Path $candidate -PathType Leaf) { [void]$result.Add($candidate) }
        }
    }
    return $result.ToArray()
}

function Get-QbraidProxyBinaries {
    $result = New-Object Collections.Generic.List[string]
    [void]$result.Add((Join-Path $HomeDir 'cliproxyapi.exe'))
    foreach ($envFile in @(Get-QbraidEnvFiles)) {
        foreach ($line in @(Get-Content $envFile)) {
            if ($line -match '^QBRAID_CODE_PROXY_BIN=(.+)$' -and -not $result.Contains($Matches[1])) { [void]$result.Add($Matches[1]) }
        }
    }
    return $result.ToArray()
}

function Get-QbraidSecretRecords {
    $records = New-Object Collections.Generic.List[object]
    foreach ($envFile in @(Get-QbraidEnvFiles)) {
        $backend = ''
        $reference = ''
        foreach ($line in @(Get-Content $envFile)) {
            if ($line -match '^QBRAID_CODE_SECRET_BACKEND=(.*)$') { $backend = $Matches[1] }
            if ($line -match '^QBRAID_CODE_SECRET_REF=(.*)$') { $reference = $Matches[1] }
        }
        if (-not $backend) { continue }
        if (-not $reference) { throw "missing secret reference in $envFile" }
        if ($backend -notin @('credential-locker','file')) { throw "unknown secret backend '$backend' in $envFile" }
        if ($backend -eq 'file') {
            $secretsDirectory = [IO.Path]::GetFullPath((Join-Path $HomeDir 'secrets')).TrimEnd('\')
            $fullReference = [IO.Path]::GetFullPath($reference)
            $parent = [IO.Path]::GetDirectoryName($fullReference).TrimEnd('\')
            if (-not [StringComparer]::OrdinalIgnoreCase.Equals($parent, $secretsDirectory)) { throw "refusing unsafe secret path '$reference'" }
            $reference = $fullReference
        }
        [void]$records.Add([pscustomobject]@{ Backend = $backend; Reference = $reference })
    }
    return $records.ToArray()
}

function Repair-QbraidJsonArtifacts {
    param([string]$Path)
    $directory = Split-Path $Path -Parent
    $cleaned = $false
    foreach ($temporary in @(Get-ChildItem $directory -Force -File -Filter '.qbraid-code-uninstall-*.tmp' -ErrorAction SilentlyContinue)) {
        if (($temporary.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing unexpected JSON temporary $($temporary.FullName)" }
        Remove-Item $temporary.FullName -Force -ErrorAction Stop
        $cleaned = $true
    }
    $backup = "$Path.qbraid-code-uninstall.backup"
    if (Test-Path $backup) {
        if (-not (Test-Path $backup -PathType Leaf)) { throw "Refusing unexpected JSON backup at $backup" }
        $backupItem = Get-Item $backup -Force
        if (($backupItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing unexpected JSON backup at $backup" }
        if (-not (Test-Path $Path)) {
            [IO.File]::Move($backup, $Path)
            throw "Recovered $Path from an interrupted update. Retry uninstall."
        }
        $currentItem = Get-Item $Path -Force
        if (($currentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing unsafe JSON file $Path" }
        try { $null = [IO.File]::ReadAllText($Path) | ConvertFrom-Json }
        catch { throw "Unexpected JSON backup at $backup; current JSON is invalid. Refusing uninstall." }
        Remove-Item $backup -Force -ErrorAction Stop
        throw "Removed an interrupted-update backup beside $Path. Retry uninstall."
    }
    if ($cleaned) { throw "Removed interrupted-update temporaries beside $Path. Retry uninstall." }
}

function Read-JsonSnapshot {
    param([string]$Path)
    Repair-QbraidJsonArtifacts $Path
    if (-not (Test-Path $Path -PathType Leaf)) { return $null }
    $item = Get-Item $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "refusing symbolic-link JSON file $Path" }
    $raw = [IO.File]::ReadAllText($Path)
    try { $document = $raw | ConvertFrom-Json }
    catch { throw "cannot safely update invalid JSON at $Path" }
    return [pscustomobject]@{ Document = $document; Raw = $raw }
}

function Write-JsonDocumentAtomic {
    param([string]$Path, [object]$Document, [string]$ExpectedRaw)
    Repair-QbraidJsonArtifacts $Path
    if (-not (Test-Path $Path -PathType Leaf) -or ((Get-Item $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing unsafe JSON file $Path"
    }
    $directory = Split-Path $Path -Parent
    $temporary = Join-Path $directory ('.qbraid-code-uninstall-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $acl = Get-Acl $Path
        [IO.File]::WriteAllText($temporary, (($Document | ConvertTo-Json -Depth 100) + "`n"), (New-Object Text.UTF8Encoding $false))
        Set-Acl -Path $temporary -AclObject $acl
        [IO.File]::Move($Path, "$Path.qbraid-code-uninstall.backup")
        $backup = "$Path.qbraid-code-uninstall.backup"
        if (-not [StringComparer]::Ordinal.Equals([IO.File]::ReadAllText($backup), $ExpectedRaw)) {
            if (-not (Test-Path $Path)) { [IO.File]::Move($backup, $Path) } else { Remove-Item $backup -Force }
            throw "$Path changed during uninstall. Retry to preserve the newer settings."
        }
        try { [IO.File]::Move($temporary, $Path) }
        catch {
            if (Test-Path $Path) { Remove-Item $backup -Force -ErrorAction SilentlyContinue }
            elseif (Test-Path $backup) { [IO.File]::Move($backup, $Path) }
            throw "$Path changed during uninstall. Retry to preserve the newer settings."
        }
        Remove-Item $backup -Force -ErrorAction Stop
    } finally { Remove-Item $temporary -Force -ErrorAction SilentlyContinue }
}

function Remove-QbraidClaudeIntegrations {
    param([object]$SettingsSnapshot, [object]$ClaudeSnapshot, [string]$SettingsPath, [string]$ClaudePath)
    if ($null -ne $SettingsSnapshot) {
        $SettingsDocument = $SettingsSnapshot.Document
        $property = $SettingsDocument.PSObject.Properties['statusLine']
        if ($null -ne $property -and $null -ne $property.Value) {
            $commandProperty = $property.Value.PSObject.Properties['command']
            $expected = 'powershell -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $HomeDir 'statusline.ps1') + '"'
            if ($null -ne $commandProperty -and [StringComparer]::OrdinalIgnoreCase.Equals([string]$commandProperty.Value, $expected)) {
                $SettingsDocument.PSObject.Properties.Remove('statusLine')
                Write-JsonDocumentAtomic $SettingsPath $SettingsDocument $SettingsSnapshot.Raw
            }
        }
    }
    if ($null -ne $ClaudeSnapshot) {
        $ClaudeDocument = $ClaudeSnapshot.Document
        $serversProperty = $ClaudeDocument.PSObject.Properties['mcpServers']
        if ($null -ne $serversProperty -and $null -ne $serversProperty.Value) {
            $qbraidProperty = $serversProperty.Value.PSObject.Properties['qbraid']
            if ($null -ne $qbraidProperty) {
                $serversProperty.Value.PSObject.Properties.Remove('qbraid')
                Write-JsonDocumentAtomic $ClaudePath $ClaudeDocument $ClaudeSnapshot.Raw
            }
        }
    }
}

function Stop-QbraidOwnedProcess {
    param([int]$ProcessId, [string]$ConfigPath, [string[]]$ExpectedExecutables)
    if (-not $ProcessId) { return }
    $running = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $running) { return }
    $record = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
    if (-not $record -or -not $record.CommandLine) { throw "cannot verify ownership of running process $ProcessId" }
    $configPattern = '(?i)(?:^|\s)-config\s+(?:"' + [regex]::Escape($ConfigPath) + '"|' + [regex]::Escape($ConfigPath) + ')(?:\s|$)'
    if ($record.CommandLine -notmatch $configPattern) { return }
    if (-not $record.ExecutablePath) { throw "cannot verify the executable for running process $ProcessId" }
    $executableMatches = $false
    foreach ($expected in $ExpectedExecutables) {
        if ($expected -and [StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetFullPath($record.ExecutablePath), [IO.Path]::GetFullPath($expected))) {
            $executableMatches = $true
            break
        }
    }
    if (-not $executableMatches) { throw "running process $ProcessId is not an owned qbraid-code proxy" }
    Stop-Process -Id $ProcessId -Force -ErrorAction Stop
    for ($attempt = 0; $attempt -lt 50 -and (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue); $attempt++) {
        Start-Sleep -Milliseconds 100
    }
    if (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue) { throw "could not stop owned proxy process $ProcessId" }
}

function Wait-QbraidMutex {
    param([Threading.Mutex]$Mutex)
    try { return $Mutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { return $true }
}

function Find-QbraidReparsePoint {
    param([string]$Root)
    $pending = New-Object Collections.Generic.Stack[string]
    $pending.Push($Root)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($item in @(Get-ChildItem $directory -Force -ErrorAction Stop)) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $item }
            if ($item.PSIsContainer) { $pending.Push($item.FullName) }
        }
    }
    return $null
}

function Remove-QbraidCredentialEntries {
    param([object]$Vault, [object[]]$Entries)
    foreach ($entry in $Entries) {
        if ([string]$entry.Resource -like 'qbraid-code:*') {
            try { $Vault.Remove($entry) } catch { throw "could not delete Credential Locker item '$($entry.Resource)'" }
        }
    }
}

function Invoke-QbraidUninstall {
    param([bool]$AssumeYes)
    $fullHome = [IO.Path]::GetFullPath($HomeDir).TrimEnd('\')
    $suppliedHome = [string]$HomeDir
    $suppliedHome = $suppliedHome.TrimEnd('\')
    $root = [IO.Path]::GetPathRoot($fullHome).TrimEnd('\')
    $userHome = [IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\')
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals($fullHome, $suppliedHome)) { throw 'installation path contains relative or dot segments; refusing uninstall' }
    if ([StringComparer]::OrdinalIgnoreCase.Equals($fullHome, $root) -or [StringComparer]::OrdinalIgnoreCase.Equals($fullHome, $userHome)) { throw "unsafe installation path '$HomeDir'" }
    if (Test-Path $fullHome) {
        $item = Get-Item $fullHome -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'installation path is a reparse point; remove it manually' }
        $managedReparsePoint = Find-QbraidReparsePoint $fullHome
        if ($null -ne $managedReparsePoint) { throw "refusing to traverse reparse point '$($managedReparsePoint.FullName)'" }
    }
    $bound = $false
    $hasSidecar = Test-Path $homeFile -PathType Leaf
    if ($hasSidecar) {
        $sidecarHome = [IO.Path]::GetFullPath((Get-Content $homeFile -Raw -Encoding UTF8).Trim()).TrimEnd('\')
        $bound = [StringComparer]::OrdinalIgnoreCase.Equals($sidecarHome, $fullHome)
        if (-not $bound) { throw 'installation is not bound by this launcher; refusing uninstall' }
    }
    $defaultHome = [IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.qbraid-code')).TrimEnd('\')
    if (-not $hasSidecar -and -not [StringComparer]::OrdinalIgnoreCase.Equals($fullHome, $defaultHome)) { throw 'custom installation is not bound by this launcher; refusing uninstall' }
    if ((Test-Path $fullHome -PathType Container) -and -not [StringComparer]::OrdinalIgnoreCase.Equals($fullHome, $defaultHome)) {
        $markerPath = Join-Path $fullHome '.qbraid-code-install'
        if (-not (Test-Path $markerPath -PathType Leaf) -or (Get-Content $markerPath -Raw -Encoding UTF8).Trim() -ne 'qbraid-code') {
            throw 'custom installation lacks its ownership marker. Re-run the installer before uninstalling.'
        }
    }

    if (-not $AssumeYes) {
        $reply = Read-Host 'Type uninstall to delete local qbraid-code profiles, keys, and files'
        if ($reply -cne 'uninstall') { throw 'uninstall cancelled' }
    }

    $installerMutex = New-Object Threading.Mutex($false, "Local\qbraid-code-installer-$($env:USERNAME)")
    $installerAcquired = $false
    $installHandle = $null
    $profileMutexes = New-Object Collections.Generic.List[object]
    $profileHandles = New-Object Collections.Generic.List[object]
    $uninstallMarker = Join-Path $fullHome '.uninstalling'
    try {
        $installerAcquired = Wait-QbraidMutex $installerMutex
        if (-not $installerAcquired) { throw 'another qbraid-code installer is running' }
        $installLock = Join-Path $fullHome '.install-lock'
        if (Test-Path $installLock -PathType Leaf) {
            try { $installHandle = [IO.File]::Open($installLock, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
            catch [IO.IOException] { throw 'another qbraid-code installer is running' }
        }
        if (Test-Path $fullHome) { [IO.File]::WriteAllText($uninstallMarker, [string]$PID, (New-Object Text.UTF8Encoding $false)) }

        $profileLockRoots = New-Object Collections.Generic.List[object]
        $profilesPath = Join-Path $fullHome 'profiles'
        foreach ($profileDirectory in @(Get-ChildItem $profilesPath -Directory -ErrorAction SilentlyContinue)) {
            if ($profileDirectory.Name -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$') {
                [void]$profileLockRoots.Add([pscustomobject]@{ Name = $profileDirectory.Name; Root = $profileDirectory.FullName })
            }
        }
        if (Test-Path (Join-Path $fullHome 'env')) {
            [void]$profileLockRoots.Add([pscustomobject]@{ Name = 'default'; Root = $fullHome })
        }
        foreach ($profileLockRoot in $profileLockRoots) {
            $mutex = New-Object Threading.Mutex($false, "Local\qbraid-code-profile-$($env:USERNAME)-$($profileLockRoot.Name)")
            if (-not (Wait-QbraidMutex $mutex)) { $mutex.Dispose(); throw "profile '$($profileLockRoot.Name)' is busy" }
            [void]$profileMutexes.Add($mutex)
            $updatePath = Join-Path $profileLockRoot.Root '.update-lock'
            try {
                $handle = [IO.File]::Open($updatePath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
                [void]$profileHandles.Add($handle)
            } catch [IO.IOException] { throw "profile '$($profileLockRoot.Name)' has a running session" }
            foreach ($lease in @(Get-ChildItem (Join-Path $profileLockRoot.Root 'session-users') -File -ErrorAction SilentlyContinue)) {
                $sessionPid = 0
                if ([int]::TryParse($lease.Name, [ref]$sessionPid) -and (Get-Process -Id $sessionPid -ErrorAction SilentlyContinue)) { throw "session process $sessionPid is still using this installation" }
            }
        }
        foreach ($session in @(Get-ChildItem $fullHome -Directory -Filter 'session.*' -ErrorAction SilentlyContinue)) {
            $sessionPid = Read-PidFile (Join-Path $session.FullName 'owner.pid')
            if ($sessionPid -and (Get-Process -Id $sessionPid -ErrorAction SilentlyContinue)) { throw "session process $sessionPid is still using this installation" }
        }

        $secretRecords = @(Get-QbraidSecretRecords)
        try {
            $vault = New-Object Windows.Security.Credentials.PasswordVault
            try { $vaultEntries = @($vault.RetrieveAll()) }
            catch { if ($_.Exception.HResult -eq -2147023728) { $vaultEntries = @() } else { throw } }
        } catch { throw 'Windows Credential Locker is unavailable; local keys were not removed' }
        $settingsPath = Join-Path (Join-Path $env:USERPROFILE '.claude') 'settings.json'
        $claudePath = Join-Path $env:USERPROFILE '.claude.json'
        $settingsSnapshot = Read-JsonSnapshot $settingsPath
        $claudeSnapshot = Read-JsonSnapshot $claudePath

        $proxyBinaries = @(Get-QbraidProxyBinaries)
        foreach ($runtime in @(Get-ChildItem $fullHome -Directory -Filter 'runtime.*' -ErrorAction SilentlyContinue)) {
            Stop-QbraidOwnedProcess (Read-PidFile (Join-Path $runtime.FullName 'proxy.pid')) (Join-Path $runtime.FullName 'proxy-config.yaml') @($proxyBinaries)
        }
        Stop-QbraidOwnedProcess (Read-PidFile (Join-Path $fullHome 'proxy.pid')) (Join-Path $fullHome 'proxy-config.yaml') @($proxyBinaries)

        Remove-QbraidClaudeIntegrations $settingsSnapshot $claudeSnapshot $settingsPath $claudePath
        Remove-QbraidCredentialEntries $vault @($vaultEntries)
        foreach ($record in $secretRecords) {
            if ($record.Backend -eq 'file' -and (Test-Path $record.Reference)) { Remove-Item $record.Reference -Force -ErrorAction Stop }
        }
        foreach ($handle in $profileHandles) { $handle.Dispose() }
        $profileHandles.Clear()
        if ($installHandle) { $installHandle.Dispose(); $installHandle = $null }
        if (Test-Path $fullHome) { Remove-Item $fullHome -Recurse -Force -ErrorAction Stop }
        if (Test-Path $fullHome) { throw "could not remove $fullHome" }
        Write-Output 'qbraid-code: local installation removed. qBraid account API keys were not revoked.'
    } finally {
        if (Test-Path $uninstallMarker) { Remove-Item $uninstallMarker -Force -ErrorAction SilentlyContinue }
        foreach ($handle in $profileHandles) { $handle.Dispose() }
        foreach ($mutex in $profileMutexes) { try { $mutex.ReleaseMutex() } catch { }; $mutex.Dispose() }
        if ($installHandle) { $installHandle.Dispose() }
        if ($installerAcquired) { try { $installerMutex.ReleaseMutex() } catch { } }
        $installerMutex.Dispose()
    }
}

if ($claudeArgs.Count -gt 0 -and $claudeArgs[0] -eq '--update-key') {
    if ($claudeArgs.Count -ne 1) { Write-Error '--update-key accepts no Claude arguments'; exit 1 }
    $selectedProfile = if ($profileOption) { $explicitProfile } elseif ($env:QBRAID_CODE_PROFILE) { $env:QBRAID_CODE_PROFILE } elseif (Test-Path (Join-Path $HomeDir 'active-profile')) { (Get-Content (Join-Path $HomeDir 'active-profile') -Raw).Trim() } else { 'default' }
    try { Invoke-QbraidKeyUpdate $selectedProfile } catch { Write-Error $_.Exception.Message; exit 1 }
    exit 0
}
if ($claudeArgs.Count -gt 0 -and $claudeArgs[0] -eq '--uninstall') {
    if ($profileOption) { Write-Error '--uninstall removes every profile; omit --profile'; exit 1 }
    $assumeYes = $claudeArgs.Count -eq 2 -and $claudeArgs[1] -eq '--yes'
    if ($claudeArgs.Count -gt 1 -and -not $assumeYes) { Write-Error '--uninstall accepts only --yes'; exit 1 }
    try { Invoke-QbraidUninstall $assumeYes } catch { Write-Error $_.Exception.Message; exit 1 }
    exit 0
}
if (Test-Path (Join-Path $HomeDir '.uninstalling')) { Write-Error 'qbraid-code is being uninstalled'; exit 1 }
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
        $owner = Read-PidFile (Join-Path $_.FullName 'owner.pid')
        if ($owner -and (Get-Process -Id $owner -ErrorAction SilentlyContinue)) { return }
        $pidPath = Join-Path $_.FullName 'proxy.pid'
        if (Test-Path $pidPath) {
            $runtimePid = Read-PidFile $pidPath
            Stop-QbraidOwnedProcess $runtimePid (Join-Path $_.FullName 'proxy-config.yaml') @(Get-QbraidProxyBinaries)
        }
        Remove-Item $_.FullName -Recurse -Force -ErrorAction Stop
    }
    Write-Output 'qbraid-code: orphaned local proxies stopped'
    exit 0
}
if ($claudeArgs.Count -gt 0 -and $claudeArgs[0] -eq '--doctor') {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $HomeDir 'doctor.ps1')
    exit $LASTEXITCODE
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
    Remove-Item (Join-Path $profileDir 'key-status') -Force -ErrorAction SilentlyContinue
    if ($null -ne $balance.data.qbraidCredits) {
        [IO.File]::WriteAllText((Join-Path $profileDir 'credits.cache'), [string]$balance.data.qbraidCredits, (New-Object Text.UTF8Encoding $false))
        [IO.File]::WriteAllText((Join-Path $profileDir 'credits.updated'), [string][DateTimeOffset]::UtcNow.ToUnixTimeSeconds(), (New-Object Text.UTF8Encoding $false))
    }
} catch {
    $statusCode = $null
    try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { }
    if ($statusCode -eq 401 -or $statusCode -eq 403) {
        [IO.File]::WriteAllText((Join-Path $profileDir 'key-status'), 'expired', (New-Object Text.UTF8Encoding $false))
    }
}
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
            Stop-QbraidOwnedProcess $orphanPid (Join-Path $_.FullName 'proxy-config.yaml') @(Get-QbraidProxyBinaries)
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
$env:QBRAID_CODE_RUNTIME_PROXY_BIN = $proxyBin
$env:QBRAID_CODE_RUNTIME_PORT = [string]$runtimePort
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $HomeDir 'qbraid-proxy.ps1') ensure
if ($LASTEXITCODE -ne 0) {
    if (-not (Test-Path (Join-Path $runtimeDir 'proxy.pid'))) { Remove-Item $runtimeDir, $portLock -Recurse -Force -ErrorAction SilentlyContinue }
    exit 1
}
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
    $proxyCleanupFailed = $false
    if ($proxyAcquired) {
        $env:QBRAID_CODE_RUNTIME_CONFIG = $runtimeConfig
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $HomeDir 'qbraid-proxy.ps1') stop *> $null
        $proxyCleanupFailed = $LASTEXITCODE -ne 0
    }
    Remove-Item (Join-Path $profileRoot "session-users\$PID") -Force -ErrorAction SilentlyContinue
    Remove-Item $sessionDir -Recurse -Force -ErrorAction SilentlyContinue
    if (-not $proxyCleanupFailed) { Remove-Item $runtimeDir, $portLock -Recurse -Force -ErrorAction SilentlyContinue }
    if ($proxyCleanupFailed) { throw "cannot verify or stop the launch-owned proxy; runtime state remains at $runtimeDir" }
    throw "cannot protect the session snapshot at $sessionDir"
}
foreach ($name in @('label','label-source','organization-id','credits.cache','credits.updated','key-status')) { $source = Join-Path $profileDir $name; if (Test-Path $source) { Copy-Item $source (Join-Path $sessionDir $name) } }
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
    $proxyCleanupFailed = $false
    if ($proxyAcquired) {
        $env:QBRAID_CODE_RUNTIME_CONFIG = $runtimeConfig
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $HomeDir 'qbraid-proxy.ps1') stop *> $null
        $proxyCleanupFailed = $LASTEXITCODE -ne 0
    }
    if (-not $proxyCleanupFailed) {
        if ($runtimeDir) { Remove-Item $runtimeDir -Recurse -Force -ErrorAction SilentlyContinue }
        if ($portLock) { Remove-Item $portLock -Recurse -Force -ErrorAction SilentlyContinue }
    }
    if ($sessionLeaseHandle) { $sessionLeaseHandle.Dispose() }
    Remove-Item (Join-Path $profileRoot "session-users\$PID") -Force -ErrorAction SilentlyContinue
    Remove-Item $sessionDir -Recurse -Force -ErrorAction SilentlyContinue
    $sessionMutex.Dispose()
    if ($proxyCleanupFailed) { throw "cannot verify or stop the launch-owned proxy; runtime state remains at $runtimeDir" }
}
exit $rc
