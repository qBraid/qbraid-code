# qbraid-code

Use Claude Code through the qBraid AI gateway.

Install `qbraid-code` without Node.js or administrator rights. Create a separate
API-key profile for each qBraid organization. The statusline shows the bound
organization, its credit balance, the model, and context use.

## Install

**macOS and Linux**

```bash
curl -fsSL https://qbraid.com/code.sh | bash
```

**Windows PowerShell**

```powershell
irm https://qbraid.com/code.ps1 | iex
```

An install without `--profile` creates the `default` profile. To add another
organization, run the installer again with a new profile name.

```bash
curl -fsSL https://qbraid.com/code.sh | bash -s -- --profile research
```

```powershell
& ([scriptblock]::Create((irm https://qbraid.com/code.ps1))) -Profile research
```

The installer uses the authenticated organization name when the API returns
one. Otherwise, set a readable local name before you run the installer.

```bash
export QBRAID_CODE_PROFILE_LABEL="Research Lab"
```

```powershell
$env:QBRAID_CODE_PROFILE_LABEL = 'Research Lab'
```

The statusline marks a user-provided name as local. When available, it also
shows a shortened verified organization ID.

Older installs that use one account migrate to `profiles/default` once. Migration does
not overwrite an existing profile. A running legacy proxy keeps its private
config until it exits. The next launch removes the retired secret files.

## Start a session

Start an interactive session with the active organization and default model.

```bash
qbraid-code
```

Send one prompt and exit.

```bash
qbraid-code -p "explain this error"
```

Run `qbraid-code --doctor` to check the active profile.

## Switch organizations

List the installed organization profiles. The active profile has an asterisk.

```bash
qbraid-code --profiles
```

Use one organization for the next session only.

```bash
qbraid-code --profile research
```

Set the organization for future sessions.

```bash
qbraid-code --use-profile research
```

Run a setup check against a specific organization.

```bash
qbraid-code --profile research --doctor
```

Put `--profile NAME` first. The launcher removes both arguments before it starts
Claude Code.

To update a profile, close its running sessions and run the installer again.
The installer stages a complete metadata generation, then switches `current`.
If the update fails, the previous generation and key remain active.

## Protect profile credentials

macOS stores keys in Keychain. Windows stores them in Credential Locker. Linux
uses Secret Service through `secret-tool` when available. Headless Linux falls
back to a private file with mode `0600`.

Claude receives only a random per-launch loopback token. The status snapshot
contains no API key.

A profile name belongs to one organization. If a key belongs to another
organization, create a new profile. Running sessions stay bound to their
original profile and generation.

Confirm the organization every time you resume a conversation.

```bash
qbraid-code --profile research --allow-profile-resume --resume SESSION_ID
```

The launcher excludes project and local Claude settings. This prevents a
project hook from reading the session credential or replacing the gateway URL.
The launcher still loads user settings.

## Read the statusline

The statusline shows the organization that pays for the current session.
Check this name before you continue work in a different organization.

```text
qbraid-code ⎇ main │ Claude Opus 5 │ C13 █░░░░░ │ qBraid Research Lab · 4281 credits
```

A running session cannot switch organizations. Exit the session, then start a
new one with `--profile NAME`.

The `qBraid` word uses the qBraid violet accent. Warning and low-credit colors
keep their usual meaning. A local organization name includes `(local)` and a
shortened verified organization ID.

```text
qBraid Research Lab (local · org a1b2c3d4…) · 4281 credits
```

Credit snapshots show `stale` after five minutes without a successful launch
refresh.

## Choose a model

Choose the model when you start the session.

### Use a GPT model

```bash
qbraid-code --model gpt-5.6-sol
qbraid-code --model gpt-5.4-mini -p "explain this error"
```

CLIProxyAPI runs on loopback only. Claude models pass through unchanged. GPT
models use the gateway OpenAI-compatible surface. Each launch owns a random
local bearer, runtime port, and proxy process. The proxy stops with the session.
Its private runtime config is removed during launch cleanup.

GPT models accept at most 128 tools. Use `--strict-mcp-config` when many MCP
servers would exceed that limit.

### Model context limits

The installer stores exact model IDs and context limits in each profile's
`models.tsv`. Verified built-in fallbacks cover Sol, Opus, Haiku, and the
GPT-5.4 family. Unknown models stay at the conservative 200,000-token policy.

One-million-token models use Claude Code's `[1m]` model marker. Sol's
1,050,000-token window is advertised conservatively as 1,000,000 tokens.
Other gateway models use `CLAUDE_CODE_MAX_CONTEXT_TOKENS` with their catalog
value.

Choose the model when you start `qbraid-code`. To change models, exit and
relaunch with `--model`. The launcher disables the in-session gateway picker
because one process cannot use several context limits safely.

### Model thinking

Claude Code sends adaptive thinking, display policy, and effort for current
Opus models.

The older global thinking-disable workaround is gone. The 128-tool limit is
independent of thinking.

## Keep plain `claude` unchanged

The installer leaves plain `claude` untouched. Legacy qBraid gateway variables
are removed from user settings during migration. `--global` is rejected because
a project setting can replace the base URL and exfiltrate a reusable key.

## How it works

Claude Code sends Anthropic Messages requests to the qBraid gateway. The local
proxy translates only the GPT routes.

```text
qbraid-code ── loopback CLIProxyAPI
                 ├─ Claude passthrough ── qBraid gateway
                 └─ GPT translation ──── qBraid gateway
```

Requests use qBraid credits at the usual rate. One hundred credits equal one US
dollar.

## Sign in to the qBraid MCP

The MCP endpoint uses OAuth rather than API keys. Sign in through your browser.

```bash
claude mcp login qbraid
```

## Layout

| Path | Purpose |
|---|---|
| `~/.qbraid-code/active-profile` | Future-session profile pointer |
| `~/.qbraid-code/profiles/<name>/current` | Atomic metadata-generation pointer |
| `~/.qbraid-code/profiles/<name>/generations/*/env` | URLs, model, secret reference, and proxy binary |
| `~/.qbraid-code/profiles/<name>/generations/*/label*` | Readable label and verified/local provenance |
| `~/.qbraid-code/profiles/<name>/generations/*/models.tsv` | Exact model context facts |
| `~/.qbraid-code/secrets/*` | Linux-only private key fallback |
| `~/.qbraid-code/runtime.*` | Short-lived proxy state |
| `~/.qbraid-code/session.*` | Short-lived non-secret status snapshot |
| `~/.qbraid-code/statusline.sh` | Unix statusline adapter |
| `~/.local/bin/qbraid-code` | Unix launcher |

Windows stores profile and runtime files under
`%USERPROFILE%\.qbraid-code`. It installs the launcher under
`%USERPROFILE%\.local\bin`.

## Troubleshooting

Start with `qbraid-code --doctor`.

**Rejected key.** Create a key at
[account.qbraid.com/account/api-keys](https://account.qbraid.com/account/api-keys),
then update the affected profile.

**Wrong organization name.** Reinstall that profile with
`QBRAID_CODE_PROFILE_LABEL` set to a readable local name. API-key
authentication does not always expose an authoritative organization name.

**Local proxy unavailable.** Re-run the installer for that profile. Every model
uses one launch-owned loopback proxy.

**Statusline missing.** Add the printed `statusLine` entry to
`~/.claude/settings.json`. The Unix installer does not rewrite existing JSON
without a real parser.

## Uninstall

On macOS or Linux, stop the proxies and remove the installed files.

```bash
qbraid-code --stop
rm -rf ~/.qbraid-code ~/.local/bin/qbraid-code ~/.local/bin/qbraid-code.home
claude mcp remove qbraid
```

On Windows, run these commands in PowerShell.

```powershell
qbraid-code --stop
Remove-Item -Recurse -Force "$env:USERPROFILE\.qbraid-code"
Remove-Item -Force "$env:USERPROFILE\.local\bin\qbraid-code.cmd"
Remove-Item -Force "$env:USERPROFILE\.local\bin\qbraid-launch.ps1"
Remove-Item -Force "$env:USERPROFILE\.local\bin\qbraid-code.home"
claude mcp remove qbraid
```

Remove the qBraid `statusLine` from the Claude user settings file. Delete
`qbraid-code` entries from Keychain or Windows Credential Manager. On Linux,
delete the matching Secret Service entries. Removing `~/.qbraid-code` also
deletes the headless Linux file fallback.
