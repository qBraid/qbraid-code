$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$vault = $null; $alphaCredential = $null; $betaCredential = $null
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("qbraid profiles ü " + [guid]::NewGuid())
try {
    $qcHome = Join-Path $tmp 'home with space'
    $bin = Join-Path $tmp 'bin'
    $alphaRoot = Join-Path $qcHome 'profiles\alpha'
    $betaRoot = Join-Path $qcHome 'profiles\beta'
    $alpha = Join-Path $alphaRoot 'generations\g-alpha'
    $beta = Join-Path $betaRoot 'generations\g-beta'
    New-Item -ItemType Directory -Force -Path $alpha, $beta, $bin | Out-Null
    'g-alpha' | Set-Content (Join-Path $alphaRoot 'current') -Encoding ASCII
    'g-beta' | Set-Content (Join-Path $betaRoot 'current') -Encoding ASCII
    $null = [Windows.Security.Credentials.PasswordVault,Windows.Security.Credentials,ContentType=WindowsRuntime]
    $null = [Windows.Security.Credentials.PasswordCredential,Windows.Security.Credentials,ContentType=WindowsRuntime]
    $vault = New-Object Windows.Security.Credentials.PasswordVault
    $alphaCredential = New-Object Windows.Security.Credentials.PasswordCredential -ArgumentList 'qbraid-code-test-alpha', $env:USERNAME, 'token-alpha'
    $betaCredential = New-Object Windows.Security.Credentials.PasswordCredential -ArgumentList 'qbraid-code-test-beta', $env:USERNAME, 'token-beta'
    $vault.Add($alphaCredential); $vault.Add($betaCredential)
    @'
QBRAID_CODE_BASE_URL=https://example.invalid/api/v1/ai
QBRAID_CODE_API_BASE=https://example.invalid/api/v1
QBRAID_CODE_SECRET_BACKEND=credential-locker
QBRAID_CODE_SECRET_REF=qbraid-code-test-alpha
QBRAID_CODE_MODEL=claude-opus-5
QBRAID_CODE_PROXY_PORT=8320
QBRAID_CODE_PROXY_BIN=PLACEHOLDER
'@ | Set-Content (Join-Path $alpha 'env') -Encoding ASCII
    @'
QBRAID_CODE_BASE_URL=https://example.invalid/api/v1/ai
QBRAID_CODE_API_BASE=https://example.invalid/api/v1
QBRAID_CODE_SECRET_BACKEND=credential-locker
QBRAID_CODE_SECRET_REF=qbraid-code-test-beta
QBRAID_CODE_MODEL=claude-haiku-4-5
QBRAID_CODE_PROXY_PORT=8321
QBRAID_CODE_PROXY_BIN=PLACEHOLDER
'@ | Set-Content (Join-Path $beta 'env') -Encoding ASCII
    $proxyBinary = (Get-Command powershell).Source
    foreach ($dir in @($alpha, $beta)) {
        (Get-Content (Join-Path $dir 'env') -Raw).Replace('PLACEHOLDER', $proxyBinary) | Set-Content (Join-Path $dir 'env') -Encoding ASCII
        @'
port: __PORT__
auth-dir: "__AUTH_DIR__"
api-keys:
  - "__LOCAL_KEY__"
claude-api-key:
  - api-key: "__QBRAID_KEY__"
'@ | Set-Content (Join-Path $dir 'proxy-template.yaml') -Encoding ASCII
        'local' | Set-Content (Join-Path $dir 'label-source') -Encoding ASCII
    }
    @'
param([string]$Action)
if ($Action -eq 'ensure' -and $env:CAPTURE_PROXY_CONFIG) { Copy-Item $env:QBRAID_CODE_RUNTIME_CONFIG $env:CAPTURE_PROXY_CONFIG -Force }
exit 0
'@ | Set-Content (Join-Path $qcHome 'qbraid-proxy.ps1') -Encoding ASCII
    "claude-opus-5`t1000000" | Set-Content (Join-Path $alpha 'models.tsv') -Encoding ASCII
    "claude-haiku-4-5`t200000" | Set-Content (Join-Path $beta 'models.tsv') -Encoding ASCII
    'Alpha Lab' | Set-Content (Join-Path $alpha 'label') -Encoding UTF8
    'Beta Lab' | Set-Content (Join-Path $beta 'label') -Encoding UTF8
    New-Item -ItemType Directory -Force -Path (Join-Path $qcHome 'profiles\default') | Out-Null
    'alpha' | Set-Content (Join-Path $qcHome 'active-profile') -Encoding ASCII
    "QBRAID_CODE_BASE_URL=https://example.invalid`nQBRAID_CODE_TOKEN=legacy-root-token`n" | Set-Content (Join-Path $qcHome 'env') -Encoding ASCII
    'api-key: legacy-root-token' | Set-Content (Join-Path $qcHome 'proxy-config.yaml') -Encoding ASCII
    @'
@echo off
echo profile_home=%QBRAID_CODE_PROFILE_HOME%
echo token=%ANTHROPIC_AUTH_TOKEN%
echo model=%ANTHROPIC_MODEL%
echo context=%CLAUDE_CODE_MAX_CONTEXT_TOKENS%
echo args=%*
'@ | Set-Content (Join-Path $bin 'claude.cmd') -Encoding ASCII
    $env:QBRAID_CODE_HOME = $qcHome
    $env:Path = "$bin;$env:Path"
    $env:CAPTURE_PROXY_CONFIG = Join-Path $tmp 'runtime.yaml'

    $out = & cmd /c (Join-Path $root 'qbraid-code.cmd') -p hello
    if ($out -match 'token=token-alpha' -or $out -notmatch 'model=claude-opus-5\[1m\]' -or $out -notmatch 'args=-p hello' -or $out -notmatch '--setting-sources user') { throw "active binding failed: $out" }
    if ((Get-Content (Join-Path $qcHome 'env') -Raw) -match 'legacy-root-token' -or (Test-Path (Join-Path $qcHome 'proxy-config.yaml'))) { throw 'legacy plaintext artifacts were not scavenged' }
    $runtimeYaml = Get-Content $env:CAPTURE_PROXY_CONFIG -Raw
    if ($runtimeYaml -notmatch 'auth-dir: "[^"]*qbraid profiles ü [^"]*/runtime\.') { throw "runtime YAML path encoding failed: $runtimeYaml" }
    $out = & cmd /c (Join-Path $root 'qbraid-code.cmd') --profile beta -p hello
    if ($out -match 'token=token-beta' -or $out -notmatch 'context=200000' -or $out -match '--profile') { throw "explicit binding failed: $out" }
    & cmd /c (Join-Path $root 'qbraid-code.cmd') --use-profile beta | Out-Null
    if ((Get-Content (Join-Path $qcHome 'active-profile') -Raw).Trim() -ne 'beta') { throw 'atomic selection failed' }
    $list = & cmd /c (Join-Path $root 'qbraid-code.cmd') --profiles
    if ($list -notmatch '\* beta' -or $list -notmatch 'Beta Lab') { throw "profile list failed: $list" }

    & cmd /c (Join-Path $root 'qbraid-code.cmd') --global *> $null
    if ($LASTEXITCODE -eq 0) { throw 'unsafe global mode was accepted' }

    & cmd /c (Join-Path $root 'qbraid-code.cmd') --profile alpha --resume *> $null
    if ($LASTEXITCODE -eq 0) { throw 'cross-profile resume was accepted without confirmation' }
    $out = & cmd /c (Join-Path $root 'qbraid-code.cmd') --profile alpha --allow-profile-resume --resume session-id
    if ($out -match 'token=token-alpha' -or $out -notmatch '--resume session-id') { throw "confirmed resume failed: $out" }

    '19' | Set-Content (Join-Path $beta 'credits.cache') -Encoding ASCII
    [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() | Set-Content (Join-Path $beta 'credits.updated') -Encoding ASCII
    $env:QBRAID_CODE_PROFILE_HOME = $beta
    $status = '{"model":{"display_name":"Haiku"},"workspace":{"current_dir":"C:\\tmp"}}' | & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'statusline.ps1')
    if ($status -notmatch 'qBraid' -or $status -notmatch 'Beta Lab' -or $status -notmatch '19') { throw "status binding failed: $status" }

    $sources = Get-Content (Join-Path $root 'qbraid-code.cmd'), (Join-Path $root 'install.ps1') -Raw
    if ($sources -match 'MAX_THINKING_TOKENS=0') { throw 'thinking workaround remains' }
    Write-Host 'windows profile tests passed'
} finally {
    if ($vault) {
        try { $vault.Remove($alphaCredential) } catch { }
        try { $vault.Remove($betaCredential) } catch { }
    }
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
