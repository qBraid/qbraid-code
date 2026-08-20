#!/usr/bin/env bash
# The launcher routes gpt-* models through the local proxy and Claude models
# direct. requested_model() decides that; test the REAL definition from the
# launcher against arg shapes, under the launcher's own shell options.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

FN=$(awk '/^requested_model\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' qbraid-code)
[ -n "$FN" ] || { echo "  FAIL could not extract requested_model"; exit 1; }

pass=0; fail=0
check() { # check <name> <default-model> <expected> [args...]
  local name="$1" def="$2" want="$3"; shift 3
  local got
  got=$(bash -c "set -euo pipefail; MODEL=\"$def\"; $FN; requested_model \"\$@\"" _ "$@")
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$name"
  else
    fail=$((fail + 1)); printf '  FAIL %s: got [%s] want [%s]\n' "$name" "$got" "$want"
  fi
}

check "default model when no --model"         claude-sonnet-4-6 claude-sonnet-4-6 -p "hi"
check "--model value wins"                    claude-sonnet-4-6 gpt-5.6-sol --model gpt-5.6-sol -p "hi"
check "--model=value wins"                    claude-sonnet-4-6 gpt-5.4 --model=gpt-5.4
check "--model anywhere in args"              claude-sonnet-4-6 claude-opus-5 -p "hi" --model claude-opus-5
check "gpt default with no args"              gpt-5.6-sol gpt-5.6-sol
check "no args, no crash"                     claude-sonnet-4-6 claude-sonnet-4-6

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
