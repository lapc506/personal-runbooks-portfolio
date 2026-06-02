#!/usr/bin/env bash
# set-alacritty-font.sh — safely set the [font] tables in alacritty.toml.
#
# Why this exists: naively rewriting alacritty.toml is how you brick live
# reload. Re-typing a control-character keybinding (e.g. chars = "<ESC><CR>")
# through shell/escape layers can inject a raw 0x1B byte, which is illegal in a
# TOML basic string — Alacritty then silently keeps the old config. This script
# NEVER touches non-font lines: it strips only the [font*] tables and prepends a
# fresh block, then validates the whole file with tomllib BEFORE writing. A bad
# edit can't reach disk, and your keybindings survive byte-for-byte.
#
# Alacritty live-reloads on save (live_config_reload defaults to true since
# 0.13), so there's no restart — the running window repaints immediately.
#
# Override the font via env vars:
#   FONT_FAMILY="Inconsolata" NORMAL_STYLE="SemiBold" ./set-alacritty-font.sh
set -euo pipefail

CONFIG="${ALACRITTY_CONFIG:-$HOME/.config/alacritty/alacritty.toml}"

# ---- defaults: the Inconsolata "Medium" end state from the runbook ----------
FONT_SIZE="${FONT_SIZE:-12.0}"
FONT_FAMILY="${FONT_FAMILY:-Inconsolata}"
NORMAL_STYLE="${NORMAL_STYLE:-Medium}"
BOLD_FAMILY="${BOLD_FAMILY:-$FONT_FAMILY}"
BOLD_STYLE="${BOLD_STYLE:-Bold}"
# Inconsolata has no italic; pointing italic at the same family/Regular keeps
# fontconfig from substituting a different font (which would break the grid).
ITALIC_FAMILY="${ITALIC_FAMILY:-$FONT_FAMILY}"
ITALIC_STYLE="${ITALIC_STYLE:-Regular}"
# -----------------------------------------------------------------------------

[ -f "$CONFIG" ] || { echo "No config at $CONFIG" >&2; exit 1; }

BACKUP="$CONFIG.bak"
cp "$CONFIG" "$BACKUP"
echo "==> Backup: $BACKUP"

# Build the new [font] block (no control chars here — safe to template).
BLOCK="$(cat <<EOF
# Alacritty live-reloads this file on save (live_config_reload defaults to true
# since 0.13), so font changes apply with NO restart.

[font]
size = $FONT_SIZE

[font.normal]
family = "$FONT_FAMILY"
style = "$NORMAL_STYLE"

[font.bold]
family = "$BOLD_FAMILY"
style = "$BOLD_STYLE"

[font.italic]
family = "$ITALIC_FAMILY"
style = "$ITALIC_STYLE"
EOF
)"

# Merge at the TEXT level: drop existing [font*] tables, keep everything else
# verbatim, prepend the new block, and validate before writing.
NEW_BLOCK="$BLOCK" python3 - "$CONFIG" <<'PY'
import os, sys, tomllib

path = sys.argv[1]
block = os.environ["NEW_BLOCK"]
orig = open(path, "r", encoding="utf-8").read()

out, skipping = [], False
for line in orig.splitlines(keepends=True):
    stripped = line.lstrip()
    if stripped.startswith("[") and not stripped.startswith("[["):
        name = stripped.strip().strip("[]").strip()
        skipping = (name == "font" or name.startswith("font."))
    elif stripped.startswith("[["):
        skipping = False  # array-of-tables (e.g. keyboard.bindings) — keep
    if not skipping:
        out.append(line)

tail = "".join(out).lstrip("\n")
new = block.rstrip("\n") + "\n\n"
if tail.strip():
    new += "# --- preserved from your previous config ---\n" + tail

# Validate BEFORE writing — a malformed file must never reach disk.
try:
    tomllib.loads(new)
except tomllib.TOMLDecodeError as e:
    sys.stderr.write(f"Refusing to write: resulting TOML is invalid: {e}\n")
    sys.exit(3)

open(path, "w", encoding="utf-8").write(new)
d = tomllib.loads(new)["font"]
print(f"==> Wrote {path}")
print(f"    normal={d['normal']['family']!r}/{d['normal']['style']}"
      f"  bold={d['bold']['style']}  italic={d['italic']['style']}")
PY

echo "==> Applied. Alacritty should repaint live. Revert: cp \"$BACKUP\" \"$CONFIG\""
