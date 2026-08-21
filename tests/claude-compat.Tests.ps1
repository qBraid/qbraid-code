$ErrorActionPreference = 'Stop'

$source = Join-Path $PSScriptRoot '..\install.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    $source, [ref]$tokens, [ref]$errors)
if ($errors) { throw "could not parse install.ps1: $errors" }

$needed = @(
    'Write-RawText',
    'Invoke-NativeQuietly',
    'Get-EnvMap',
    'Confirm-Step',
    'ConvertFrom-ClaudeVersionString',
    'Compare-ClaudeVersion',
    'Test-ClaudeUpgradeSafe',
    'Get-ClaudeVersionStatus',
    'Get-ClaudePolicyAction',
    'Test-ClaudeMcpCommand',
    'Test-ClaudeMcpHttp',
    'Test-ClaudeMcpUserScope',
    'Update-ClaudeState',
    'Test-ClaudeRequiredCapabilities',
    'Confirm-ClaudeCompatibility'
)

foreach ($name in $needed) {
    $definition = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $name
    }, $true) | Select-Object -First 1
    if (-not $definition) { throw "could not extract $name from install.ps1" }
    Invoke-Expression $definition.Extent.Text
}

$script:Passed = 0
$script:Failed = 0
function Assert-Equal {
    param([string]$Name, $Actual, $Expected)
    if ($Actual -eq $Expected) {
        $script:Passed++
        Write-Host "  ok   $Name"
    } else {
        $script:Failed++
        Write-Host "  FAIL $Name`: got [$Actual] want [$Expected]"
    }
}

$writeRawTextDefinition = $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Write-RawText'
}, $true) | Select-Object -First 1
$firstWriteRawTextCall = $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -eq 'Write-RawText'
}, $true) | Sort-Object { $_.Extent.StartOffset } | Select-Object -First 1
Assert-Equal 'Write-RawText is defined before its first call' `
    ($writeRawTextDefinition.Extent.StartOffset -lt $firstWriteRawTextCall.Extent.StartOffset) $true
Assert-Equal 'expected native failure is returned instead of terminating' `
    (Invoke-NativeQuietly 'cmd.exe' @('/c', 'echo expected 1>&2 & exit /b 7')) 7
$getEnvMapDefinition = $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Get-EnvMap'
}, $true) | Select-Object -First 1
$firstGetEnvMapCall = $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -eq 'Get-EnvMap'
}, $true) | Sort-Object { $_.Extent.StartOffset } | Select-Object -First 1
Assert-Equal 'Get-EnvMap is defined before its first call' `
    ($getEnvMapDefinition.Extent.StartOffset -lt $firstGetEnvMapCall.Extent.StartOffset) $true
$installerText = Get-Content $source -Raw
foreach ($adaptiveModel in @('claude-opus-4-8', 'claude-opus-5', 'claude-sonnet-4-6')) {
    Assert-Equal "filter fixed thinking for $adaptiveModel" `
        ($installerText -match [regex]::Escape("- name: `"$adaptiveModel`"")) $true
}
Assert-Equal 'thinking compatibility filter removes request fields' `
    ($installerText -match '- \"thinking\"' -and $installerText -match '- \"output_config\"') $true
function global:Read-Host { return $null }
Assert-Equal 'exhausted stdin uses the confirmation default' (Confirm-Step 'Continue?' 'y') $true
Remove-Item Function:\Read-Host

$script:ClaudeMinVersion = '2.1.186'
$script:ClaudeTestedMax = '2.1.238'

Assert-Equal 'parse native version output' `
    (ConvertFrom-ClaudeVersionString '2.1.179 (Claude Code)') '2.1.179'
Assert-Equal 'parse version with surrounding text' `
    (ConvertFrom-ClaudeVersionString 'Claude Code version 2.1.238') '2.1.238'
Assert-Equal 'missing version parses empty' `
    (ConvertFrom-ClaudeVersionString 'present but unparseable') $null

Assert-Equal 'older version compares below' (Compare-ClaudeVersion '2.1.185' '2.1.186') -1
Assert-Equal 'equal version compares equal' (Compare-ClaudeVersion '2.1.186' '2.1.186') 0
Assert-Equal 'newer patch compares above' (Compare-ClaudeVersion '2.1.238' '2.1.186') 1
Assert-Equal 'newer minor compares above' (Compare-ClaudeVersion '2.2.0' '2.1.999') 1
Assert-Equal 'stable target allows an upgrade' (Test-ClaudeUpgradeSafe '2.1.185' '2.1.228') $true
Assert-Equal 'stable target refuses a tested-range downgrade' (Test-ClaudeUpgradeSafe '2.1.238' '2.1.228') $false

Assert-Equal 'unknown version status' (Get-ClaudeVersionStatus $null) 'unknown'
Assert-Equal 'below minimum status' (Get-ClaudeVersionStatus '2.1.185') 'below-minimum'
Assert-Equal 'minimum is tested' (Get-ClaudeVersionStatus '2.1.186') 'tested'
Assert-Equal 'tested maximum is tested' (Get-ClaudeVersionStatus '2.1.238') 'tested'
Assert-Equal 'newer version is informational' (Get-ClaudeVersionStatus '2.1.239') 'newer-than-tested'

Assert-Equal 'upgrade policy upgrades' (Get-ClaudePolicyAction 'upgrade' $false) 'upgrade'
Assert-Equal 'fail policy fails' (Get-ClaudePolicyAction 'fail' $true) 'fail'
Assert-Equal 'continue policy continues' (Get-ClaudePolicyAction 'continue' $false) 'continue'
Assert-Equal 'interactive prompt prompts' (Get-ClaudePolicyAction 'prompt' $true) 'prompt'
Assert-Equal 'noninteractive prompt fails' (Get-ClaudePolicyAction 'prompt' $false) 'fail'

function global:claude {
    $joined = $args -join ' '
    if ($joined -eq '--version') {
        "$script:FakeClaudeVersion (Claude Code)"
    } elseif ($joined -eq 'mcp --help') {
        'Commands:'
        '  add [options]'
        '  get <name>'
        if ($script:FakeMcpLogin) { '  login <name>' }
    } elseif ($joined -eq 'mcp add --help') {
        '  --transport <transport>  stdio, sse, or http'
        if ($script:FakeUserScope) { '  --scope <scope>          local, project, or user' }
    }
}

$script:FakeClaudeVersion = '2.1.179'
$script:FakeMcpLogin = $false
$script:FakeUserScope = $true
Assert-Equal 'detect mcp add' (Test-ClaudeMcpCommand 'add') $true
Assert-Equal 'detect mcp get' (Test-ClaudeMcpCommand 'get') $true
Assert-Equal 'detect missing mcp login' (Test-ClaudeMcpCommand 'login') $false
$script:FakeMcpLogin = $true
Assert-Equal 'detect available mcp login' (Test-ClaudeMcpCommand 'login') $true
Assert-Equal 'detect HTTP transport' (Test-ClaudeMcpHttp) $true
Assert-Equal 'detect user scope' (Test-ClaudeMcpUserScope) $true

function Warn { param($Message) $script:Messages += "WARN $Message" }
function Ok { param($Message) $script:Messages += "OK $Message" }
function Die { param($Message) throw "DIE $Message" }
function Test-InteractiveConsole { return $script:Interactive }
function Confirm-Step { return $script:ConfirmResult }
function Install-ClaudeStable { $script:FakeClaudeVersion = '2.1.238' }

$env:QBRAID_CODE_CLAUDE_POLICY = 'continue'
$script:Interactive = $false
$script:Messages = @()
Confirm-ClaudeCompatibility
Assert-Equal 'continue flow keeps old version' $script:FakeClaudeVersion '2.1.179'
Assert-Equal 'continue flow warns' ($script:Messages -join "`n" -match 'unsupported Claude Code') $true

$env:QBRAID_CODE_CLAUDE_POLICY = 'fail'
$script:Messages = @()
$failedClosed = $false
try { Confirm-ClaudeCompatibility } catch { $failedClosed = $_.Exception.Message -match 'incompatible' }
Assert-Equal 'fail flow rejects old version' $failedClosed $true

$env:QBRAID_CODE_CLAUDE_POLICY = 'upgrade'
$script:FakeClaudeVersion = '2.1.179'
$script:Messages = @()
Confirm-ClaudeCompatibility
Assert-Equal 'upgrade flow reaches stable version' $script:FakeClaudeVersion '2.1.238'

$env:QBRAID_CODE_CLAUDE_POLICY = 'prompt'
$script:FakeClaudeVersion = '2.1.179'
$script:Interactive = $false
$failedClosed = $false
try { Confirm-ClaudeCompatibility } catch { $failedClosed = $_.Exception.Message -match 'incompatible' }
Assert-Equal 'noninteractive prompt fails closed' $failedClosed $true

$script:Interactive = $true
$script:ConfirmResult = $false
$script:Messages = @()
Confirm-ClaudeCompatibility
Assert-Equal 'interactive prompt can decline upgrade' `
    ($script:Messages -join "`n" -match 'reduced compatibility') $true

$env:QBRAID_CODE_CLAUDE_POLICY = 'upgrade'
$script:FakeClaudeVersion = '2.1.239'
$script:FakeUserScope = $false
$refusedDowngrade = $false
try { Confirm-ClaudeCompatibility } catch { $refusedDowngrade = $_.Exception.Message -match 'Refusing to downgrade' }
Assert-Equal 'upgrade never downgrades a newer CLI' $refusedDowngrade $true
Assert-Equal 'newer CLI version remains installed' $script:FakeClaudeVersion '2.1.239'

$env:QBRAID_CODE_CLAUDE_POLICY = 'prompt'
$script:Interactive = $true
$script:Messages = @()
Confirm-ClaudeCompatibility
Assert-Equal 'prompt never downgrades a newer CLI' `
    ($script:Messages -join "`n" -match 'refusing to downgrade') $true

$env:QBRAID_CODE_CLAUDE_POLICY = 'upgrade'
$script:FakeClaudeVersion = 'mystery-version'
$script:FakeUserScope = $true
$unknownRefused = $false
try { Confirm-ClaudeCompatibility } catch { $unknownRefused = $_.Exception.Message -match 'could downgrade' }
Assert-Equal 'upgrade never replaces an unknown version' $unknownRefused $true
Assert-Equal 'unknown version remains installed' $script:FakeClaudeVersion 'mystery-version'

$env:QBRAID_CODE_CLAUDE_POLICY = 'prompt'
$script:Interactive = $true
$script:Messages = @()
Confirm-ClaudeCompatibility
Assert-Equal 'prompt never replaces an unknown version' `
    ($script:Messages -join "`n" -match 'could downgrade') $true

Remove-Item Env:\QBRAID_CODE_CLAUDE_POLICY
Remove-Item Function:\claude

Write-Host "`n$($script:Passed) passed, $($script:Failed) failed"
if ($script:Failed -ne 0) { exit 1 }
