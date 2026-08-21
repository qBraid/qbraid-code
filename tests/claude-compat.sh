#!/usr/bin/env bash
# Exercise the installer compatibility policy through its real helper
# definitions. The fake claude executable keeps the tests deterministic and
# avoids changing whichever Claude Code version is installed on the runner.
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
  claude_supports_mcp_http claude_supports_mcp_user_scope; do
  src=$(extract_fn "$fn")
  if [ -z "$src" ]; then
    printf '  FAIL could not extract %s from install.sh\n' "$fn"
    exit 1
  fi
  FUNCTIONS="$FUNCTIONS
$src"
done

pass=0; fail=0
check_eq() { # check_eq <name> <want> <command...>
  local name="$1" want="$2" got
  shift 2
  got=$(bash -c "set -euo pipefail; CLAUDE_MIN_VERSION=2.1.186; CLAUDE_TESTED_MAX=2.1.238; $FUNCTIONS; $*" 2>/dev/null) || got="<command failed>"
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$name"
  else
    fail=$((fail + 1)); printf '  FAIL %s: got [%s] want [%s]\n' "$name" "$got" "$want"
  fi
}

check_eq "parse native version output" 2.1.179 \
  "parse_claude_version '2.1.179 (Claude Code)'"
check_eq "parse version with surrounding text" 2.1.238 \
  "parse_claude_version 'Claude Code version 2.1.238'"
check_eq "missing version parses empty" "" \
  "parse_claude_version 'present but unparseable'"

check_eq "older version compares below" -1 "compare_versions 2.1.185 2.1.186"
check_eq "equal version compares equal" 0 "compare_versions 2.1.186 2.1.186"
check_eq "newer patch compares above" 1 "compare_versions 2.1.238 2.1.186"
check_eq "newer minor compares above" 1 "compare_versions 2.2.0 2.1.999"

check_eq "unknown version status" unknown "claude_version_status ''"
check_eq "below minimum status" below-minimum "claude_version_status 2.1.185"
check_eq "minimum is tested" tested "claude_version_status 2.1.186"
check_eq "tested maximum is tested" tested "claude_version_status 2.1.238"
check_eq "newer version is informational" newer-than-tested "claude_version_status 2.1.239"

check_eq "upgrade policy upgrades" upgrade "claude_policy_action upgrade no"
check_eq "fail policy fails" fail "claude_policy_action fail yes"
check_eq "continue policy continues" continue "claude_policy_action continue no"
check_eq "interactive prompt prompts" prompt "claude_policy_action prompt yes"
check_eq "noninteractive prompt fails" fail "claude_policy_action prompt no"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/claude" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "mcp --help")
    printf '%s\n' 'Commands:' '  add [options]' '  get <name>'
    [ "${FAKE_MCP_LOGIN:-no}" = yes ] && printf '%s\n' '  login <name>'
    ;;
  "mcp add")
    [ "${3:-}" = --help ] && printf '%s\n' \
      '  --transport <transport>  stdio, sse, or http' \
      '  --scope <scope>          local, project, or user'
    ;;
esac
EOF
chmod +x "$tmp/claude"

check_cap() { # check_cap <name> <login yes|no> <want> <expression>
  local name="$1" login="$2" want="$3" expr="$4" got
  got=$(PATH="$tmp:$PATH" FAKE_MCP_LOGIN="$login" bash -c \
    "set -euo pipefail; $FUNCTIONS; if $expr; then printf yes; else printf no; fi")
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$name"
  else
    fail=$((fail + 1)); printf '  FAIL %s: got [%s] want [%s]\n' "$name" "$got" "$want"
  fi
}

check_cap "detect mcp add" no yes "claude_supports_mcp_command add"
check_cap "detect mcp get" no yes "claude_supports_mcp_command get"
check_cap "detect missing mcp login" no no "claude_supports_mcp_command login"
check_cap "detect available mcp login" yes yes "claude_supports_mcp_command login"
check_cap "detect HTTP transport" no yes "claude_supports_mcp_http"
check_cap "detect user scope" no yes "claude_supports_mcp_user_scope"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
