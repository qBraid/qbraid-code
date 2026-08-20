# qbraid-code

Claude Code, powered by the **qBraid AI gateway**. One command installs everything
and leaves you in a working session: Claude Code itself, your qBraid credentials,
a live credit statusline, and the qBraid MCP tools.

Your own `claude` command stays untouched unless you ask for `--global`.

## Install

**macOS and Linux**

```bash
curl -fsSL https://qbraid.com/code.sh | bash
```

**Windows** (PowerShell)

```powershell
irm https://qbraid.com/code.ps1 | iex
```

That is all. The installer:

- installs **Claude Code** if you do not have it — a native binary, no Node.js and no administrator rights
- finds your **qBraid API key**, or opens the page where you can copy one
- shows you which **organization** the key belongs to and asks you to confirm it
- lets you **choose a default model** from the list the gateway is actually serving
- registers the **qBraid MCP** and signs you in
- installs a **statusline** showing your remaining qBraid credits
- runs a **real request** to prove it works before it says "ready"

Re-running it is safe.

## Use

```bash
qbraid-code                      # start a session
qbraid-code -p "explain this"    # ask one question and exit
qbraid-code --doctor             # check your setup
```

Every other flag goes straight through to `claude`, so `-c`, `--model`,
`--allowedTools` and the rest behave normally.

A session looks like this:

```
qbraid-code ⎇ main │ Claude Opus 5 │ C13 █░░░░░ │ 4281 credits
```

Folder and branch, the model you are talking to, how much of the context window
is used, and what you have left to spend.

### Take over the plain `claude` command

If qBraid is the only backend you use, install with `--global` and plain `claude`
will use it too:

```bash
curl -fsSL https://qbraid.com/code.sh | bash -s -- --global
```

```powershell
& ([scriptblock]::Create((irm https://qbraid.com/code.ps1))) -Global
```

## How it works

Claude Code speaks the Anthropic Messages API. So does the qBraid gateway — it
exposes an Anthropic-compatible surface at `/api/v1/ai/v1/messages` (the double
`v1` is deliberate, so `ANTHROPIC_BASE_URL` works with no client changes).

```
qbraid-code
   │  ANTHROPIC_BASE_URL=https://api-v2.qbraid.com/api/v1/ai
   │  ANTHROPIC_AUTH_TOKEN=qbr_...
   ▼
Claude Code ──Anthropic Messages──► qBraid AI gateway ──► Claude on Bedrock
```

**There is no proxy and no daemon.** Nothing runs in the background, nothing
listens on a port. The launcher sets four environment variables and execs
`claude`.

Requests are billed against your qBraid credits at the usual rate
(100 credits = $1).

## The qBraid MCP

The MCP endpoint at `mcp.qbraid.com/mcp` uses OAuth, not API keys, so it needs a
browser sign-in that your API key cannot do for you. The installer runs it during
setup, while you are still there. If you skipped it:

```bash
claude mcp login qbraid
```

## Layout

| Path | What |
|---|---|
| `~/.qbraid-code/env` | your key, gateway URL and default model (mode `600`) |
| `~/.qbraid-code/statusline.sh` | statusline script (`statusline.ps1` on Windows) |
| `~/.qbraid-code/credits.cache` | last known credit balance, refreshed every 60s |
| `~/.qbraid-code/credits.attempt` | when a refresh was last tried, so failures back off |
| `~/.local/bin/qbraid-code` | the launcher (`qbraid-code.cmd` on Windows) |
| `~/.claude/settings.json` | statusline wiring, plus gateway env with `--global` |

## Troubleshooting

Start with `qbraid-code --doctor`. It reports whether Claude Code is installed,
whether your key still works, your credit balance, whether the gateway is
reachable, and whether the MCP is registered.

**`key: REJECTED`** — your API key was deleted or expired. Make a new one at
[account.qbraid.com/account/api-keys](https://account.qbraid.com/account/api-keys)
and re-run the installer.

**`qbraid-code: command not found`** — `~/.local/bin` is not on your `PATH`. The
installer prints the line to add. On Windows, open a new terminal first.

**Wrong organization** — credits come from the organization the key belongs to.
Create a key under the organization you want, then re-run the installer.

**Statusline did not appear** — when `python3` is unavailable (no Xcode Command
Line Tools on macOS, or no `python3` on Linux) and `~/.claude/settings.json`
already exists, the installer cannot merge JSON safely and skips this step. It
prints the snippet to add by hand.

## Trust

The installer is served from `qbraid.com` but its source of truth is the `main`
branch of this repository, fetched at request time with no pin and no signature.
Anyone who can push here can change what a `curl | bash` runs, which is the
normal trade-off for a one-line installer that must stay current. Two things
follow from that: branch protection on `main` is load-bearing, and if you would
rather read before you run, fetch the script and inspect it first:

```bash
curl -fsSL https://qbraid.com/code.sh -o install.sh
less install.sh
bash install.sh
```

## Uninstall

```bash
rm -rf ~/.qbraid-code ~/.local/bin/qbraid-code
claude mcp remove qbraid
```

Then remove the `statusLine` entry (and the `env` block, if you used `--global`)
from `~/.claude/settings.json`.
