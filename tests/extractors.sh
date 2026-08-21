#!/usr/bin/env bash
# Regression test for the silent-exit bug found by the first real install.
#
# install.sh runs under `set -euo pipefail`. Its JSON extractors are grep
# pipelines, and a grep that matches NOTHING makes the pipeline non-zero —
# so an absent field (a normal outcome, e.g. an error body with no `name`)
# killed the installer with no message at all, right after "key accepted".
#
# This test extracts the REAL function definitions from install.sh — not a
# copy that could drift — and calls them on bodies missing the field, under
# the same shell options install.sh uses.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

pass=0; fail=0

# Pull each function's source out of install.sh by its opening line.
extract_fn() { # extract_fn <name>
  awk -v fn="$1" '
    $0 ~ "^"fn"\\(\\) \\{" { inside = 1 }
    inside { print }
    inside && /^\}$/ { exit }
  ' install.sh
}

JSON_STR_SRC=$(extract_fn json_str)
JSON_NUM_SRC=$(extract_fn json_num)
if [ -z "$JSON_STR_SRC" ] || [ -z "$JSON_NUM_SRC" ]; then
  echo "  FAIL could not extract json_str/json_num from install.sh"
  exit 1
fi

check() { # check <name> <script>
  if bash -c "set -euo pipefail; $JSON_STR_SRC; $JSON_NUM_SRC; $2" >/dev/null 2>&1; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$1"
  else
    fail=$((fail + 1)); printf '  FAIL %s (extractor killed a set -e shell)\n' "$1"
  fi
}

ERR='{"success":false,"message":"Organization context required"}'
OKB='{"data":{"name":"qBraid","qbraidCredits":42.5,"organizationId":"abc"}}'

check "json_str on a missing field survives set -e" \
  "x=\$(json_str '$ERR' name); [ -z \"\$x\" ]"
check "json_num on a missing field survives set -e" \
  "x=\$(json_num '$ERR' qbraidCredits); [ -z \"\$x\" ]"
check "json_str still extracts a present field" \
  "x=\$(json_str '$OKB' name); [ \"\$x\" = qBraid ]"
check "json_num still extracts a present number" \
  "x=\$(json_num '$OKB' qbraidCredits); [ \"\$x\" = 42.5 ]"
check "json_str on an empty body survives set -e" \
  "x=\$(json_str '' name); [ -z \"\$x\" ]"

# proxy_supports_picker: grep -q + pipefail must not fail on success.
FN2=$(awk '/^proxy_supports_picker\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' install.sh)
if [ -n "$FN2" ] && bash -c "set -euo pipefail; $FN2; proxy_supports_picker /bin/ls || true; exit 0"; then
  # positive case: a file that certainly contains the marker
  tmpbin=$(mktemp); printf 'xx disable-cloaking-model-list yy' > "$tmpbin"
  if bash -c "set -euo pipefail; $FN2; proxy_supports_picker '$tmpbin'"; then
    pass=$((pass + 1)); printf '  ok   proxy_supports_picker survives pipefail\n'
  else
    fail=$((fail + 1)); printf '  FAIL proxy_supports_picker false-negative under pipefail\n'
  fi
  rm -f "$tmpbin"
else
  fail=$((fail + 1)); printf '  FAIL proxy_supports_picker extraction or negative case\n'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
