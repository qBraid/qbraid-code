#!/usr/bin/env bash
# Smoke-check a real Claude Code release installed by the CI version matrix.
set -euo pipefail

version=$(claude --version)
printf 'claude: %s\n' "$version"

cli_help=$(claude --help)
for option in --settings --setting-sources --strict-mcp-config; do
  printf '%s
' "$cli_help" | grep -Fq -- "$option" || {
    printf 'missing required isolation option: %s
' "$option" >&2
    exit 1
  }
done

help=$(claude mcp --help)
for command in add get; do
  printf '%s\n' "$help" | grep -Eq "^[[:space:]]+$command([[:space:]]|$)" || {
    printf 'missing required mcp command: %s\n' "$command" >&2
    exit 1
  }
done

if printf '%s\n' "$help" | grep -Eq '^[[:space:]]+login([[:space:]]|$)'; then
  printf 'mcp login: available\n'
else
  printf 'mcp login: unavailable; interactive /mcp fallback required\n'
fi

add_help=$(claude mcp add --help)
printf '%s\n' "$add_help" | grep -Eq -- '--transport.*http' || {
  printf 'mcp add does not advertise HTTP transport\n' >&2
  exit 1
}
printf '%s\n' "$add_help" | grep -Eq -- '--scope.*user' || {
  printf 'mcp add does not advertise user scope\n' >&2
  exit 1
}

printf 'Claude Code compatibility checks passed\n'
