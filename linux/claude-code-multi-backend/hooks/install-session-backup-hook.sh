#!/usr/bin/env bash
# Registra session-backup.sh como hook SessionStart en ~/.claude/settings.json.
# Idempotente: si ya está registrado, no duplica. No toca el resto de settings.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
HOOK="$SCRIPT_DIR/session-backup.sh"
SETTINGS="$HOME/.claude/settings.json"

chmod +x "$HOOK"

[ -f "$SETTINGS" ] || { mkdir -p "$(dirname "$SETTINGS")"; echo '{}' > "$SETTINGS"; }

python3 - "$SETTINGS" "$HOOK" <<'PY'
import json, sys, shutil, os, time

settings_path, hook_cmd = sys.argv[1], sys.argv[2]
with open(settings_path) as fh:
    cfg = json.load(fh)

hooks = cfg.setdefault('hooks', {})
session_start = hooks.setdefault('SessionStart', [])

def already_registered(blocks):
    for blk in blocks:
        for h in blk.get('hooks', []):
            if h.get('command') == hook_cmd:
                return True
    return False

if already_registered(session_start):
    print("Ya registrado, sin cambios.")
    sys.exit(0)

# Backup del settings antes de tocarlo.
shutil.copy(settings_path, settings_path + f".bak.{int(time.time())}")

session_start.append({"hooks": [{"type": "command", "command": hook_cmd}]})
with open(settings_path, 'w') as fh:
    json.dump(cfg, fh, indent=2)
print(f"Hook SessionStart registrado → {hook_cmd}")
PY
