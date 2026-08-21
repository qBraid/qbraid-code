#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

TMP=$(mktemp -d); listener=''; trap '[ -z "$listener" ] || kill "$listener" 2>/dev/null || true; rm -rf "$TMP"' EXIT
QC_HOME="$TMP/qc\"quote\\slash"; BIN="$TMP/bin"; PROFILE="$QC_HOME/profiles/default"
mkdir -p "$PROFILE" "$BIN"
printf 'default\n' > "$QC_HOME/active-profile"
printf 'Default\n' > "$PROFILE/label"
cat > "$PROFILE/env" <<'EOF'
QBRAID_CODE_BASE_URL=https://example.invalid/api/v1/ai
QBRAID_CODE_API_BASE=https://example.invalid/api/v1
QBRAID_CODE_TOKEN=test-token
QBRAID_CODE_MODEL=claude-opus-5
QBRAID_CODE_PROXY_PORT=8780
QBRAID_CODE_PROXY_BIN=PLACEHOLDER
EOF
sed "s|PLACEHOLDER|$BIN/cliproxyapi|" "$PROFILE/env" > "$PROFILE/env.tmp" && mv "$PROFILE/env.tmp" "$PROFILE/env"
cat > "$PROFILE/proxy-template.yaml" <<'EOF'
port: __PORT__
auth-dir: "__AUTH_DIR__"
api-keys:
  - "__LOCAL_KEY__"
claude-api-key:
  - api-key: "__QBRAID_KEY__"
EOF
cat > "$PROFILE/models.tsv" <<'EOF'
claude-opus-5	1050000
future-400k	400000
EOF
cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
last="${!#:-}"
case "$last" in http://127.0.0.1:*/) exec /usr/bin/curl "$@" ;; esac
out=""; status=0
while [ "$#" -gt 0 ]; do case "$1" in -o) out="$2"; shift 2;; -w) status=1; shift 2;; --config|-m) shift 2;; *) shift;; esac; done
[ -z "$out" ] || printf '{}' > "$out"
if [ "$status" -eq 0 ] && [ -n "${CAPTURE_PROXY_CONFIG:-}" ]; then i=0; while [ ! -f "$CAPTURE_PROXY_CONFIG" ] && [ "$i" -lt 50 ]; do sleep 0.02; i=$((i + 1)); done; fi
[ "$status" -eq 0 ] || printf 200
EOF
cat > "$BIN/cliproxyapi" <<'EOF'
#!/usr/bin/env bash
[ -z "${CAPTURE_PROXY_CONFIG:-}" ] || cp "$2" "$CAPTURE_PROXY_CONFIG"
sleep 0.4
[ -f "$2" ] || exit 42
[ -z "${PROXY_WATCHER_READY:-}" ] || printf 'ready\n' > "$PROXY_WATCHER_READY"
while :; do sleep 60; done
EOF
chmod +x "$BIN/curl" "$BIN/cliproxyapi"
cat > "$BIN/claude" <<'EOF'
#!/usr/bin/env bash
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --settings|--setting-sources) shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
if [ -n "${PROXY_WATCHER_READY:-}" ]; then i=0; while [ ! -f "$PROXY_WATCHER_READY" ] && [ "$i" -lt 75 ]; do sleep 0.02; i=$((i + 1)); done; [ -f "$PROXY_WATCHER_READY" ] || exit 42; fi
printf '%s|%s|%s\n' "$ANTHROPIC_MODEL" "${CLAUDE_CODE_MAX_CONTEXT_TOKENS-unset}" "${args[*]}"
EOF
chmod +x "$BIN/claude"
PYTHON_BIN=$(command -v python3)
export QBRAID_CODE_HOME="$QC_HOME" PATH="$BIN:/usr/bin:/bin"

pass=0; fail=0
check() {
  local name="$1" want="$2"; shift 2
  local got
  got=$(bash qbraid-code "$@")
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$name"
  else
    fail=$((fail + 1)); printf '  FAIL %s\n       got:  %s\n       want: %s\n' "$name" "$got" "$want"
  fi
}

export CAPTURE_PROXY_CONFIG="$TMP/proxy.yaml"
export PROXY_WATCHER_READY="$TMP/proxy-watcher.ready"
"$PYTHON_BIN" -m http.server 8780 --bind 127.0.0.1 > /dev/null 2>&1 & listener=$!
i=0; while ! /usr/bin/curl -sS -m 1 -o /dev/null http://127.0.0.1:8780/ 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
if ! /usr/bin/curl -sS -m 1 -o /dev/null http://127.0.0.1:8780/ 2>/dev/null; then printf '  FAIL occupied-port fixture did not start\n'; exit 1; fi
check 'million-token default gets marker and no process cap' \
  'claude-opus-5[1m]|unset|-p high' -p high
kill "$listener" 2>/dev/null || true; wait "$listener" 2>/dev/null || true; listener=''
if [ -f "$PROXY_WATCHER_READY" ]; then pass=$((pass + 1)); printf '  ok   runtime config survives proxy watcher startup\n'; else fail=$((fail + 1)); printf '  FAIL runtime config vanished before watcher startup\n'; fi
if [ ! -f "$CAPTURE_PROXY_CONFIG" ]; then
  fail=$((fail + 1)); printf '  FAIL runtime proxy config was not generated\n'
elif grep -q '^port: 8780$' "$CAPTURE_PROXY_CONFIG"; then
  fail=$((fail + 1)); printf '  FAIL occupied base port was reused\n'
else
  pass=$((pass + 1)); printf '  ok   occupied base port advances to a free runtime port\n'
fi
auth_line=$(grep '^auth-dir:' "$CAPTURE_PROXY_CONFIG" 2>/dev/null || true)
case "$auth_line" in
  *'\"'*'\\'*) pass=$((pass + 1)); printf '  ok   runtime YAML escapes quote and backslash paths\n' ;;
  *) fail=$((fail + 1)); printf '  FAIL runtime YAML path escaping: %s\n' "$auth_line" ;;
esac
check 'lower known model gets exact cap' \
  'future-400k|400000|--model future-400k -p lower' --model future-400k -p lower
check 'unknown model stays conservatively capped' \
  'future-model|200000|--model future-model -p unknown' --model future-model -p unknown

# Inherited policy must never leak across model classes.
export CLAUDE_CODE_MAX_CONTEXT_TOKENS=777777
check 'million-token launch clears inherited cap' \
  'claude-opus-5[1m]|unset|-p inherited' -p inherited
check 'known lower launch replaces inherited cap exactly' \
  'future-400k|400000|--model future-400k' --model future-400k

if grep -R 'MAX_THINKING_TOKENS=0' install.sh qbraid-code README.md >/dev/null 2>&1; then
  fail=$((fail + 1)); printf '  FAIL MAX_THINKING_TOKENS=0 workaround remains\n'
else
  pass=$((pass + 1)); printf '  ok   MAX_THINKING_TOKENS=0 workaround removed\n'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
