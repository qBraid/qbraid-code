#!/usr/bin/env bash
# The doctor must explain unsupported versions and use the interactive MCP
# fallback without contacting qBraid or relying on the host's Claude install.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home/.qbraid-code" "$tmp/bin"
cat > "$tmp/home/.qbraid-code/env" <<'EOF'
QBRAID_CODE_BASE_URL=
QBRAID_CODE_API_BASE=
QBRAID_CODE_TOKEN=
QBRAID_CODE_MODEL=claude-sonnet-4-6
QBRAID_CODE_PROXY_BIN=
EOF

cat > "$tmp/bin/claude" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "--version ") printf '%s\n' "${FAKE_CLAUDE_VERSION:-2.1.179} (Claude Code)" ;;
  "mcp --help")
    printf '%s\n' 'Commands:' '  add [options]' '  get <name>'
    [ "${FAKE_MCP_LOGIN:-no}" = yes ] && printf '%s\n' '  login <name>'
    ;;
  "mcp add")
    [ "${3:-}" = --help ] && printf '%s\n' \
      '  --transport <transport>  stdio, sse, or http' \
      '  --scope <scope>          local, project, or user'
    ;;
  "mcp get") [ "${3:-}" = qbraid ] && [ "${FAKE_MCP_REGISTERED:-yes}" = yes ] ;;
esac
EOF
chmod +x "$tmp/bin/claude"

pass=0; fail=0
check_contains() { # check_contains <name> <output> <text>
  local name="$1" output="$2" text="$3"
  if printf '%s\n' "$output" | grep -Fq "$text"; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$name"
  else
    fail=$((fail + 1)); printf '  FAIL %s: missing [%s]\n' "$name" "$text"
  fi
}

old=$(HOME="$tmp/home" PATH="$tmp/bin:$PATH" ./qbraid-code --doctor)
check_contains "doctor rejects old version" "$old" \
  "claude-min: FAIL (requires 2.1.186+, found 2.1.179)"
check_contains "doctor reports missing login capability" "$old" "mcp-login=no"
check_contains "doctor gives interactive MCP fallback" "$old" \
  "registered (run /mcp inside Claude Code to authenticate)"

unregistered=$(HOME="$tmp/home" PATH="$tmp/bin:$PATH" \
  FAKE_MCP_REGISTERED=no ./qbraid-code --doctor)
check_contains "doctor gives fallback when MCP is unregistered" "$unregistered" \
  "NOT REGISTERED — configure and authenticate through /mcp"

new=$(HOME="$tmp/home" PATH="$tmp/bin:$PATH" \
  FAKE_CLAUDE_VERSION=2.1.239 FAKE_MCP_LOGIN=yes ./qbraid-code --doctor)
check_contains "doctor permits newer version" "$new" \
  "claude-min: PASS (requires 2.1.186+)"
check_contains "doctor labels newer version without blocking" "$new" \
  "claude-tested: NEWER than tested 2.1.238 (not blocked)"
check_contains "doctor reports login capability" "$new" "mcp-login=yes"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
