#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
HOME_ROOT="$TMP/home with space"
QC_HOME="$HOME_ROOT/.qbraid-code"
BIN="$TMP/bin"
mkdir -p "$QC_HOME/profiles/alpha" "$QC_HOME/profiles/beta" "$BIN"

make_profile() {
  local slug="$1" label="$2" token="$3" model="$4" port="$5"
  cat > "$QC_HOME/profiles/$slug/env" <<EOF
QBRAID_CODE_BASE_URL=https://example.invalid/api/v1/ai
QBRAID_CODE_API_BASE=https://example.invalid/api/v1
QBRAID_CODE_TOKEN=$token
QBRAID_CODE_MODEL=$model
QBRAID_CODE_PROXY_PORT=$port
QBRAID_CODE_PROXY_BIN=$BIN/cliproxyapi
EOF
  cat > "$QC_HOME/profiles/$slug/proxy-template.yaml" <<'EOF'
port: __PORT__
auth-dir: "__AUTH_DIR__"
api-keys:
  - "__LOCAL_KEY__"
claude-api-key:
  - api-key: "__QBRAID_KEY__"
EOF
  printf '%s\n' "$label" > "$QC_HOME/profiles/$slug/label"
  printf 'local\n' > "$QC_HOME/profiles/$slug/label-source"
  cat > "$QC_HOME/profiles/$slug/models.tsv" <<'EOF'
claude-opus-5	1050000
gpt-5.4-mini	400000
claude-haiku-4-5	200000
EOF
}
make_profile alpha "Alpha Org" token-alpha claude-opus-5 8320
make_profile beta "Beta Org" token-beta claude-haiku-4-5 8321
printf 'alpha\n' > "$QC_HOME/active-profile"

cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
out=""; status=0
while [ "$#" -gt 0 ]; do case "$1" in -o) out="$2"; shift 2;; -w) status=1; shift 2;; --config|-m) shift 2;; *) shift;; esac; done
[ -z "$out" ] || printf '{}' > "$out"
[ "$status" -eq 0 ] || printf '%s' "${CREDIT_STATUS:-200}"
EOF
cc tests/fake-proxy.c -o "$BIN/cliproxyapi"
chmod +x "$BIN/curl" "$BIN/cliproxyapi"
cat > "$BIN/claude" <<'EOF'
#!/usr/bin/env bash
printf 'profile_home=%s\n' "${QBRAID_CODE_PROFILE_HOME:-}"
[ ! -f "${QBRAID_CODE_PROFILE_HOME:-}/env" ] || printf 'secret_snapshot=yes\n'
printf 'token=%s\n' "${ANTHROPIC_AUTH_TOKEN:-}"
printf 'model=%s\n' "${ANTHROPIC_MODEL:-}"
printf 'max_context=%s\n' "${CLAUDE_CODE_MAX_CONTEXT_TOKENS-unset}"
printf 'args='; printf '<%s>' "$@"; printf '\n'
EOF
chmod +x "$BIN/claude"

export HOME="$HOME_ROOT"
export QBRAID_CODE_HOME="$QC_HOME"
export PATH="$BIN:/usr/bin:/bin"

pass=0; fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; [ $# -lt 2 ] || printf '       %s\n' "$2"; }
contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

out=$(bash qbraid-code -p 'hello world' --allowedTools 'Read Bash')
contains "$out" "profile_home=$QC_HOME/session.alpha." &&
! contains "$out" 'token=token-' &&
! contains "$out" 'secret_snapshot=yes' &&
contains "$out" 'model=claude-opus-5[1m]' &&
contains "$out" 'max_context=unset' &&
contains "$out" 'args=<-p><hello world><--allowedTools><Read Bash>' &&
contains "$out" '<--setting-sources><user>' \
  && ok 'active profile binds once, excludes project settings, and preserves Claude args' \
  || bad 'active profile binding or argument preservation' "$out"

CREDIT_STATUS=401 bash qbraid-code --profile alpha -p rejected >/dev/null
if [ "$(cat "$QC_HOME/profiles/alpha/key-status" 2>/dev/null)" = expired ]; then
  ok 'confirmed key rejection is cached for the statusline'
else
  bad 'confirmed key rejection was not cached'
fi
CREDIT_STATUS=200 bash qbraid-code --profile alpha -p recovered >/dev/null
if [ ! -e "$QC_HOME/profiles/alpha/key-status" ]; then
  ok 'successful key check clears the expired marker'
else
  bad 'successful key check left the expired marker'
fi

out=$(bash qbraid-code --profile beta -p beta-question)
contains "$out" "profile_home=$QC_HOME/session.beta." &&
! contains "$out" 'token=token-' &&
contains "$out" 'model=claude-haiku-4-5' &&
contains "$out" 'max_context=200000' &&
contains "$out" 'args=<-p><beta-question>' \
  && ok 'first --profile selects and is removed' \
  || bad 'explicit profile selection' "$out"

out=$(bash qbraid-code -p keep --profile beta)
! contains "$out" 'token=token-' && contains "$out" 'args=<-p><keep><--profile><beta>' \
  && ok 'non-leading --profile remains a Claude argument' \
  || bad 'non-leading --profile was consumed' "$out"

out=$(bash qbraid-code --profiles)
contains "$out" '* alpha' && contains "$out" 'Alpha Org' &&
contains "$out" '  beta' && contains "$out" 'Beta Org' \
  && ok '--profiles lists labels and active profile' \
  || bad '--profiles output' "$out"

if bash qbraid-code --profile '../bad' -p nope >"$TMP/out" 2>"$TMP/err"; then
  bad 'invalid profile slug was accepted'
elif grep -q 'invalid profile' "$TMP/err"; then
  ok 'invalid profile slug is rejected'
else
  bad 'invalid profile error missing' "$(cat "$TMP/err")"
fi
if bash qbraid-code --global > "$TMP/global.out" 2> "$TMP/global.err"; then bad 'unsafe launcher global mode was accepted';
elif grep -q 'removed.*exfiltrate' "$TMP/global.err"; then ok 'unsafe launcher global mode is rejected'; else bad 'launcher global removal diagnosis'; fi

bash qbraid-code --use-profile beta >/dev/null
[ "$(cat "$QC_HOME/active-profile")" = beta ] \
  && ok '--use-profile atomically changes future default' \
  || bad '--use-profile did not update active marker'

selection_failed=0
selection_pids=""
i=0
while [ "$i" -lt 20 ]; do
  target=alpha; [ $((i % 2)) -eq 1 ] && target=beta
  (bash qbraid-code --use-profile "$target" >/dev/null) & selection_pids="$selection_pids $!"
  i=$((i + 1))
done
for pid in $selection_pids; do wait "$pid" || selection_failed=1; done
active=$(cat "$QC_HOME/active-profile")
if [ "$selection_failed" -eq 0 ] && { [ "$active" = alpha ] || [ "$active" = beta ]; }; then
  ok 'concurrent selection uses collision-free atomic writes'
else
  bad 'concurrent atomic selection failed' "active=$active"
fi

# Two future launches may bind different profiles concurrently without sharing
# credentials, profile homes, or configured ports.
(bash qbraid-code --profile alpha -p one > "$TMP/alpha.out") & p1=$!
(bash qbraid-code --profile beta -p two > "$TMP/beta.out") & p2=$!
wait "$p1"; wait "$p2"
if ! grep -q 'token=token-' "$TMP/alpha.out" &&
   grep -q 'profile_home=.*/session.alpha.' "$TMP/alpha.out" &&
   ! grep -q 'token=token-' "$TMP/beta.out" &&
   grep -q 'profile_home=.*/session.beta.' "$TMP/beta.out"; then
  ok 'concurrent launches stay profile-bound'
else
  bad 'concurrent profile binding crossed state'
fi

if bash qbraid-code --profile alpha --resume >"$TMP/out" 2>"$TMP/err"; then
  bad 'cross-profile resume was accepted without confirmation'
elif grep -q 'explicit profile confirmation' "$TMP/err"; then
  ok 'cross-profile resume fails closed'
else
  bad 'cross-profile resume error missing' "$(cat "$TMP/err")"
fi
out=$(bash qbraid-code --profile alpha --allow-profile-resume --resume session-id)
if ! contains "$out" 'token=token-' && contains "$out" 'args=<--resume><session-id>'; then
  ok 'explicit resume confirmation preserves arguments'
else
  bad 'confirmed profile resume failed' "$out"
fi

printf '11' > "$QC_HOME/profiles/alpha/credits.cache"
printf '22' > "$QC_HOME/profiles/beta/credits.cache"
date +%s > "$QC_HOME/profiles/alpha/credits.updated"
date +%s > "$QC_HOME/profiles/beta/credits.updated"
: > "$QC_HOME/profiles/alpha/credits.attempt"
: > "$QC_HOME/profiles/beta/credits.attempt"
alpha_status=$(printf '{}' | QBRAID_CODE_PROFILE_HOME="$QC_HOME/profiles/alpha" bash statusline.sh | sed $'s/\033\[[0-9;]*m//g')
beta_status=$(printf '{}' | QBRAID_CODE_PROFILE_HOME="$QC_HOME/profiles/beta" bash statusline.sh | sed $'s/\033\[[0-9;]*m//g')
if contains "$alpha_status" 'qBraid Alpha Org (local) · 11 credits' &&
   contains "$beta_status" 'qBraid Beta Org (local) · 22 credits'; then
  ok 'status labels and credit caches stay profile-scoped'
else
  bad 'profile status cache isolation' "$alpha_status | $beta_status"
fi

cat > "$QC_HOME/env" <<'EOF'
QBRAID_CODE_API_BASE=https://example.invalid/api/v1
EOF
printf 'Legacy Org\n' > "$QC_HOME/label"
printf 'local\n' > "$QC_HOME/label-source"
printf '33\n' > "$QC_HOME/credits.cache"
date +%s > "$QC_HOME/credits.updated"
legacy_status=$(printf '{}' | env QBRAID_CODE_PROFILE_HOME='' QBRAID_CODE_PROFILE='' bash statusline.sh | sed $'s/\033\[[0-9;]*m//g')
if contains "$legacy_status" 'qBraid Legacy Org (local) · 33 credits'; then
  ok 'unbound legacy status stays on the legacy account'
else
  bad 'legacy status followed the new active profile' "$legacy_status"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
