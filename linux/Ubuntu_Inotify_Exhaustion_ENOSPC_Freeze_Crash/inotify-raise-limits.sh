#!/usr/bin/env bash
# inotify-raise-limits.sh — persistently raise per-user inotify limits.
#
# Why: Ubuntu defaults (1024 instances / 65536 watches) are exhausted by heavy
# desktop sessions (many Electron/Chromium apps) plus AI-agent workflows with
# subagents + worktree isolation. Exhaustion surfaces as fake ENOSPC: frozen
# WebKitGTK windows, crashing TUI file-watchers. See README.md.
#
# Idempotent: re-running just rewrites the same conf and re-applies.
# Needs sudo ONCE (writes /etc/sysctl.d + sysctl --system).
set -euo pipefail

GRN=$'\033[32m'; YEL=$'\033[33m'; CYA=$'\033[36m'; RST=$'\033[0m'
ok(){   printf '%s✔%s %s\n' "$GRN" "$RST" "$*"; }
info(){ printf '%s•%s %s\n' "$CYA" "$RST" "$*"; }

CONF=/etc/sysctl.d/60-inotify.conf
WANT_WATCHES=524288
WANT_INSTANCES=4096

info "writing $CONF (sudo)..."
sudo sh -c "printf 'fs.inotify.max_user_watches=${WANT_WATCHES}\nfs.inotify.max_user_instances=${WANT_INSTANCES}\n' > '$CONF'" \
  && sudo chmod 644 "$CONF"

info "applying live..."
sudo sysctl -p "$CONF"

ok "done — fully quit and reopen affected apps (frozen instances stay dead)"
