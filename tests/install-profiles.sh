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
case "${1:-} ${2:-} ${3:-}" in
  '--version  ') echo 2.1.238 ;;
  'mcp --help ') printf '%s\n' '  add' '  get' '  login' ;;
  'mcp add --help') printf '%s\n' '--transport <transport> [http]' '--scope <scope> [user]' ;;
  'mcp get '*) [ "${FAIL_MCP_ADD:-0}" -ne 1 ] ;;
  'mcp add '*) [ "${FAIL_MCP_ADD:-0}" -ne 1 ] ;;
esac
EOF
cc tests/fake-proxy.c -o "$FAKE_BIN/cliproxyapi"
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
  *'/ai/models') body='{"data":[{"id":"claude-haiku-4-5","context_window":200000},{"id":"gpt-5.4","context_window":400000}]}'; code=200 ;;
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

rollback_generation=$(cat "$QC_HOME/profiles/beta/current")
rollback_secret=$(profile_secret "$BETA_DIR")
rollback_key_files=$(find "$HOME" -maxdepth 1 -name '.fake-key.*' -print | sort)
if FAIL_MCP_ADD=1 QBRAID_API_KEY=key-beta-post-commit bash install.sh --profile beta > "$TMP/post-commit.out" 2> "$TMP/post-commit.err"; then
  bad 'post-stage failure was reported as a successful update'
else
  after_key_files=$(find "$HOME" -maxdepth 1 -name '.fake-key.*' -print | sort)
  if grep -q 'could not register' "$TMP/post-commit.err" \
    && [ "$(cat "$QC_HOME/profiles/beta/current")" = "$rollback_generation" ] \
    && [ "$(profile_secret "$BETA_DIR")" = "$rollback_secret" ] \
    && [ "$after_key_files" = "$rollback_key_files" ] && no_stage; then
    ok 'post-stage failures preserve the committed generation and key'
  else bad 'post-stage rollback after MCP failure'; fi
fi

rotation_generation=$(cat "$QC_HOME/profiles/beta/current")
mkdir -p "$HOME/.qbraid"
printf 'api-key = key-beta-rotated
' > "$HOME/.qbraid/qbraidrc"
if bash install.sh --profile beta --update-key > "$TMP/update-key.out" 2> "$TMP/update-key.err"; then
  bad 'update-key reused the stored key instead of requesting a replacement'
elif grep -q 'Set QBRAID_API_KEY' "$TMP/update-key.err"   && [ "$(cat "$QC_HOME/profiles/beta/current")" = "$rotation_generation" ]; then
  ok 'update-key ignores the expired stored key and preserves the committed generation'
else bad 'update-key replacement prompt or rollback'; fi
if QBRAID_API_KEY=key-beta-new bash install.sh --profile missing --update-key > /dev/null 2> "$TMP/update-missing.err"; then
  bad 'update-key created a missing profile'
elif grep -q 'is not installed' "$TMP/update-missing.err"; then ok 'update-key requires an existing profile'; else bad 'missing update profile diagnosis'; fi

printf 'alpha\n' > "$QC_HOME/active-profile"
chmod 600 "$HOME_ROOT/.claude/settings.json"
update_before_model=$(sed -n 's/^QBRAID_CODE_MODEL=//p' "$BETA_DIR/env")
update_before_label=$(cat "$BETA_DIR/label")
update_before_source=$(cat "$BETA_DIR/label-source")
update_proxy_bin=$(sed -n 's/^QBRAID_CODE_PROXY_BIN=//p' "$BETA_DIR/env" | head -1)
update_proxy_config="$BETA_DIR/proxy-config.yaml"
printf 'port: 8320\n' > "$update_proxy_config"
cc tests/fake-proxy.c -o "$TMP/unowned-update-proxy"
bash -c 'exec -a "$1" "$2" -config "$3"' _ "$update_proxy_bin" "$TMP/unowned-update-proxy" "$update_proxy_config" >/dev/null 2>&1 & unowned_update_pid=$!
printf '%s\n' "$unowned_update_pid" > "$BETA_DIR/proxy.pid"
before_unowned_generation=$(cat "$QC_HOME/profiles/beta/current")
if QBRAID_API_KEY=key-beta-new bash install.sh --profile beta --update-key > /dev/null 2> "$TMP/unowned-update.err"; then
  bad 'installer accepted an unowned stale proxy process'
elif kill -0 "$unowned_update_pid" 2>/dev/null && [ "$(cat "$QC_HOME/profiles/beta/current")" = "$before_unowned_generation" ]; then
  ok 'installer rejects a spoofed stale proxy process'
else bad 'installer killed or committed over an unowned stale proxy'; fi
kill "$unowned_update_pid" 2>/dev/null || true; wait "$unowned_update_pid" 2>/dev/null || true
rm -f "$BETA_DIR/proxy.pid"
cc tests/fake-proxy.c -o "$update_proxy_bin"
owned_update_pid=$(python3 - "$update_proxy_bin" "$update_proxy_config" <<'PY'
import subprocess, sys
process = subprocess.Popen([sys.argv[1], '-config', sys.argv[2]], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
print(process.pid)
PY
)
printf '%s\n' "$owned_update_pid" > "$BETA_DIR/proxy.pid"
if QBRAID_CODE_MODEL='' QBRAID_CODE_PROFILE_LABEL='' QBRAID_API_KEY=key-beta-new bash install.sh --profile beta --update-key > "$TMP/update-success.out" 2> "$TMP/update-success.err"; then
  BETA_DIR=$(profile_dir beta)
  if [ "$(sed -n 's/^QBRAID_CODE_MODEL=//p' "$BETA_DIR/env")" = "$update_before_model" ] \
    && [ "$(cat "$BETA_DIR/label")" = "$update_before_label" ] \
    && [ "$(cat "$BETA_DIR/label-source")" = "$update_before_source" ] \
    && [ "$(cat "$QC_HOME/active-profile")" = alpha ] \
    && [ "$(stat -c '%a' "$HOME_ROOT/.claude/settings.json" 2>/dev/null || stat -f '%Lp' "$HOME_ROOT/.claude/settings.json")" = 600 ] \
    && ! grep -q 'key-beta-new' "$TMP/update-success.out" "$TMP/update-success.err"; then
    ok 'update-key preserves model, label, active profile, and output secrecy'
  else bad 'update-key changed settings outside the key'; fi
else bad 'same-organization update-key failed'; fi
if ! kill -0 "$owned_update_pid" 2>/dev/null; then ok 'installer stops a verified owned stale proxy'; else bad 'installer left an owned stale proxy running'; kill "$owned_update_pid" 2>/dev/null || true; fi

missing_org=$(cat "$BETA_DIR/organization-id")
rm -f "$BETA_DIR/organization-id"
if QBRAID_API_KEY=key-beta-newer bash install.sh --profile beta --update-key > /dev/null 2> "$TMP/update-no-org.err"; then
  bad 'update-key accepted a profile without verified organization identity'
elif grep -q 'no verified organization ID' "$TMP/update-no-org.err"; then
  ok 'update-key fails closed without the previous organization identity'
else bad 'missing organization identity diagnosis'; fi
printf '%s\n' "$missing_org" > "$BETA_DIR/organization-id"


cat > "$FAKE_BIN/mv" <<'EOF'
#!/usr/bin/env bash
/bin/mv "$@" || exit
last=""; for arg in "$@"; do last="$arg"; done
case "$last" in */current) [ "${SIGNAL_CURRENT:-0}" -ne 1 ] || kill -TERM "$PPID" ;; esac
EOF
chmod +x "$FAKE_BIN/mv"
if SIGNAL_CURRENT=1 QBRAID_API_KEY=key-beta-signal bash install.sh --profile beta > "$TMP/signal.out" 2> "$TMP/signal.err"; then
  BETA_DIR=$(profile_dir beta)
  if [ -f "$BETA_DIR/env" ] && [ "$(profile_secret "$BETA_DIR")" = key-beta-signal ]; then
    ok 'signal at pointer publication cannot delete the committed generation'
  else bad 'signal left current pointing at a deleted generation'; fi
else bad 'signal at pointer publication aborted an atomic commit'; fi

mkdir -p "$QC_HOME/profiles/beta/session-users"
printf '' > "$QC_HOME/profiles/beta/session-users/$$"
if QBRAID_API_KEY=key-beta bash install.sh --profile beta > "$TMP/live.out" 2> "$TMP/live.err"; then
  bad 'installer updated a profile with a live session'
elif grep -q 'running session' "$TMP/live.err"; then ok 'live profile update fails closed'; else bad 'live update diagnosis'; fi
rm -f "$QC_HOME/profiles/beta/session-users/$$"
QBRAID_CODE_PROFILE_LABEL='' QBRAID_API_KEY=key-beta bash install.sh --profile verified > "$TMP/verified.out"
VERIFIED_DIR=$(profile_dir verified)
if [ "$(cat "$VERIFIED_DIR/label")" = 'Verified Lab' ] && [ "$(cat "$VERIFIED_DIR/label-source")" = verified ]; then ok 'authenticated organization names retain verified provenance'; else bad 'verified label provenance'; fi

# Custom install paths cannot gain ownership through aliases or nested links.
ALIASED_USER="$TMP/aliased-user"
ALIASED_TARGET="$TMP/aliased-target"
ALIASED_PARENT="$TMP/aliased-parent"
ALIASED_BIN="$TMP/aliased-bin"
mkdir -p "$ALIASED_USER/.claude" "$ALIASED_TARGET" "$ALIASED_BIN"
ln -s "$ALIASED_TARGET" "$ALIASED_PARENT"
if HOME="$ALIASED_USER" QBRAID_CODE_HOME="$ALIASED_PARENT/qbraid-code" QBRAID_CODE_BIN_DIR="$ALIASED_BIN" \
  PATH="$FAKE_BIN:/usr/bin:/bin" QBRAID_CODE_MODEL=claude-haiku-4-5 QBRAID_API_KEY=key-beta bash install.sh --profile alias >/dev/null 2>&1; then
  bad 'custom install accepted a symbolic-link path component'
elif [ ! -e "$ALIASED_TARGET/qbraid-code" ]; then ok 'custom install rejects symbolic-link path components before writing'; else bad 'custom alias target was mutated'; fi

NESTED_USER="$TMP/nested-user"
NESTED_ROOT=$(CDPATH='' cd "$TMP" && pwd -P)/nested-root
NESTED_BIN="$TMP/nested-bin"
NESTED_OUTSIDE="$TMP/nested-outside"
mkdir -p "$NESTED_USER/.claude" "$NESTED_ROOT" "$NESTED_BIN" "$NESTED_OUTSIDE"
printf 'qbraid-code\n' > "$NESTED_ROOT/.qbraid-code-install"
ln -s "$NESTED_OUTSIDE" "$NESTED_ROOT/profiles"
if HOME="$NESTED_USER" QBRAID_CODE_HOME="$NESTED_ROOT" QBRAID_CODE_BIN_DIR="$NESTED_BIN" \
  PATH="$FAKE_BIN:/usr/bin:/bin" QBRAID_CODE_MODEL=claude-haiku-4-5 QBRAID_API_KEY=key-beta bash install.sh --profile nested >/dev/null 2>&1; then
  bad 'installer traversed a nested managed symlink'
elif [ -z "$(ls -A "$NESTED_OUTSIDE")" ]; then ok 'installer rejects nested managed symlinks before writing'; else bad 'nested symlink target was mutated'; fi

# A sidecar-bound pre-marker custom install can migrate when every root entry is managed.
CUSTOM_MIGRATE_USER="$TMP/custom-migrate-user"
CUSTOM_MIGRATE_ROOT=$(CDPATH='' cd "$TMP" && pwd -P)/custom-migrate-root
CUSTOM_MIGRATE_BIN=$(CDPATH='' cd "$TMP" && pwd -P)/custom-migrate-bin
mkdir -p "$CUSTOM_MIGRATE_USER/.claude" "$CUSTOM_MIGRATE_ROOT" "$CUSTOM_MIGRATE_BIN"
printf 'QBRAID_CODE_BASE_URL=https://example.invalid\nQBRAID_CODE_TOKEN=legacy-token\n' > "$CUSTOM_MIGRATE_ROOT/env"
printf 'Legacy Label\n' > "$CUSTOM_MIGRATE_ROOT/label"
printf 'port: __PORT__\n' > "$CUSTOM_MIGRATE_ROOT/proxy-template.yaml"
printf 'stale\n' > "$CUSTOM_MIGRATE_ROOT/.qbraid-code-install.tmp.123"
printf '%s\n' "$CUSTOM_MIGRATE_ROOT" > "$CUSTOM_MIGRATE_BIN/qbraid-code.home"
if HOME="$CUSTOM_MIGRATE_USER" QBRAID_CODE_HOME="$CUSTOM_MIGRATE_ROOT" QBRAID_CODE_BIN_DIR="$CUSTOM_MIGRATE_BIN" \
  PATH="$FAKE_BIN:/usr/bin:/bin" QBRAID_CODE_MODEL=claude-haiku-4-5 QBRAID_API_KEY=key-beta \
  bash install.sh --profile beta > "$TMP/custom-migrate.out" 2> "$TMP/custom-migrate.err" \
  && [ "$(cat "$CUSTOM_MIGRATE_ROOT/.qbraid-code-install")" = qbraid-code ] \
  && [ -f "$CUSTOM_MIGRATE_ROOT/profiles/default/env" ] \
  && [ -f "$CUSTOM_MIGRATE_ROOT/profiles/default/proxy-template.yaml" ]; then
  ok 'pre-marker custom installs migrate through the managed-file allowlist'
else bad 'pre-marker custom install could not gain its ownership marker'; fi

# Failed companion downloads must never truncate a working launcher.
REMOTE_ROOT="$TMP/remote-install"
REMOTE_HOME="$TMP/remote-user"
REMOTE_QC="$REMOTE_HOME/.qbraid-code"
REMOTE_BIN="$REMOTE_HOME/bin"
REMOTE_FAKE="$TMP/remote-fake"
mkdir -p "$REMOTE_ROOT" "$REMOTE_QC" "$REMOTE_BIN" "$REMOTE_FAKE" "$REMOTE_HOME/.claude"
cp install.sh "$REMOTE_ROOT/install.sh"
printf 'working-launcher\n' > "$REMOTE_BIN/qbraid-code"
printf 'working-statusline\n' > "$REMOTE_QC/statusline.sh"
cp "$FAKE_BIN/claude" "$FAKE_BIN/cliproxyapi" "$FAKE_BIN/security" "$FAKE_BIN/secret-tool" "$REMOTE_FAKE/"
cat > "$REMOTE_FAKE/curl" <<'EOF'
#!/usr/bin/env bash
out=""; want_status=0; url=""; cfg=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;; -w) want_status=1; shift 2 ;; -m|-d|-H) shift 2 ;;
    --config) [ "$2" != - ] || cfg=$(cat); shift 2 ;; -*) shift ;; http*) url="$1"; shift ;; *) shift ;;
  esac
done
case "$url" in
  *qbraid.com/code/*|*raw.githubusercontent.com*) exit 22 ;;
  *billing/credits/balance*) body='{"data":{"organizationId":"org-beta","qbraidCredits":100}}'; code=200 ;;
  *organizations/current*) body='{"data":{"name":"Verified Lab"}}'; code=200 ;;
  *'/quota') body='{"plan":"pro"}'; code=200 ;;
  *'/ai/models') body='{"data":[{"id":"claude-haiku-4-5"}]}'; code=200 ;;
  *) body='{}'; code=200 ;;
esac
[ -z "$out" ] || printf '%s' "$body" > "$out"
[ "$want_status" -eq 0 ] || printf '%s' "$code"
EOF
chmod +x "$REMOTE_FAKE"/*
if HOME="$REMOTE_HOME" QBRAID_CODE_HOME="$REMOTE_QC" QBRAID_CODE_BIN_DIR="$REMOTE_BIN" \
  PATH="$REMOTE_FAKE:/usr/bin:/bin" QBRAID_CODE_MODEL=claude-haiku-4-5 QBRAID_API_KEY=key-beta \
  bash "$REMOTE_ROOT/install.sh" --profile beta > /dev/null 2> "$TMP/remote-fail.err"; then
  bad 'failed companion download was reported as success'
elif [ "$(cat "$REMOTE_BIN/qbraid-code")" = working-launcher ] \
  && [ "$(cat "$REMOTE_QC/statusline.sh")" = working-statusline ]; then
  ok 'failed companion downloads preserve working live files'
else bad 'failed companion download truncated a working file'; fi

if bash install.sh --profle beta > /dev/null 2> "$TMP/unknown.err"; then bad 'unknown installer option was ignored';
elif grep -q 'unknown option' "$TMP/unknown.err"; then ok 'unknown installer option is rejected'; else bad 'unknown option diagnosis'; fi

if bash install.sh --global > /dev/null 2> "$TMP/global.err"; then bad 'unsafe global mode was accepted';
elif grep -q 'removed.*exfiltrate' "$TMP/global.err"; then ok 'unsafe plain-Claude global mode is rejected'; else bad 'global removal diagnosis'; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
