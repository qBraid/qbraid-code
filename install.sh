#!/usr/bin/env bash
# qbraid-code installer — Claude Code, powered by the qBraid AI gateway.
#
#   curl -fsSL https://qbraid.com/code.sh | bash
#   curl -fsSL https://qbraid.com/code.sh | bash -s -- --global
#
# There is no proxy and no daemon. The qBraid gateway serves an
# Anthropic-compatible surface, so Claude Code talks to it directly through
# ANTHROPIC_BASE_URL. The double `v1` in /api/v1/ai/v1/messages is deliberate,
# not a typo: Claude Code appends /v1/messages to whatever base URL it is
# given.
#
# Everything this writes lives in ~/.qbraid-code and ~/.local/bin.
# Re-running is safe.
set -euo pipefail

GATEWAY_HOST="api-v2.qbraid.com"
API_BASE="https://${GATEWAY_HOST}/api/v1"
GATEWAY_URL="${API_BASE}/ai"
MCP_NAME="qbraid"
# Local translation proxy for the gateway's GPT models. Claude Code speaks the
# Anthropic Messages API; the gateway serves GPT only on its OpenAI-compat
# surface. CLIProxyAPI bridges the two on loopback. Port is qbraid-code's own —
# claudeseek and other tools use neighbouring ports.
PROXY_PORT="${QBRAID_CODE_PROXY_PORT:-8320}"
PROXY_REPO="router-for-me/CLIProxyAPI"
MCP_URL="https://mcp.qbraid.com/mcp"
KEYS_URL="https://account.qbraid.com/account/api-keys"
CLAUDE_MIN_VERSION="2.1.186"
CLAUDE_TESTED_MAX="2.1.238"

# Companion files are fetched from qbraid.com first. That is the whole point
# of the proxy: on a campus network that blocks raw.githubusercontent.com, an
# install that got this far would otherwise die on its last step.
SITE_BASE="https://qbraid.com/code"
RAW_BASE="https://raw.githubusercontent.com/qBraid/qbraid-code/main"
GH_CONTENTS="/repos/qBraid/qbraid-code/contents"

HOME_DIR="${QBRAID_CODE_HOME:-$HOME/.qbraid-code}"
BIN_DIR="${QBRAID_CODE_BIN_DIR:-$HOME/.local/bin}"
CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
CLAUDE_JSON="$HOME/.claude.json"

GLOBAL=0
GLOBAL_APPLIED=0
for arg in "$@"; do
  case "$arg" in
    --global) GLOBAL=1 ;;
    --help|-h)
      cat <<'EOF'
qbraid-code installer

  --global   also point the plain `claude` command at qBraid
  --help     show this message

Environment:
  QBRAID_API_KEY        use this key instead of prompting
  QBRAID_CODE_MODEL     use this model instead of prompting
  QBRAID_CODE_HOME      config directory (default ~/.qbraid-code)
  QBRAID_CODE_BIN_DIR   install directory (default ~/.local/bin)
  QBRAID_CODE_CLAUDE_POLICY
                         prompt, upgrade, fail, or continue
EOF
      exit 0 ;;
    *) ;;
  esac
done

# ------------------------------------------------------------------ output

if [ -t 1 ]; then
  bold=$(tput bold 2>/dev/null || true); dim=$(tput dim 2>/dev/null || true)
  red=$(tput setaf 1 2>/dev/null || true); grn=$(tput setaf 2 2>/dev/null || true)
  ylw=$(tput setaf 3 2>/dev/null || true); rst=$(tput sgr0 2>/dev/null || true)
else
  bold=""; dim=""; red=""; grn=""; ylw=""; rst=""
fi

say()  { printf '%s==>%s %s\n' "$bold" "$rst" "$*"; }
ok()   { printf '  %s+%s %s\n' "$grn" "$rst" "$*"; }
warn() { printf '  %s!%s %s\n' "$ylw" "$rst" "$*"; }
die()  { printf '\n%serror:%s %s\n' "$red" "$rst" "$*" >&2; exit 1; }

# When this script is piped from curl, stdin is the script itself — prompts
# must read the keyboard directly. If there is no terminal at all (CI), the
# install has to be driven entirely by environment variables.
# `[ -r /dev/tty ]` passes even where the device cannot actually be opened
# (some CI harnesses report "Device not configured" only on open), so probe by
# really opening it in both directions.
TTY=""
if (exec 3</dev/tty) 2>/dev/null && (exec 3>/dev/tty) 2>/dev/null; then TTY=/dev/tty; fi

prompt() { # prompt <question> -> echoes the answer
  local q="$1" reply=""
  [ -n "$TTY" ] || die "no terminal available for input. Set QBRAID_API_KEY and re-run."
  printf '%s%s%s ' "$bold" "$q" "$rst" > "$TTY"
  IFS= read -r reply < "$TTY"
  printf '%s' "$reply"
}

prompt_secret() { # prompt_secret <question> -> echoes the answer, no terminal echo
  local q="$1" reply=""
  [ -n "$TTY" ] || die "no terminal available for input. Set QBRAID_API_KEY and re-run."
  printf '%s%s%s ' "$bold" "$q" "$rst" > "$TTY"
  IFS= read -rs reply < "$TTY"
  printf '\n' > "$TTY"
  printf '%s' "$reply"
}

confirm() { # confirm <question> <default y|n> -> 0 if yes
  local q="$1" def="${2:-y}" reply="" hint="[Y/n]"
  [ "$def" = n ] && hint="[y/N]"
  if [ -z "$TTY" ]; then
    # Say so out loud. A silent auto-yes previously printed "organization
    # confirmed" when nobody had confirmed anything.
    warn "no terminal — assuming '$def' for: $q"
    [ "$def" = y ]
    return
  fi
  printf '%s%s%s %s ' "$bold" "$q" "$rst" "$hint" > "$TTY"
  IFS= read -r reply < "$TTY"
  reply="$(printf '%s' "$reply" | tr '[:upper:]' '[:lower:]')"
  [ -z "$reply" ] && reply="$def"
  [ "$reply" = y ] || [ "$reply" = yes ]
}

# ------------------------------------------------------ Claude compatibility

parse_claude_version() { # parse_claude_version <claude --version output>
  (
    set +o pipefail
    printf '%s' "$1" | grep -o '[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*' | head -1
  ) || true
}

compare_versions() { # compare_versions <left> <right> -> -1, 0, or 1
  awk -v left="$1" -v right="$2" 'BEGIN {
    split(left, l, "."); split(right, r, ".")
    for (i = 1; i <= 3; i++) {
      if ((l[i] + 0) < (r[i] + 0)) { print -1; exit }
      if ((l[i] + 0) > (r[i] + 0)) { print 1; exit }
    }
    print 0
  }'
}

claude_version_status() { # claude_version_status <version>
  local version="$1" compared
  [ -n "$version" ] || { printf 'unknown'; return; }
  compared=$(compare_versions "$version" "$CLAUDE_MIN_VERSION")
  [ "$compared" -ge 0 ] || { printf 'below-minimum'; return; }
  compared=$(compare_versions "$version" "$CLAUDE_TESTED_MAX")
  [ "$compared" -le 0 ] && printf 'tested' || printf 'newer-than-tested'
}

claude_policy_action() { # claude_policy_action <policy> <interactive yes|no>
  case "$1" in
    upgrade|fail|continue) printf '%s' "$1" ;;
    prompt) [ "$2" = yes ] && printf 'prompt' || printf 'fail' ;;
    *) printf 'invalid' ;;
  esac
}

claude_supports_mcp_command() { # claude_supports_mcp_command <command>
  local help
  help=$(claude mcp --help 2>/dev/null || true)
  printf '%s\n' "$help" | grep -Eq "^[[:space:]]+$1([[:space:]]|$)"
}

claude_supports_mcp_http() {
  local help
  help=$(claude mcp add --help 2>/dev/null || true)
  printf '%s\n' "$help" | grep -Eq -- '--transport.*http'
}

claude_supports_mcp_user_scope() {
  local help
  help=$(claude mcp add --help 2>/dev/null || true)
  printf '%s\n' "$help" | grep -Eq -- '--scope.*user'
}

install_claude_stable() {
  warn "installing Claude Code from Anthropic's stable channel"
  curl -fsSL https://claude.ai/install.sh | bash -s stable \
    || die "Claude Code stable-channel install failed. See https://claude.com/product/claude-code"
  export PATH="$HOME/.local/bin:$PATH"
  hash -r
  command -v claude >/dev/null 2>&1 \
    || die "Claude Code installed but \`claude\` is not on PATH."
}

refresh_claude_state() {
  local output
  output=$(claude --version 2>/dev/null || true)
  CLAUDE_VERSION=$(parse_claude_version "$output")
  CLAUDE_VERSION_STATUS=$(claude_version_status "$CLAUDE_VERSION")
  CLAUDE_MCP_ADD=0; CLAUDE_MCP_GET=0; CLAUDE_MCP_LOGIN=0
  CLAUDE_MCP_HTTP=0; CLAUDE_MCP_USER_SCOPE=0
  claude_supports_mcp_command add && CLAUDE_MCP_ADD=1
  claude_supports_mcp_command get && CLAUDE_MCP_GET=1
  claude_supports_mcp_command login && CLAUDE_MCP_LOGIN=1
  claude_supports_mcp_http && CLAUDE_MCP_HTTP=1
  claude_supports_mcp_user_scope && CLAUDE_MCP_USER_SCOPE=1
  return 0
}

claude_required_capabilities_present() {
  [ "$CLAUDE_MCP_ADD" = 1 ] && [ "$CLAUDE_MCP_GET" = 1 ] \
    && [ "$CLAUDE_MCP_HTTP" = 1 ] && [ "$CLAUDE_MCP_USER_SCOPE" = 1 ]
}

ensure_claude_compatible() {
  local policy="${QBRAID_CODE_CLAUDE_POLICY:-prompt}" interactive=no action issue="" upgraded=0
  [ -n "$TTY" ] && interactive=yes
  case "$policy" in
    prompt|upgrade|fail|continue) ;;
    *) die "QBRAID_CODE_CLAUDE_POLICY must be prompt, upgrade, fail, or continue." ;;
  esac

  if ! command -v claude >/dev/null 2>&1; then
    action=$(claude_policy_action "$policy" "$interactive")
    case "$action" in
      upgrade) install_claude_stable ;;
      prompt)
        confirm "Claude Code is not installed. Install the stable channel now?" y \
          && install_claude_stable \
          || die "Claude Code is required. Re-run with QBRAID_CODE_CLAUDE_POLICY=upgrade to install it."
        ;;
      *) die "Claude Code is not installed. Re-run with QBRAID_CODE_CLAUDE_POLICY=upgrade." ;;
    esac
  fi

  refresh_claude_state
  case "$CLAUDE_VERSION_STATUS" in
    unknown) issue="could not determine its version" ;;
    below-minimum) issue="version $CLAUDE_VERSION is below the supported minimum $CLAUDE_MIN_VERSION" ;;
  esac
  if ! claude_required_capabilities_present; then
    [ -n "$issue" ] && issue="$issue; "
    issue="${issue}required HTTP MCP commands are unavailable"
  fi

  if [ -n "$issue" ]; then
    action=$(claude_policy_action "$policy" "$interactive")
    if [ "$CLAUDE_VERSION_STATUS" = newer-than-tested ]; then
      case "$action" in
        continue|prompt)
          warn "Claude Code $CLAUDE_VERSION is newer than tested and lacks required capabilities; refusing to downgrade it and continuing with reduced compatibility."
          ;;
        *)
          die "Claude Code $CLAUDE_VERSION is newer than tested and lacks required capabilities. Refusing to downgrade it; set QBRAID_CODE_CLAUDE_POLICY=continue to skip unavailable features."
          ;;
      esac
      action=handled
    fi
    case "$action" in
      upgrade)
        warn "the installed Claude Code is incompatible: $issue"
        install_claude_stable; upgraded=1
        ;;
      prompt)
        warn "the installed Claude Code is incompatible: $issue"
        if confirm "Upgrade Claude Code to the stable channel now?" y; then
          install_claude_stable; upgraded=1
        else
          warn "continuing with reduced compatibility at your request"
        fi
        ;;
      continue) warn "continuing with an unsupported Claude Code: $issue" ;;
      fail)
        die "the installed Claude Code is incompatible: $issue. Upgrade it, or explicitly set QBRAID_CODE_CLAUDE_POLICY=continue."
        ;;
      handled) ;;
    esac
  fi

  if [ "$upgraded" = 1 ]; then
    refresh_claude_state
    [ "$CLAUDE_VERSION_STATUS" != unknown ] \
      && [ "$CLAUDE_VERSION_STATUS" != below-minimum ] \
      && claude_required_capabilities_present \
      || die "Claude Code was upgraded, but version $CLAUDE_MIN_VERSION+ with HTTP MCP support is still unavailable."
  fi

  case "$CLAUDE_VERSION_STATUS" in
    tested) ok "Claude Code $CLAUDE_VERSION" ;;
    newer-than-tested) warn "Claude Code $CLAUDE_VERSION is newer than the latest tested version ($CLAUDE_TESTED_MAX); continuing without downgrading." ;;
    *) warn "Claude Code ${CLAUDE_VERSION:-present} remains outside the supported range; unavailable features will be skipped." ;;
  esac
}

# ---------------------------------------------------------------- 1. platform

case "$(uname -s)" in
  Darwin) OS=darwin ;;
  Linux)  OS=linux ;;
  *) die "unsupported OS: $(uname -s). On Windows, run this in PowerShell instead:
    irm https://qbraid.com/code.ps1 | iex" ;;
esac
case "$(uname -m)" in
  arm64|aarch64) ARCH=arm64 ;;
  x86_64|amd64)  ARCH=x64 ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac
command -v curl >/dev/null || die "curl is required but not installed."
say "Platform: $OS/$ARCH"

mkdir -p "$HOME_DIR" "$BIN_DIR" "$CLAUDE_DIR"

# Merging JSON into an existing settings file needs a real parser. On macOS
# /usr/bin/python3 is a stub that pops a GUI installer prompt unless the
# Command Line Tools are present, so check for those before trusting it.
have_python() {
  command -v python3 >/dev/null 2>&1 || return 1
  if [ "$OS" = darwin ] && ! xcode-select -p >/dev/null 2>&1; then return 1; fi
  python3 -c 'import json' >/dev/null 2>&1
}

# ------------------------------------------------------------ 2. claude code

say "Claude Code"
ensure_claude_compatible

# ------------------------------------------------------------- 3. credential

# `set -o pipefail` is on, so a grep that matches NOTHING makes the whole
# pipeline non-zero, and `set -e` then kills the installer with no message at
# all. An absent field is a normal outcome here (an error body has no `name`),
# not an error, so pipefail is disabled inside the extracting subshell.
json_str() { # json_str <blob> <key> -> the value, or empty
  (
    set +o pipefail
    printf '%s' "$1" | grep -o "\"$2\":\"[^\"]*\"" | head -1 | sed "s/\"$2\":\"//; s/\"$//"
  )
}

json_num() { # json_num <blob> <key> -> the value, or empty
  (
    set +o pipefail
    printf '%s' "$1" | grep -o "\"$2\":-\?[0-9.]*" | head -1 | sed 's/.*://'
  )
}

HTTP_STATUS=""
API_BODY=""
# Sets API_BODY and HTTP_STATUS in the CALLER (000 = could not connect).
# It must not print the body: `x=$(api_get ...)` would run this in a subshell
# and the status would never make it back, so every failure read as "rejected".
api_get() { # api_get <url> <key> [org-id]
  local url="$1" key="$2" org="${3:-}" tmp
  API_BODY=""
  tmp=$(mktemp) || { HTTP_STATUS="000"; return 0; }
  if [ -n "$org" ]; then
    HTTP_STATUS=$(curl -sS -m 25 -o "$tmp" -w '%{http_code}' "$url" \
      -H "X-API-Key: $key" -H "X-Organization-Id: $org" 2>/dev/null) || HTTP_STATUS="000"
  else
    HTTP_STATUS=$(curl -sS -m 25 -o "$tmp" -w '%{http_code}' "$url" \
      -H "X-API-Key: $key" 2>/dev/null) || HTTP_STATUS="000"
  fi
  API_BODY=$(cat "$tmp")
  rm -f "$tmp"
}

BALANCE=""
# 0 = accepted, 1 = rejected by qBraid, 2 = could not reach qBraid.
# Collapsing 2 into 1 told people their key was bad when their wifi was.
try_key() {
  api_get "$API_BASE/billing/credits/balance" "$1"
  case "$HTTP_STATUS" in
    200) BALANCE="$API_BODY"; return 0 ;;
    000) return 2 ;;
    *)   return 1 ;;
  esac
}

read_qbraidrc_key() {
  [ -f "$HOME/.qbraid/qbraidrc" ] || return 1
  sed -n 's/^[[:space:]]*api-key[[:space:]]*=[[:space:]]*//p' "$HOME/.qbraid/qbraidrc" \
    | head -1 | tr -d '[:space:]'
}

unreachable_msg="could not reach $GATEWAY_HOST. Check your internet connection and re-run."

say "qBraid account"
API_KEY="${QBRAID_API_KEY:-}"
KEY_SOURCE="QBRAID_API_KEY"

if [ -n "$API_KEY" ]; then
  rc=0; try_key "$API_KEY" || rc=$?
  case $rc in
    0) ;;
    2) die "$unreachable_msg" ;;
    *) die "the API key from $KEY_SOURCE was rejected by qBraid." ;;
  esac
else
  if CANDIDATE=$(read_qbraidrc_key) && [ -n "$CANDIDATE" ]; then
    rc=0; try_key "$CANDIDATE" || rc=$?
    case $rc in
      0) API_KEY="$CANDIDATE"; KEY_SOURCE="your qBraid CLI config" ;;
      2) die "$unreachable_msg" ;;
      *) warn "the key in your qBraid CLI config is no longer valid — ignoring it" ;;
    esac
  fi
fi

if [ -z "$API_KEY" ]; then
  cat <<EOF

  You need a qBraid API key. Opening the page where you can copy one:

    ${bold}$KEYS_URL${rst}

  Sign in, create a key if you do not have one, then copy it.

EOF
  case "$OS" in
    darwin) open "$KEYS_URL" >/dev/null 2>&1 || true ;;
    linux)  (xdg-open "$KEYS_URL" >/dev/null 2>&1 &) || true ;;
  esac

  ATTEMPT=0
  while [ -z "$API_KEY" ]; do
    ATTEMPT=$((ATTEMPT + 1))
    [ "$ATTEMPT" -gt 5 ] && die "too many attempts. Re-run once you have a working key."
    # Not echoed: this is a live credential and the terminal scrollback is shared.
    CANDIDATE=$(prompt_secret "Paste your qBraid API key:")
    CANDIDATE=$(printf '%s' "$CANDIDATE" | tr -d '[:space:]')
    if [ -z "$CANDIDATE" ]; then
      warn "nothing pasted — try again."
      continue
    fi
    rc=0; try_key "$CANDIDATE" || rc=$?
    case $rc in
      0) API_KEY="$CANDIDATE"; KEY_SOURCE="pasted" ;;
      2) warn "$unreachable_msg" ;;
      *) warn "qBraid did not accept that key. Check you copied all of it, then try again." ;;
    esac
  done
fi
ok "key accepted (from $KEY_SOURCE)"

# The key and model are written into a file that qbraid-code and statusline.sh
# both `.` as shell source, so anything exotic in them would be executed.
# Both are server-controlled strings; validate rather than trust.
case "$API_KEY" in
  ''|*[!A-Za-z0-9_.-]*) die "the API key contains unexpected characters — refusing to save it." ;;
esac

# ------------------------------------------------------- 4. organization check

ORG_ID=$(json_str "$BALANCE" organizationId)
CREDITS_RAW=$(json_num "$BALANCE" qbraidCredits)
if [ -n "$CREDITS_RAW" ]; then
  CREDITS=$(awk -v c="$CREDITS_RAW" 'BEGIN { printf "%.0f", c }' 2>/dev/null) || CREDITS="$CREDITS_RAW"
else
  CREDITS="unknown"
fi

# An API key cannot read its organization's NAME: /organizations/current needs
# a JWT org context and /organizations rejects key auth outright (both verified
# 2026-08-20). Showing a raw Mongo id and asking "is this right?" is worse than
# not asking — nobody recognises 507f1f77bcf86cd799439011. Show what the key
# DOES tell us (plan, credits), name the organization only when it resolves,
# and make the escape hatch the actionable sentence.
ORG_NAME=""
if [ -n "$ORG_ID" ]; then
  api_get "$API_BASE/organizations/current" "$API_KEY" "$ORG_ID"
  if [ "$HTTP_STATUS" = 200 ]; then
    ORG_DATA=$(printf '%s' "$API_BODY" | sed 's/.*"data"[[:space:]]*:[[:space:]]*{//')
    ORG_NAME=$(json_str "$ORG_DATA" name)
  fi
fi

PLAN=""
api_get "$GATEWAY_URL/quota" "$API_KEY"
[ "$HTTP_STATUS" = 200 ] && PLAN=$(json_str "$API_BODY" plan)

printf '\n'
if [ -n "$ORG_NAME" ]; then
  printf '  Organization: %s%s%s\n' "$bold" "$ORG_NAME" "$rst"
fi
[ -n "$PLAN" ] && printf '  Plan:         %s%s%s\n' "$bold" "$PLAN" "$rst"
printf '  Credits:      %s%s%s\n' "$bold" "$CREDITS" "$rst"
if [ -z "$ORG_NAME" ]; then
  printf '\n  These are the credits this API key can spend.\n'
  printf '  Using a different organization means creating a key under it at\n'
  printf '  %s%s%s\n' "$bold" "$KEYS_URL" "$rst"
fi
printf '\n'

if ! confirm "Continue with this account?" y; then
  cat <<EOF

  No problem. Create a key under the organization you want at
  ${bold}$KEYS_URL${rst}, then run this installer again.

EOF
  exit 1
fi
ok "account confirmed"

if [ "$CREDITS" != unknown ] && awk -v c="$CREDITS_RAW" 'BEGIN { exit !(c <= 0) }'; then
  warn "this organization has no credits left — requests will fail until it is topped up."
fi

# ------------------------------------------------------------- 5. model choice

say "Model"
MODEL="${QBRAID_CODE_MODEL:-}"
if [ -z "$MODEL" ]; then
  # The list is fetched live so new gateway models appear without a release here.
  api_get "$GATEWAY_URL/v1/models" "$API_KEY"
  MODEL_IDS=$(set +o pipefail; printf '%s' "$API_BODY" | grep -o '"id":"[^"]*"' | sed 's/"id":"//; s/"$//')
  if [ -z "$MODEL_IDS" ]; then
    warn "could not list models — defaulting to claude-sonnet-4-6"
    MODEL="claude-sonnet-4-6"
  elif [ -z "$TTY" ]; then
    MODEL=$(printf '%s\n' "$MODEL_IDS" | head -1)
  else
    MODEL_COUNT=$(printf '%s\n' "$MODEL_IDS" | wc -l | tr -d ' ')
    printf '\n  Available models:\n\n' > "$TTY"
    i=0
    while IFS= read -r m; do
      i=$((i + 1))
      printf '    %2d) %s\n' "$i" "$m" > "$TTY"
    done <<EOF
$MODEL_IDS
EOF
    printf '\n' > "$TTY"
    CHOICE=$(prompt "Choose a default model [1]:")
    CHOICE=$(printf '%s' "$CHOICE" | tr -d '[:space:]')
    [ -z "$CHOICE" ] && CHOICE=1
    # Reject 0 and anything out of range BEFORE sed sees it: GNU sed treats
    # line address 0 as an error and kills the installer under `set -e`.
    case "$CHOICE" in
      ''|*[!0-9]*) CHOICE=1 ;;
    esac
    if [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt "$MODEL_COUNT" ]; then
      warn "no such option — using 1."
      CHOICE=1
    fi
    MODEL=$(printf '%s\n' "$MODEL_IDS" | sed -n "${CHOICE}p")
    [ -n "$MODEL" ] || MODEL=$(printf '%s\n' "$MODEL_IDS" | head -1)
  fi
fi
case "$MODEL" in
  ''|*[!A-Za-z0-9_.:/-]*) die "the model name contains unexpected characters — refusing to save it." ;;
esac
ok "default model: $MODEL"

# ---------------------------------------------------------------- 6. env file

OLD_UMASK=$(umask)
umask 077
cat > "$HOME_DIR/env" <<EOF
QBRAID_CODE_BASE_URL=$GATEWAY_URL
QBRAID_CODE_API_BASE=$API_BASE
QBRAID_CODE_TOKEN=$API_KEY
QBRAID_CODE_MODEL=$MODEL
EOF
chmod 600 "$HOME_DIR/env"
umask "$OLD_UMASK"
# The cached balance belongs to whichever key was configured before. Re-running
# with a key from a different organization must not keep rendering the old
# organization's wallet.
rm -f "$HOME_DIR/credits.cache" "$HOME_DIR/credits.attempt"
ok "config written to $HOME_DIR/env"

# ------------------------------------------------- 7. launcher and statusline

# When piped from curl there is no local checkout, so companion files are
# fetched: qbraid.com first (allowlisted on networks that block GitHub), then
# raw.githubusercontent, then `gh` as a last resort if both are unreachable.
SRC_DIR=""
if [ -f "${BASH_SOURCE[0]:-}" ]; then
  CAND=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  [ -f "$CAND/qbraid-code" ] && SRC_DIR="$CAND"
fi

fetch_file() { # fetch_file <name> <dest>
  local name="$1" dest="$2"
  if [ -n "$SRC_DIR" ]; then
    cp "$SRC_DIR/$name" "$dest"; return 0
  fi
  if curl -fsSL -m 30 -o "$dest" "$SITE_BASE/$name" 2>/dev/null && [ -s "$dest" ]; then return 0; fi
  if curl -fsSL -m 30 -o "$dest" "$RAW_BASE/$name" 2>/dev/null && [ -s "$dest" ]; then return 0; fi
  command -v gh >/dev/null 2>&1 \
    || die "could not download $name from qbraid.com or GitHub. Check your connection and re-run."
  gh api -H "Accept: application/vnd.github.raw" "$GH_CONTENTS/$name" > "$dest" \
    || die "could not download $name — is \`gh auth login\` done, and are you in the qBraid org?"
  [ -s "$dest" ] || die "downloaded $name but it is empty."
}

fetch_file qbraid-code "$BIN_DIR/qbraid-code"
chmod 0755 "$BIN_DIR/qbraid-code"
# QBRAID_CODE_HOME is resolved once, here, and baked into the installed copies.
# Re-deriving it at run time meant a non-default install reported success and
# then could not find its own config in a fresh shell.
sed "s|^HOME_DIR=.*|HOME_DIR=\"\${QBRAID_CODE_HOME:-$HOME_DIR}\"|" \
  "$BIN_DIR/qbraid-code" > "$BIN_DIR/qbraid-code.tmp" \
  && mv "$BIN_DIR/qbraid-code.tmp" "$BIN_DIR/qbraid-code" \
  && chmod 0755 "$BIN_DIR/qbraid-code"
ok "launcher installed to $BIN_DIR/qbraid-code"

fetch_file statusline.sh "$HOME_DIR/statusline.sh"
chmod 0755 "$HOME_DIR/statusline.sh"
ok "statusline installed to $HOME_DIR/statusline.sh"

# ------------------------------------------------ 7b. GPT models (local proxy)

# Non-fatal throughout: Claude models work without any of this. If a step
# fails, the install continues and `qbraid-code --model gpt-*` explains itself.
say "GPT models"

# The /model picker integration needs `claude-code.disable-cloaking-model-list`
# (CLIProxyAPI >= 7.2.135-ish); an older binary would show the picker reversed
# pseudo-model gibberish. Feature-detect on the binary itself, not a version
# number.
proxy_supports_picker() {
  # grep -q exits at the first match, strings then dies of SIGPIPE, and
  # pipefail would turn that into failure-on-success. Same class of bug as
  # the json extractors; same cure.
  (
    set +o pipefail
    strings "$1" 2>/dev/null | grep -q "disable-cloaking-model-list"
  )
}

PROXY_BIN=""
for cand in "$(command -v cliproxyapi 2>/dev/null || true)" "$HOME_DIR/cliproxyapi"; do
  [ -n "$cand" ] && [ -x "$cand" ] || continue
  if proxy_supports_picker "$cand"; then
    PROXY_BIN="$cand"
    ok "using existing $PROXY_BIN"
    break
  fi
  warn "$cand is too old for the /model picker — upgrading"
done
if [ -z "$PROXY_BIN" ] && [ "$OS" = darwin ] && command -v brew >/dev/null 2>&1; then
  if brew install cliproxyapi >/dev/null 2>&1 || brew upgrade cliproxyapi >/dev/null 2>&1; then
    CAND="$(command -v cliproxyapi 2>/dev/null || true)"
    if [ -n "$CAND" ] && proxy_supports_picker "$CAND"; then
      PROXY_BIN="$CAND"
      ok "proxy installed via Homebrew"
    fi
  fi
fi
if [ -z "$PROXY_BIN" ]; then
  PROXY_ARCH="$ARCH"; [ "$PROXY_ARCH" = arm64 ] && PROXY_ARCH=aarch64
  [ "$PROXY_ARCH" = x64 ] && PROXY_ARCH=amd64
  TAG=$( (set +o pipefail; curl -fsSL -m 20 "https://api.github.com/repos/$PROXY_REPO/releases/latest" 2>/dev/null         | grep -o '"tag_name": *"[^"]*"' | head -1 | sed 's/.*"tag_name": *"//; s/"$//') || true)
  if [ -n "$TAG" ]; then
    VER="${TAG#v}"
    PROXY_URL="https://github.com/$PROXY_REPO/releases/download/$TAG/CLIProxyAPI_${VER}_${OS}_${PROXY_ARCH}.tar.gz"
    PROXY_TMP=$(mktemp -d)
    if curl -fsSL -m 120 -o "$PROXY_TMP/cpa.tar.gz" "$PROXY_URL" 2>/dev/null \
      && tar xzf "$PROXY_TMP/cpa.tar.gz" -C "$PROXY_TMP" cli-proxy-api 2>/dev/null \
      && proxy_supports_picker "$PROXY_TMP/cli-proxy-api"; then
      install -m 0755 "$PROXY_TMP/cli-proxy-api" "$HOME_DIR/cliproxyapi"
      PROXY_BIN="$HOME_DIR/cliproxyapi"
      ok "proxy installed to $PROXY_BIN"
    fi
    rm -rf "$PROXY_TMP"
  fi
fi

GPT_MODELS=""
if [ -n "$PROXY_BIN" ]; then
  # The gateway's OpenAI-compat surface lists every model; only the gpt-* ones
  # need the proxy — Claude models go to the Anthropic surface directly.
  api_get "$GATEWAY_URL/models" "$API_KEY"
  GPT_MODELS=$(set +o pipefail; printf '%s' "$API_BODY" | grep -o '"id":"gpt-[^"]*"' | sed 's/"id":"//; s/"$//')
  if [ -z "$GPT_MODELS" ]; then
    warn "could not list GPT models from the gateway — skipping proxy config"
  else
    if [ ! -s "$HOME_DIR/proxy.key" ]; then
      # Loopback bearer so only processes on this machine can use the proxy.
      OLD_UMASK=$(umask); umask 077
      od -An -tx1 -N 24 /dev/urandom | tr -d ' \n' > "$HOME_DIR/proxy.key"
      umask "$OLD_UMASK"
    fi
    PROXY_LOCAL_KEY=$(cat "$HOME_DIR/proxy.key")
    # One proxy, every model: Claude models pass through to the Anthropic
    # surface untouched (claude-api-key with a custom base-url), GPT models are
    # translated to the OpenAI surface. The proxy's /v1/models then lists all
    # of them, and one base URL serves any `--model`.
    CLAUDE_MODELS=$(set +o pipefail; printf '%s' "$API_BODY" | grep -o '"id":"claude-[^"]*"' | sed 's/"id":"//; s/"$//')
    OLD_UMASK=$(umask); umask 077
    {
      cat <<PEOF
# Generated by the qbraid-code installer. Loopback only.
host: "127.0.0.1"
port: $PROXY_PORT
tls:
  enable: false
auth-dir: "$HOME_DIR/proxy-auth"
api-keys:
  - "$PROXY_LOCAL_KEY"
remote-management:
  allow-remote: false
  disable-control-panel: true
debug: false
# Model-list cloaking rewrites ids into reversed pseudo-claude names so they
# pass Claude Code's discovery filter — the picker then shows gibberish. Our
# anthropic-compat/ aliases pass the filter with readable names instead.
claude-code:
  disable-cloaking-model-list: true
claude-api-key:
  - api-key: "$API_KEY"
    base-url: "$GATEWAY_URL"
    models:
PEOF
      printf '%s\n' "$CLAUDE_MODELS" | while IFS= read -r cm; do
        [ -n "$cm" ] || continue
        printf '      - name: "%s"\n        alias: "%s"\n' "$cm" "$cm"
      done
      cat <<PEOF
openai-compatibility:
  - name: "qbraid-gateway-gpt"
    base-url: "$GATEWAY_URL"
    api-key-entries:
      - api-key: "$API_KEY"
    models:
PEOF
      printf '%s\n' "$GPT_MODELS" | while IFS= read -r gm; do
        [ -n "$gm" ] || continue
        # Two aliases per GPT model: the plain id for the command line, and a
        # prefixed one containing "anthropic" so Claude Code's /model picker
        # discovery filter (which keeps only ids containing claude|anthropic)
        # shows it. The alias IS the inference mapping — selecting the
        # prefixed row routes to the same upstream model.
        printf '      - name: "%s"\n        alias: "%s"\n' "$gm" "$gm"
        printf '      - name: "%s"\n        alias: "anthropic-compat/%s"\n' "$gm" "$gm"
      done
    } > "$HOME_DIR/proxy-config.yaml"
    chmod 600 "$HOME_DIR/proxy-config.yaml"
    umask "$OLD_UMASK"
    mkdir -p "$HOME_DIR/proxy-auth"
    GPT_COUNT=$(printf '%s\n' "$GPT_MODELS" | wc -l | tr -d ' ')
    CLAUDE_COUNT=$(printf '%s\n' "$CLAUDE_MODELS" | wc -l | tr -d ' ')
    ok "proxy configured: all $((GPT_COUNT + CLAUDE_COUNT)) models on one endpoint (starts on demand)"
  fi
else
  warn "CLIProxyAPI unavailable — GPT models will not work; Claude models are unaffected."
fi

# Appended here rather than written in section 6: PROXY_BIN does not exist yet
# when the env file is first created.
{
  printf 'QBRAID_CODE_PROXY_PORT=%s\n' "$PROXY_PORT"
  printf 'QBRAID_CODE_PROXY_BIN=%s\n' "$PROXY_BIN"
} >> "$HOME_DIR/env"

# --------------------------------------------------------- 8. first-run flags

say "Claude Code first run"
if confirm "Skip Claude Code's introductory screens?" y; then
  if [ ! -f "$CLAUDE_JSON" ]; then
    printf '{"hasCompletedOnboarding":true}\n' > "$CLAUDE_JSON"
    ok "introductory screens will be skipped"
  elif have_python; then
    # Written to a temp file and renamed, so an interrupted run cannot leave a
    # half-written ~/.claude.json behind. A failure here is not worth aborting
    # a working install for.
    if python3 - "$CLAUDE_JSON" <<'PY'
import json, os, sys
path = sys.argv[1]
with open(path) as fh:
    data = json.load(fh)
data["hasCompletedOnboarding"] = True
tmp = path + ".qbraid-code.tmp"
with open(tmp, "w") as fh:
    json.dump(data, fh, indent=2)
os.replace(tmp, path)
PY
    then
      ok "introductory screens will be skipped"
    else
      warn "could not update $CLAUDE_JSON — leaving it alone"
    fi
  else
    warn "python3 unavailable — leaving $CLAUDE_JSON alone"
  fi
else
  ok "introductory screens left on"
fi

# ------------------------------------------------------------ 9. settings.json

# The statusline (and, with --global, the gateway env) go into the user
# settings file. Exit codes are distinct so the caller can say what actually
# went wrong: 2 = no python3, 3 = python3 ran and failed.
write_settings() {
  local statusline_cmd="$1"
  if [ ! -f "$SETTINGS" ]; then
    if [ "$GLOBAL" = 1 ]; then
      cat > "$SETTINGS" <<EOF
{
  "env": {
    "ANTHROPIC_BASE_URL": "$GATEWAY_URL",
    "ANTHROPIC_AUTH_TOKEN": "$API_KEY",
    "ANTHROPIC_MODEL": "$MODEL",
    "ANTHROPIC_SMALL_FAST_MODEL": "$MODEL",
    "MAX_THINKING_TOKENS": "0"
  },
  "statusLine": { "type": "command", "command": "'$statusline_cmd'" }
}
EOF
    else
      cat > "$SETTINGS" <<EOF
{
  "statusLine": { "type": "command", "command": "'$statusline_cmd'" }
}
EOF
    fi
    return 0
  fi

  have_python || return 2
  QC_STATUSLINE="'$statusline_cmd'" QC_GLOBAL="$GLOBAL" QC_BASE_URL="$GATEWAY_URL" \
  QC_TOKEN="$API_KEY" QC_MODEL="$MODEL" python3 - "$SETTINGS" <<'PY' || return 3
import json, os, sys
path = sys.argv[1]
with open(path) as fh:
    data = json.load(fh)
data["statusLine"] = {"type": "command", "command": os.environ["QC_STATUSLINE"]}
if os.environ["QC_GLOBAL"] == "1":
    env = data.setdefault("env", {})
    env["ANTHROPIC_BASE_URL"] = os.environ["QC_BASE_URL"]
    env["ANTHROPIC_AUTH_TOKEN"] = os.environ["QC_TOKEN"]
    env["ANTHROPIC_MODEL"] = os.environ["QC_MODEL"]
    env["ANTHROPIC_SMALL_FAST_MODEL"] = os.environ["QC_MODEL"]
    # The gateway rejects Claude Code's adaptive-thinking parameter; see the
    # launcher for the full note. Remove when the gateway accepts "adaptive".
    env["MAX_THINKING_TOKENS"] = "0"
tmp = path + ".qbraid-code.tmp"
with open(tmp, "w") as fh:
    json.dump(data, fh, indent=2)
os.replace(tmp, path)
PY
  return 0
}

say "Statusline"
# The path is single-quoted inside the JSON string so a HOME_DIR containing a
# space is still one argument when Claude Code runs it through a shell.
set +e
write_settings "$HOME_DIR/statusline.sh"
SETTINGS_RC=$?
set -e
case "$SETTINGS_RC" in
  0)
    ok "statusline enabled in $SETTINGS"
    if [ "$GLOBAL" = 1 ]; then
      # It now holds a live credential; the env file is already 600.
      chmod 600 "$SETTINGS" 2>/dev/null || warn "could not tighten permissions on $SETTINGS"
      GLOBAL_APPLIED=1
      ok "plain \`claude\` now uses qBraid too"
    fi
    ;;
  2) warn "python3 unavailable and $SETTINGS already exists — skipping." ;;
  3) warn "could not update $SETTINGS (it may not be valid JSON) — skipping." ;;
esac
if [ "$SETTINGS_RC" != 0 ]; then
  warn "add this to it by hand to enable the statusline:"
  printf '      %s"statusLine": { "type": "command", "command": "'"'"'%s'"'"'" }%s\n' \
    "$dim" "$HOME_DIR/statusline.sh" "$rst"
  [ "$GLOBAL" = 1 ] && warn "--global was NOT applied; plain \`claude\` is unchanged."
fi

# ------------------------------------------------------------------- 10. mcp

say "qBraid MCP"
MCP_REGISTERED=0
if ! claude_required_capabilities_present; then
  warn "this Claude Code version cannot register an HTTP MCP server from the command line."
  warn "Start Claude Code, run /mcp, and add $MCP_URL manually; or upgrade Claude Code."
elif claude mcp get "$MCP_NAME" >/dev/null 2>&1; then
  MCP_REGISTERED=1
  ok "already registered"
else
  claude mcp add --transport http "$MCP_NAME" "$MCP_URL" --scope user >/dev/null \
    || die "could not register the qBraid MCP server."
  MCP_REGISTERED=1
  ok "registered $MCP_URL"
fi

# The MCP endpoint is JWT-only (OAuth + dynamic client registration): the API
# key above cannot authorize it. Do the browser sign-in now, while the user is
# still here, rather than surprising them mid-session.
if [ "$MCP_REGISTERED" != 1 ]; then
  warn "MCP sign-in was skipped because registration is incomplete."
elif [ "$CLAUDE_MCP_LOGIN" != 1 ]; then
  warn "this Claude Code version authenticates MCP servers through its interactive menu."
  warn "Start Claude Code, run /mcp, select '$MCP_NAME', and choose Authenticate."
elif [ -n "$TTY" ]; then
  if confirm "Sign in to the qBraid MCP now? (opens a browser)" y; then
    # `claude mcp login` needs a real terminal to take the redirect URL. Under
    # `curl … | bash` this script's stdin IS the pipe, so it must be handed the
    # terminal explicitly — otherwise sign-in always fails with
    # "stdin isn't a terminal".
    claude mcp login "$MCP_NAME" < "$TTY" \
      || warn "MCP sign-in did not complete. Run \`claude mcp login $MCP_NAME\` later."
  else
    warn "skipped. Run \`claude mcp login $MCP_NAME\` when you want the qBraid tools."
  fi
else
  warn "no terminal — run \`claude mcp login $MCP_NAME\` to finish MCP sign-in."
fi

# ------------------------------------------------------------ 11. smoke test

# A failure here does not undo a complete install, so it warns rather than
# dies. The commonest cause is an empty wallet, which is not a broken setup.
say "Verifying"
SMOKE_TMP=$(mktemp)
SMOKE_STATUS=$(curl -sS -m 90 -o "$SMOKE_TMP" -w '%{http_code}' "$GATEWAY_URL/v1/messages" \
  -H "Authorization: Bearer $API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"$MODEL\",\"max_tokens\":32,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: OK\"}]}" \
  2>/dev/null) || SMOKE_STATUS="000"
SMOKE_BODY=$(cat "$SMOKE_TMP"); rm -f "$SMOKE_TMP"

case "$SMOKE_STATUS" in
  200)
    case "$SMOKE_BODY" in
      *'"text"'*) ok "end-to-end request succeeded" ;;
      *) warn "the gateway replied but not with a message. Run \`qbraid-code --doctor\`." ;;
    esac ;;
  402) warn "the gateway refused the request: no credits left. Top up, then run \`qbraid-code\`." ;;
  000) warn "could not reach the gateway to verify. Everything is installed; run \`qbraid-code --doctor\` when you are online." ;;
  *)   warn "the gateway returned HTTP $SMOKE_STATUS on the test request. Run \`qbraid-code --doctor\`." ;;
esac

# ---------------------------------------------------------------- 12. finish

printf '\n%sqbraid-code is ready.%s\n\n' "$bold$grn" "$rst"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    SHELL_RC="$HOME/.bashrc"
    case "${SHELL:-}" in *zsh) SHELL_RC="$HOME/.zshrc" ;; esac
    printf '  %sFirst, add %s to your PATH:%s\n' "$ylw" "$BIN_DIR" "$rst"
    printf '    echo '"'"'export PATH="%s:$PATH"'"'"' >> %s\n' "$BIN_DIR" "$SHELL_RC"
    printf '    source %s\n\n' "$SHELL_RC"
    ;;
esac

cat <<EOF
  Run it from any folder:

    ${bold}qbraid-code${rst}                 start a session
    ${bold}qbraid-code -p "..."${rst}        ask one question and exit
    ${bold}qbraid-code --doctor${rst}        check your setup

EOF
if [ "$GLOBAL_APPLIED" = 1 ]; then
  printf '  The plain %sclaude%s command uses qBraid as well.\n\n' "$bold" "$rst"
else
  printf '  Your own %sclaude%s command is untouched.\n\n' "$bold" "$rst"
fi
