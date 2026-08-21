#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# Extract the installer helpers without running the networked installer.
HELPERS=$(awk '
  /^valid_profile_slug\(\) \{/ { emit=1 }
  /^# ------------------------------------------------------------------ output/ { emit=0 }
  emit { print }
' install.sh)
[ -n "$HELPERS" ] || { echo '  FAIL installer profile helpers missing'; exit 1; }
eval "$HELPERS"
PRUNE_HELPER=$(awk '/^delete_retired_profile_secret\(\)/,/^# ------------------------------------------------------- 4\./ { if ($0 !~ /^# /) print }' install.sh)
eval "$PRUNE_HELPER"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
ROOT="$TMP/qc"
export OS=linux
mkdir -p "$ROOT/proxy-auth"
cc tests/fake-proxy.c -o "$ROOT/cliproxyapi"
printf 'QBRAID_CODE_BASE_URL=https://example.invalid\nQBRAID_CODE_PROXY_BIN=%s\nQBRAID_CODE_TOKEN=legacy-token\n' "$ROOT/cliproxyapi" > "$ROOT/env"
printf 'legacy-cache\n' > "$ROOT/credits.cache"
printf 'legacy-auth\n' > "$ROOT/proxy-auth/session"
printf 'api-key: legacy-token\n' > "$ROOT/proxy-config.yaml"

pass=0; fail=0
for slug in default a A0 'team.one' 'team_name' 'team-name' 12345678901234567890123456789012; do
  if valid_profile_slug "$slug"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "  FAIL valid slug rejected: $slug"; fi
done
for slug in '' '.bad' '-bad' '_bad' 'bad/name' 'bad name' 'bad@name' 'équipe' 123456789012345678901234567890123; do
  if valid_profile_slug "$slug"; then fail=$((fail + 1)); echo "  FAIL invalid slug accepted: $slug"; else pass=$((pass + 1)); fi
done
printf '  ok   profile slug validation cases\n'
unicode_label='A🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂'
if [ "$(LC_ALL=C sanitize_profile_label "$unicode_label" fallback)" = "$unicode_label" ]; then
  pass=$((pass + 1)); printf '  ok   C-locale label handling preserves UTF-8 boundaries\n'
else
  fail=$((fail + 1)); printf '  FAIL C-locale label handling split UTF-8\n'
fi

adopt_legacy_profile "$ROOT"
if ! grep -q 'legacy-token' "$ROOT/profiles/default/env" &&
   grep -q 'QBRAID_CODE_SECRET_BACKEND=file' "$ROOT/profiles/default/env" &&
   [ "$(cat "$ROOT/secrets/default")" = legacy-token ] &&
   [ "$(cat "$ROOT/profiles/default/credits.cache")" = legacy-cache ] &&
   grep -q 'legacy-token' "$ROOT/env" && grep -q 'QBRAID_CODE_BASE_URL' "$ROOT/env"; then
  pass=$((pass + 1)); printf '  ok   legacy migration stages without breaking the old launcher\n'
else
  fail=$((fail + 1)); printf '  FAIL legacy adoption contents\n'
fi
scrub_legacy_token "$ROOT"
if ! grep -q legacy-token "$ROOT/env" && grep -q QBRAID_CODE_BASE_URL "$ROOT/env" && [ ! -e "$ROOT/proxy-config.yaml" ]; then pass=$((pass + 1)); printf '  ok   committed migration scrubs legacy plaintext and proxy config\n'; else fail=$((fail + 1)); printf '  FAIL committed legacy scrub\n'; fi
printf 'api-key: live-legacy\n' > "$ROOT/proxy-config.yaml"
"$ROOT/cliproxyapi" -config "$ROOT/proxy-config.yaml" >/dev/null 2>&1 & legacy_proxy=$!
printf '%s\n' "$legacy_proxy" > "$ROOT/proxy.pid"
sleep 0.1; scrub_legacy_token "$ROOT"
if [ -f "$ROOT/proxy-config.yaml" ]; then pass=$((pass + 1)); printf '  ok   live legacy proxy retains its watched config\n'; else fail=$((fail + 1)); printf '  FAIL live legacy proxy config was removed\n'; fi
kill "$legacy_proxy" 2>/dev/null || true; wait "$legacy_proxy" 2>/dev/null || true
scrub_legacy_token "$ROOT"
if [ ! -e "$ROOT/proxy-config.yaml" ]; then pass=$((pass + 1)); printf '  ok   dead legacy proxy config is scavenged\n'; else fail=$((fail + 1)); printf '  FAIL dead legacy proxy config remains\n'; fi

printf 'profile-edit\n' > "$ROOT/profiles/default/env"
printf 'legacy-edit\n' > "$ROOT/env"
adopt_legacy_profile "$ROOT"
if [ "$(cat "$ROOT/profiles/default/env")" = profile-edit ]; then
  pass=$((pass + 1)); printf '  ok   migration rerun does not overwrite profile state\n'
else
  fail=$((fail + 1)); printf '  FAIL migration rerun overwrote profile state\n'
fi

PARTIAL="$TMP/partial"
mkdir -p "$PARTIAL/profiles/default"
printf 'QBRAID_CODE_TOKEN=legacy-A\n' > "$PARTIAL/env"
printf 'legacy-A-config\n' > "$PARTIAL/proxy-config.yaml"
printf 'new-B\n' > "$PARTIAL/profiles/default/env"
adopt_legacy_profile "$PARTIAL"
if [ "$(cat "$PARTIAL/profiles/default/env")" = new-B ] && [ ! -e "$PARTIAL/profiles/default/proxy-config.yaml" ]; then
  pass=$((pass + 1)); printf '  ok   partial destination never mixes legacy generations\n'
else
  fail=$((fail + 1)); printf '  FAIL partial destination mixed legacy state\n'
fi
SS_ROOT="$TMP/secret-service"
SS_BIN="$TMP/ss-bin"
mkdir -p "$SS_ROOT" "$SS_BIN"
printf 'QBRAID_CODE_TOKEN=vault-token\n' > "$SS_ROOT/env"
cat > "$SS_BIN/secret-tool" <<'EOF'
#!/usr/bin/env bash
case "$1" in store) cat > "$SECRET_TOOL_CAPTURE" ;; lookup) cat "$SECRET_TOOL_CAPTURE" ;; clear) rm -f "$SECRET_TOOL_CAPTURE" ;; esac
EOF
chmod +x "$SS_BIN/secret-tool"
SECRET_TOOL_CAPTURE="$TMP/secret-service.value" PATH="$SS_BIN:$PATH" adopt_legacy_profile "$SS_ROOT"
scrub_legacy_token "$SS_ROOT"
if grep -q 'SECRET_BACKEND=secret-service' "$SS_ROOT/profiles/default/env" && [ "$(cat "$TMP/secret-service.value")" = vault-token ] && [ ! -e "$SS_ROOT/secrets/default" ] && ! grep -q vault-token "$SS_ROOT/env"; then
  pass=$((pass + 1)); printf '  ok   Linux Secret Service is preferred and legacy plaintext is scrubbed\n'
else fail=$((fail + 1)); printf '  FAIL Linux Secret Service migration\n'; fi
mkdir -p "$SS_ROOT/profiles/default/generations/current-gen"
SECRET_TOOL_CAPTURE="$TMP/secret-service.value" PATH="$SS_BIN:$PATH" PROFILE_ROOT="$SS_ROOT/profiles/default" PROFILE=default HOME_DIR="$SS_ROOT" prune_profile_generations current-gen
if [ ! -f "$SS_ROOT/profiles/default/env" ] && [ ! -f "$TMP/secret-service.value" ]; then
  pass=$((pass + 1)); printf '  ok   first generation retires migrated flat-profile secrets\n'
else fail=$((fail + 1)); printf '  FAIL migrated flat-profile secret cleanup\n'; fi

mode=$(stat -c '%a' "$ROOT/profiles/default" 2>/dev/null || stat -f '%Lp' "$ROOT/profiles/default" 2>/dev/null)
if [ "$mode" = 700 ]; then pass=$((pass + 1)); printf '  ok   migrated profile is private\n'; else fail=$((fail + 1)); echo "  FAIL migrated mode=$mode"; fi

# Configured ports are unique and existing profiles retain their allocation.
mkdir -p "$ROOT/profiles/alpha" "$ROOT/profiles/beta"
printf 'QBRAID_CODE_PROXY_PORT=8320\n' > "$ROOT/profiles/default/env"
printf 'QBRAID_CODE_PROXY_PORT=8321\n' > "$ROOT/profiles/alpha/env"
port=$(allocate_proxy_port "$ROOT" beta '')
if [ "$port" = 8322 ]; then pass=$((pass + 1)); printf '  ok   next free profile port allocated\n'; else fail=$((fail + 1)); echo "  FAIL port=$port want=8322"; fi
port=$(allocate_proxy_port "$ROOT" alpha 8321)
if [ "$port" = 8321 ]; then pass=$((pass + 1)); printf '  ok   existing profile port retained\n'; else fail=$((fail + 1)); echo "  FAIL retained port=$port want=8321"; fi

# Catalog stays exact TSV, overlays discovered context, and keeps fallbacks.
BODY='{"data":[{"id":"gpt-5.4-mini","_qbraid":{"maxTokens":444444}},{"id":"future-model","_qbraid":{"maxTokens":333333}},{"id":"no-context","_qbraid":{}}]}'
write_models_tsv "$ROOT/models.tsv" "$BODY"
if awk -F '\t' 'NF != 2 || $1 == "" || $2 !~ /^[0-9]+$/ { exit 1 }' "$ROOT/models.tsv" &&
   grep -q "^gpt-5.4-mini$(printf '\t')444444$" "$ROOT/models.tsv" &&
   grep -q "^future-model$(printf '\t')333333$" "$ROOT/models.tsv" &&
   grep -q "^claude-haiku-4-5$(printf '\t')200000$" "$ROOT/models.tsv"; then
  pass=$((pass + 1)); printf '  ok   models.tsv exact format, discovery overlay, fallbacks\n'
else
  fail=$((fail + 1)); printf '  FAIL models.tsv contents\n'; cat "$ROOT/models.tsv"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
