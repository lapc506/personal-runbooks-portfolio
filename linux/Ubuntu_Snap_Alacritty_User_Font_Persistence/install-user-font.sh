#!/usr/bin/env bash
# install-user-font.sh — install a user font and verify it is visible BOTH on
# the host AND inside a snap-confined app's fontconfig.
#
# The host `fc-list` showing the font is necessary but NOT sufficient: a
# strictly-confined snap may not see ~/.local/share/fonts (it lives under the
# hidden .local dir). The only trustworthy check is to query fontconfig from
# inside the snap's confinement — which is what this script does.
#
# Usage:
#   ./install-user-font.sh <subdir> <url> [<snap-app>]
#
# Examples:
#   ./install-user-font.sh Inconsolata \
#     'https://raw.githubusercontent.com/google/fonts/main/ofl/inconsolata/Inconsolata%5Bwdth,wght%5D.ttf' \
#     alacritty
#
# Idempotent: re-running re-downloads and refreshes the cache.
set -euo pipefail

SUBDIR="${1:?usage: install-user-font.sh <subdir> <url> [<snap-app>]}"
URL="${2:?missing <url>}"
SNAP_APP="${3:-}"

FONT_ROOT="$HOME/.local/share/fonts"
DEST="$FONT_ROOT/$SUBDIR"
mkdir -p "$DEST"

# Derive a filename from the URL (strip query/%-encoding noise into something sane).
fname="$(basename "${URL%%\?*}")"
fname="$(printf '%s' "$fname" | sed 's/%5B/[/g; s/%5D/]/g; s/%20/ /g')"
case "$fname" in
  *.ttf|*.otf) : ;;
  *) fname="$SUBDIR.ttf" ;;   # fall back to a stable name
esac

echo "==> Downloading: $URL"
echo "    -> $DEST/$fname"
curl -fsSL "$URL" -o "$DEST/$fname"
file -b "$DEST/$fname" | cut -c1-50

echo "==> Refreshing font cache (host)"
fc-cache -f "$FONT_ROOT" >/dev/null 2>&1

# Read the real family name straight from the file (authoritative).
FAMILY="$(fc-query -f '%{family[0]}\n' "$DEST/$fname" 2>/dev/null | head -1)"
echo "==> Family name (from file): ${FAMILY:-<unknown>}"

echo "==> Host visibility:"
if fc-list | grep -F -- "$DEST/" >/dev/null 2>&1; then
  fc-list | grep -F -- "$DEST/" | sed 's/^/    /' | sort
else
  echo "    !! NOT found by host fontconfig — investigate cache/permissions" >&2
  exit 1
fi

if [ -n "$SNAP_APP" ] && [ -n "${FAMILY:-}" ]; then
  echo "==> Confined visibility (snap: $SNAP_APP):"
  # Query fontconfig from inside the snap's confinement. The hyphen in some
  # family names is a pattern metacharacter, so escape it for the CLI.
  q_family="${FAMILY//-/\\-}"
  if snap run --shell "$SNAP_APP" -c "fc-match \"$q_family\"" 2>/dev/null | grep -qi "$SUBDIR\|$(basename "$fname")\|${FAMILY%% *}"; then
    snap run --shell "$SNAP_APP" -c "fc-match \"$q_family\"" 2>/dev/null | sed 's/^/    /'
    echo "    OK: '$SNAP_APP' can resolve the font."
  else
    echo "    !! '$SNAP_APP' does NOT resolve '$FAMILY' — its confinement may not"
    echo "       expose ~/.local/share/fonts. Check snapd version / interfaces." >&2
    exit 2
  fi
else
  echo "==> (skip snap check: pass a snap app name as \$3 to verify confinement)"
fi

echo "==> Done. Family to use in your config: \"${FAMILY:-?}\""
