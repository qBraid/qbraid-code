#!/usr/bin/env bash
# Drive the real top-level compatibility decision against a fake Claude binary.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

extract_fn() { # extract_fn <name>
  awk -v fn="$1" '
    $0 ~ "^"fn"\\(\\) \\{" { inside = 1 }
    inside { print }
    inside && /^\}$/ { exit }
  ' install.sh
}

FUNCTIONS=""
for fn in parse_claude_version compare_versions claude_version_status \
  claude_policy_action claude_supports_mcp_command \
  claude_supports_mcp_http claude_supports_mcp_user_scope \
  refresh_claude_state claude_required_capabilities_present \
  ensure_claude_compatible; do
  src=$(extract_fn "$fn")
  [ -n "$src" ] || { printf '  FAIL could not extract %s\n' "$fn"; exit 1; }
  FUNCTIONS="$FUNCTIONS
$src"
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
state="$tmp/version"
printf '2.1.179' > "$state"
cat > "$tmp/claude" <<'EOF'
#!/usr/bin/env bash
version=$(cat "$FAKE_CLAUDE_STATE")
case "${1:-} ${2:-}" in
  "--version ") printf '%s (Claude Code)\n' "$version" ;;
  "mcp --help")
    printf '%s\n' 'Commands:' '  add [options]' '  get <name>'
    [ "$version" != 2.1.179 ] && printf '%s\n' '  login <name>'
    ;;
  "mcp add")
    if [ "${3:-}" = --help ]; then
      printf '%s\n' '  --transport <transport>  stdio, sse, or http'
      [ "${FAKE_USER_SCOPE:-yes}" = yes ] \
        && printf '%s\n' '  --scope <scope>          local, project, or user'
    fi
    ;;
esac
EOF
chmod +x "$tmp/claude"

HARNESS="
CLAUDE_MIN_VERSION=2.1.186
CLAUDE_TESTED_MAX=2.1.238
warn() { printf 'WARN %s\\n' \"\$*\"; }
ok() { printf 'OK %s\\n' \"\$*\"; }
die() { printf 'DIE %s\\n' \"\$*\"; exit 1; }
confirm() { [ \"\${CONFIRM_RESULT:-no}\" = yes ]; }
install_claude_stable() { printf '2.1.238' > \"\$FAKE_CLAUDE_STATE\"; }
$FUNCTIONS
ensure_claude_compatible
"

pass=0; fail=0
run_case() { # run_case <name> <policy> <tty> <want-rc> <want-text> [scope] [version]
  local name="$1" policy="$2" tty="$3" want_rc="$4" want_text="$5"
  local user_scope="${6:-yes}" initial_version="${7:-2.1.179}" output rc=0
  printf '%s' "$initial_version" > "$state"
  if [ "$tty" = yes ]; then tty_value=/dev/tty; else tty_value=""; fi
  output=$(PATH="$tmp:$PATH" FAKE_CLAUDE_STATE="$state" FAKE_USER_SCOPE="$user_scope" \
    QBRAID_CODE_CLAUDE_POLICY="$policy" TTY="$tty_value" \
    bash -c "set -euo pipefail; $HARNESS" 2>&1) || rc=$?
  if [ "$rc" = "$want_rc" ] && printf '%s\n' "$output" | grep -Fq "$want_text"; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$name"
  else
    fail=$((fail + 1)); printf '  FAIL %s: rc=%s output=[%s]\n' "$name" "$rc" "$output"
  fi
}

run_case "continue keeps old version" continue no 0 \
  "continuing with an unsupported Claude Code"
run_case "fail rejects old version" fail no 1 \
  "the installed Claude Code is incompatible"
run_case "upgrade reaches stable version" upgrade no 0 "OK Claude Code 2.1.238"
run_case "noninteractive prompt fails closed" prompt no 1 \
  "the installed Claude Code is incompatible"
run_case "continue degrades missing capability" continue no 0 \
  "required HTTP MCP commands are unavailable" no
run_case "upgrade never downgrades a newer CLI" upgrade no 1 \
  "Refusing to downgrade it" no 2.1.239
run_case "prompt never downgrades a newer CLI" prompt yes 0 \
  "refusing to downgrade it and continuing" no 2.1.239
run_case "upgrade never replaces an unknown version" upgrade no 1 \
  "could downgrade it" yes mystery-version
run_case "prompt never replaces an unknown version" prompt yes 0 \
  "could downgrade it" yes mystery-version

printf '2.1.179' > "$state"
rc=0
prompt_output=$(PATH="$tmp:$PATH" FAKE_CLAUDE_STATE="$state" \
  QBRAID_CODE_CLAUDE_POLICY=prompt TTY=/dev/tty CONFIRM_RESULT=no \
  bash -c "set -euo pipefail; $HARNESS" 2>&1) || rc=$?
if [ "$rc" = 0 ] && printf '%s\n' "$prompt_output" | grep -Fq \
  "continuing with reduced compatibility at your request"; then
  pass=$((pass + 1)); printf '  ok   interactive prompt can decline upgrade\n'
else
  fail=$((fail + 1)); printf '  FAIL interactive prompt decline: rc=%s output=[%s]\n' "$rc" "$prompt_output"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
