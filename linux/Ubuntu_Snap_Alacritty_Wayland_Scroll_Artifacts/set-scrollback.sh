#!/usr/bin/env bash
# set-scrollback.sh — make Alacritty's scrollback cap explicit & intentional.
#
# This is HYGIENE, not a RAM fix. Alacritty's default is already 10,000 lines
# (tens of MB at most). A runaway child process dumping GBs of output is a
# separate problem and is NOT bounded by this. See README.md.
#
# Idempotent: adds a [scrollback] block if missing, updates `history` if present,
# and preserves the rest of the file verbatim. Alacritty live-reloads on save.
#
# Usage:
#   ./set-scrollback.sh            # default history=10000 (the implicit default, made explicit)
#   ./set-scrollback.sh 1000       # leaner ring
set -euo pipefail

CONF="${ALACRITTY_CONFIG:-$HOME/.config/alacritty/alacritty.toml}"
HISTORY="${1:-10000}"

if ! [[ "$HISTORY" =~ ^[0-9]+$ ]]; then
  echo "history must be a non-negative integer, got: $HISTORY" >&2
  exit 2
fi

if [[ ! -f "$CONF" ]]; then
  echo "config not found: $CONF" >&2
  exit 1
fi

# Back up once per run.
cp -p "$CONF" "$CONF.bak.$(date +%Y%m%d-%H%M%S)"

if grep -qE '^\[scrollback\]' "$CONF"; then
  # Update history inside the existing [scrollback] block (first occurrence).
  awk -v h="$HISTORY" '
    /^\[scrollback\]/ { in_sb=1; print; next }
    /^\[/ && in_sb    { in_sb=0 }
    in_sb && /^[[:space:]]*history[[:space:]]*=/ { print "history = " h; done=1; next }
    { print }
  ' "$CONF" > "$CONF.tmp"
  mv "$CONF.tmp" "$CONF"
  # If the block existed but had no history line, append one under it.
  if ! awk '/^\[scrollback\]/{f=1} f&&/^[[:space:]]*history[[:space:]]*=/{ok=1} END{exit !ok}' "$CONF"; then
    printf '\n[scrollback]\nhistory = %s\n' "$HISTORY" >> "$CONF"
  fi
else
  # Append a fresh block. Leading blank line keeps TOML table separation clean.
  printf '\n[scrollback]\nhistory = %s\nmultiplier = 3\n' "$HISTORY" >> "$CONF"
fi

echo "Set [scrollback].history = $HISTORY in $CONF"
echo "Alacritty live-reloads on save; no restart needed."
