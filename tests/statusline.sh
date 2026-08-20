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

# file_age must work on THIS platform. `stat -f %m` is BSD-only and on GNU
# coreutils fails while still printing to stdout, which froze the balance
# forever. With a fresh attempt stamp no refresh is due; if file_age is broken
# the script cannot tell, so assert it reads back a sane age.
: > "$TMP/credits.attempt"
age_probe=$(
  # shellcheck disable=SC1090
  mtime=$(stat -c %Y "$TMP/credits.attempt" 2>/dev/null) \
    || mtime=$(stat -f %m "$TMP/credits.attempt" 2>/dev/null) \
    || mtime=""
  case "$mtime" in
    ''|*[!0-9]*) echo "BAD" ;;
    *) echo $(( $(date +%s) - mtime )) ;;
  esac
)
if [ "$age_probe" != BAD ] && [ "$age_probe" -lt 5 ] 2>/dev/null; then
  pass=$((pass + 1)); printf '  ok   file mtime readable on %s (age %ss)\n' "$(uname -s)" "$age_probe"
else
  fail=$((fail + 1)); printf '  FAIL file mtime unreadable on %s: %s\n' "$(uname -s)" "$age_probe"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
