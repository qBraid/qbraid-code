$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$tmp = Join-Path $PSScriptRoot ('.qbraid-native-installer-' + [guid]::NewGuid().ToString('N'))
$originalUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$vault = $null

function Get-CurrentProfileDirectory {
    param([string]$HomeDir, [string]$Profile)
    $root = Join-Path $HomeDir "profiles\$Profile"
    $generation = (Get-Content (Join-Path $root 'current') -Raw).Trim()
    return Join-Path $root "generations\$generation"
}

function Get-VaultPassword {
    param([string]$Reference)
    $credential = $vault.Retrieve($Reference, $env:USERNAME)
    $credential.RetrievePassword()
    return $credential.Password
}

function Invoke-TestInstaller {
    param([string[]]$Arguments, [string]$ApiKey = '', [string]$PromptKey = '', [switch]$FailMcp)
    $env:QBRAID_API_KEY = $ApiKey
    $env:TEST_PROMPT_KEY = $PromptKey
    $env:TEST_FAIL_MCP = if ($FailMcp) { '1' } else { '0' }
    $output = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tmp 'installer-wrapper.ps1') @Arguments 6>&1
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
}

try {
    $userHome = Join-Path $tmp 'user home'
    $homeDir = Join-Path $userHome '.qbraid-code'
    $binDir = Join-Path $userHome '.local\bin'
    New-Item -ItemType Directory -Force -Path $userHome, $homeDir, $binDir | Out-Null
    [IO.File]::WriteAllText((Join-Path $homeDir 'cliproxyapi.exe'), 'test proxy')
    [Environment]::SetEnvironmentVariable('Path', "$binDir;$originalUserPath", 'User')
    $env:USERPROFILE = $userHome
    $env:HOME = $userHome
    $env:QBRAID_CODE_HOME = $homeDir
    $env:QBRAID_CODE_BIN_DIR = $binDir
    $env:TEST_REPO_ROOT = $repo
    $env:QBRAID_CODE_MODEL = 'claude-opus-5'
    $env:QBRAID_CODE_PROFILE_LABEL = 'Local Lab'

    @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$InstallerArguments)
$ErrorActionPreference = 'Stop'
function global:Read-Host {
    param([string]$Prompt, [switch]$AsSecureString)
    if ($AsSecureString) { return ConvertTo-SecureString $env:TEST_PROMPT_KEY -AsPlainText -Force }
    return 'y'
}
function global:Start-Process { param($FilePath) }
function global:claude {
    $joined = $args -join ' '
    if ($joined -eq '--version') { $global:LASTEXITCODE = 0; '2.1.238 (Claude Code)'; return }
    if ($joined -eq 'mcp --help') { $global:LASTEXITCODE = 0; '  add'; '  get'; '  login'; return }
    if ($joined -eq 'mcp add --help') { $global:LASTEXITCODE = 0; '--transport <transport> [http]'; '--scope <scope> [user]'; return }
    if ($joined -like 'mcp get *') { $global:LASTEXITCODE = 1; return }
    if ($joined -like 'mcp add *') { $global:LASTEXITCODE = if ($env:TEST_FAIL_MCP -eq '1') { 1 } else { 0 }; return }
    if ($joined -like 'mcp login *') { $global:LASTEXITCODE = 0; return }
    $global:LASTEXITCODE = 0
}
function global:Invoke-WebRequest {
    param($Uri, $OutFile, $TimeoutSec, $UseBasicParsing)
    if ($OutFile) { throw "unexpected binary download: $Uri" }
    $name = [IO.Path]::GetFileName(([uri]$Uri).AbsolutePath)
    $source = Join-Path $env:TEST_REPO_ROOT $name
    if (-not (Test-Path $source)) { throw "missing test companion $name" }
    return [pscustomobject]@{ StatusCode = 200; Content = [IO.File]::ReadAllText($source) }
}
function global:Invoke-RestMethod {
    param($Uri, $Headers, $TimeoutSec, $Method, $ContentType, $Body)
    if ($Uri -like '*/stable') { return '2.1.238' }
    if ($Uri -like '*/billing/credits/balance') {
        $key = $Headers['X-API-Key']
        $org = if ($key -eq 'test-cross-org') { 'org-other' } else { 'org-alpha' }
        return [pscustomobject]@{ data = [pscustomobject]@{ organizationId = $org; qbraidCredits = 100 } }
    }
    if ($Uri -like '*/organizations/current') { return [pscustomobject]@{ data = [pscustomobject]@{ name = 'Verified Lab' } } }
    if ($Uri -like '*/v1/models') { return [pscustomobject]@{ data = @([pscustomobject]@{ id = 'claude-opus-5' }) } }
    if ($Uri -like '*/ai/models') { return [pscustomobject]@{ data = @([pscustomobject]@{ id = 'claude-opus-5' }) } }
    if ($Uri -like '*/v1/messages') { return [pscustomobject]@{ content = @([pscustomobject]@{ text = 'OK' }) } }
    throw "unexpected request: $Uri"
}
& (Join-Path $env:TEST_REPO_ROOT 'install.ps1') @InstallerArguments
exit $LASTEXITCODE
'@ | Set-Content (Join-Path $tmp 'installer-wrapper.ps1') -Encoding UTF8

    $null = [Windows.Security.Credentials.PasswordVault,Windows.Security.Credentials,ContentType=WindowsRuntime]
    $vault = New-Object Windows.Security.Credentials.PasswordVault

    $first = Invoke-TestInstaller -Arguments @('-Profile', 'lifecycle-native') -ApiKey 'test-initial-secret'
    if ($first.ExitCode -ne 0) { throw "initial native install failed: $($first.Output)" }
    $firstDir = Get-CurrentProfileDirectory $homeDir 'lifecycle-native'
    $firstGeneration = Split-Path $firstDir -Leaf
    $firstRef = ((Get-Content (Join-Path $firstDir 'env')) | Where-Object { $_ -like 'QBRAID_CODE_SECRET_REF=*' }).Substring('QBRAID_CODE_SECRET_REF='.Length)
    if ((Get-VaultPassword $firstRef) -ne 'test-initial-secret') { throw 'initial Credential Locker secret mismatch' }

    $staleProgram = 'using System.Threading; public static class StaleFixture { public static void Main(string[] args) { Thread.Sleep(600000); } }'
    $staleExecutable = Join-Path $tmp 'unowned-stale-proxy.exe'
    Add-Type -TypeDefinition $staleProgram -Language CSharp -OutputAssembly $staleExecutable -OutputType ConsoleApplication
    $staleConfig = Join-Path $firstDir 'proxy-config.yaml'
    [IO.File]::WriteAllText($staleConfig, "port: 8320`n")
    $staleProcess = Start-Process $staleExecutable -ArgumentList @('-config', "`"$staleConfig`"") -PassThru
    [IO.File]::WriteAllText((Join-Path $firstDir 'proxy.pid'), [string]$staleProcess.Id)
    $beforeStaleRejection = (Get-Content (Join-Path $homeDir 'profiles\lifecycle-native\current') -Raw).Trim()
    $staleRejection = Invoke-TestInstaller -Arguments @('-Profile', 'lifecycle-native', '-UpdateKey') -ApiKey 'test-stale-rejected-secret'
    $staleProcess.Refresh()
    if ($staleRejection.ExitCode -eq 0 -or $staleProcess.HasExited -or
        (Get-Content (Join-Path $homeDir 'profiles\lifecycle-native\current') -Raw).Trim() -ne $beforeStaleRejection) {
        throw "installer did not reject an unowned stale proxy process: $($staleRejection.Output)"
    }
    Stop-Process -Id $staleProcess.Id -Force
    Remove-Item (Join-Path $firstDir 'proxy.pid'), $staleConfig -Force

    New-Item -ItemType Directory -Force -Path (Join-Path $userHome '.qbraid') | Out-Null
    'api-key = test-qbraidrc-old' | Set-Content (Join-Path $userHome '.qbraid\qbraidrc') -Encoding ASCII
    'other' | Set-Content (Join-Path $homeDir 'active-profile') -Encoding ASCII
    $env:QBRAID_CODE_MODEL = ''
    $env:QBRAID_CODE_PROFILE_LABEL = ''
    Copy-Item $staleExecutable (Join-Path $homeDir 'cliproxyapi.exe') -Force
    [IO.File]::WriteAllText($staleConfig, "port: 8320`n")
    $ownedStaleProcess = Start-Process (Join-Path $homeDir 'cliproxyapi.exe') -ArgumentList @('-config', "`"$staleConfig`"") -PassThru
    [IO.File]::WriteAllText((Join-Path $firstDir 'proxy.pid'), [string]$ownedStaleProcess.Id)
    $rotated = Invoke-TestInstaller -Arguments @('-Profile', 'lifecycle-native', '-UpdateKey') -PromptKey 'test-replacement-secret'
    if ($rotated.ExitCode -ne 0) { throw "native rotation failed: $($rotated.Output)" }
    $ownedStaleProcess.Refresh()
    if (-not $ownedStaleProcess.HasExited) { Stop-Process -Id $ownedStaleProcess.Id -Force; throw 'installer did not stop an owned stale proxy process' }
    $rotatedDir = Get-CurrentProfileDirectory $homeDir 'lifecycle-native'
    $rotatedGeneration = Split-Path $rotatedDir -Leaf
    $rotatedRef = ((Get-Content (Join-Path $rotatedDir 'env')) | Where-Object { $_ -like 'QBRAID_CODE_SECRET_REF=*' }).Substring('QBRAID_CODE_SECRET_REF='.Length)
    if ($rotatedGeneration -eq $firstGeneration -or (Get-VaultPassword $rotatedRef) -ne 'test-replacement-secret') { throw 'rotation did not commit the replacement secret' }
    try { $null = $vault.Retrieve($firstRef, $env:USERNAME); throw 'retired Credential Locker secret remains' } catch { if ($_.Exception.HResult -ne -2147023728) { throw } }
    if ((Get-Content (Join-Path $rotatedDir 'organization-id') -Raw).Trim() -ne 'org-alpha') { throw 'organization binding was not preserved' }
    if ((Get-Content (Join-Path $rotatedDir 'label') -Raw).Trim() -ne 'Local Lab' -or (Get-Content (Join-Path $rotatedDir 'label-source') -Raw).Trim() -ne 'local') { throw 'rotation changed the profile label' }
    if ((Get-Content (Join-Path $rotatedDir 'env') -Raw) -notmatch 'QBRAID_CODE_MODEL=claude-opus-5') { throw 'rotation changed the model' }
    if ((Get-Content (Join-Path $homeDir 'active-profile') -Raw).Trim() -ne 'other') { throw 'rotation changed the active profile' }
    if ($rotated.Output -match 'test-(initial|replacement|qbraidrc)-') { throw 'rotation printed a credential' }

    $beforeCross = (Get-Content (Join-Path $homeDir 'profiles\lifecycle-native\current') -Raw).Trim()
    $cross = Invoke-TestInstaller -Arguments @('-Profile', 'lifecycle-native', '-UpdateKey') -ApiKey 'test-cross-org'
    if ($cross.ExitCode -eq 0 -or $cross.Output -notmatch 'another organization') { throw "cross-organization rotation was not rejected: $($cross.Output)" }
    if ((Get-Content (Join-Path $homeDir 'profiles\lifecycle-native\current') -Raw).Trim() -ne $beforeCross) { throw 'cross-organization rejection changed the generation' }

    $rollback = Invoke-TestInstaller -Arguments @('-Profile', 'lifecycle-native', '-UpdateKey') -ApiKey 'test-post-stage-secret' -FailMcp
    if ($rollback.ExitCode -eq 0 -or $rollback.Output -notmatch 'could not register') { throw "post-stage failure was not reported: $($rollback.Output)" }
    if ((Get-Content (Join-Path $homeDir 'profiles\lifecycle-native\current') -Raw).Trim() -ne $beforeCross -or (Get-VaultPassword $rotatedRef) -ne 'test-replacement-secret') { throw 'post-stage failure changed the committed generation or secret' }
    $owned = @($vault.RetrieveAll() | Where-Object { $_.Resource -like 'qbraid-code:lifecycle-native:*' })
    if ($owned.Count -ne 1 -or $owned[0].Resource -ne $rotatedRef) { throw 'post-stage rollback left a staged credential' }
    if ($rollback.Output -match 'test-post-stage-secret') { throw 'failed rotation printed its credential' }

    Remove-Item (Join-Path $rotatedDir 'organization-id') -Force
    $missingOrg = Invoke-TestInstaller -Arguments @('-Profile', 'lifecycle-native', '-UpdateKey') -ApiKey 'test-same-org-after-missing-id'
    if ($missingOrg.ExitCode -eq 0 -or $missingOrg.Output -notmatch 'no verified organization ID') { throw 'rotation without the previous organization identity did not fail closed' }

    $junctionTarget = Join-Path $tmp 'junction-target'
    $junctionHome = Join-Path $tmp 'junction-home'
    $junctionBin = Join-Path $tmp 'junction-bin'
    New-Item -ItemType Directory -Force -Path $junctionTarget, $junctionBin | Out-Null
    & cmd.exe /d /c "mklink /J `"$junctionHome`" `"$junctionTarget`"" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'could not create installer junction fixture' }
    $env:QBRAID_CODE_HOME = $junctionHome
    $env:QBRAID_CODE_BIN_DIR = $junctionBin
    $junctionInstall = Invoke-TestInstaller -Arguments @('-Profile', 'junction-native') -ApiKey 'test-junction-secret'
    if ($junctionInstall.ExitCode -eq 0 -or (Test-Path (Join-Path $junctionTarget '.qbraid-code-install'))) {
        throw "installer accepted a reparse-point custom home: $($junctionInstall.Output)"
    }
    & cmd.exe /d /c "rmdir `"$junctionHome`"" | Out-Null

    $customHome = Join-Path $tmp 'legacy-custom-root'
    $customBin = Join-Path $tmp 'legacy-custom-bin'
    New-Item -ItemType Directory -Force -Path $customHome, $customBin | Out-Null
    "QBRAID_CODE_BASE_URL=https://example.invalid`n" | Set-Content (Join-Path $customHome 'env') -Encoding ASCII
    'Legacy Label' | Set-Content (Join-Path $customHome 'label') -Encoding UTF8
    'port: __PORT__' | Set-Content (Join-Path $customHome 'proxy-template.yaml') -Encoding UTF8
    'stale' | Set-Content (Join-Path $customHome '.qbraid-code-install.stale.tmp') -Encoding UTF8
    [IO.File]::WriteAllText((Join-Path $customBin 'qbraid-code.home'), $customHome, (New-Object Text.UTF8Encoding $false))
    [IO.File]::WriteAllText((Join-Path $customHome 'cliproxyapi.exe'), 'test proxy')
    $env:QBRAID_CODE_HOME = $customHome
    $env:QBRAID_CODE_BIN_DIR = $customBin
    $env:QBRAID_CODE_MODEL = 'claude-opus-5'
    $customMigration = Invoke-TestInstaller -Arguments @('-Profile', 'custom-native') -ApiKey 'test-custom-secret'
    if ($customMigration.ExitCode -ne 0 -or (Get-Content (Join-Path $customHome '.qbraid-code-install') -Raw).Trim() -ne 'qbraid-code' -or
        -not (Test-Path (Join-Path $customHome 'profiles\default\env')) -or -not (Test-Path (Join-Path $customHome 'profiles\default\proxy-template.yaml'))) {
        throw "pre-marker custom Windows migration failed: $($customMigration.Output)"
    }

    Write-Host 'windows native installer lifecycle tests passed'
} finally {
    if ($vault) {
        foreach ($credential in @($vault.RetrieveAll() | Where-Object { $_.Resource -like 'qbraid-code:lifecycle-native*' -or $_.Resource -like 'qbraid-code:custom-native*' })) {
            try { $vault.Remove($credential) } catch { }
        }
    }
    [Environment]::SetEnvironmentVariable('Path', $originalUserPath, 'User')
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
