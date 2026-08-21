#!/usr/bin/env bash
# qbraid-code installer — Claude Code, powered by the qBraid AI gateway.
#
#   curl -fsSL https://qbraid.com/code.sh | bash
#
# Claude models use the gateway's Anthropic-compatible surface. GPT models
# use an on-demand loopback translation proxy. The double `v1` in
# /api/v1/ai/v1/messages is deliberate because Claude Code appends
# /v1/messages to ANTHROPIC_BASE_URL.
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
PROXY_PORT_OVERRIDE="${QBRAID_CODE_PROXY_PORT:-}"
PROXY_PORT=""
PROXY_REPO="router-for-me/CLIProxyAPI"
MCP_URL="https://mcp.qbraid.com/mcp"
KEYS_URL="https://account.qbraid.com/account/api-keys"
CLAUDE_RELEASES_URL="https://downloads.claude.ai/claude-code-releases"
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

PROFILE="${QBRAID_CODE_PROFILE:-}"
PROFILE_OPTION=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --global) printf 'error: --global was removed because project settings can exfiltrate its credential. Use qbraid-code.\n' >&2; exit 1 ;;
    --profile)
      [ "$#" -ge 2 ] || { printf 'error: --profile needs a name\n' >&2; exit 1; }
      PROFILE_OPTION=1; PROFILE="$2"; shift 2 ;;
    --profile=*) PROFILE_OPTION=1; PROFILE="${1#--profile=}"; shift ;;
    --help|-h)
      cat <<'EOF'
qbraid-code installer

  --profile NAME   create or update a named qBraid profile
  --global         removed. Use the isolated qbraid-code wrapper.
  --help           show this message

Environment:
  QBRAID_API_KEY             use this key instead of prompting
  QBRAID_CODE_MODEL          use this model instead of prompting
  QBRAID_CODE_PROFILE_LABEL  readable local account label
  QBRAID_CODE_CLAUDE_POLICY  prompt, upgrade, fail, or continue
  QBRAID_CODE_HOME           config directory (default ~/.qbraid-code)
  QBRAID_CODE_BIN_DIR        install directory (default ~/.local/bin)
EOF
      exit 0 ;;
    *) printf 'error: unknown option: %s\n' "$1" >&2; exit 1 ;;
  esac
done
[ "$PROFILE_OPTION" -eq 0 ] || [ -n "$PROFILE" ] || { printf 'error: invalid empty profile\n' >&2; exit 1; }

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed 's/'"'"'/'"'"'\\'"'"''"'"'/g'
  printf "'"
}

json_escape_value() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g'
}

valid_profile_slug() {
  local LC_ALL=C
  case "${1:-}" in
    ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#1}" -le 32 ]
}

sanitize_profile_label() { # sanitize_profile_label <label> <fallback>
  local label bytes
  label=$(printf '%s' "$1" | tr -d '\001-\037\177')
  bytes=$(LC_ALL=C printf '%s' "$label" | wc -c | tr -d ' ')
  if [ -n "$label" ] && [ "$bytes" -le 80 ]; then printf '%s' "$label"; else printf '%s' "$2"; fi
}

adopt_legacy_profile() { # adopt_legacy_profile <root>
  local root="$1" dest="$1/profiles/default" stage item token secret_ref account
  [ -f "$root/env" ] || return 0
  [ ! -e "$dest" ] || return 0
  stage="$root/profiles/.default.migrate.$$"
  rm -rf "$stage"; mkdir -p "$stage"; chmod 700 "$stage" 2>/dev/null || true
  token=$(sed -n 's/^QBRAID_CODE_TOKEN=//p' "$root/env" | head -1)
  grep -v '^QBRAID_CODE_TOKEN=' "$root/env" > "$stage/env"
  if [ -n "$token" ]; then
    if [ "${OS:-linux}" = darwin ]; then
      account="${USER:-$(id -un)}"; secret_ref='qbraid-code:default'
      printf '%s\n%s\n' "$token" "$token" | security add-generic-password -U -a "$account" -s "$secret_ref" -w >/dev/null 2>&1 \
        || { rm -rf "$stage"; die "could not migrate the default key into macOS Keychain."; }
      printf 'QBRAID_CODE_SECRET_BACKEND=keychain\nQBRAID_CODE_SECRET_REF=%s\n' "$secret_ref" >> "$stage/env"
    elif command -v secret-tool >/dev/null 2>&1 && printf '%s' "$token" | secret-tool store --label='qbraid-code default profile' service qbraid-code ref qbraid-code:default >/dev/null 2>&1; then
      secret_ref='qbraid-code:default'
      printf 'QBRAID_CODE_SECRET_BACKEND=secret-service\nQBRAID_CODE_SECRET_REF=%s\n' "$secret_ref" >> "$stage/env"
    else
      mkdir -p "$root/secrets"; chmod 700 "$root/secrets"
      secret_ref="$root/secrets/default"
      printf '%s\n' "$token" > "$secret_ref.tmp.$$"; chmod 600 "$secret_ref.tmp.$$"; mv "$secret_ref.tmp.$$" "$secret_ref"
      printf 'QBRAID_CODE_SECRET_BACKEND=file\nQBRAID_CODE_SECRET_REF=%s\n' "$secret_ref" >> "$stage/env"
    fi
  fi
  for item in label models.tsv credits.cache credits.updated organization-id label-source; do
    [ -e "$root/$item" ] || continue
    cp -R "$root/$item" "$stage/$item"
  done
  [ -f "$stage/label" ] || printf 'default\n' > "$stage/label"
  [ -f "$stage/label-source" ] || printf 'local\n' > "$stage/label-source"
  chmod -R go-rwx "$stage" 2>/dev/null || true
  mv "$stage" "$dest"
}

scrub_legacy_token() { # scrub_legacy_token <root>
  local root="$1" proxy_pid="" proxy_command="" keep_config=0
  [ -e "$root/profiles/default" ] || return 0
  if [ -f "$root/env" ]; then
    { grep -v '^QBRAID_CODE_TOKEN=' "$root/env" || true; } > "$root/env.migrate.$$"
    chmod 600 "$root/env.migrate.$$"; mv "$root/env.migrate.$$" "$root/env"
  fi
  proxy_pid=$(cat "$root/proxy.pid" 2>/dev/null || true)
  if [ -n "$proxy_pid" ] && kill -0 "$proxy_pid" 2>/dev/null; then
    keep_config=1
    if [ -r "/proc/$proxy_pid/cmdline" ]; then proxy_command=$(tr '\000' ' ' < "/proc/$proxy_pid/cmdline" 2>/dev/null || true)
    elif command -v ps >/dev/null 2>&1; then proxy_command=$(ps -p "$proxy_pid" -o command= 2>/dev/null || true); fi
    case "$proxy_command" in '') ;; *"$root/proxy-config.yaml"*) ;; *) keep_config=0 ;; esac
  fi
  [ "$keep_config" -eq 1 ] || rm -f "$root/proxy-config.yaml"
}

allocate_proxy_port() { # allocate_proxy_port <root> <profile> <existing>
  local root="$1" existing="${3:-}" port=8320 file used
  if [ -n "$existing" ]; then printf '%s\n' "$existing"; return; fi
  while :; do
    used=0
    for file in "$root"/profiles/*/env; do
      [ -f "$file" ] || continue
      grep -q "^QBRAID_CODE_PROXY_PORT=$port$" "$file" && { used=1; break; }
    done
    [ "$used" -eq 1 ] || { printf '%s\n' "$port"; return; }
    port=$((port + 1))
  done
}

write_models_tsv() { # write_models_tsv <dest> <gateway-json>
  local dest="$1" body="${2:-}" tmp row id context
  tmp="$dest.tmp.$$"
  cat > "$tmp" <<'EOF'
gpt-5.6-sol	1050000
claude-opus-5	1000000
claude-sonnet-4-6	1000000
claude-opus-4-8	1000000
claude-haiku-4-5	200000
gpt-5.4	400000
gpt-5.4-mini	400000
gpt-5.4-nano	400000
EOF
  printf '%s' "$body" | tr -d '\r\n' | sed 's/},{[[:space:]]*"id"/}\
{"id"/g' |
    while IFS= read -r row; do
      id=$(printf '%s' "$row" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
      context=$(printf '%s' "$row" | sed -n \
        -e 's/.*"maxTokens"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
        -e 's/.*"context_window"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
        -e 's/.*"contextWindow"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)
      [ -n "$id" ] && [ -n "$context" ] && printf '%s\t%s\n' "$id" "$context"
    done >> "$tmp"
  awk -F '\t' 'NF == 2 { values[$1]=$2 } END { for (id in values) print id "\t" values[id] }' "$tmp" |
    sort > "$dest"
  rm -f "$tmp"
}

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

claude_upgrade_is_safe() { # claude_upgrade_is_safe <installed> <target>
  [ -z "$1" ] || [ "$(compare_versions "$1" "$2")" -le 0 ]
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
  local installed="${CLAUDE_VERSION:-}" target raw
  raw=$(curl -fsSL --max-time 20 "$CLAUDE_RELEASES_URL/stable") \
    || die "could not resolve Anthropic's stable Claude Code version."
  target=$(parse_claude_version "$raw")
  [ -n "$target" ] && [ "$raw" = "$target" ] \
    || die "Anthropic's stable Claude Code version was invalid."
  claude_upgrade_is_safe "$installed" "$target" \
    || die "Claude Code $installed is newer than stable $target. Refusing to downgrade it; update Claude Code manually or set QBRAID_CODE_CLAUDE_POLICY=continue."
  warn "installing Claude Code $target from Anthropic's stable channel"
  curl -fsSL https://claude.ai/install.sh | bash -s "$target" \
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
    case "$CLAUDE_VERSION_STATUS" in
      newer-than-tested)
        case "$action" in
          continue|prompt) warn "Claude Code $CLAUDE_VERSION is newer than tested and lacks required capabilities; refusing to downgrade it and continuing with reduced compatibility." ;;
          *) die "Claude Code $CLAUDE_VERSION is newer than tested and lacks required capabilities. Refusing to downgrade it; set QBRAID_CODE_CLAUDE_POLICY=continue to skip unavailable features." ;;
        esac
        action=handled
        ;;
      unknown)
        case "$action" in
          continue|prompt) warn "Claude Code's version is unknown; refusing to replace it with stable because that could downgrade it, and continuing with reduced compatibility." ;;
          *) die "Claude Code's version is unknown. Refusing to replace it with stable because that could downgrade it; update Claude Code manually or set QBRAID_CODE_CLAUDE_POLICY=continue." ;;
        esac
        action=handled
        ;;
    esac
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
INSTALL_LOCK="$HOME_DIR/.install-lock"
if ! mkdir "$INSTALL_LOCK" 2>/dev/null; then
  LOCK_PID=$(cat "$INSTALL_LOCK/pid" 2>/dev/null || true)
  if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" 2>/dev/null; then
    die "another qbraid-code installer is running."
  fi
  rm -rf "$INSTALL_LOCK"
  mkdir "$INSTALL_LOCK" 2>/dev/null || die "another qbraid-code installer is running."
fi
printf '%s\n' "$$" > "$INSTALL_LOCK/pid"
PROFILE_UPDATE_LOCK=""
PROFILE_STAGE=""
SECRET_STAGED=0
SECRET_BACKEND=""
SECRET_REF=""
cleanup_installer() {
  if [ "$SECRET_STAGED" -eq 1 ]; then
    case "$SECRET_BACKEND" in secret-service) secret-tool clear service qbraid-code ref "$SECRET_REF" >/dev/null 2>&1 || true ;; keychain) security delete-generic-password -a "${USER:-$(id -un)}" -s "$SECRET_REF" >/dev/null 2>&1 || true ;; file) rm -f "$SECRET_REF" ;; esac
  fi
  [ -z "$PROFILE_STAGE" ] || rm -rf "$PROFILE_STAGE"
  [ -z "$PROFILE_UPDATE_LOCK" ] || rm -rf "$PROFILE_UPDATE_LOCK"
  rm -rf "$INSTALL_LOCK"
}
trap cleanup_installer EXIT INT TERM HUP
adopt_legacy_profile "$HOME_DIR"
if [ -z "$PROFILE" ] && [ -f "$HOME_DIR/active-profile" ]; then
  IFS= read -r PROFILE < "$HOME_DIR/active-profile" || true
fi
[ -n "$PROFILE" ] || PROFILE=default
valid_profile_slug "$PROFILE" || die "invalid profile '$PROFILE'. Use letters, numbers, dot, underscore, or dash."
PROFILE_ROOT="$HOME_DIR/profiles/$PROFILE"
mkdir -p "$PROFILE_ROOT"
chmod 700 "$PROFILE_ROOT" 2>/dev/null || true
PROFILE_DIR="$PROFILE_ROOT"
if [ -f "$PROFILE_ROOT/current" ]; then
  IFS= read -r CURRENT_GENERATION < "$PROFILE_ROOT/current" || true
  case "$CURRENT_GENERATION" in ''|*/*|.*) die "profile '$PROFILE' has an invalid generation pointer." ;; esac
  [ -f "$PROFILE_ROOT/generations/$CURRENT_GENERATION/env" ] || die "profile '$PROFILE' generation is incomplete."
  PROFILE_DIR="$PROFILE_ROOT/generations/$CURRENT_GENERATION"
fi
PROFILE_COORD_LOCK="$PROFILE_ROOT/.coord-lock"
if ! mkdir "$PROFILE_COORD_LOCK" 2>/dev/null; then
  COORD_PID=$(cat "$PROFILE_COORD_LOCK/pid" 2>/dev/null || true)
  if [ -n "$COORD_PID" ] && kill -0 "$COORD_PID" 2>/dev/null; then die "profile '$PROFILE' is busy."; fi
  rm -rf "$PROFILE_COORD_LOCK"; mkdir "$PROFILE_COORD_LOCK" || die "profile '$PROFILE' is busy."
fi
printf '%s\n' "$$" > "$PROFILE_COORD_LOCK/pid"
PROFILE_UPDATE_LOCK="$PROFILE_ROOT/.update-lock"
rm -rf "$PROFILE_UPDATE_LOCK"
mkdir "$PROFILE_UPDATE_LOCK"
printf '%s\n' "$$" > "$PROFILE_UPDATE_LOCK/pid"
mkdir -p "$PROFILE_ROOT/session-users"
for user_file in "$PROFILE_ROOT"/session-users/*; do
  [ -f "$user_file" ] || continue
  USER_PID=${user_file##*/}
  if kill -0 "$USER_PID" 2>/dev/null; then
    rm -rf "$PROFILE_COORD_LOCK"
    die "profile '$PROFILE' has a running session. Update it after that session exits."
  fi
  rm -f "$user_file"
done
rm -rf "$PROFILE_COORD_LOCK"
STALE_PROXY_PID=$(cat "$PROFILE_DIR/proxy.pid" 2>/dev/null || true)
if [ -n "$STALE_PROXY_PID" ]; then
  STALE_PROXY_COMMAND=""
  if ! kill -0 "$STALE_PROXY_PID" 2>/dev/null; then rm -f "$PROFILE_DIR/proxy.pid"
  else
    if [ -r "/proc/$STALE_PROXY_PID/cmdline" ]; then STALE_PROXY_COMMAND=$(tr '\000' ' ' < "/proc/$STALE_PROXY_PID/cmdline" 2>/dev/null || true)
    elif command -v ps >/dev/null 2>&1; then STALE_PROXY_COMMAND=$(ps -p "$STALE_PROXY_PID" -o command= 2>/dev/null || true); fi
    case "$STALE_PROXY_COMMAND" in *" -config $PROFILE_DIR/proxy-config.yaml"*) kill "$STALE_PROXY_PID" 2>/dev/null || true; rm -f "$PROFILE_DIR/proxy.pid" ;; esac
  fi
fi
EXISTING_PORT=""
if [ -f "$PROFILE_DIR/env" ]; then EXISTING_PORT=$(sed -n 's/^QBRAID_CODE_PROXY_PORT=//p' "$PROFILE_DIR/env" | head -1); fi
PROXY_PORT=$(allocate_proxy_port "$HOME_DIR" "$PROFILE" "${PROXY_PORT_OVERRIDE:-$EXISTING_PORT}")
# Merging JSON into an existing settings file needs a real parser. On macOS
# /usr/bin/python3 is a stub that pops a GUI installer prompt unless the
# Command Line Tools are present, so check for those before trusting it.
have_python() {
  command -v python3 >/dev/null 2>&1 || return 1
  if [ "$OS" = darwin ] && ! xcode-select -p >/dev/null 2>&1; then return 1; fi
  python3 -c 'import json' >/dev/null 2>&1
}

remove_legacy_global_settings() {
  [ -f "$SETTINGS" ] || { rm -f "$HOME_DIR/global-profile"; return 0; }
  grep -q 'ANTHROPIC_BASE_URL.*api-v2.qbraid.com' "$SETTINGS" 2>/dev/null || { rm -f "$HOME_DIR/global-profile"; return 0; }
  have_python || die "legacy plain-Claude gateway settings are unsafe. Remove the ANTHROPIC_* qBraid entries from $SETTINGS, then rerun."
  python3 - "$SETTINGS" <<'PY'
import json, os, sys
path = sys.argv[1]
with open(path) as fh:
    data = json.load(fh)
env = data.get("env", {})
for key in ("ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_MODEL", "ANTHROPIC_SMALL_FAST_MODEL", "QBRAID_CODE_PROFILE", "QBRAID_CODE_HOME"):
    env.pop(key, None)
if not env:
    data.pop("env", None)
tmp = path + ".qbraid-code.tmp"
with open(tmp, "w") as fh:
    json.dump(data, fh, indent=2)
os.replace(tmp, path)
PY
  rm -f "$HOME_DIR/global-profile"
  warn "removed unsafe legacy plain-Claude gateway settings; use qbraid-code"
}
remove_legacy_global_settings

read_profile_secret() {
  local backend ref
  [ -f "$PROFILE_DIR/env" ] || return 1
  backend=$(sed -n 's/^QBRAID_CODE_SECRET_BACKEND=//p' "$PROFILE_DIR/env" | head -1)
  ref=$(sed -n 's/^QBRAID_CODE_SECRET_REF=//p' "$PROFILE_DIR/env" | head -1)
  case "$backend" in
    keychain) security find-generic-password -a "${USER:-$(id -un)}" -s "$ref" -w 2>/dev/null ;;
    secret-service) command -v secret-tool >/dev/null 2>&1 && secret-tool lookup service qbraid-code ref "$ref" 2>/dev/null ;;
    file) [ -f "$ref" ] && cat "$ref" ;;
    *) sed -n 's/^QBRAID_CODE_TOKEN=//p' "$PROFILE_DIR/env" | head -1 ;;
  esac
}

store_profile_secret() {
  SECRET_REF="qbraid-code:$PROFILE:$GENERATION"
  if [ "$OS" = darwin ]; then
    command -v security >/dev/null 2>&1 || die "macOS Keychain is unavailable."
    printf '%s\n%s\n' "$API_KEY" "$API_KEY" | security add-generic-password -U -a "${USER:-$(id -un)}" -s "$SECRET_REF" -w >/dev/null 2>&1 \
      || die "could not store the profile key in macOS Keychain."
    SECRET_BACKEND="keychain"
  elif command -v secret-tool >/dev/null 2>&1 && printf '%s' "$API_KEY" | secret-tool store --label="qbraid-code $PROFILE profile" service qbraid-code ref "qbraid-code:$PROFILE:$GENERATION" >/dev/null 2>&1; then
    SECRET_REF="qbraid-code:$PROFILE:$GENERATION"
    SECRET_BACKEND="secret-service"
  else
    SECRET_DIR="$HOME_DIR/secrets"
    mkdir -p "$SECRET_DIR"; chmod 700 "$SECRET_DIR"
    SECRET_REF="$SECRET_DIR/$PROFILE.$GENERATION"
    printf '%s\n' "$API_KEY" > "$SECRET_REF.tmp.$$"
    chmod 600 "$SECRET_REF.tmp.$$"
    mv "$SECRET_REF.tmp.$$" "$SECRET_REF"
    SECRET_BACKEND="file"
  fi
  SECRET_STAGED=1
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
    HTTP_STATUS=$(printf 'header = "X-API-Key: %s"\nheader = "X-Organization-Id: %s"\n' "$key" "$org" |
      curl -sS -m 25 -o "$tmp" -w '%{http_code}' --config - "$url" 2>/dev/null) || HTTP_STATUS="000"
  else
    HTTP_STATUS=$(printf 'header = "X-API-Key: %s"\n' "$key" |
      curl -sS -m 25 -o "$tmp" -w '%{http_code}' --config - "$url" 2>/dev/null) || HTTP_STATUS="000"
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
if [ -z "$API_KEY" ]; then
  API_KEY=$(read_profile_secret 2>/dev/null || true)
  [ -z "$API_KEY" ] || KEY_SOURCE="profile secret store"
fi

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

# Keep stored credentials and model identifiers within the gateway's expected
# character set. They also flow into HTTP and proxy configuration.
case "$API_KEY" in
  ''|*[!A-Za-z0-9_.-]*) die "the API key contains unexpected characters — refusing to save it." ;;
esac

prune_profile_generations() { # prune_profile_generations <current-generation>
  local current="$1" dir env_file backend ref
  if [ -f "$PROFILE_ROOT/env" ]; then
    backend=$(sed -n 's/^QBRAID_CODE_SECRET_BACKEND=//p' "$PROFILE_ROOT/env" | head -1)
    ref=$(sed -n 's/^QBRAID_CODE_SECRET_REF=//p' "$PROFILE_ROOT/env" | head -1)
    case "$backend:$ref" in
      secret-service:qbraid-code:"$PROFILE") secret-tool clear service qbraid-code ref "$ref" >/dev/null 2>&1 || true ;;
      keychain:qbraid-code:"$PROFILE") security delete-generic-password -a "${USER:-$(id -un)}" -s "$ref" >/dev/null 2>&1 || true ;;
      file:"$HOME_DIR"/secrets/"$PROFILE") rm -f "$ref" ;;
    esac
    rm -f "$PROFILE_ROOT/env" "$PROFILE_ROOT/proxy-template.yaml" "$PROFILE_ROOT/label" "$PROFILE_ROOT/label-source" "$PROFILE_ROOT/models.tsv" "$PROFILE_ROOT/credits.cache" "$PROFILE_ROOT/credits.updated" "$PROFILE_ROOT/organization-id"
  fi
  for dir in "$PROFILE_ROOT"/generations/*; do
    [ -d "$dir" ] || continue
    [ "${dir##*/}" != "$current" ] || continue
    env_file="$dir/env"; backend=""; ref=""
    if [ -f "$env_file" ]; then
      backend=$(sed -n 's/^QBRAID_CODE_SECRET_BACKEND=//p' "$env_file" | head -1)
      ref=$(sed -n 's/^QBRAID_CODE_SECRET_REF=//p' "$env_file" | head -1)
      case "$backend:$ref" in
        secret-service:qbraid-code:"$PROFILE":*) secret-tool clear service qbraid-code ref "$ref" >/dev/null 2>&1 || true ;;
        keychain:qbraid-code:"$PROFILE":*) security delete-generic-password -a "${USER:-$(id -un)}" -s "$ref" >/dev/null 2>&1 || true ;;
        file:"$HOME_DIR"/secrets/"$PROFILE".*) rm -f "$ref" ;;
      esac
    fi
    rm -rf "$dir"
  done
}

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

OLD_ORG_ID=$(cat "$PROFILE_DIR/organization-id" 2>/dev/null || true)
if [ -n "$OLD_ORG_ID" ] && { [ -z "$ORG_ID" ] || [ "$OLD_ORG_ID" != "$ORG_ID" ]; }; then
  die "profile '$PROFILE' belongs to another organization. Use a new profile name."
fi

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

GENERATION="$(date +%s).$$"
mkdir -p "$PROFILE_ROOT/generations"
PROFILE_STAGE="$PROFILE_ROOT/generations/.stage.$$"
rm -rf "$PROFILE_STAGE"; mkdir "$PROFILE_STAGE"; chmod 700 "$PROFILE_STAGE"
store_profile_secret
PROFILE_DIR="$PROFILE_STAGE"
if [ -n "${QBRAID_CODE_PROFILE_LABEL:-}" ]; then PROFILE_LABEL=$(sanitize_profile_label "$QBRAID_CODE_PROFILE_LABEL" "$PROFILE"); PROFILE_LABEL_SOURCE=local
elif [ -n "$ORG_NAME" ]; then PROFILE_LABEL=$(sanitize_profile_label "$ORG_NAME" "$PROFILE"); PROFILE_LABEL_SOURCE=verified
else PROFILE_LABEL="$PROFILE"; PROFILE_LABEL_SOURCE=local; fi
OLD_UMASK=$(umask)
umask 077
rm -f "$PROFILE_DIR/proxy-config.yaml" "$PROFILE_DIR/proxy-template.yaml" "$PROFILE_DIR/proxy.key"
rm -rf "$PROFILE_DIR/proxy-auth"
cat > "$PROFILE_DIR/env" <<EOF
QBRAID_CODE_BASE_URL=$GATEWAY_URL
QBRAID_CODE_API_BASE=$API_BASE
QBRAID_CODE_MODEL=$MODEL
QBRAID_CODE_SECRET_BACKEND=$SECRET_BACKEND
QBRAID_CODE_SECRET_REF=$SECRET_REF
EOF
printf '%s\n' "$PROFILE_LABEL" > "$PROFILE_DIR/label"
printf '%s\n' "$PROFILE_LABEL_SOURCE" > "$PROFILE_DIR/label-source"
[ -z "$ORG_ID" ] || printf '%s\n' "$ORG_ID" > "$PROFILE_DIR/organization-id"
write_models_tsv "$PROFILE_DIR/models.tsv" "${API_BODY:-}"
chmod 600 "$PROFILE_DIR/env" "$PROFILE_DIR/label" "$PROFILE_DIR/models.tsv" "$PROFILE_DIR/organization-id" 2>/dev/null || true
umask "$OLD_UMASK"
if [ "$CREDITS_RAW" ]; then
  printf '%s\n' "$CREDITS_RAW" > "$PROFILE_DIR/credits.cache"
  date +%s > "$PROFILE_DIR/credits.updated"
fi
rm -f "$PROFILE_DIR/credits.attempt"
ok "profile '$PROFILE' metadata prepared"

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
printf '%s\n' "$HOME_DIR" > "$BIN_DIR/qbraid-code.home"
chmod 0600 "$BIN_DIR/qbraid-code.home"
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
proxy_supports_gateway_config() {
  grep -a -q "disable-cloaking-model-list" "$1" 2>/dev/null
}

PROXY_BIN=""
for cand in "$(command -v cliproxyapi 2>/dev/null || true)" "$HOME_DIR/cliproxyapi"; do
  [ -n "$cand" ] && [ -x "$cand" ] || continue
  if proxy_supports_gateway_config "$cand"; then
    PROXY_BIN="$cand"
    ok "using existing $PROXY_BIN"
    break
  fi
  warn "$cand is too old for the unified gateway config — upgrading"
done
if [ -z "$PROXY_BIN" ] && [ "$OS" = darwin ] && command -v brew >/dev/null 2>&1; then
  if brew install cliproxyapi >/dev/null 2>&1 || brew upgrade cliproxyapi >/dev/null 2>&1; then
    CAND="$(command -v cliproxyapi 2>/dev/null || true)"
    if [ -n "$CAND" ] && proxy_supports_gateway_config "$CAND"; then
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
      && proxy_supports_gateway_config "$PROXY_TMP/cli-proxy-api"; then
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
  write_models_tsv "$PROFILE_DIR/models.tsv" "${API_BODY:-}"
  chmod 600 "$PROFILE_DIR/models.tsv"
  GPT_MODELS=$(set +o pipefail; printf '%s' "$API_BODY" | grep -o '"id":"gpt-[^"]*"' | sed 's/"id":"//; s/"$//')
  CLAUDE_MODELS=$(set +o pipefail; printf '%s' "$API_BODY" | grep -o '"id":"claude-[^"]*"' | sed 's/"id":"//; s/"$//')
  if [ -z "$GPT_MODELS$CLAUDE_MODELS" ]; then
    die "could not list proxy models from the gateway; the profile was not changed."
  else
    # One proxy, every model: Claude models pass through to the Anthropic
    # surface untouched (claude-api-key with a custom base-url), GPT models are
    # translated to the OpenAI surface. The proxy's /v1/models then lists all
    # of them, and one base URL serves any `--model`.
    OLD_UMASK=$(umask); umask 077
    {
      cat <<PEOF
# Generated by the qbraid-code installer. Loopback only.
host: "127.0.0.1"
port: __PORT__
tls:
  enable: false
auth-dir: "__AUTH_DIR__"
api-keys:
  - "__LOCAL_KEY__"
remote-management:
  allow-remote: false
  disable-control-panel: true
debug: false
# Keep model identifiers stable for explicit --model launches.
claude-code:
  disable-cloaking-model-list: true
claude-api-key:
  - api-key: "__QBRAID_KEY__"
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
      - api-key: "__QBRAID_KEY__"
    models:
PEOF
      printf '%s\n' "$GPT_MODELS" | while IFS= read -r gm; do
        [ -n "$gm" ] || continue
        printf '      - name: "%s"\n        alias: "%s"\n' "$gm" "$gm"
      done
    } > "$PROFILE_DIR/proxy-template.yaml"
    chmod 600 "$PROFILE_DIR/proxy-template.yaml"
    umask "$OLD_UMASK"
    GPT_COUNT=$(printf '%s\n' "$GPT_MODELS" | wc -l | tr -d ' ')
    CLAUDE_COUNT=$(printf '%s\n' "$CLAUDE_MODELS" | wc -l | tr -d ' ')
    ok "proxy configured: all $((GPT_COUNT + CLAUDE_COUNT)) models on one endpoint (starts on demand)"
  fi
else
  die "CLIProxyAPI unavailable; the profile was not changed."
fi

# Appended here rather than written in section 6: PROXY_BIN does not exist yet
# when the env file is first created.
{
  printf 'QBRAID_CODE_PROXY_PORT=%s\n' "$PROXY_PORT"
  printf 'QBRAID_CODE_PROXY_BIN=%s\n' "$PROXY_BIN"
} >> "$PROFILE_DIR/env"

FINAL_GENERATION="$PROFILE_ROOT/generations/$GENERATION"
mv "$PROFILE_STAGE" "$FINAL_GENERATION"
PROFILE_STAGE=""
printf '%s\n' "$GENERATION" > "$PROFILE_ROOT/current.tmp.$$"
mv "$PROFILE_ROOT/current.tmp.$$" "$PROFILE_ROOT/current"
SECRET_STAGED=0
PROFILE_DIR="$FINAL_GENERATION"
prune_profile_generations "$GENERATION"
scrub_legacy_token "$HOME_DIR"
ok "profile '$PROFILE' metadata committed"

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

# The statusline goes into the user settings file. Exit codes are distinct so the caller can say what actually
# went wrong: 2 = no python3, 3 = python3 ran and failed.
write_settings() {
  local statusline_cmd="$1" statusline_json
  statusline_json=$(json_escape_value "$statusline_cmd")
  if [ ! -f "$SETTINGS" ]; then
    cat > "$SETTINGS" <<EOF
{
  "statusLine": { "type": "command", "command": "$statusline_json" }
}
EOF
    return 0
  fi
  have_python || return 2
  QC_STATUSLINE="$statusline_cmd" python3 - "$SETTINGS" <<'PY' || return 3
import json, os, sys
path = sys.argv[1]
with open(path) as fh:
    data = json.load(fh)
data["statusLine"] = {"type": "command", "command": os.environ["QC_STATUSLINE"]}
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
STATUSLINE_COMMAND=$(shell_quote "$HOME_DIR/statusline.sh")
write_settings "$STATUSLINE_COMMAND"
SETTINGS_RC=$?
set -e
case "$SETTINGS_RC" in
  0) ok "statusline enabled in $SETTINGS" ;;
  2) warn "python3 unavailable and $SETTINGS already exists — skipping." ;;
  3) warn "could not update $SETTINGS (it may not be valid JSON) — skipping." ;;
esac
if [ "$SETTINGS_RC" != 0 ]; then
  warn "add this to it by hand to enable the statusline:"
  printf '      %s"statusLine": { "type": "command", "command": "%s" }%s\n' \
    "$dim" "$(json_escape_value "$STATUSLINE_COMMAND")" "$rst"
fi

# ------------------------------------------------------------------- 10. mcp

say "qBraid MCP"
MCP_REGISTERED=0
if [ "$CLAUDE_MCP_GET" = 1 ] && claude mcp get "$MCP_NAME" >/dev/null 2>&1; then
  MCP_REGISTERED=1
  ok "already registered"
elif claude_required_capabilities_present; then
  claude mcp add --transport http "$MCP_NAME" "$MCP_URL" --scope user >/dev/null \
    || die "could not register the qBraid MCP server."
  MCP_REGISTERED=1
  ok "registered $MCP_URL"
else
  warn "this Claude Code version cannot register an HTTP MCP server from the command line."
  warn "Start Claude Code, run /mcp, and add $MCP_URL manually; or upgrade Claude Code."
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
SMOKE_STATUS=$(printf 'header = "Authorization: Bearer %s"\n' "$API_KEY" |
  curl -sS -m 90 -o "$SMOKE_TMP" -w '%{http_code}' --config - "$GATEWAY_URL/v1/messages" \
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

printf '%s\n' "$PROFILE" > "$HOME_DIR/active-profile.tmp.$$"
mv "$HOME_DIR/active-profile.tmp.$$" "$HOME_DIR/active-profile"

printf '\n%sqbraid-code is ready.%s\n\n' "$bold$grn" "$rst"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    SHELL_RC="$HOME/.bashrc"
    case "${SHELL:-}" in *zsh) SHELL_RC="$HOME/.zshrc" ;; esac
    printf '  %sAdd %s to PATH in %s, then open a new shell.%s\n\n' "$ylw" "$BIN_DIR" "$SHELL_RC" "$rst"
    ;;
esac

cat <<EOF
  Run it from any folder:

    ${bold}qbraid-code${rst}                 start a session
    ${bold}qbraid-code -p "..."${rst}        ask one question and exit
    ${bold}qbraid-code --doctor${rst}        check your setup

EOF
printf '  Your own %sclaude%s command is untouched.\n\n' "$bold" "$rst"
