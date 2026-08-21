# qbraid-code

Claude Code, powered by the **qBraid AI gateway**.

The installer adds Claude Code, qBraid API-key profiles, a credit statusline,
GPT translation, and the qBraid MCP. It needs no Node.js or administrator rights.

## Install

**macOS and Linux**

```bash
curl -fsSL https://qbraid.com/code.sh | bash
```

**Windows PowerShell**

```powershell
irm https://qbraid.com/code.ps1 | iex
```

The first install creates the `default` profile. Add a named profile with the
same installer.

```bash
curl -fsSL https://qbraid.com/code.sh | bash -s -- --profile research
```

```powershell
& ([scriptblock]::Create((irm https://qbraid.com/code.ps1))) -Profile research
```

Set `QBRAID_CODE_PROFILE_LABEL` to show a different readable label. The
installer uses an authenticated organization name when the API returns one.
Otherwise it marks this label as local and adds a shortened verified
organization-ID tag.

Existing singleton installs migrate to `profiles/default` once. Migration does
not overwrite an existing profile. The old files remain available to sessions
that were already running.

## Use profiles

```bash
qbraid-code                           # use the active profile
qbraid-code --profile research       # bind this session to research
qbraid-code --profiles               # list profiles
qbraid-code --use-profile research   # select future sessions
qbraid-code --doctor                 # check the bound profile
```

`--profile` must be the first option. The launcher removes it before forwarding
the remaining arguments to Claude Code.

Each launch resolves one immutable metadata generation. Profile updates stage a
complete generation and atomically switch `current`. Failed updates leave the
previous generation and secret reference intact.

macOS stores keys in Keychain. Windows stores them in Credential Locker. Linux
uses Secret Service through `secret-tool` when available. Headless Linux falls
back to a documented private `0600` file.
Claude receives only a random per-launch loopback token. The status snapshot
contains no API key.

A profile slug belongs to one organization. Use a new slug when a key belongs
to another organization. Existing sessions stay pinned to their generation.

Every resume requires `--allow-profile-resume`. Confirm the intended account
with `--profile NAME --allow-profile-resume --resume ...`.

The launcher excludes project and local Claude settings. Their hooks can read
process credentials or replace the gateway. User settings still load. Gateway
credentials are pinned through higher-precedence CLI settings.

The statusline renders the account beside its balance.

```text
qbraid-code ⎇ main │ Claude Opus 5 │ C13 █░░░░░ │ qBraid Research Lab · 4281 credits
```

The `qBraid` word uses the qBraid violet accent. Warning and low-credit colors
remain semantic.
Unverified profile labels include `(local)`. Their account segment also includes
a shortened verified organization ID. Credit snapshots show `stale` after five
minutes without a successful launch refresh.

### GPT models

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

### Context windows

The installer stores exact model IDs and context limits in each profile's
`models.tsv`. Verified built-in fallbacks cover Sol, Opus, Haiku, and the
GPT-5.4 family. Unknown models stay at the conservative 200,000-token policy.

One-million-token models use Claude Code's `[1m]` model marker. Sol's
1,050,000-token window is advertised conservatively as 1,000,000 tokens.
Other gateway models use `CLAUDE_CODE_MAX_CONTEXT_TOKENS` with their catalog
value.

Context policy belongs to the Claude Code process. Gateway picker discovery is
disabled because its rows can mix incompatible context classes. Relaunch with
`--model` to change models. This keeps accounting accurate.

### Thinking

Claude Code sends adaptive thinking, display policy, and effort for current
Opus models. qbraid-api must preserve those fields at the Bedrock boundary.
Deploy the coordinated qbraid-api adaptive-thinking fix before this version.

The older global thinking-disable workaround is gone. A live Sol probe also
succeeded with Claude Code's default thinking when MCP tools were excluded. The
128-tool limit is independent of thinking.

### Plain `claude`

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

## qBraid MCP

The MCP endpoint uses OAuth rather than API keys. Sign in with a browser.

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

Windows uses the same layout under `%USERPROFILE%\.qbraid-code`.

## Troubleshooting

Start with `qbraid-code --doctor`.

**Rejected key.** Create a key at
[account.qbraid.com/account/api-keys](https://account.qbraid.com/account/api-keys),
then update the affected profile.

**Wrong account label.** Reinstall with `QBRAID_CODE_PROFILE_LABEL` set to a
readable local name. API-key authentication does not always expose an
authoritative organization name.

**GPT proxy unavailable.** Re-run the installer for that profile. Claude models
continue to use the gateway directly.

**Statusline missing.** Add the printed `statusLine` entry to
`~/.claude/settings.json`. The Unix installer does not rewrite existing JSON
without a real parser.

## Uninstall

```bash
qbraid-code --stop
rm -rf ~/.qbraid-code ~/.local/bin/qbraid-code ~/.local/bin/qbraid-code.home
claude mcp remove qbraid
```

Remove the qBraid `statusLine` from `~/.claude/settings.json`.
