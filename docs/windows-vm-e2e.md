# Windows VM end-to-end testing

This guide reproduces the Windows 11 environment used to test the PowerShell
installer against real Claude Code releases and the live qBraid gateway. It is
for maintainers testing `install.ps1`, not for end-user installation.

The tested host was Arch Linux with Docker, hardware virtualization, and
read/write access to `/dev/kvm`. The guest used Windows PowerShell 5.1, which is
important: it exposed compatibility failures that did not reproduce in modern
PowerShell.

## Tested configuration

| Setting | Value |
|---|---|
| VM image | `dockurr/windows` 5.14 |
| Tested image digest | `sha256:20b398ab935465f97ec8ab06489f7a85a5ad58e74e036ce66cc3c9172e7dbea8` |
| Windows release | Windows 11 LTSC (`VERSION=11l`) |
| RAM / CPUs / disk | 8 GiB / 4 / 64 GiB |
| Persistent volume | `qbraid-code-windows-e2e` mounted at `/storage` |
| Container | `qbraid-code-windows-e2e` |
| noVNC / RDP / SSH | host ports 8006 / 3389 / 2222 |
| Windows account | dockurr test default `Docker` / `admin` |
| PowerShell | Windows PowerShell 5.1.26100.1591 |

The default password is appropriate only for a disposable test VM. The commands
below bind every published port to `127.0.0.1`. Change the password before
making the VM reachable from another host.

## 1. Check the host

```bash
docker version
test -r /dev/kvm && test -w /dev/kvm
test -c /dev/net/tun
```

Create the persistent volume and start the VM. The digest below pins the image
used by the successful run; `dockurr/windows` can be substituted when testing a
newer image deliberately.

```bash
docker volume create qbraid-code-windows-e2e

docker run -d \
  --name qbraid-code-windows-e2e \
  --device=/dev/kvm \
  --device=/dev/net/tun \
  --cap-add NET_ADMIN \
  -e VERSION=11l \
  -e RAM_SIZE=8G \
  -e CPU_CORES=4 \
  -e DISK_SIZE=64G \
  -p 127.0.0.1:8006:8006 \
  -p 127.0.0.1:3389:3389/tcp \
  -v qbraid-code-windows-e2e:/storage \
  -v "$PWD:/shared:ro" \
  dockurr/windows@sha256:20b398ab935465f97ec8ab06489f7a85a5ad58e74e036ce66cc3c9172e7dbea8
```

Watch startup with `docker logs -f qbraid-code-windows-e2e`. Open
`http://localhost:8006` for the noVNC console and let Windows finish its first
boot. The image creates and signs into the `Docker` account automatically.

## 2. Enable SSH once

In noVNC, open **Windows PowerShell as Administrator** and run:

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service sshd -StartupType Automatic

if (-not (Get-NetFirewallRule -Name OpenSSH-Server-In-TCP -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule `
        -Name OpenSSH-Server-In-TCP `
        -DisplayName 'OpenSSH Server (sshd)' `
        -Enabled True `
        -Direction Inbound `
        -Protocol TCP `
        -Action Allow `
        -LocalPort 22
}
```

Recreate the container with SSH published. The Windows installation remains in
the named volume.

```bash
docker stop qbraid-code-windows-e2e
docker rm qbraid-code-windows-e2e

docker run -d \
  --name qbraid-code-windows-e2e \
  --device=/dev/kvm \
  --device=/dev/net/tun \
  --cap-add NET_ADMIN \
  -e VERSION=11l \
  -e RAM_SIZE=8G \
  -e CPU_CORES=4 \
  -e DISK_SIZE=64G \
  -p 127.0.0.1:8006:8006 \
  -p 127.0.0.1:3389:3389/tcp \
  -p 127.0.0.1:2222:22/tcp \
  -v qbraid-code-windows-e2e:/storage \
  -v "$PWD:/shared:ro" \
  dockurr/windows@sha256:20b398ab935465f97ec8ab06489f7a85a5ad58e74e036ce66cc3c9172e7dbea8
```

Wait for SSH to answer before continuing:

```bash
until timeout 2 bash -c '</dev/tcp/127.0.0.1/2222' 2>/dev/null; do
  sleep 5
done
```

## 3. Create the SSH helper

The test host did not need a native SSH client. This small helper image keeps
the dependency isolated:

```bash
docker build -t qbraid-code-win-ssh - <<'EOF'
FROM alpine:3.22
RUN apk add --no-cache openssh-client sshpass
EOF
```

Verify Windows PowerShell 5.1 is reachable:

```bash
docker run --rm --network host qbraid-code-win-ssh \
  sshpass -p admin ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -p 2222 Docker@127.0.0.1 \
    powershell.exe -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
```

## 4. Copy the working tree

Run these commands from the repository root:

```bash
docker run --rm --network host -v "$PWD:/src:ro" qbraid-code-win-ssh sh -lc '
  sshpass -p admin ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -p 2222 Docker@127.0.0.1 \
    powershell.exe -NoProfile -Command \
      "New-Item -ItemType Directory -Force C:\Users\Docker\qbraid-code-e2e\tests"

  sshpass -p admin scp -q \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -P 2222 \
    /src/*.ps1 /src/*.cmd \
    Docker@127.0.0.1:C:/Users/Docker/qbraid-code-e2e/

  sshpass -p admin scp -q \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -P 2222 \
    /src/tests/*.ps1 \
    Docker@127.0.0.1:C:/Users/Docker/qbraid-code-e2e/tests/
'
```

For an interactive Windows shell:

```bash
docker run --rm -it --network host qbraid-code-win-ssh \
  sshpass -p admin ssh -tt \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -p 2222 Docker@127.0.0.1 \
    powershell.exe -NoProfile -ExecutionPolicy Bypass
```

Do not put a real qBraid API key in the repository or in a committed test
script. Enter a disposable test key at the installer's prompt, or set it only in
the interactive Windows process:

```powershell
$env:QBRAID_API_KEY = Read-Host 'Disposable qBraid API key'
$env:QBRAID_CODE_MODEL = 'claude-opus-5'
$env:Path = "$env:USERPROFILE\.local\bin;$env:Path"
```

## 5. Run the compatibility matrix

Install a specific Claude Code release with Anthropic's installer:

```powershell
$installer = [scriptblock]::Create((Invoke-RestMethod -Uri 'https://claude.ai/install.ps1'))
& $installer '2.1.186'
claude --version
```

For each row below, install the starting release, set the policy, record
`claude --version`, run the local qbraid-code installer, and verify the version
afterward.

| Starting release | Policy | Expected result |
|---|---|---|
| `2.1.179` | `continue` | Remains 2.1.179; setup and model request succeed with reduced MCP guidance |
| `2.1.179` | `upgrade` | Moves to Anthropic `stable`; setup and model request succeed |
| `2.1.186` | `fail` | Remains 2.1.186; setup and model request succeed |
| `2.1.228` | `fail` | Remains 2.1.228; setup and model request succeed |
| `2.1.238` | `fail` | Remains 2.1.238; setup and model request succeed |

The stable channel resolved to 2.1.228 during the recorded run. Treat the
channel as moving; the important assertion is that an upgrade reaches a
compatible release and that already-compatible or newer versions are not
replaced.

```powershell
$env:QBRAID_CODE_CLAUDE_POLICY = 'fail'
$before = claude --version

& C:\Users\Docker\qbraid-code-e2e\install.ps1

$after = claude --version
if ($before -ne $after) {
    throw "Claude version changed unexpectedly: $before -> $after"
}

qbraid-code --doctor
qbraid-code -p 'Reply with exactly: WINDOWS_E2E_OK'
```

For the old-version upgrade row, use `upgrade` and assert that `$after` is a
supported stable version instead of asserting equality. For the `continue` row,
`qbraid-code --doctor` deliberately reports the below-minimum release while the
real model request still proves the degraded path works.

MCP OAuth is a separate browser-backed check. API-key validity does not
authenticate the MCP endpoint. Run `claude mcp login qbraid` only when a test
qBraid browser account is available; otherwise verify registration and expect
doctor to report that authentication is still needed.

## 6. Mirror the Windows CI checks

In the interactive Windows shell:

```powershell
$root = 'C:\Users\Docker\qbraid-code-e2e'
$files = @(Get-ChildItem "$root\*.ps1") +
    @(Get-ChildItem "$root\tests\*.ps1")

foreach ($file in $files) {
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName, [ref]$null, [ref]$errors) | Out-Null
    if ($errors) { throw "Parse failure in $($file.Name): $errors" }
}

if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
    Install-PackageProvider NuGet -Force | Out-Null
    Install-Module PSScriptAnalyzer -Force -Scope CurrentUser
}

$results = Invoke-ScriptAnalyzer -Path $root -Severity Error,Warning -Recurse
$results | Format-Table -AutoSize
if ($results | Where-Object Severity -eq Error) {
    throw 'PSScriptAnalyzer reported an error'
}

& "$root\tests\claude-compat.Tests.ps1"
& "$root\tests\windows-profiles.ps1"
```

The recorded run parsed every script, reported no analyzer errors, and passed
all 45 PowerShell compatibility assertions. It also generated fresh profile
configuration and completed real gateway requests with Claude Code 2.1.179,
2.1.186, 2.1.228, and 2.1.238.

## 7. Stop or destroy the VM

Stop the container while keeping the installed Windows volume:

```bash
docker stop qbraid-code-windows-e2e
```

Delete everything, including the Windows installation:

```bash
docker rm -f qbraid-code-windows-e2e
docker volume rm qbraid-code-windows-e2e
docker image rm qbraid-code-win-ssh
```
