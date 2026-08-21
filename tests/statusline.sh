#!/usr/bin/env bash
# Renders statusline.sh against fixture payloads and asserts each segment.
#
# These are the cases that broke in review and could only be caught by running
# the thing: a BSD-only `stat` flavour that froze the balance on Linux, a zero
# balance, and payloads missing fields.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export QBRAID_CODE_HOME="$TMP"

# Token deliberately empty: no test may touch the network.
cat > "$TMP/env" <<'EOF'
QBRAID_CODE_BASE_URL=https://example.invalid/api/v1/ai
QBRAID_CODE_API_BASE=https://example.invalid/api/v1
QBRAID_CODE_TOKEN=
QBRAID_CODE_MODEL=claude-opus-5
EOF
printf 'Research Lab\n' > "$TMP/label"
printf 'local\n' > "$TMP/label-source"
date +%s > "$TMP/credits.updated"

pass=0; fail=0
render() { printf '%s' "$1" | bash statusline.sh 2>/dev/null; }
# Colour resets sit between segments, so assertions match the plain text.
strip_ansi() { sed $'s/\033\[[0-9;]*m//g'; }
check() { # check <name> <payload> <regex>
  local out
  out=$(render "$2" | strip_ansi)
  if printf '%s' "$out" | grep -qE "$3"; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$1"
  else
    fail=$((fail + 1)); printf '  FAIL %s\n       got: %s\n' "$1" "$out"
  fi
}

FULL='{"model":{"display_name":"Claude Opus 5"},"workspace":{"current_dir":"/tmp"},"context_window":{"remaining_percentage":87}}'

check "model name renders"       "$FULL" 'Claude Opus 5'
check "qBraid identity renders"  "$FULL" 'qBraid Research Lab'
printf 'org-123456789\n' > "$TMP/organization-id"
check "verified organization ID accompanies local label" "$FULL" 'Research Lab \(local · org org-1234…\)'
rm -f "$TMP/organization-id"
raw_brand=$(render "$FULL")
if printf '%s' "$raw_brand" | grep -q "$(printf '\033')\[38;2;168;85;247mqBraid"; then
  pass=$((pass + 1)); printf '  ok   qBraid uses one violet accent\n'
else
  fail=$((fail + 1)); printf '  FAIL qBraid violet accent missing\n'
fi
check "context 87 pct -> C13"    "$FULL" 'C13'
check "one filled block"         "$FULL" '█░░░░░'
check "100 pct remaining -> C0"  '{"context_window":{"remaining_percentage":100},"workspace":{"current_dir":"/tmp"}}' 'C0'
check "5 pct remaining -> C95"   '{"context_window":{"remaining_percentage":5},"workspace":{"current_dir":"/tmp"}}'   'C95'
check "full bar at 5 pct"        '{"context_window":{"remaining_percentage":5},"workspace":{"current_dir":"/tmp"}}'   '██████'
check "missing context_window"   '{"model":{"display_name":"Claude Opus 5"},"workspace":{"current_dir":"/tmp"}}' 'Claude Opus 5'
check "empty stdin renders"      '' '.'

# A directory name carrying a backslash escape must be printed literally, never
# re-interpreted into a terminal control sequence (printf %s, not %b).
ESC_PAYLOAD='{"workspace":{"current_dir":"/tmp/x\u001b[31mRED"},"context_window":{"remaining_percentage":50}}'
esc_out=$(render "$ESC_PAYLOAD" | strip_ansi)
if printf '%s' "$esc_out" | grep -q 'u001b'; then
  pass=$((pass + 1)); printf '  ok   escape sequence not interpreted\n'
else
  fail=$((fail + 1)); printf '  FAIL escape sequence was interpreted\n       got: %s\n' "$esc_out"
fi

# Zero must render as a number, not vanish or read as "unknown".
printf '0' > "$TMP/credits.cache"
check "zero credits renders" "$FULL" '0 credits'

printf '4281.4' > "$TMP/credits.cache"
check "credits are rounded"  "$FULL" '4281 credits'
printf 'expired\n' > "$TMP/key-status"
check "confirmed rejection marks the key expired" "$FULL" 'key expired'
rm -f "$TMP/key-status"

printf '%s
' "$(( $(date +%s) - 600 ))" > "$TMP/credits.updated"
check "stale credits are marked" "$FULL" '4281 credits · stale 10m'
date +%s > "$TMP/credits.updated"
if ! render "$FULL" | strip_ansi | grep -q stale; then
  pass=$((pass + 1)); printf '  ok   fresh credits are not marked stale\n'
else
  fail=$((fail + 1)); printf '  FAIL fresh credits marked stale\n'
fi

if grep -E -- '-H[[:space:]]+"[^"$]*\$(TOKEN|API_KEY)' statusline.sh install.sh qbraid-code >/dev/null; then
  fail=$((fail + 1)); printf '  FAIL API key appears in a process argument\n'
elif ! grep -q 'QBRAID_CODE_TOKEN' statusline.sh && grep -q -- '--config -' install.sh; then
  pass=$((pass + 1)); printf '  ok   API keys use curl config stdin, not process arguments\n'
else
  fail=$((fail + 1)); printf '  FAIL secret-free curl transport missing\n'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
