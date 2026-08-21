#!/usr/bin/env bash
# qbraid-code statusline — folder, branch, model, context, qBraid credits.
#
# Claude Code runs this on every render and feeds it the session JSON on
# stdin. It must never block: the credit balance is served from a short-lived
# cache and refreshed in the background, so a slow network costs nothing.
set -uo pipefail

HOME_DIR="${QBRAID_CODE_HOME:-$HOME/.qbraid-code}"
PROFILE_HOME="${QBRAID_CODE_PROFILE_HOME:-}"
if [ -z "$PROFILE_HOME" ]; then
  if [ -f "$HOME_DIR/env" ]; then
    PROFILE_HOME="$HOME_DIR"
  elif [ -f "$HOME_DIR/active-profile" ]; then
    IFS= read -r profile < "$HOME_DIR/active-profile" || true
    if [ -n "${profile:-}" ]; then
      PROFILE_HOME="$HOME_DIR/profiles/$profile"
      if [ -f "$PROFILE_HOME/current" ]; then
        IFS= read -r generation < "$PROFILE_HOME/current" || true
        case "${generation:-}" in ''|*/*|.*) ;; *) PROFILE_HOME="$PROFILE_HOME/generations/$generation" ;; esac
      fi
    fi
  fi
fi
[ -n "$PROFILE_HOME" ] || PROFILE_HOME="$HOME_DIR"
CACHE="$PROFILE_HOME/credits.cache"
UPDATED="$PROFILE_HOME/credits.updated"
KEY_STATUS=$(cat "$PROFILE_HOME/key-status" 2>/dev/null || true)
PROFILE_LABEL=$(cat "$PROFILE_HOME/label" 2>/dev/null || printf '%s' "${QBRAID_CODE_PROFILE:-default}")
PROFILE_LABEL=$(printf '%s' "$PROFILE_LABEL" | tr -d '\001-\037\177')
LABEL_BYTES=$(LC_ALL=C printf '%s' "$PROFILE_LABEL" | wc -c | tr -d ' ')
[ -n "$PROFILE_LABEL" ] && [ "$LABEL_BYTES" -le 80 ] || PROFILE_LABEL="${QBRAID_CODE_PROFILE:-default}"

esc=$(printf '\033')
dim="${esc}[2m"; rst="${esc}[0m"
violet="${esc}[38;2;168;85;247m"; grn="${esc}[32m"; ylw="${esc}[33m"; red="${esc}[31m"

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
place="${name}"
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

credits=""
[ -s "$CACHE" ] && credits=$(cat "$CACHE" 2>/dev/null)
updated=$(cat "$UPDATED" 2>/dev/null || true)
case "$updated" in ''|*[!0-9]*) stale="stale" ;; *)
  age=$(( $(date +%s) - updated ))
  if [ "$age" -gt 300 ]; then stale="stale $((age / 60))m"; else stale=""; fi ;;
esac
label_source=$(cat "$PROFILE_HOME/label-source" 2>/dev/null || printf 'local')
if [ "$label_source" = local ]; then
  org_tag=$(cat "$PROFILE_HOME/organization-id" 2>/dev/null || true)
  case "$org_tag" in ''|*[!A-Za-z0-9._-]*) PROFILE_LABEL="$PROFILE_LABEL (local)" ;; *) PROFILE_LABEL="$PROFILE_LABEL (local · org $(printf '%s' "$org_tag" | cut -c1-8)…)" ;; esac
fi
account_seg="${violet}qBraid${rst} ${PROFILE_LABEL}"
if [ "$KEY_STATUS" = expired ]; then
  account_seg="${account_seg}${dim} · ${rst}${red}key expired${rst}"
elif [ -n "$credits" ]; then
  pretty=$(awk -v c="$credits" 'BEGIN { printf "%.0f", c }' 2>/dev/null)
  [ -n "$pretty" ] || pretty="$credits"
  colour="$grn"
  awk -v c="$credits" 'BEGIN { exit !(c < 100) }' && colour="$ylw"
  awk -v c="$credits" 'BEGIN { exit !(c < 10) }'  && colour="$red"
  stale_suffix=""; [ -z "$stale" ] || stale_suffix=" · $stale"
  account_seg="${account_seg}${dim} · ${rst}${colour}${pretty}${rst}${dim} credits${stale_suffix}${rst}"
fi

# ------------------------------------------------------------------ render

sep="${dim} │ ${rst}"
out="$place${sep}${dim}${model}${rst}"
[ -n "$bar" ] && out="${out}${sep}${bar}"
out="${out}${sep}${account_seg}"
# %s, not %b: the directory name comes from the session payload and must not
# have backslash escapes re-interpreted into terminal control sequences. The
# colours above are already literal ESC bytes and are unaffected.
printf '%s\n' "$out"
