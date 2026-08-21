#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0

ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

# Help must not need an installation or touch helpers that could access a
# credential store or network.
HELP_HOME="$TMP/help-home"
HELP_BIN="$TMP/help-bin"
mkdir -p "$HELP_BIN"
for tool in curl security secret-tool claude; do
  cat > "$HELP_BIN/$tool" <<EOF
#!/usr/bin/env bash
printf '%s\\n' "$tool" >> '$TMP/help-accessed'
exit 97
EOF
  chmod +x "$HELP_BIN/$tool"
done
help_output=$(HOME="$HELP_HOME" QBRAID_CODE_HOME="$HELP_HOME/missing" PATH="$HELP_BIN:/usr/bin:/bin" bash qbraid-code --help 2>&1)
help_rc=$?
if [ "$help_rc" -eq 0 ] && [ ! -e "$HELP_HOME/missing" ] && [ ! -e "$TMP/help-accessed" ]; then
  ok 'help is available before installation without machine access'
else
  bad 'help is available before installation without machine access'
fi
for command in --profiles --use-profile --allow-profile-resume --update-key --doctor --stop --uninstall 'claude --help'; do
  if contains "$help_output" "$command"; then ok "help lists $command"; else bad "help lists $command"; fi
done

# update-key must select the profile without reading its expired secret. The
# downloaded installer owns validation, organization binding, and atomic commit.
UPDATE_HOME="$TMP/update-home"
UPDATE_QC="$UPDATE_HOME/.qbraid-code"
UPDATE_BIN="$TMP/update-bin"
mkdir -p "$UPDATE_QC/profiles/research/generations/g1" "$UPDATE_BIN"
printf 'g1\n' > "$UPDATE_QC/profiles/research/current"
printf 'research\n' > "$UPDATE_QC/active-profile"
cat > "$UPDATE_QC/profiles/research/generations/g1/env" <<'EOF'
QBRAID_CODE_SECRET_BACKEND=unavailable-old-store
QBRAID_CODE_SECRET_REF=expired
EOF
cat > "$UPDATE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$UPDATE_CURL_ARGS"
cat <<'INSTALLER'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$UPDATE_INSTALL_ARGS"
INSTALLER
EOF
chmod +x "$UPDATE_BIN/curl"
update_output=$(HOME="$UPDATE_HOME" QBRAID_CODE_HOME="$UPDATE_QC" \
  UPDATE_CURL_ARGS="$TMP/update-curl-args" UPDATE_INSTALL_ARGS="$TMP/update-install-args" \
  PATH="$UPDATE_BIN:/usr/bin:/bin" bash qbraid-code --update-key 2>&1)
update_rc=$?
if [ "$update_rc" -eq 0 ] \
  && grep -qx -- '--profile' "$TMP/update-install-args" \
  && grep -qx 'research' "$TMP/update-install-args" \
  && grep -qx -- '--update-key' "$TMP/update-install-args" \
  && grep -qx 'https://qbraid.com/code.sh' "$TMP/update-curl-args" \
  && contains "$update_output" 'same qBraid organization'; then
  ok 'update-key uses the active profile and official installer'
else
  bad 'update-key uses the active profile and official installer'
fi
rm -f "$TMP/update-install-args" "$TMP/update-curl-args"
HOME="$UPDATE_HOME" QBRAID_CODE_HOME="$UPDATE_QC" UPDATE_CURL_ARGS="$TMP/update-curl-args" \
  UPDATE_INSTALL_ARGS="$TMP/update-install-args" PATH="$UPDATE_BIN:/usr/bin:/bin" \
  bash qbraid-code --profile research --update-key >/dev/null 2>&1
if grep -qx 'research' "$TMP/update-install-args"; then ok 'update-key accepts an explicit profile'; else bad 'update-key accepts an explicit profile'; fi

CUSTOM_UPDATE_HOME="$TMP/custom-update-home"
CUSTOM_UPDATE_QC="$TMP/custom-qbraid-root"
CUSTOM_UPDATE_BIN="$TMP/custom-update-bin"
mkdir -p "$CUSTOM_UPDATE_HOME" "$CUSTOM_UPDATE_QC/profiles/research/generations/g1" "$CUSTOM_UPDATE_BIN"
printf 'g1\n' > "$CUSTOM_UPDATE_QC/profiles/research/current"
printf 'QBRAID_CODE_SECRET_BACKEND=file\nQBRAID_CODE_SECRET_REF=unused\n' > "$CUSTOM_UPDATE_QC/profiles/research/generations/g1/env"
cp qbraid-code "$CUSTOM_UPDATE_BIN/qbraid-code"; chmod +x "$CUSTOM_UPDATE_BIN/qbraid-code"
printf '%s\n' "$CUSTOM_UPDATE_QC" > "$CUSTOM_UPDATE_BIN/qbraid-code.home"
cat > "$CUSTOM_UPDATE_BIN/curl" <<'EOF'
#!/usr/bin/env bash
cat <<'INSTALLER'
#!/usr/bin/env bash
printf '%s|%s\n' "$QBRAID_CODE_HOME" "$QBRAID_CODE_BIN_DIR" > "$CUSTOM_UPDATE_CAPTURE"
INSTALLER
EOF
chmod +x "$CUSTOM_UPDATE_BIN/curl"
HOME="$CUSTOM_UPDATE_HOME" QBRAID_CODE_HOME='' CUSTOM_UPDATE_CAPTURE="$TMP/custom-update-capture" \
  PATH="$CUSTOM_UPDATE_BIN:/usr/bin:/bin" "$CUSTOM_UPDATE_BIN/qbraid-code" --profile research --update-key >/dev/null 2>&1
CUSTOM_UPDATE_BIN_PHYSICAL=$(CDPATH='' cd "$CUSTOM_UPDATE_BIN" && pwd -P)
if [ "$(cat "$TMP/custom-update-capture")" = "$CUSTOM_UPDATE_QC|$CUSTOM_UPDATE_BIN_PHYSICAL" ]; then
  ok 'custom launcher passes its bound home and bin directory to key rotation'
else bad 'custom launcher rotation targeted the default installation'; fi

if HOME="$UPDATE_HOME" QBRAID_CODE_HOME="$UPDATE_QC" PATH="$UPDATE_BIN:/usr/bin:/bin" \
  bash qbraid-code --profile missing --update-key >/dev/null 2>&1; then
  bad 'update-key rejects an uninstalled profile'
else
  ok 'update-key rejects an uninstalled profile'
fi

make_file_install() {
  local root="$1" home qc generation
  home="$root/home"
  qc="$home/.qbraid-code"
  generation="$qc/profiles/alpha/generations/g1"
  mkdir -p "$generation" "$qc/secrets" "$home/.claude" "$root/bin"
  printf 'local-secret\n' > "$qc/secrets/alpha.g1"
  chmod 600 "$qc/secrets/alpha.g1"
  cat > "$generation/env" <<EOF
QBRAID_CODE_SECRET_BACKEND=file
QBRAID_CODE_SECRET_REF=$qc/secrets/alpha.g1
EOF
  printf 'g1\n' > "$qc/profiles/alpha/current"
  printf '#!/usr/bin/env bash\n' > "$qc/statusline.sh"
  python3 - "$home/.claude/settings.json" "$home/.claude.json" "$qc/statusline.sh" <<'PY'
import json, shlex, sys
settings, claude, statusline = sys.argv[1:]
with open(settings, "w") as stream:
    json.dump({"statusLine": {"type": "command", "command": shlex.quote(statusline)}, "theme": "dark"}, stream)
with open(claude, "w") as stream:
    json.dump({"mcpServers": {"qbraid": {"type": "http"}, "keep": {"type": "stdio"}}, "other": 1}, stream)
PY
  cp qbraid-code "$root/bin/qbraid-code"
  chmod +x "$root/bin/qbraid-code"
  printf '%s\n' "$qc" > "$root/bin/qbraid-code.home"
}

STOP_ROOT="$TMP/stop-owned"
make_file_install "$STOP_ROOT"
cc tests/fake-proxy.c -o "$STOP_ROOT/home/.qbraid-code/cliproxyapi"
STOP_RUNTIME="$STOP_ROOT/home/.qbraid-code/runtime.alpha.test"
mkdir -p "$STOP_RUNTIME"
printf 'port: 8320\n' > "$STOP_RUNTIME/proxy-config.yaml"
stop_pid=$(python3 - "$STOP_ROOT/home/.qbraid-code/cliproxyapi" "$STOP_RUNTIME/proxy-config.yaml" <<'PY'
import subprocess, sys
process = subprocess.Popen([sys.argv[1], '-config', sys.argv[2]], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
print(process.pid)
PY
)
printf '%s\n' "$stop_pid" > "$STOP_RUNTIME/proxy.pid"
printf '%s\n' "$$" > "$STOP_RUNTIME/owner.pid"
HOME="$STOP_ROOT/home" QBRAID_CODE_HOME="$STOP_ROOT/home/.qbraid-code" "$STOP_ROOT/bin/qbraid-code" --profile alpha --stop >/dev/null
if kill -0 "$stop_pid" 2>/dev/null; then ok '--stop preserves proxies owned by live sessions'; else bad '--stop killed a live session proxy'; fi
printf '99999996\n' > "$STOP_RUNTIME/owner.pid"
HOME="$STOP_ROOT/home" QBRAID_CODE_HOME="$STOP_ROOT/home/.qbraid-code" "$STOP_ROOT/bin/qbraid-code" --profile alpha --stop >/dev/null
if ! kill -0 "$stop_pid" 2>/dev/null && [ ! -d "$STOP_RUNTIME" ]; then ok '--stop removes verified orphaned proxies'; else bad '--stop left an orphaned owned proxy'; kill "$stop_pid" 2>/dev/null || true; fi

SYMLINK_STOP="$TMP/symlink-stop"
make_file_install "$SYMLINK_STOP"
cc tests/fake-proxy.c -o "$SYMLINK_STOP/proxy-target"
ln -s "$SYMLINK_STOP/proxy-target" "$SYMLINK_STOP/home/.qbraid-code/cliproxyapi"
SYMLINK_RUNTIME="$SYMLINK_STOP/home/.qbraid-code/runtime.alpha.test"
mkdir -p "$SYMLINK_RUNTIME"
printf 'port: 8320\n' > "$SYMLINK_RUNTIME/proxy-config.yaml"
symlink_pid=$(python3 - "$SYMLINK_STOP/home/.qbraid-code/cliproxyapi" "$SYMLINK_RUNTIME/proxy-config.yaml" <<'PY'
import subprocess, sys
process = subprocess.Popen([sys.argv[1], '-config', sys.argv[2]], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
print(process.pid)
PY
)
printf '%s\n' "$symlink_pid" > "$SYMLINK_RUNTIME/proxy.pid"; printf '99999995\n' > "$SYMLINK_RUNTIME/owner.pid"
HOME="$SYMLINK_STOP/home" QBRAID_CODE_HOME="$SYMLINK_STOP/home/.qbraid-code" "$SYMLINK_STOP/bin/qbraid-code" --profile alpha --stop >/dev/null
if ! kill -0 "$symlink_pid" 2>/dev/null && [ ! -d "$SYMLINK_RUNTIME" ]; then ok '--stop resolves an owned proxy executable symlink'; else bad '--stop rejected a legitimate proxy symlink'; kill "$symlink_pid" 2>/dev/null || true; fi

SPOOF_STOP="$TMP/spoof-stop"
make_file_install "$SPOOF_STOP"
cc tests/fake-proxy.c -o "$SPOOF_STOP/unrelated-proxy"
cp "$SPOOF_STOP/unrelated-proxy" "$SPOOF_STOP/home/.qbraid-code/cliproxyapi"
SPOOF_RUNTIME="$SPOOF_STOP/home/.qbraid-code/runtime.alpha.test"
mkdir -p "$SPOOF_RUNTIME"
printf 'port: 8320\n' > "$SPOOF_RUNTIME/proxy-config.yaml"
bash -c 'exec -a "$1" "$2" -config "$3"' _ "$SPOOF_STOP/home/.qbraid-code/cliproxyapi" "$SPOOF_STOP/unrelated-proxy" "$SPOOF_RUNTIME/proxy-config.yaml" >/dev/null 2>&1 & spoof_pid=$!
printf '%s\n' "$spoof_pid" > "$SPOOF_RUNTIME/proxy.pid"; printf '99999994\n' > "$SPOOF_RUNTIME/owner.pid"
if HOME="$SPOOF_STOP/home" QBRAID_CODE_HOME="$SPOOF_STOP/home/.qbraid-code" "$SPOOF_STOP/bin/qbraid-code" --profile alpha --stop >/dev/null 2>&1; then
  bad '--stop reported success for a spoofed proxy argv zero'
elif kill -0 "$spoof_pid" 2>/dev/null && [ -d "$SPOOF_RUNTIME" ]; then ok '--stop rejects a spoofed proxy argv zero'; else bad '--stop killed an executable with a spoofed proxy argv zero'; fi
kill "$spoof_pid" 2>/dev/null || true; wait "$spoof_pid" 2>/dev/null || true

INSTALL="$TMP/install with space"
make_file_install "$INSTALL"
for helper in curl claude python3; do
  cat > "$INSTALL/bin/$helper" <<EOF
#!/usr/bin/env bash
printf '%s\n' "$helper" >> '$TMP/uninstall-helper-accessed'
exit 97
EOF
  chmod +x "$INSTALL/bin/$helper"
done
UNINSTALL_HOME="$INSTALL/home"
UNINSTALL_QC="$UNINSTALL_HOME/.qbraid-code"
uninstall_output=$(HOME="$UNINSTALL_HOME" QBRAID_CODE_HOME="$UNINSTALL_QC" PATH="$INSTALL/bin:/usr/bin:/bin" \
  "$INSTALL/bin/qbraid-code" --uninstall --yes 2>&1)
uninstall_rc=$?
if [ "$uninstall_rc" -eq 0 ] && [ ! -e "$UNINSTALL_QC" ] \
  && [ ! -e "$INSTALL/bin/qbraid-code" ] && [ ! -e "$INSTALL/bin/qbraid-code.home" ]; then
  ok 'uninstall removes the bound installation and launcher'
else
  bad 'uninstall removes the bound installation and launcher'
fi
if python3 - "$UNINSTALL_HOME/.claude/settings.json" "$UNINSTALL_HOME/.claude.json" <<'PY'
import json, sys
settings, claude = (json.load(open(path)) for path in sys.argv[1:])
assert settings == {"theme": "dark"}
assert claude["mcpServers"] == {"keep": {"type": "stdio"}}
assert claude["other"] == 1
PY
then
  ok 'uninstall preserves unrelated Claude settings and MCP servers'
else
  bad 'uninstall preserves unrelated Claude settings and MCP servers'
fi
if contains "$uninstall_output" 'were not revoked'; then ok 'uninstall states the upstream-key boundary'; else bad 'uninstall states the upstream-key boundary'; fi
if [ ! -e "$TMP/uninstall-helper-accessed" ]; then ok 'uninstall is local and needs no Python or Claude command'; else bad 'uninstall is local and needs no Python or Claude command'; fi

# A tampered profile must never turn its secret reference into arbitrary file deletion.
UNSAFE="$TMP/unsafe"
make_file_install "$UNSAFE"
printf 'keep\n' > "$UNSAFE/outside-key"
cat > "$UNSAFE/home/.qbraid-code/profiles/alpha/generations/g1/env" <<EOF
QBRAID_CODE_SECRET_BACKEND=file
QBRAID_CODE_SECRET_REF=$UNSAFE/home/.qbraid-code/secrets/../../../../outside-key
EOF
if HOME="$UNSAFE/home" QBRAID_CODE_HOME="$UNSAFE/home/.qbraid-code" \
  "$UNSAFE/bin/qbraid-code" --uninstall --yes >/dev/null 2>&1; then
  bad 'uninstall rejects traversing secret references'
elif [ -e "$UNSAFE/outside-key" ] && [ -e "$UNSAFE/home/.qbraid-code" ] && [ -e "$UNSAFE/bin/qbraid-code" ]; then
  ok 'uninstall rejects traversing secret references'
else
  bad 'uninstall leaves state intact after an unsafe reference'
fi

# Managed-directory symlinks cannot redirect recursive deletion outside the install.
LINKED="$TMP/linked"
make_file_install "$LINKED"
mkdir -p "$LINKED/outside-directory"
printf 'keep\n' > "$LINKED/outside-directory/keep"
ln -s "$LINKED/outside-directory" "$LINKED/home/.qbraid-code/linked-outside"
if HOME="$LINKED/home" QBRAID_CODE_HOME="$LINKED/home/.qbraid-code" \
  "$LINKED/bin/qbraid-code" --uninstall --yes >/dev/null 2>&1; then
  bad 'uninstall rejects managed-directory symlinks'
elif [ -e "$LINKED/outside-directory/keep" ] && [ -e "$LINKED/home/.qbraid-code" ]; then
  ok 'uninstall rejects managed-directory symlinks without touching targets'
else
  bad 'uninstall traversed a managed-directory symlink'
fi

# Live sessions prevent cleanup. Uninstall does not kill a Claude process.
LIVE="$TMP/live"
make_file_install "$LIVE"
mkdir -p "$LIVE/home/.qbraid-code/profiles/alpha/session-users"
: > "$LIVE/home/.qbraid-code/profiles/alpha/session-users/$$"
if HOME="$LIVE/home" QBRAID_CODE_HOME="$LIVE/home/.qbraid-code" \
  "$LIVE/bin/qbraid-code" --uninstall --yes >/dev/null 2>&1; then
  bad 'uninstall refuses a live session'
elif [ -e "$LIVE/home/.qbraid-code" ] && [ -e "$LIVE/bin/qbraid-code" ]; then
  ok 'uninstall refuses a live session'
else
  bad 'uninstall damaged a live installation'
fi

# An installer lock belongs to its live process and cannot be stolen by uninstall.
BUSY="$TMP/busy-installer"
make_file_install "$BUSY"
mkdir -p "$BUSY/home/.qbraid-code/.install-lock"
printf '%s\n' "$$" > "$BUSY/home/.qbraid-code/.install-lock/pid"
if HOME="$BUSY/home" QBRAID_CODE_HOME="$BUSY/home/.qbraid-code" \
  "$BUSY/bin/qbraid-code" --uninstall --yes >/dev/null 2>&1; then
  bad 'uninstall refuses a concurrent installer'
elif [ -e "$BUSY/home/.qbraid-code/.install-lock/pid" ] && [ -e "$BUSY/bin/qbraid-code" ]; then
  ok 'uninstall refuses a concurrent installer without stealing its lock'
else
  bad 'uninstall damaged a concurrent installer lock'
fi

# Keychain deletion is exact and occurs before metadata disappears.
KEYCHAIN="$TMP/keychain"
KEYCHAIN_HOME="$KEYCHAIN/home"
KEYCHAIN_QC="$KEYCHAIN_HOME/.qbraid-code"
mkdir -p "$KEYCHAIN_QC/profiles/alpha/generations/g1" "$KEYCHAIN/bin"
cat > "$KEYCHAIN_QC/profiles/alpha/generations/g1/env" <<'EOF'
QBRAID_CODE_SECRET_BACKEND=keychain
QBRAID_CODE_SECRET_REF=qbraid-code:alpha:g1
EOF
printf 'g1\n' > "$KEYCHAIN_QC/profiles/alpha/current"
cat > "$KEYCHAIN/bin/security" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  find-generic-password) exit 0 ;;
  delete-generic-password) printf '%s\n' "$@" >> "$KEYCHAIN_LOG" ;;
  dump-keychain) printf '    "svce"<blob>="qbraid-code:orphan:g9"\n' ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$KEYCHAIN/bin/security"
cp qbraid-code "$KEYCHAIN/bin/qbraid-code"
printf '%s\n' "$KEYCHAIN_QC" > "$KEYCHAIN/bin/qbraid-code.home"
chmod +x "$KEYCHAIN/bin/qbraid-code"
HOME="$KEYCHAIN_HOME" QBRAID_CODE_HOME="$KEYCHAIN_QC" KEYCHAIN_LOG="$TMP/keychain-log" \
  PATH="$KEYCHAIN/bin:/usr/bin:/bin" "$KEYCHAIN/bin/qbraid-code" --uninstall --yes >/dev/null 2>&1
if grep -qx 'qbraid-code:alpha:g1' "$TMP/keychain-log" \
  && grep -qx 'qbraid-code:orphan:g9' "$TMP/keychain-log" && [ ! -e "$KEYCHAIN_QC" ]; then
  ok 'uninstall deletes referenced and orphaned Keychain secrets'
else
  bad 'uninstall deletes referenced and orphaned Keychain secrets'
fi

# Invalid Claude JSON must stop cleanup before a local secret disappears.
INVALID="$TMP/invalid-json"
make_file_install "$INVALID"
printf '{"statusLine":' > "$INVALID/home/.claude/settings.json"
if HOME="$INVALID/home" QBRAID_CODE_HOME="$INVALID/home/.qbraid-code" \
  "$INVALID/bin/qbraid-code" --uninstall --yes >/dev/null 2>&1; then
  bad 'uninstall rejects invalid Claude JSON before deleting secrets'
elif [ -e "$INVALID/home/.qbraid-code/secrets/alpha.g1" ] && [ -e "$INVALID/bin/qbraid-code" ]; then
  ok 'uninstall rejects invalid Claude JSON before deleting secrets'
else
  bad 'uninstall changed state before rejecting invalid Claude JSON'
fi

# Secret Service entries use the exact profile reference and no secret value is logged.
SERVICE="$TMP/secret-service"
SERVICE_HOME="$SERVICE/home"
SERVICE_QC="$SERVICE_HOME/.qbraid-code"
mkdir -p "$SERVICE_QC/profiles/alpha/generations/g1" "$SERVICE/bin"
cat > "$SERVICE_QC/profiles/alpha/generations/g1/env" <<'EOF'
QBRAID_CODE_SECRET_BACKEND=secret-service
QBRAID_CODE_SECRET_REF=qbraid-code:alpha:g1
EOF
printf 'g1\n' > "$SERVICE_QC/profiles/alpha/current"
cat > "$SERVICE/bin/secret-tool" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  lookup) printf 'local-test-secret\n' ;;
  clear)
    if [ "$#" -gt 3 ]; then printf '%s\n' "$@" >> "$SECRET_SERVICE_LOG"
    elif [ ! -e "$SECRET_SERVICE_STATE" ]; then touch "$SECRET_SERVICE_STATE"; printf '%s\n' "$@" >> "$SECRET_SERVICE_LOG"
    else exit 1
    fi ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$SERVICE/bin/secret-tool"
cp qbraid-code "$SERVICE/bin/qbraid-code"
printf '%s\n' "$SERVICE_QC" > "$SERVICE/bin/qbraid-code.home"
chmod +x "$SERVICE/bin/qbraid-code"
HOME="$SERVICE_HOME" QBRAID_CODE_HOME="$SERVICE_QC" SECRET_SERVICE_LOG="$TMP/secret-service-log" SECRET_SERVICE_STATE="$TMP/secret-service-state" \
  PATH="$SERVICE/bin:/usr/bin:/bin" "$SERVICE/bin/qbraid-code" --uninstall --yes >/dev/null 2>&1
if grep -qx 'qbraid-code:alpha:g1' "$TMP/secret-service-log" \
  && grep -qx 'qbraid-code' "$TMP/secret-service-log" \
  && ! grep -q 'local-test-secret' "$TMP/secret-service-log" && [ ! -e "$SERVICE_QC" ]; then
  ok 'uninstall deletes referenced and orphaned Secret Service entries without logging values'
else
  bad 'uninstall deletes referenced and orphaned Secret Service entries without logging values'
fi

# The command remains idempotent if only the standard home is already absent.
IDEMPOTENT_HOME="$TMP/idempotent/home"
mkdir -p "$IDEMPOTENT_HOME"
if HOME="$IDEMPOTENT_HOME" QBRAID_CODE_HOME="$IDEMPOTENT_HOME/.qbraid-code" \
  bash qbraid-code --uninstall --yes >/dev/null 2>&1; then
  ok 'uninstall tolerates an already absent standard installation'
else
  bad 'uninstall tolerates an already absent standard installation'
fi


# Lexical aliases must not turn the installation path into the user home.
ALIAS_HOME="$TMP/alias-home"
mkdir -p "$ALIAS_HOME"; printf 'keep\n' > "$ALIAS_HOME/sentinel"
if HOME="$ALIAS_HOME" QBRAID_CODE_HOME="$ALIAS_HOME/" bash qbraid-code --uninstall --yes >/dev/null 2>&1; then
  bad 'uninstall accepted the user home through a trailing-slash alias'
elif [ -e "$ALIAS_HOME/sentinel" ]; then ok 'uninstall rejects a trailing-slash alias of the user home'; else bad 'uninstall deleted the user home alias'; fi

LINK_HOME="$TMP/link-home"
LINK_TARGET="$TMP/link-target"
mkdir -p "$LINK_HOME" "$LINK_TARGET"; printf 'keep\n' > "$LINK_TARGET/sentinel"
ln -s "$LINK_TARGET" "$LINK_HOME/qbraid-link"
if HOME="$LINK_HOME" QBRAID_CODE_HOME="$LINK_HOME/qbraid-link/" bash qbraid-code --uninstall --yes >/dev/null 2>&1; then
  bad 'uninstall accepted a trailing-slash installation symlink'
elif [ -e "$LINK_TARGET/sentinel" ]; then ok 'uninstall rejects trailing-slash installation symlinks'; else bad 'uninstall traversed a trailing-slash symlink'; fi

CUSTOM_ABSENT_HOME="$TMP/custom-absent-user"
CUSTOM_ABSENT_ROOT=$(CDPATH='' cd "$TMP" && pwd -P)/custom-absent-root
CUSTOM_ABSENT_BIN="$TMP/custom-absent-bin"
mkdir -p "$CUSTOM_ABSENT_HOME" "$CUSTOM_ABSENT_BIN"
cp qbraid-code "$CUSTOM_ABSENT_BIN/qbraid-code"; chmod +x "$CUSTOM_ABSENT_BIN/qbraid-code"
printf '%s\n' "$CUSTOM_ABSENT_ROOT" > "$CUSTOM_ABSENT_BIN/qbraid-code.home"
if HOME="$CUSTOM_ABSENT_HOME" QBRAID_CODE_HOME="$CUSTOM_ABSENT_ROOT" "$CUSTOM_ABSENT_BIN/qbraid-code" --uninstall --yes >/dev/null 2>&1 \
  && [ ! -e "$CUSTOM_ABSENT_BIN/qbraid-code" ] && [ ! -e "$CUSTOM_ABSENT_BIN/qbraid-code.home" ]; then
  ok 'absent custom root still permits bound launcher cleanup'
else bad 'absent custom root stranded its bound launcher'; fi

PHYSICAL_TMP=$(CDPATH='' cd "$TMP" && pwd -P)
SHARED_HOME="$PHYSICAL_TMP/shared-user"
SHARED_ROOT="$PHYSICAL_TMP/shared-config"
SHARED_BIN="$PHYSICAL_TMP/shared-bin"
mkdir -p "$SHARED_HOME" "$SHARED_ROOT" "$SHARED_BIN"
printf 'unrelated\n' > "$SHARED_ROOT/sentinel"
cp qbraid-code "$SHARED_BIN/qbraid-code"; chmod +x "$SHARED_BIN/qbraid-code"
printf '%s\n' "$SHARED_ROOT" > "$SHARED_BIN/qbraid-code.home"
if HOME="$SHARED_HOME" QBRAID_CODE_HOME="$SHARED_ROOT" "$SHARED_BIN/qbraid-code" --uninstall --yes >/dev/null 2>&1; then
  bad 'uninstall deleted an unmarked shared custom root'
elif [ -e "$SHARED_ROOT/sentinel" ]; then ok 'uninstall requires exclusive ownership for a custom root'; else bad 'uninstall deleted unrelated custom-root data'; fi

EMPTY_JSON="$TMP/empty-json"
make_file_install "$EMPTY_JSON"
printf '{}\n' > "$EMPTY_JSON/home/.claude/settings.json"
printf '{"mcpServers":{"keep":{"type":"stdio"}}}\n' > "$EMPTY_JSON/home/.claude.json"
if HOME="$EMPTY_JSON/home" QBRAID_CODE_HOME="$EMPTY_JSON/home/.qbraid-code" "$EMPTY_JSON/bin/qbraid-code" --uninstall --yes >/dev/null 2>&1 \
  && [ ! -e "$EMPTY_JSON/home/.qbraid-code" ]; then
  ok 'uninstall preserves valid JSON without owned integrations'
else bad 'uninstall misclassified unchanged valid JSON'; fi

ESCAPED_JSON="$TMP/escaped json"
make_file_install "$ESCAPED_JSON"
printf '{"status\\u004cine":{"type":"command","command":"owned"}}\n' > "$ESCAPED_JSON/home/.claude/settings.json"
if HOME="$ESCAPED_JSON/home" QBRAID_CODE_HOME="$ESCAPED_JSON/home/.qbraid-code" "$ESCAPED_JSON/bin/qbraid-code" --uninstall --yes >/dev/null 2>&1; then
  bad 'uninstall ignored an escaped owned JSON member name'
elif [ -e "$ESCAPED_JSON/home/.qbraid-code/secrets/alpha.g1" ]; then
  ok 'escaped target-level JSON member names fail closed'
else bad 'escaped JSON member removed credential metadata'; fi

INTERRUPTED_JSON="$TMP/interrupted json"
make_file_install "$INTERRUPTED_JSON"
mv "$INTERRUPTED_JSON/home/.claude/settings.json" "$INTERRUPTED_JSON/home/.claude/settings.json.qbraid-code-uninstall.backup"
if HOME="$INTERRUPTED_JSON/home" QBRAID_CODE_HOME="$INTERRUPTED_JSON/home/.qbraid-code" "$INTERRUPTED_JSON/bin/qbraid-code" --uninstall --yes >/dev/null 2>&1; then
  bad 'interrupted JSON backup was silently accepted'
elif [ -f "$INTERRUPTED_JSON/home/.claude/settings.json" ] \
  && [ -e "$INTERRUPTED_JSON/home/.qbraid-code/secrets/alpha.g1" ]; then
  ok 'interrupted JSON replacement recovers before credential deletion'
else bad 'interrupted JSON replacement was not safely recovered'; fi

RECOVERY_RACE="$TMP/recovery race"
make_file_install "$RECOVERY_RACE"
mv "$RECOVERY_RACE/home/.claude/settings.json" "$RECOVERY_RACE/home/.claude/settings.json.qbraid-code-uninstall.backup"
mkdir -p "$RECOVERY_RACE/fake-bin"
cat > "$RECOVERY_RACE/fake-bin/ln" <<'EOF'
#!/usr/bin/env bash
printf '{"concurrent":2}
' > "$2"
exec /bin/ln "$@"
EOF
chmod +x "$RECOVERY_RACE/fake-bin/ln"
if HOME="$RECOVERY_RACE/home" QBRAID_CODE_HOME="$RECOVERY_RACE/home/.qbraid-code" PATH="$RECOVERY_RACE/fake-bin:/usr/bin:/bin" "$RECOVERY_RACE/bin/qbraid-code" --uninstall --yes >/dev/null 2>&1; then
  bad 'JSON recovery race was silently accepted'
elif grep -q '"concurrent":2' "$RECOVERY_RACE/home/.claude/settings.json" \
  && [ -f "$RECOVERY_RACE/home/.claude/settings.json.qbraid-code-uninstall.backup" ] \
  && [ -e "$RECOVERY_RACE/home/.qbraid-code/secrets/alpha.g1" ]; then
  ok 'JSON recovery never overwrites a concurrent writer'
else bad 'JSON recovery overwrote or deleted concurrent state'; fi

COMPLETED_JSON="$TMP/completed json"
make_file_install "$COMPLETED_JSON"
printf '{"new":true}\n' > "$COMPLETED_JSON/home/.claude/settings.json"
printf '{"old":true}\n' > "$COMPLETED_JSON/home/.claude/settings.json.qbraid-code-uninstall.backup"
if HOME="$COMPLETED_JSON/home" QBRAID_CODE_HOME="$COMPLETED_JSON/home/.qbraid-code" "$COMPLETED_JSON/bin/qbraid-code" --uninstall --yes >/dev/null 2>&1; then
  bad 'completed JSON crash state was silently accepted'
elif grep -q '"new":true' "$COMPLETED_JSON/home/.claude/settings.json" \
  && [ ! -e "$COMPLETED_JSON/home/.claude/settings.json.qbraid-code-uninstall.backup" ] \
  && [ -e "$COMPLETED_JSON/home/.qbraid-code/secrets/alpha.g1" ]; then
  ok 'completed JSON replacement cleans its backup before retry'
else bad 'completed JSON crash backup was not safely cleaned'; fi

ORPHAN_JSON="$TMP/orphan json"
make_file_install "$ORPHAN_JSON"
printf '{"temporary":"secret"}\n' > "$ORPHAN_JSON/home/.claude/settings.json.qbraid-code-uninstall.ABC123"
if HOME="$ORPHAN_JSON/home" QBRAID_CODE_HOME="$ORPHAN_JSON/home/.qbraid-code" "$ORPHAN_JSON/bin/qbraid-code" --uninstall --yes >/dev/null 2>&1; then
  bad 'orphan JSON temporary was silently accepted'
elif [ ! -e "$ORPHAN_JSON/home/.claude/settings.json.qbraid-code-uninstall.ABC123" ] \
  && [ -e "$ORPHAN_JSON/home/.qbraid-code/secrets/alpha.g1" ]; then
  ok 'orphaned JSON temporaries are removed before retry'
else bad 'orphaned JSON temporary was not safely cleaned'; fi

READONLY="$TMP/readonly-json"
make_file_install "$READONLY"
chmod 500 "$READONLY/home/.claude"
if HOME="$READONLY/home" QBRAID_CODE_HOME="$READONLY/home/.qbraid-code" "$READONLY/bin/qbraid-code" --uninstall --yes >/dev/null 2>&1; then
  bad 'uninstall ignored an unwritable Claude settings directory'
elif [ -e "$READONLY/home/.qbraid-code/secrets/alpha.g1" ] && [ -e "$READONLY/home/.qbraid-code" ]; then
  ok 'JSON rewrite failure occurs before credential deletion'
else bad 'JSON rewrite failure deleted the credential first'; fi
chmod 700 "$READONLY/home/.claude"

JSON_RACE="$TMP/json race"
make_file_install "$JSON_RACE"
mkdir -p "$JSON_RACE/fake-bin"
cat > "$JSON_RACE/fake-bin/cmp" <<'EOF'
#!/usr/bin/env bash
if [ ! -e "$JSON_RACE_DONE" ]; then
  : > "$JSON_RACE_DONE"
  printf '{"concurrent":2}\n' > "$JSON_RACE_SETTINGS"
fi
exec /usr/bin/cmp "$@"
EOF
chmod +x "$JSON_RACE/fake-bin/cmp"
if HOME="$JSON_RACE/home" QBRAID_CODE_HOME="$JSON_RACE/home/.qbraid-code" \
  JSON_RACE_DONE="$JSON_RACE/done" JSON_RACE_SETTINGS="$JSON_RACE/home/.claude/settings.json" \
  PATH="$JSON_RACE/fake-bin:/usr/bin:/bin" "$JSON_RACE/bin/qbraid-code" --uninstall --yes >/dev/null 2>&1; then
  bad 'uninstall overwrote a concurrent Claude settings update'
elif grep -q '"concurrent":2' "$JSON_RACE/home/.claude/settings.json" \
  && [ -e "$JSON_RACE/home/.qbraid-code/secrets/alpha.g1" ]; then
  ok 'concurrent Claude settings changes abort before credential deletion'
else bad 'concurrent Claude settings update or credential was lost'; fi

STORE_FAIL="$TMP/store-failure"
STORE_HOME="$STORE_FAIL/home"
STORE_QC="$STORE_HOME/.qbraid-code"
mkdir -p "$STORE_QC/profiles/alpha/generations/g1" "$STORE_FAIL/bin"
printf 'g1\n' > "$STORE_QC/profiles/alpha/current"
printf 'QBRAID_CODE_SECRET_BACKEND=secret-service\nQBRAID_CODE_SECRET_REF=qbraid-code:alpha:g1\n' > "$STORE_QC/profiles/alpha/generations/g1/env"
cat > "$STORE_FAIL/bin/secret-tool" <<'EOF'
#!/usr/bin/env bash
printf 'secret service unavailable\n' >&2
exit 2
EOF
chmod +x "$STORE_FAIL/bin/secret-tool"
cp qbraid-code "$STORE_FAIL/bin/qbraid-code"; chmod +x "$STORE_FAIL/bin/qbraid-code"
printf '%s\n' "$STORE_QC" > "$STORE_FAIL/bin/qbraid-code.home"
if HOME="$STORE_HOME" QBRAID_CODE_HOME="$STORE_QC" PATH="$STORE_FAIL/bin:/usr/bin:/bin" "$STORE_FAIL/bin/qbraid-code" --uninstall --yes >/dev/null 2>&1; then
  bad 'uninstall treated a Secret Service failure as a missing item'
elif [ -e "$STORE_QC/profiles/alpha/generations/g1/env" ]; then
  ok 'secret-store failures preserve credential metadata for retry'
else bad 'secret-store failure erased credential metadata'; fi

PROCESS_OWNER="$TMP/process-owner"
make_file_install "$PROCESS_OWNER"
PROCESS_QC="$PROCESS_OWNER/home/.qbraid-code"
printf 'QBRAID_CODE_PROXY_BIN=%s/cliproxyapi\n' "$PROCESS_QC" >> "$PROCESS_QC/profiles/alpha/generations/g1/env"
mkdir -p "$PROCESS_QC/runtime.test"
printf 'config\n' > "$PROCESS_QC/runtime.test/proxy-config.yaml"
cat > "$PROCESS_OWNER/unrelated-proxy" <<'EOF'
#!/usr/bin/env bash
while :; do sleep 1; done
EOF
chmod +x "$PROCESS_OWNER/unrelated-proxy"
"$PROCESS_OWNER/unrelated-proxy" -config "$PROCESS_QC/runtime.test/proxy-config.yaml" & unrelated_pid=$!
printf '%s\n' "$unrelated_pid" > "$PROCESS_QC/runtime.test/proxy.pid"
if HOME="$PROCESS_OWNER/home" QBRAID_CODE_HOME="$PROCESS_QC" "$PROCESS_OWNER/bin/qbraid-code" --uninstall --yes >/dev/null 2>&1; then
  bad 'uninstall accepted an unowned executable for an exact runtime config'
elif kill -0 "$unrelated_pid" 2>/dev/null && [ -e "$PROCESS_QC" ]; then
  ok 'uninstall does not kill a reused PID owned by another executable'
else bad 'uninstall killed an unrelated process'; fi
kill "$unrelated_pid" 2>/dev/null || true; wait "$unrelated_pid" 2>/dev/null || true

LOCK_HELPERS=$(awk '/^lock_dir_is_stale\(\)/,/^acquire_uninstall_lock_dir\(\)/ { if ($0 !~ /^acquire_uninstall_lock_dir/) print }' qbraid-code)
LOCK_RACE="$TMP/lock-race"
mkdir -p "$LOCK_RACE"; printf '99999999\n' > "$LOCK_RACE/pid"
: > "$TMP/lock-winners"
(eval "$LOCK_HELPERS"; if try_acquire_lock_dir "$LOCK_RACE"; then printf '%s\n' "$$" >> "$TMP/lock-winners"; sleep 1; fi) & lock_one=$!
(eval "$LOCK_HELPERS"; if try_acquire_lock_dir "$LOCK_RACE"; then printf '%s\n' "$$" >> "$TMP/lock-winners"; sleep 1; fi) & lock_two=$!
wait "$lock_one"; wait "$lock_two"
if [ "$(wc -l < "$TMP/lock-winners" | tr -d ' ')" -eq 1 ]; then
  ok 'stale lock reclamation admits only one contender'
else bad 'two contenders reclaimed the same stale lock'; fi

LEGACY_RECLAIM="$TMP/legacy-reclaim"
mkdir -p "$LEGACY_RECLAIM" "$LEGACY_RECLAIM.reclaim"
printf '99999998\n' > "$LEGACY_RECLAIM/pid"
printf '99999997\n' > "$LEGACY_RECLAIM.reclaim/pid"
if (eval "$LOCK_HELPERS"; try_acquire_lock_dir "$LEGACY_RECLAIM"); then
  ok 'stale legacy reclaim guards recover on the next acquisition'
else bad 'stale legacy reclaim guard blocked all future acquisitions'; fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
