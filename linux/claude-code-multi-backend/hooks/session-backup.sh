#!/usr/bin/env bash
# SessionStart hook — respalda la metadata de la sesión apenas arranca.
#
# Motivación (fix 2): el selector de claude-code-vertex sólo respaldaba una
# sesión cuando la RETOMABAS por el menú. Si una sesión nueva crasheaba antes
# de ser retomada (típico de un freeze de GPU / corte de energía), nunca se
# respaldaba. Este hook corre en CADA arranque de sesión, así el respaldo
# ocurre "al iniciar, no al retomar" y sobrevive a reinicios duros.
#
# Entrada: JSON de Claude Code por stdin (session_id, cwd, transcript_path...).
# Salida: ninguna a stdout (no inyecta contexto). Siempre exit 0 — un hook
# de respaldo nunca debe bloquear el arranque de la sesión.
set -uo pipefail

BACKUP_DIR="$HOME/.claude/sessions-backup"
SESSIONS_DIR="$HOME/.claude/sessions"
mkdir -p "$BACKUP_DIR"

payload="$(cat 2>/dev/null || true)"
[ -n "$payload" ] || exit 0

python3 - "$payload" "$BACKUP_DIR" "$SESSIONS_DIR" <<'PY' 2>/dev/null || true
import json, sys, os, glob, time

payload, backup_dir, sessions_dir = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    h = json.loads(payload)
except Exception:
    sys.exit(0)

sid = h.get('session_id') or h.get('sessionId') or ''
if not sid:
    sys.exit(0)
cwd = h.get('cwd', '')
dest = os.path.join(backup_dir, f"{sid}.json")

# 1) Si ya existe el heartbeat vivo de esta sesión, cópialo tal cual:
#    trae el 'name' auto-generado y el resto de la metadata.
for f in glob.glob(os.path.join(sessions_dir, '*.json')):
    try:
        d = json.load(open(f))
    except Exception:
        continue
    if d.get('sessionId') == sid:
        json.dump(d, open(dest, 'w'))
        sys.exit(0)

# 2) Si el heartbeat aún no aparece, sintetiza metadata mínima sin pisar
#    un 'name' que un respaldo previo ya tuviera.
prev = {}
if os.path.exists(dest):
    try:
        prev = json.load(open(dest))
    except Exception:
        prev = {}
rec = {"sessionId": sid, "cwd": cwd or prev.get('cwd', ''),
       "kind": "interactive", "status": "start-backup",
       "updatedAt": int(time.time() * 1000)}
if prev.get('name'):
    rec["name"] = prev["name"]
json.dump(rec, open(dest, 'w'))
PY

exit 0
