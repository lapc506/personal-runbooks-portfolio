#!/usr/bin/env bash
# inotify-diagnose.sh — read-only check for inotify exhaustion (the fake ENOSPC).
#
# Why: when per-user inotify limits are exhausted, apps fail with misleading
# "No space left on device" / ENOSPC errors — frozen WebKitGTK windows (dead
# WebKitWebProcess), crashing file-watchers (OpenCode TUI storage watcher).
# See README.md. Never writes anything; never needs sudo.
set -euo pipefail

GRN=$'\033[32m'; YEL=$'\033[33m'; CYA=$'\033[36m'; RST=$'\033[0m'
ok(){   printf '%s✔%s %s\n' "$GRN" "$RST" "$*"; }
info(){ printf '%s•%s %s\n' "$CYA" "$RST" "$*"; }
warn(){ printf '%s⚠%s %s\n' "$YEL" "$RST" "$*" >&2; }

WATCHES=$(cat /proc/sys/fs/inotify/max_user_watches)
INSTANCES=$(cat /proc/sys/fs/inotify/max_user_instances)
info "limits: max_user_watches=$WATCHES max_user_instances=$INSTANCES"

IN_USE=$(find /proc/[0-9]*/fd -lname 'anon_inode:inotify' 2>/dev/null | wc -l || true)
info "inotify instances in use: $IN_USE / $INSTANCES"
if [ "$IN_USE" -gt $(( INSTANCES * 75 / 100 )) ]; then
  warn "over 75% of instance budget — bursts will fail with ENOSPC"
else
  ok "instance headroom looks healthy"
fi

WATCHES_USED=$(grep -h "inotify wd:" /proc/[0-9]*/fdinfo/* 2>/dev/null | wc -l || true)
info "inotify watches in use (approx): $WATCHES_USED / $WATCHES"
if [ "$WATCHES_USED" -gt $(( WATCHES * 75 / 100 )) ]; then
  warn "over 75% of watch budget — new watchers will fail with ENOSPC"
else
  ok "watch headroom looks healthy"
fi

info "top inotify consumers (instances pid comm):"
for d in /proc/[0-9]*/fd; do
  pid=${d%/fd}; pid=${pid#/proc/}
  n=$(find "$d" -lname 'anon_inode:inotify' 2>/dev/null | wc -l || true)
  if [ "$n" -gt 0 ]; then
    printf '%s %s %s\n' "$n" "$pid" "$(cat "/proc/$pid/comm" 2>/dev/null || echo '?')"
  fi
done 2>/dev/null | sort -rn | head -10

info "recent inotify/ENOSPC journal hits (24h):"
if journalctl --since "24 hours ago" --no-pager 2>&1 \
    | grep -iE "inotify.*(no space left on device|No space left)|ENOSPC" \
    | tail -5; then
  :
else
  ok "none found"
fi

info "disk space (must have free room to rule out real ENOSPC):"
df -h / | tail -1
