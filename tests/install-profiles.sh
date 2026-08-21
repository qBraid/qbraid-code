#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
HOME_ROOT="$TMP/o'brien home"
QC_HOME="$HOME_ROOT/.qbraid-code"
BIN_DIR="$HOME_ROOT/bin with space"
FAKE_BIN="$TMP/fake-bin"
mkdir -p "$HOME_ROOT/.claude" "$QC_HOME" "$FAKE_BIN"
printf 'alpha\n' > "$QC_HOME/active-profile"
printf 'alpha\n' > "$QC_HOME/global-profile"
cat > "$HOME_ROOT/.claude/settings.json" <<'EOF'
{"env":{"ANTHROPIC_BASE_URL":"https://api-v2.qbraid.com/api/v1/ai","ANTHROPIC_AUTH_TOKEN":"key-alpha","ANTHROPIC_MODEL":"claude-opus-5","ANTHROPIC_SMALL_FAST_MODEL":"claude-opus-5","QBRAID_CODE_PROFILE":"alpha"}}
EOF
cat > "$FAKE_BIN/claude" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo 2.1.238 ;;
  mcp)
    if [ "${2:-}" = --help ]; then
      printf '  add
  get
  login
'
    elif [ "${2:-}" = add ] && [ "${3:-}" = --help ]; then
      printf '%s
' '--transport <transport> [http]' '--scope <scope> [user]'
    fi
    ;;
esac
exit 0
EOF
cat > "$FAKE_BIN/cliproxyapi" <<'EOF'
#!/usr/bin/env bash
# disable-cloaking-model-list
exit 0
EOF
cat > "$FAKE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
out=""; want_status=0; url=""; cfg=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;; -w) want_status=1; shift 2 ;;
    -m|-d|-H) shift 2 ;;
    --config) if [ "$2" = - ]; then cfg=$(cat); fi; shift 2 ;;
    -*) shift ;; http*) url="$1"; shift ;; *) shift ;;
  esac
done
case "$url" in
  *billing/credits/balance*) org=org-alpha; case "$cfg" in *key-beta*) org=org-beta ;; esac; body="{\"data\":{\"organizationId\":\"$org\",\"qbraidCredits\":100}}"; code=200 ;;
  *organizations/current*) body='{"data":{"name":"Verified Lab"}}'; code=200 ;; *'/quota') body='{"plan":"pro"}'; code=200 ;;
  *'/ai/models') body='{"data":[{"id":"claude-haiku-4-5","context_window":200000},{"id":"claude-opus-4-8","context_window":1000000},{"id":"claude-opus-5","context_window":1000000},{"id":"claude-sonnet-4-6","context_window":1000000},{"id":"gpt-5.4","context_window":400000}]}'; code=200 ;;
  *'/v1/messages') body='{"content":[{"text":"OK"}]}'; code=200 ;; *api.github.com*) exit 22 ;;
  *) body='{}'; code=404 ;;
esac
if [ -n "$out" ]; then printf '%s' "$body" > "$out"; else printf '%s' "$body"; fi
[ "$want_status" -ne 1 ] || printf '%s' "$code"
EOF
cat > "$FAKE_BIN/secret-tool" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$FAKE_BIN/secret-tool"
cat > "$FAKE_BIN/security" <<'EOF'
#!/usr/bin/env bash
action="$1"; shift; service=""
while [ "$#" -gt 0 ]; do case "$1" in -s) service="$2"; shift 2;; -w) want_password=1; shift;; *) shift;; esac; done
file="$HOME/.fake-key.$(printf '%s' "$service" | tr ':/' '__')"
case "$action" in
  add-generic-password) IFS= read -r value; printf '%s\n' "$value" > "$file" ;;
  find-generic-password) cat "$file" ;;
  delete-generic-password) rm -f "$file" ;;
esac
EOF
chmod +x "$FAKE_BIN/claude" "$FAKE_BIN/curl" "$FAKE_BIN/security" "$FAKE_BIN/cliproxyapi"
export HOME="$HOME_ROOT" QBRAID_CODE_HOME="$QC_HOME" QBRAID_CODE_BIN_DIR="$BIN_DIR"
export PATH="$FAKE_BIN:/usr/bin:/bin" QBRAID_CODE_MODEL=claude-haiku-4-5 QBRAID_CODE_PROFILE_LABEL='Beta Team'
profile_dir() { local root="$QC_HOME/profiles/$1" generation; generation=$(cat "$root/current"); printf '%s/generations/%s' "$root" "$generation"; }
profile_secret() {
  local dir="$1" backend ref
  backend=$(sed -n 's/^QBRAID_CODE_SECRET_BACKEND=//p' "$dir/env")
  ref=$(sed -n 's/^QBRAID_CODE_SECRET_REF=//p' "$dir/env")
  case "$backend" in keychain) security find-generic-password -s "$ref" -w ;; file) cat "$ref" ;; esac
}
profile_secret_exists() {
  local backend="$1" ref="$2"
  case "$backend" in keychain) security find-generic-password -s "$ref" -w >/dev/null 2>&1 ;; file) [ -f "$ref" ] ;; esac
}
pass=0; fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }

QBRAID_API_KEY=key-beta bash install.sh --profile beta > "$TMP/install.out" 2> "$TMP/install.err"
BETA_DIR=$(profile_dir beta)
if [ "$(cat "$QC_HOME/active-profile")" = beta ] &&
   [ ! -e "$QC_HOME/global-profile" ] &&
   [ "$(cat "$BETA_DIR/organization-id")" = org-beta ] &&
   [ "$(cat "$BETA_DIR/label")" = 'Beta Team' ] && [ "$(cat "$BETA_DIR/label-source")" = local ] &&
   grep -q '^QBRAID_CODE_SECRET_BACKEND=\(keychain\|file\)$' "$BETA_DIR/env" &&
   ! grep -q 'key-beta' "$BETA_DIR/env"; then
  ok 'install activates metadata without persisting its key'
else bad 'profile activation or secret storage'; fi
if [ "$(cat "$BIN_DIR/qbraid-code.home")" = "$QC_HOME" ] && [ -x "$BIN_DIR/qbraid-code" ]; then
  status_command=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["statusLine"]["command"])' "$HOME_ROOT/.claude/settings.json")
  if printf '{}' | /bin/sh -c "$status_command" >/dev/null; then ok 'quoted custom paths survive installation'; else bad 'quoted status command'; fi
else bad 'custom path launcher binding'; fi
profile_list=$(QBRAID_CODE_HOME='' bash "$BIN_DIR/qbraid-code" --profiles)
if printf '%s' "$profile_list" | grep -q '\* beta' && printf '%s' "$profile_list" | grep -q 'Beta Team'; then
  ok 'installed launcher resolves the atomic profile generation'
else bad 'installed generation lookup'; fi
if ! grep -q 'ANTHROPIC_' "$HOME_ROOT/.claude/settings.json" &&
   ! grep -q 'key-alpha\|key-beta' "$HOME_ROOT/.claude/settings.json"; then
  ok 'unsafe legacy plain-Claude credentials are removed'
else bad 'plain Claude credential cleanup'; fi
if grep -q 'name: "claude-opus-4-8"' "$BETA_DIR/proxy-template.yaml" &&
   grep -q 'name: "claude-opus-5"' "$BETA_DIR/proxy-template.yaml" &&
   grep -q 'name: "claude-sonnet-4-6"' "$BETA_DIR/proxy-template.yaml" &&
   grep -q '^[[:space:]]*- "thinking"$' "$BETA_DIR/proxy-template.yaml" &&
   grep -q '^[[:space:]]*- "output_config"$' "$BETA_DIR/proxy-template.yaml"; then
  ok 'adaptive-only Claude models filter incompatible fixed thinking'
else bad 'Claude thinking compatibility filter'; fi

if QBRAID_API_KEY=key-alpha bash install.sh --profile beta > "$TMP/cross.out" 2> "$TMP/cross.err"; then
  bad 'profile accepted a different organization'
elif grep -q 'another organization' "$TMP/cross.err" && ! grep -q 'key-alpha' "$BETA_DIR/env"; then
  ok 'organization binding fails closed before profile replacement'
else bad 'organization mismatch diagnosis'; fi

before_generation=$(cat "$QC_HOME/profiles/beta/current")
before_secret=$(profile_secret "$BETA_DIR")
chmod -x "$FAKE_BIN/cliproxyapi"
no_stage() { local path; for path in "$QC_HOME/profiles/beta/generations"/.stage.*; do [ ! -e "$path" ] || return 1; done; }
if QBRAID_API_KEY=key-beta-rotated bash install.sh --profile beta > "$TMP/atomic.out" 2> "$TMP/atomic.err"; then
  bad 'incomplete profile generation was committed'
elif [ "$(cat "$QC_HOME/profiles/beta/current")" = "$before_generation" ] && [ "$(profile_secret "$BETA_DIR")" = "$before_secret" ] && no_stage; then
  ok 'failed updates leave the committed generation intact'
else bad 'failed update changed the profile pointer'; fi
chmod +x "$FAKE_BIN/cliproxyapi"
old_dir="$BETA_DIR"
old_backend=$(sed -n 's/^QBRAID_CODE_SECRET_BACKEND=//p' "$old_dir/env")
old_ref=$(sed -n 's/^QBRAID_CODE_SECRET_REF=//p' "$old_dir/env")
QBRAID_API_KEY=key-beta-rotated bash install.sh --profile beta > "$TMP/rotate.out"
BETA_DIR=$(profile_dir beta)
if [ "$BETA_DIR" != "$old_dir" ] && [ ! -d "$old_dir" ] && ! profile_secret_exists "$old_backend" "$old_ref" && [ "$(profile_secret "$BETA_DIR")" = key-beta-rotated ]; then
  ok 'successful key rotation prunes the previous generation secret'
else bad 'rotated generation cleanup'; fi

mkdir -p "$QC_HOME/profiles/beta/session-users"
printf '' > "$QC_HOME/profiles/beta/session-users/$$"
if QBRAID_API_KEY=key-beta bash install.sh --profile beta > "$TMP/live.out" 2> "$TMP/live.err"; then
  bad 'installer updated a profile with a live session'
elif grep -q 'running session' "$TMP/live.err"; then ok 'live profile update fails closed'; else bad 'live update diagnosis'; fi
rm -f "$QC_HOME/profiles/beta/session-users/$$"
QBRAID_CODE_PROFILE_LABEL='' QBRAID_API_KEY=key-beta bash install.sh --profile verified > "$TMP/verified.out"
VERIFIED_DIR=$(profile_dir verified)
if [ "$(cat "$VERIFIED_DIR/label")" = 'Verified Lab' ] && [ "$(cat "$VERIFIED_DIR/label-source")" = verified ]; then ok 'authenticated organization names retain verified provenance'; else bad 'verified label provenance'; fi

if bash install.sh --profle beta > /dev/null 2> "$TMP/unknown.err"; then bad 'unknown installer option was ignored';
elif grep -q 'unknown option' "$TMP/unknown.err"; then ok 'unknown installer option is rejected'; else bad 'unknown option diagnosis'; fi

if bash install.sh --global > /dev/null 2> "$TMP/global.err"; then bad 'unsafe global mode was accepted';
elif grep -q 'removed.*exfiltrate' "$TMP/global.err"; then ok 'unsafe plain-Claude global mode is rejected'; else bad 'global removal diagnosis'; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
