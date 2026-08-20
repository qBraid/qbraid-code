#!/usr/bin/env bash
# qbraid-code statusline — folder, branch, model, context, qBraid credits.
#
# Claude Code runs this on every render and feeds it the session JSON on
# stdin. It must never block: the credit balance is served from a short-lived
# cache and refreshed in the background, so a slow network costs nothing.
set -uo pipefail

HOME_DIR="${QBRAID_CODE_HOME:-$HOME/.qbraid-code}"
CACHE="$HOME_DIR/credits.cache"
TTL=60

[ -f "$HOME_DIR/env" ] && . "$HOME_DIR/env"
API_BASE="${QBRAID_CODE_API_BASE:-https://api-v2.qbraid.com/api/v1}"
TOKEN="${QBRAID_CODE_TOKEN:-}"

esc=$(printf '\033')
dim="${esc}[2m"; rst="${esc}[0m"
cyan="${esc}[36m"; grn="${esc}[32m"; ylw="${esc}[33m"; red="${esc}[31m"

payload=$(cat)

field() { # field <key> — first string value for a key
  printf '%s' "$payload" | grep -o "\"$1\":\"[^\"]*\"" | head -1 | sed "s/\"$1\":\"//; s/\"$//"
}
number() { # number <key> — first numeric value for a key
  printf '%s' "$payload" | grep -o "\"$1\":-\?[0-9.]*" | head -1 | sed 's/.*://'
}

model=$(field display_name); [ -n "$model" ] || model="Claude"
dir=$(field current_dir);    [ -n "$dir" ] || dir="$PWD"
remaining=$(number remaining_percentage)

# ------------------------------------------------------------------ folder

name=$(basename "$dir")
branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
place="${cyan}${name}${rst}"
if [ -n "$branch" ] && [ "$branch" != HEAD ]; then
  if [ "${#branch}" -gt 22 ]; then branch="${branch:0:21}…"; fi
  place="${place} ${dim}⎇ ${branch}${rst}"
fi

# ----------------------------------------------------------------- context

bar=""
if [ -n "$remaining" ]; then
  used=$(awk -v r="$remaining" 'BEGIN { u = 100 - r; if (u < 0) u = 0; if (u > 100) u = 100; printf "%d", u }')
  filled=$(( (used + 16) / 17 ))
  [ "$filled" -gt 6 ] && filled=6
  blocks=""
  i=0
  while [ "$i" -lt 6 ]; do
    if [ "$i" -lt "$filled" ]; then blocks="${blocks}█"; else blocks="${blocks}░"; fi
    i=$((i + 1))
  done
  colour="$grn"
  [ "$used" -ge 60 ] && colour="$ylw"
  [ "$used" -ge 85 ] && colour="$red"
  bar="${dim}C${used}${rst} ${colour}${blocks}${rst}"
fi

# ----------------------------------------------------------------- credits

# Refresh out of band so the prompt never waits on the network.
refresh_credits() {
  [ -n "$TOKEN" ] || return 0
  (
    body=$(curl -fsS -m 15 "$API_BASE/billing/credits/balance" -H "X-API-Key: $TOKEN" 2>/dev/null) || exit 0
    value=$(printf '%s' "$body" | grep -o '"qbraidCredits":-\?[0-9.]*' | head -1 | sed 's/.*://')
    [ -n "$value" ] || exit 0
    printf '%s' "$value" > "$CACHE.tmp.$$" && mv "$CACHE.tmp.$$" "$CACHE"
  ) >/dev/null 2>&1 &
}

file_age() { # file_age <path> — seconds since last modification
  local mtime
  mtime=$(stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null) || return 1
  echo $(( $(date +%s) - mtime ))
}

credits=""
if [ -s "$CACHE" ]; then
  credits=$(cat "$CACHE" 2>/dev/null)
  age=$(file_age "$CACHE" 2>/dev/null || echo "$((TTL + 1))")
  [ "$age" -ge "$TTL" ] && refresh_credits
else
  refresh_credits
fi

credit_seg=""
if [ -n "$credits" ]; then
  pretty=$(awk -v c="$credits" 'BEGIN { printf "%.0f", c }' 2>/dev/null)
  [ -n "$pretty" ] || pretty="$credits"
  colour="$grn"
  awk -v c="$credits" 'BEGIN { exit !(c < 100) }' && colour="$ylw"
  awk -v c="$credits" 'BEGIN { exit !(c < 10) }'  && colour="$red"
  credit_seg="${colour}${pretty}${rst}${dim} credits${rst}"
fi

# ------------------------------------------------------------------ render

sep="${dim} │ ${rst}"
out="$place${sep}${dim}${model}${rst}"
[ -n "$bar" ] && out="${out}${sep}${bar}"
[ -n "$credit_seg" ] && out="${out}${sep}${credit_seg}"
printf '%b\n' "$out"
