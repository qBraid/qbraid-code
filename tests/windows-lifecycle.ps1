Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$tmp = Join-Path $PSScriptRoot ('.qbraid-lifecycle-' + [guid]::NewGuid().ToString('N'))
$originalUserProfile = $env:USERPROFILE
$originalHome = $env:QBRAID_CODE_HOME
$pass = 0
$fail = 0
$vault = $null
$credentialResource = ''
$invalidCredentialResource = ''
$null = [Windows.Security.Credentials.PasswordVault,Windows.Security.Credentials,ContentType=WindowsRuntime]
$null = [Windows.Security.Credentials.PasswordCredential,Windows.Security.Credentials,ContentType=WindowsRuntime]

function Pass([string]$Name) { $script:pass++; Write-Output "  ok   $Name" }
function Fail([string]$Name) { $script:fail++; Write-Output "  FAIL $Name" }
function Write-Utf8([string]$Path, [string]$Value) { [IO.File]::WriteAllText($Path, $Value, (New-Object Text.UTF8Encoding $false)) }
function Invoke-ChildPowerShell([string]$ScriptPath, [string[]]$ArgumentList = @()) {
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $script:LastChildOutput = (& powershell -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @ArgumentList 2>&1 | Out-String)
        return [int]$LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
}
function New-Profile([string]$HomeDir, [string]$Backend, [string]$Reference) {
    $generation = Join-Path $HomeDir 'profiles\alpha\generations\g1'
    New-Item -ItemType Directory -Force -Path $generation | Out-Null
    Write-Utf8 (Join-Path $HomeDir 'profiles\alpha\current') "g1`n"
    Write-Utf8 (Join-Path $generation 'env') "QBRAID_CODE_SECRET_BACKEND=$Backend`nQBRAID_CODE_SECRET_REF=$Reference`n"
}

try {
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null

    $helpHome = Join-Path $tmp 'help-home'
    $env:USERPROFILE = $helpHome
    $env:QBRAID_CODE_HOME = Join-Path $helpHome 'missing-install'
    $help = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'qbraid-launch.ps1') --help 6>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -and -not (Test-Path $env:QBRAID_CODE_HOME) -and $help.Contains('--profiles') -and $help.Contains('--use-profile') -and
        $help.Contains('--allow-profile-resume') -and $help.Contains('--update-key') -and $help.Contains('--doctor') -and
        $help.Contains('--stop') -and $help.Contains('--uninstall') -and $help.Contains('claude --help')) {
        Pass 'offline help lists every lifecycle command'
    } else { Fail 'offline help lists every lifecycle command' }

    $launcherSource = Get-Content (Join-Path $root 'qbraid-launch.ps1') -Raw
    $jsonStart = $launcherSource.IndexOf('function Repair-QbraidJsonArtifacts')
    $jsonEnd = $launcherSource.IndexOf('function Remove-QbraidClaudeIntegrations')
    Invoke-Expression $launcherSource.Substring($jsonStart, $jsonEnd - $jsonStart)
    $credentialStart = $launcherSource.IndexOf('function Remove-QbraidCredentialEntries')
    $credentialEnd = $launcherSource.IndexOf('function Invoke-QbraidUninstall')
    Invoke-Expression $launcherSource.Substring($credentialStart, $credentialEnd - $credentialStart)
    $failingVault = New-Object psobject
    $failingVault | Add-Member ScriptMethod Remove { param($entry); throw 'simulated store failure' }
    $credentialFailureRejected = $false
    try { Remove-QbraidCredentialEntries $failingVault @([pscustomobject]@{ Resource = 'qbraid-code:test-failure' }) }
    catch { $credentialFailureRejected = $_.Exception.Message -like '*could not delete Credential Locker item*' }
    if ($credentialFailureRejected) { Pass 'Credential Locker deletion failures abort cleanup' }
    else { Fail 'Credential Locker deletion failures abort cleanup' }

    $casPath = Join-Path $tmp 'cas-settings.json'
    Write-Utf8 $casPath '{"before":1}'
    $casSnapshot = Read-JsonSnapshot $casPath
    Write-Utf8 $casPath '{"newer":2}'
    $casRejected = $false
    try { Write-JsonDocumentAtomic $casPath ([pscustomobject]@{ after = 3 }) $casSnapshot.Raw } catch { $casRejected = $true }
    if ($casRejected -and (Get-Content $casPath -Raw) -eq '{"newer":2}') { Pass 'Windows JSON replacement rejects a concurrent update' }
    else { Fail 'Windows JSON replacement rejects a concurrent update' }

    $proxyProgram = 'using System; using System.Threading; public static class ProxyFixture { public static void Main(string[] args) { Thread.Sleep(600000); } }'
    $ownedProxyFixture = Join-Path $tmp 'owned-proxy.exe'
    $unownedProxyFixture = Join-Path $tmp 'unowned-proxy.exe'
    Add-Type -TypeDefinition $proxyProgram -Language CSharp -OutputAssembly $ownedProxyFixture -OutputType ConsoleApplication
    Copy-Item $ownedProxyFixture $unownedProxyFixture

    $proxyStopRuntime = Join-Path $tmp 'proxy-stop-runtime'
    New-Item -ItemType Directory -Force -Path $proxyStopRuntime | Out-Null
    $proxyStopConfig = Join-Path $proxyStopRuntime 'proxy-config.yaml'
    Write-Utf8 $proxyStopConfig "port: 8320`n"
    $env:QBRAID_CODE_RUNTIME_CONFIG = $proxyStopConfig
    $env:QBRAID_CODE_RUNTIME_PROXY_BIN = $ownedProxyFixture
    $unownedStopProcess = Start-Process $unownedProxyFixture -ArgumentList @('-config', "`"$proxyStopConfig`"") -PassThru
    Write-Utf8 (Join-Path $proxyStopRuntime 'proxy.pid') ([string]$unownedStopProcess.Id)
    $unownedStopExit = Invoke-ChildPowerShell (Join-Path $root 'qbraid-proxy.ps1') @('stop')
    $unownedStopProcess.Refresh()
    if ($unownedStopExit -ne 0 -and -not $unownedStopProcess.HasExited -and (Test-Path (Join-Path $proxyStopRuntime 'proxy.pid'))) {
        Pass 'session cleanup refuses an unowned executable using its runtime config'
    } else { Fail 'session cleanup refuses an unowned executable using its runtime config' }
    if (-not $unownedStopProcess.HasExited) { Stop-Process -Id $unownedStopProcess.Id -Force }

    $ownedStopProcess = Start-Process $ownedProxyFixture -ArgumentList @('-config', "`"$proxyStopConfig`"") -PassThru
    Write-Utf8 (Join-Path $proxyStopRuntime 'proxy.pid') ([string]$ownedStopProcess.Id)
    $ownedStopExit = Invoke-ChildPowerShell (Join-Path $root 'qbraid-proxy.ps1') @('stop')
    $ownedStopProcess.Refresh()
    if ($ownedStopExit -eq 0 -and $ownedStopProcess.HasExited -and -not (Test-Path (Join-Path $proxyStopRuntime 'proxy.pid'))) {
        Pass 'session cleanup stops only its exact owned proxy executable'
    } else { Fail 'session cleanup stops only its exact owned proxy executable' }
    Remove-Item Env:QBRAID_CODE_RUNTIME_CONFIG, Env:QBRAID_CODE_RUNTIME_PROXY_BIN -ErrorAction SilentlyContinue

    $ownedProcessUser = Join-Path $tmp 'owned-process-user'
    $ownedProcessHome = Join-Path $ownedProcessUser '.qbraid-code'
    $ownedSecret = Join-Path $ownedProcessHome 'secrets\alpha'
    New-Profile $ownedProcessHome 'file' $ownedSecret
    New-Item -ItemType Directory -Force -Path (Split-Path $ownedSecret -Parent) | Out-Null
    Write-Utf8 $ownedSecret 'owned-process-secret'
    Copy-Item $ownedProxyFixture (Join-Path $ownedProcessHome 'cliproxyapi.exe')
    $ownedRuntime = Join-Path $ownedProcessHome 'runtime.alpha.test'
    New-Item -ItemType Directory -Force -Path $ownedRuntime | Out-Null
    $ownedConfig = Join-Path $ownedRuntime 'proxy-config.yaml'
    Write-Utf8 $ownedConfig "port: 8320`n"
    $ownedProxyProcess = Start-Process (Join-Path $ownedProcessHome 'cliproxyapi.exe') -ArgumentList @('-config', "`"$ownedConfig`"") -PassThru
    Write-Utf8 (Join-Path $ownedRuntime 'proxy.pid') ([string]$ownedProxyProcess.Id)
    Write-Utf8 (Join-Path $ownedRuntime 'owner.pid') ([string]$PID)
    $env:USERPROFILE = $ownedProcessUser
    $env:QBRAID_CODE_HOME = $ownedProcessHome
    $liveStopExit = Invoke-ChildPowerShell (Join-Path $root 'qbraid-launch.ps1') @('--profile', 'alpha', '--stop')
    $ownedProxyProcess.Refresh()
    if ($liveStopExit -eq 0 -and -not $ownedProxyProcess.HasExited) { Pass '--stop preserves proxies owned by live Windows sessions' }
    else { Fail '--stop preserves proxies owned by live Windows sessions' }
    Write-Utf8 (Join-Path $ownedRuntime 'owner.pid') '99999996'
    $orphanStopExit = Invoke-ChildPowerShell (Join-Path $root 'qbraid-launch.ps1') @('--profile', 'alpha', '--stop')
    $ownedProxyProcess.Refresh()
    if ($orphanStopExit -eq 0 -and $ownedProxyProcess.HasExited -and -not (Test-Path $ownedRuntime)) { Pass '--stop removes verified orphaned Windows proxies' }
    else { Fail '--stop removes verified orphaned Windows proxies'; Write-Output $script:LastChildOutput }

    New-Item -ItemType Directory -Force -Path $ownedRuntime | Out-Null
    Write-Utf8 $ownedConfig "port: 8320`n"
    $ownedProxyProcess = Start-Process (Join-Path $ownedProcessHome 'cliproxyapi.exe') -ArgumentList @('-config', "`"$ownedConfig`"") -PassThru
    Write-Utf8 (Join-Path $ownedRuntime 'proxy.pid') ([string]$ownedProxyProcess.Id)
    $ownedProcessExit = Invoke-ChildPowerShell (Join-Path $root 'qbraid-launch.ps1') @('--uninstall', '--yes')
    $ownedProxyProcess.Refresh()
    if ($ownedProcessExit -eq 0 -and $ownedProxyProcess.HasExited -and -not (Test-Path $ownedProcessHome)) {
        Pass 'uninstall stops only an owned proxy executable with its exact config'
    } else { Fail 'uninstall stops only an owned proxy executable with its exact config'; Write-Output $script:LastChildOutput }

    $unownedProcessUser = Join-Path $tmp 'unowned-process-user'
    $unownedProcessHome = Join-Path $unownedProcessUser '.qbraid-code'
    $unownedSecret = Join-Path $unownedProcessHome 'secrets\alpha'
    New-Profile $unownedProcessHome 'file' $unownedSecret
    New-Item -ItemType Directory -Force -Path (Split-Path $unownedSecret -Parent) | Out-Null
    Write-Utf8 $unownedSecret 'unowned-process-secret'
    Copy-Item $ownedProxyFixture (Join-Path $unownedProcessHome 'cliproxyapi.exe')
    $unownedRuntime = Join-Path $unownedProcessHome 'runtime.alpha.test'
    New-Item -ItemType Directory -Force -Path $unownedRuntime | Out-Null
    $unownedConfig = Join-Path $unownedRuntime 'proxy-config.yaml'
    Write-Utf8 $unownedConfig "port: 8321`n"
    $unownedProxyProcess = Start-Process $unownedProxyFixture -ArgumentList @('-config', "`"$unownedConfig`"") -PassThru
    Write-Utf8 (Join-Path $unownedRuntime 'proxy.pid') ([string]$unownedProxyProcess.Id)
    $env:USERPROFILE = $unownedProcessUser
    $env:QBRAID_CODE_HOME = $unownedProcessHome
    $unownedProcessExit = Invoke-ChildPowerShell (Join-Path $root 'qbraid-launch.ps1') @('--uninstall', '--yes')
    $unownedProxyProcess.Refresh()
    if ($unownedProcessExit -ne 0 -and -not $unownedProxyProcess.HasExited -and (Test-Path $unownedSecret)) {
        Pass 'uninstall refuses a reused PID owned by another executable'
    } else { Fail 'uninstall refuses a reused PID owned by another executable' }
    if (-not $unownedProxyProcess.HasExited) { Stop-Process -Id $unownedProxyProcess.Id -Force }

    $interruptedJson = Join-Path $tmp 'interrupted-settings.json'
    Write-Utf8 $interruptedJson '{"owned":true}'
    Move-Item $interruptedJson "$interruptedJson.qbraid-code-uninstall.backup"
    $interruptedRejected = $false
    try { $null = Read-JsonSnapshot $interruptedJson } catch { $interruptedRejected = $true }
    if ($interruptedRejected -and (Get-Content $interruptedJson -Raw) -eq '{"owned":true}') {
        Pass 'interrupted Windows JSON replacement restores before cleanup'
    } else { Fail 'interrupted Windows JSON replacement restores before cleanup' }

    $installedJson = Join-Path $tmp 'installed-settings.json'
    Write-Utf8 $installedJson '{"new":true}'
    Write-Utf8 "$installedJson.qbraid-code-uninstall.backup" '{"old":true}'
    $installedRejected = $false
    try { $null = Read-JsonSnapshot $installedJson } catch { $installedRejected = $true }
    if ($installedRejected -and (Get-Content $installedJson -Raw) -eq '{"new":true}' -and -not (Test-Path "$installedJson.qbraid-code-uninstall.backup")) {
        Pass 'completed Windows JSON install cleans its crash backup before retry'
    } else { Fail 'completed Windows JSON install cleans its crash backup before retry' }

    $orphanJson = Join-Path $tmp 'orphan-settings.json'
    $orphanTemporary = Join-Path $tmp '.qbraid-code-uninstall-orphan.tmp'
    Write-Utf8 $orphanJson '{"current":true}'
    Write-Utf8 $orphanTemporary '{"secret":"temporary"}'
    $orphanRejected = $false
    try { $null = Read-JsonSnapshot $orphanJson } catch { $orphanRejected = $true }
    if ($orphanRejected -and -not (Test-Path $orphanTemporary) -and (Get-Content $orphanJson -Raw) -eq '{"current":true}') {
        Pass 'orphaned Windows JSON temporaries are removed before retry'
    } else { Fail 'orphaned Windows JSON temporaries are removed before retry' }

    $updateProfile = Join-Path $tmp 'update-user'
    $updateHome = Join-Path $updateProfile '.qbraid-code'
    New-Profile $updateHome 'unavailable-old-store' 'expired'
    Write-Utf8 (Join-Path $updateHome 'active-profile') "alpha`n"
    $updateWrapper = Join-Path $tmp 'update-wrapper.ps1'
    Write-Utf8 $updateWrapper @'
function global:Invoke-RestMethod {
    param([string]$Uri)
    [IO.File]::WriteAllText($env:UPDATE_URL_CAPTURE, $Uri)
    return 'param([string]$Profile, [switch]$UpdateKey); [IO.File]::WriteAllText($env:UPDATE_PROFILE_CAPTURE, ($Profile + ''|'' + $UpdateKey.IsPresent + ''|'' + $env:QBRAID_CODE_HOME + ''|'' + $env:QBRAID_CODE_BIN_DIR))'
}
& $env:UPDATE_LAUNCHER --update-key
'@
    $env:USERPROFILE = $updateProfile
    $env:QBRAID_CODE_HOME = $updateHome
    $env:UPDATE_LAUNCHER = Join-Path $root 'qbraid-launch.ps1'
    $env:UPDATE_URL_CAPTURE = Join-Path $tmp 'update-url'
    $env:UPDATE_PROFILE_CAPTURE = Join-Path $tmp 'update-profile'
    $updateExit = Invoke-ChildPowerShell $updateWrapper
    if ($updateExit -eq 0 -and (Get-Content $env:UPDATE_URL_CAPTURE -Raw) -eq 'https://qbraid.com/code.ps1' -and
        (Get-Content $env:UPDATE_PROFILE_CAPTURE -Raw) -eq ("alpha|True|$updateHome|$root")) {
        Pass 'update-key uses the active profile and official installer without the old key'
    } else { Fail 'update-key uses the active profile and official installer without the old key' }

    $customProfile = Join-Path $tmp 'custom-sidecar-user'
    $customHome = Join-Path $tmp 'custom-sidecar-root'
    $customBin = Join-Path $tmp 'custom-sidecar-bin'
    New-Item -ItemType Directory -Force -Path $customProfile, $customBin | Out-Null
    New-Profile $customHome 'file' (Join-Path $customHome 'secrets\alpha')
    New-Item -ItemType Directory -Force -Path (Join-Path $customHome 'secrets') | Out-Null
    Write-Utf8 (Join-Path $customHome 'secrets\alpha') 'local-secret'
    Write-Utf8 (Join-Path $customHome '.qbraid-code-install') "qbraid-code`n"
    Write-Utf8 (Join-Path $customHome 'active-profile') "alpha`n"
    Copy-Item (Join-Path $root 'qbraid-launch.ps1') (Join-Path $customBin 'qbraid-launch.ps1')
    Write-Utf8 (Join-Path $customBin 'qbraid-code.home') "$customHome`n"
    $customUpdateWrapper = Join-Path $tmp 'custom-update-wrapper.ps1'
    Write-Utf8 $customUpdateWrapper @'
function global:Invoke-RestMethod {
    param([string]$Uri)
    return 'param([string]$Profile, [switch]$UpdateKey); [IO.File]::WriteAllText($env:CUSTOM_UPDATE_CAPTURE, ($env:QBRAID_CODE_HOME + ''|'' + $env:QBRAID_CODE_BIN_DIR))'
}
Remove-Item Env:QBRAID_CODE_HOME, Env:QBRAID_CODE_BIN_DIR -ErrorAction SilentlyContinue
& $env:CUSTOM_UPDATE_LAUNCHER --update-key
'@
    $env:USERPROFILE = $customProfile
    Remove-Item Env:QBRAID_CODE_HOME, Env:QBRAID_CODE_BIN_DIR -ErrorAction SilentlyContinue
    $env:CUSTOM_UPDATE_CAPTURE = Join-Path $tmp 'custom-update-binding'
    $env:CUSTOM_UPDATE_LAUNCHER = Join-Path $customBin 'qbraid-launch.ps1'
    $customUpdateExit = Invoke-ChildPowerShell $customUpdateWrapper
    if ($customUpdateExit -eq 0 -and (Get-Content $env:CUSTOM_UPDATE_CAPTURE -Raw) -eq "$customHome|$customBin") {
        Pass 'custom sidecar binds key rotation without environment overrides'
    } else { Fail 'custom sidecar binds key rotation without environment overrides' }

    $offlineUninstallWrapper = Join-Path $tmp 'offline-uninstall-wrapper.ps1'
    Write-Utf8 $offlineUninstallWrapper @'
function global:Invoke-RestMethod { throw 'network access during uninstall' }
function global:Invoke-WebRequest { throw 'network access during uninstall' }
Remove-Item Env:QBRAID_CODE_HOME, Env:QBRAID_CODE_BIN_DIR -ErrorAction SilentlyContinue
& $env:OFFLINE_UNINSTALL_LAUNCHER --uninstall --yes
'@
    $env:OFFLINE_UNINSTALL_LAUNCHER = Join-Path $customBin 'qbraid-launch.ps1'
    $offlineUninstallExit = Invoke-ChildPowerShell $offlineUninstallWrapper
    if ($offlineUninstallExit -eq 0 -and -not (Test-Path $customHome)) {
        Pass 'custom sidecar uninstall is local and needs no environment override'
    } else { Fail 'custom sidecar uninstall is local and needs no environment override'; Write-Output $script:LastChildOutput }

    $invalidProfile = Join-Path $tmp 'invalid-json-user'
    $invalidHome = Join-Path $invalidProfile '.qbraid-code'
    $invalidBin = Join-Path $invalidProfile '.local\bin'
    $invalidCredentialResource = 'qbraid-code:invalid-json-' + [guid]::NewGuid().ToString('N')
    New-Item -ItemType Directory -Force -Path $invalidBin, (Join-Path $invalidProfile '.claude') | Out-Null
    New-Profile $invalidHome 'credential-locker' $invalidCredentialResource
    Copy-Item (Join-Path $root 'qbraid-launch.ps1') (Join-Path $invalidBin 'qbraid-launch.ps1')
    Write-Utf8 (Join-Path $invalidBin 'qbraid-code.home') "$invalidHome`n"
    Write-Utf8 (Join-Path $invalidProfile '.claude\settings.json') '{not-json'
    $vault = New-Object Windows.Security.Credentials.PasswordVault
    $invalidCredential = New-Object Windows.Security.Credentials.PasswordCredential -ArgumentList $invalidCredentialResource, $env:USERNAME, 'local-secret'
    $vault.Add($invalidCredential)
    $env:USERPROFILE = $invalidProfile
    $env:QBRAID_CODE_HOME = $invalidHome
    $invalidExit = Invoke-ChildPowerShell (Join-Path $invalidBin 'qbraid-launch.ps1') @('--uninstall', '--yes')
    $invalidCredentialStillPresent = $false
    try { $null = $vault.Retrieve($invalidCredentialResource, $env:USERNAME); $invalidCredentialStillPresent = $true } catch { }
    if ($invalidExit -ne 0 -and $invalidCredentialStillPresent -and (Test-Path $invalidHome)) {
        Pass 'invalid Windows Claude JSON fails before credential deletion'
    } else { Fail 'invalid Windows Claude JSON fails before credential deletion' }

    $userProfile = Join-Path $tmp 'user profile with space'
    $homeDir = Join-Path $userProfile '.qbraid-code'
    $binDir = Join-Path $userProfile '.local\bin'
    New-Item -ItemType Directory -Force -Path $binDir, (Join-Path $userProfile '.claude') | Out-Null
    Copy-Item (Join-Path $root 'qbraid-launch.ps1') (Join-Path $binDir 'qbraid-launch.ps1')
    Copy-Item (Join-Path $root 'qbraid-code.cmd') (Join-Path $binDir 'qbraid-code.cmd')
    Write-Utf8 (Join-Path $binDir 'qbraid-code.home') "$homeDir`n"

    $credentialResource = 'qbraid-code:lifecycle-' + [guid]::NewGuid().ToString('N') + ':g1'
    New-Profile $homeDir 'credential-locker' $credentialResource
    Write-Utf8 (Join-Path $homeDir 'statusline.ps1') "Write-Output 'status'`n"
    $credential = New-Object Windows.Security.Credentials.PasswordCredential -ArgumentList $credentialResource, $env:USERNAME, 'local-test-secret'
    $vault.Add($credential)

    $settingsPath = Join-Path $userProfile '.claude\settings.json'
    $claudePath = Join-Path $userProfile '.claude.json'
    $statusCommand = 'powershell -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $homeDir 'statusline.ps1') + '"'
    Write-Utf8 $settingsPath (@{ statusLine = @{ type = 'command'; command = $statusCommand }; theme = 'dark' } | ConvertTo-Json -Depth 10)
    Write-Utf8 $claudePath (@{ mcpServers = @{ qbraid = @{ type = 'http' }; keep = @{ type = 'stdio' } }; other = 1 } | ConvertTo-Json -Depth 10)

    $env:USERPROFILE = $userProfile
    $env:QBRAID_CODE_HOME = $homeDir
    $cmdPath = Join-Path $binDir 'qbraid-code.cmd'
    Push-Location $binDir
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & cmd.exe /d /c qbraid-code.cmd --uninstall --yes 2>&1 | Out-String
        $uninstallExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
        Pop-Location
    }
    if ($uninstallExit -eq 0 -and -not (Test-Path $homeDir) -and -not (Test-Path $cmdPath) -and
        -not (Test-Path (Join-Path $binDir 'qbraid-launch.ps1')) -and -not (Test-Path (Join-Path $binDir 'qbraid-code.home'))) {
        Pass 'uninstall removes the Windows installation and launchers'
    } else { Fail "uninstall removes the Windows installation and launchers: $output" }

    $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
    $claude = Get-Content $claudePath -Raw | ConvertFrom-Json
    if ($null -eq $settings.PSObject.Properties['statusLine'] -and $settings.theme -eq 'dark' -and
        $null -eq $claude.mcpServers.PSObject.Properties['qbraid'] -and $null -ne $claude.mcpServers.PSObject.Properties['keep'] -and $claude.other -eq 1) {
        Pass 'uninstall preserves unrelated Claude settings and MCP servers'
    } else { Fail 'uninstall preserves unrelated Claude settings and MCP servers' }
    try { $null = $vault.Retrieve($credentialResource, $env:USERNAME); Fail 'uninstall deletes Credential Locker secrets' }
    catch { Pass 'uninstall deletes Credential Locker secrets' }
    if ($output.Contains('were not revoked')) { Pass 'uninstall states the upstream-key boundary' } else { Fail 'uninstall states the upstream-key boundary' }

    $unsafeProfile = Join-Path $tmp 'unsafe-user'
    $unsafeHome = Join-Path $unsafeProfile '.qbraid-code'
    $unsafeBin = Join-Path $unsafeProfile '.local\bin'
    $outside = Join-Path $unsafeProfile 'outside-key'
    New-Item -ItemType Directory -Force -Path $unsafeBin | Out-Null
    Write-Utf8 $outside 'keep'
    New-Profile $unsafeHome 'file' (Join-Path $unsafeHome 'secrets\..\..\outside-key')
    Copy-Item (Join-Path $root 'qbraid-launch.ps1') (Join-Path $unsafeBin 'qbraid-launch.ps1')
    Write-Utf8 (Join-Path $unsafeBin 'qbraid-code.home') "$unsafeHome`n"
    $env:USERPROFILE = $unsafeProfile
    $env:QBRAID_CODE_HOME = $unsafeHome
    $unsafeExit = Invoke-ChildPowerShell (Join-Path $unsafeBin 'qbraid-launch.ps1') @('--uninstall', '--yes')
    if ($unsafeExit -ne 0 -and (Test-Path $outside) -and (Test-Path $unsafeHome)) { Pass 'uninstall rejects unsafe secret paths without deleting state' }
    else { Fail 'uninstall rejects unsafe secret paths without deleting state' }

    $linkedProfile = Join-Path $tmp 'linked-user'
    $linkedHome = Join-Path $linkedProfile '.qbraid-code'
    $linkedOutside = Join-Path $linkedProfile 'outside-directory'
    New-Item -ItemType Directory -Force -Path $linkedHome, $linkedOutside | Out-Null
    Write-Utf8 (Join-Path $linkedOutside 'keep') 'keep'
    New-Item -ItemType Junction -Path (Join-Path $linkedHome 'linked-outside') -Target $linkedOutside | Out-Null
    $env:USERPROFILE = $linkedProfile
    $env:QBRAID_CODE_HOME = $linkedHome
    $linkedExit = Invoke-ChildPowerShell (Join-Path $root 'qbraid-launch.ps1') @('--uninstall', '--yes')
    if ($linkedExit -ne 0 -and (Test-Path (Join-Path $linkedOutside 'keep')) -and (Test-Path $linkedHome)) {
        Pass 'uninstall rejects managed reparse points without touching targets'
    } else { Fail 'uninstall rejects managed reparse points without touching targets' }

    $liveProfile = Join-Path $tmp 'live-user'
    $liveHome = Join-Path $liveProfile '.qbraid-code'
    $liveBin = Join-Path $liveProfile '.local\bin'
    New-Item -ItemType Directory -Force -Path $liveBin | Out-Null
    New-Profile $liveHome 'credential-locker' ('qbraid-code:absent-' + [guid]::NewGuid().ToString('N'))
    $leases = Join-Path $liveHome 'profiles\alpha\session-users'
    New-Item -ItemType Directory -Force -Path $leases | Out-Null
    Write-Utf8 (Join-Path $leases ([string]$PID)) ''
    Copy-Item (Join-Path $root 'qbraid-launch.ps1') (Join-Path $liveBin 'qbraid-launch.ps1')
    Write-Utf8 (Join-Path $liveBin 'qbraid-code.home') "$liveHome`n"
    $env:USERPROFILE = $liveProfile
    $env:QBRAID_CODE_HOME = $liveHome
    $liveExit = Invoke-ChildPowerShell (Join-Path $liveBin 'qbraid-launch.ps1') @('--uninstall', '--yes')
    if ($liveExit -ne 0 -and (Test-Path $liveHome)) { Pass 'uninstall refuses a live session' } else { Fail 'uninstall refuses a live session' }

    $legacyProfile = Join-Path $tmp 'legacy-live-user'
    $legacyHome = Join-Path $legacyProfile '.qbraid-code'
    $legacyBin = Join-Path $legacyProfile '.local\bin'
    New-Item -ItemType Directory -Force -Path (Join-Path $legacyHome 'session-users'), $legacyBin | Out-Null
    Write-Utf8 (Join-Path $legacyHome 'env') "QBRAID_CODE_SECRET_BACKEND=file`nQBRAID_CODE_SECRET_REF=$legacyHome\secrets\legacy`n"
    Write-Utf8 (Join-Path (Join-Path $legacyHome 'session-users') ([string]$PID)) ''
    Copy-Item (Join-Path $root 'qbraid-launch.ps1') (Join-Path $legacyBin 'qbraid-launch.ps1')
    Write-Utf8 (Join-Path $legacyBin 'qbraid-code.home') "$legacyHome`n"
    $env:USERPROFILE = $legacyProfile
    $env:QBRAID_CODE_HOME = $legacyHome
    $legacyExit = Invoke-ChildPowerShell (Join-Path $legacyBin 'qbraid-launch.ps1') @('--uninstall', '--yes')
    if ($legacyExit -ne 0 -and (Test-Path $legacyHome)) { Pass 'uninstall refuses a live flat-profile session' } else { Fail 'uninstall refuses a live flat-profile session' }

    $mismatchProfile = Join-Path $tmp 'sidecar-mismatch-user'
    $mismatchDefault = Join-Path $mismatchProfile '.qbraid-code'
    $mismatchCustom = Join-Path $tmp 'sidecar-custom-root'
    $mismatchBin = Join-Path $mismatchProfile '.local\bin'
    New-Item -ItemType Directory -Force -Path $mismatchDefault, $mismatchCustom, $mismatchBin | Out-Null
    Write-Utf8 (Join-Path $mismatchDefault 'keep') 'default'
    Write-Utf8 (Join-Path $mismatchCustom '.qbraid-code-install') "qbraid-code`n"
    Write-Utf8 (Join-Path $mismatchCustom 'keep') 'custom'
    Copy-Item (Join-Path $root 'qbraid-launch.ps1') (Join-Path $mismatchBin 'qbraid-launch.ps1')
    Write-Utf8 (Join-Path $mismatchBin 'qbraid-code.home') "$mismatchCustom`n"
    $env:USERPROFILE = $mismatchProfile
    $env:QBRAID_CODE_HOME = $mismatchDefault
    $mismatchExit = Invoke-ChildPowerShell (Join-Path $mismatchBin 'qbraid-launch.ps1') @('--uninstall', '--yes')
    if ($mismatchExit -ne 0 -and (Test-Path (Join-Path $mismatchDefault 'keep')) -and (Test-Path (Join-Path $mismatchCustom 'keep'))) {
        Pass 'launcher sidecar cannot authorize an environment-selected installation'
    } else { Fail 'launcher sidecar mismatch deleted an installation' }

    $mutexProfile = Join-Path $tmp 'mutex-user'
    $mutexHome = Join-Path $mutexProfile '.qbraid-code'
    New-Item -ItemType Directory -Force -Path $mutexHome | Out-Null
    Write-Utf8 (Join-Path $mutexHome 'keep') 'keep'
    $heldMutex = New-Object Threading.Mutex($false, "Local\qbraid-code-installer-$($env:USERNAME)")
    $held = $heldMutex.WaitOne(0)
    try {
        $env:USERPROFILE = $mutexProfile
        $env:QBRAID_CODE_HOME = $mutexHome
        $mutexExit = Invoke-ChildPowerShell (Join-Path $root 'qbraid-launch.ps1') @('--uninstall', '--yes')
        if ($mutexExit -ne 0 -and (Test-Path (Join-Path $mutexHome 'keep'))) { Pass 'uninstall refuses an active Windows installer mutex' }
        else { Fail 'uninstall refuses an active Windows installer mutex' }
    } finally {
        if ($held) { $heldMutex.ReleaseMutex() }
        $heldMutex.Dispose()
    }

    $absentCustomProfile = Join-Path $tmp 'absent-custom-user'
    $absentCustomRoot = Join-Path $tmp 'absent-custom-root'
    $absentCustomBin = Join-Path $tmp 'absent-custom-bin'
    New-Item -ItemType Directory -Force -Path $absentCustomProfile, $absentCustomBin | Out-Null
    Copy-Item (Join-Path $root 'qbraid-launch.ps1') (Join-Path $absentCustomBin 'qbraid-launch.ps1')
    Copy-Item (Join-Path $root 'qbraid-code.cmd') (Join-Path $absentCustomBin 'qbraid-code.cmd')
    Write-Utf8 (Join-Path $absentCustomBin 'qbraid-code.home') "$absentCustomRoot`n"
    $env:USERPROFILE = $absentCustomProfile
    Remove-Item Env:QBRAID_CODE_HOME, Env:QBRAID_CODE_BIN_DIR -ErrorAction SilentlyContinue
    Push-Location $absentCustomBin
    try { & cmd.exe /d /c qbraid-code.cmd --uninstall --yes *> $null; $absentCustomExit = $LASTEXITCODE } finally { Pop-Location }
    if ($absentCustomExit -eq 0 -and -not (Test-Path (Join-Path $absentCustomBin 'qbraid-code.cmd')) -and
        -not (Test-Path (Join-Path $absentCustomBin 'qbraid-launch.ps1')) -and -not (Test-Path (Join-Path $absentCustomBin 'qbraid-code.home'))) {
        Pass 'absent custom root still permits bound launcher cleanup'
    } else { Fail 'absent custom root still permits bound launcher cleanup' }

    $idempotentProfile = Join-Path $tmp 'empty-user'
    $env:USERPROFILE = $idempotentProfile
    $env:QBRAID_CODE_HOME = Join-Path $idempotentProfile '.qbraid-code'
    New-Item -ItemType Directory -Force -Path $idempotentProfile | Out-Null
    $idempotentExit = Invoke-ChildPowerShell (Join-Path $root 'qbraid-launch.ps1') @('--uninstall', '--yes')
    if ($idempotentExit -eq 0) { Pass 'uninstall tolerates an already absent standard installation' } else { Fail 'uninstall tolerates an already absent standard installation' }
} finally {
    $env:USERPROFILE = $originalUserProfile
    $env:QBRAID_CODE_HOME = $originalHome
    if ($vault -and $credentialResource) {
        try { $leftover = $vault.Retrieve($credentialResource, $env:USERNAME); $vault.Remove($leftover) } catch { }
    }
    if ($vault -and $invalidCredentialResource) {
        try { $leftover = $vault.Retrieve($invalidCredentialResource, $env:USERNAME); $vault.Remove($leftover) } catch { }
    }
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output "`n$pass passed, $fail failed"
if ($fail -ne 0) { exit 1 }
