#!/usr/bin/env bash
# protect-compositor-scheduling.sh — partition CPU/IO priority so the GNOME Shell
# compositor (and your interactive session) win over background containers under
# contention. Does NOT reduce load: cgroup weights are proportional and only bite
# when the host is actually contended. No reboot.
#
#   sudo bash protect-compositor-scheduling.sh          # apply (idempotent)
#        bash protect-compositor-scheduling.sh verify    # show live weights (no root)
#   sudo bash protect-compositor-scheduling.sh revert    # remove all drop-ins
#
# Rationale + full table: see README.md, "Experiment 1".
set -uo pipefail

# Tunables (proportional weights; default for everything is 100).
W_USER_SLICE=5000      # your whole interactive session vs system.slice
IO_USER_SLICE=5000
W_DOCKER=50            # dockerd yields within system.slice
IO_DOCKER=50
W_SHELL=10000          # compositor vs your own Claude agents inside user.slice
MEMLOW_SHELL=512M      # shield compositor from memory reclaim

SYS_DROPIN_USER=/etc/systemd/system/user.slice.d/90-desktop-priority.conf
SYS_DROPIN_DOCKER=/etc/systemd/system/docker.service.d/90-yield-to-desktop.conf
# Resolve the invoking (non-root) user so we can target their --user manager.
REAL_USER="${SUDO_USER:-$USER}"
REAL_UID="$(id -u "$REAL_USER")"
USER_DROPIN_DIR="/home/$REAL_USER/.config/systemd/user/org.gnome.Shell@wayland.service.d"
USER_DROPIN="$USER_DROPIN_DIR/90-compositor-priority.conf"

run_user() { sudo -u "$REAL_USER" XDG_RUNTIME_DIR="/run/user/$REAL_UID" systemctl --user "$@"; }

need_root() { [ "$(id -u)" -eq 0 ] || { echo "ERROR: run with sudo for '$1'." >&2; exit 2; }; }

cmd="${1:-apply}"

case "$cmd" in
apply)
  need_root apply

  echo "==> System scope: user.slice gets priority over system.slice"
  install -d -m755 "$(dirname "$SYS_DROPIN_USER")"
  cat > "$SYS_DROPIN_USER" <<EOF
# Managed by protect-compositor-scheduling.sh (runbook: Xwayland BadWindow under load).
# Interactive session beats background system services (dockerd, Supabase) under contention.
[Slice]
CPUWeight=$W_USER_SLICE
IOWeight=$IO_USER_SLICE
EOF

  echo "==> System scope: docker.service yields within system.slice"
  install -d -m755 "$(dirname "$SYS_DROPIN_DOCKER")"
  cat > "$SYS_DROPIN_DOCKER" <<EOF
# Managed by protect-compositor-scheduling.sh.
[Service]
CPUWeight=$W_DOCKER
IOWeight=$IO_DOCKER
EOF

  systemctl daemon-reload
  # Apply live without waiting (set-property writes a runtime drop-in too).
  systemctl set-property user.slice    "CPUWeight=$W_USER_SLICE" "IOWeight=$IO_USER_SLICE" 2>/dev/null || true
  systemctl set-property docker.service "CPUWeight=$W_DOCKER"     "IOWeight=$IO_DOCKER"     2>/dev/null || true

  echo "==> User scope: compositor priority + memory protection (user $REAL_USER)"
  install -d -m755 -o "$REAL_USER" -g "$REAL_USER" "$USER_DROPIN_DIR"
  cat > "$USER_DROPIN" <<EOF
# Managed by protect-compositor-scheduling.sh.
# Compositor beats the Claude agents in app.slice and is shielded from reclaim.
[Service]
CPUWeight=$W_SHELL
MemoryLow=$MEMLOW_SHELL
EOF
  chown "$REAL_USER:$REAL_USER" "$USER_DROPIN"
  run_user daemon-reload 2>/dev/null || true
  run_user set-property org.gnome.Shell@wayland.service "CPUWeight=$W_SHELL" "MemoryLow=$MEMLOW_SHELL" 2>/dev/null \
    || echo "  (note: live --user set-property needs an active graphical session; drop-in binds next login)"

  echo
  echo "✅ Applied. Weights bite only under contention; idle behavior is unchanged."
  echo "   Verify: bash $0 verify"
  ;;

verify)
  echo "=== System scope ==="
  echo "user.slice    : $(systemctl show user.slice    -p CPUWeight -p IOWeight 2>/dev/null | tr '\n' ' ')"
  echo "system.slice  : $(systemctl show system.slice  -p CPUWeight -p IOWeight 2>/dev/null | tr '\n' ' ')"
  echo "docker.service: $(systemctl show docker.service -p CPUWeight -p IOWeight 2>/dev/null | tr '\n' ' ')"
  echo "=== User scope (compositor) ==="
  run_user show org.gnome.Shell@wayland.service -p CPUWeight -p MemoryLow 2>/dev/null \
    || systemctl --user show org.gnome.Shell@wayland.service -p CPUWeight -p MemoryLow 2>/dev/null
  echo "=== Live pressure (should stay low under load now) ==="
  echo "cpu: $(cat /proc/pressure/cpu | head -1)"
  echo "io : $(cat /proc/pressure/io  | head -1)"
  echo "=== IO scheduler (IOWeight needs bfq to fully bite) ==="
  for d in /sys/block/nvme*/queue/scheduler /sys/block/sd*/queue/scheduler; do
    [ -e "$d" ] && echo "  $d: $(cat "$d")"
  done
  ;;

revert)
  need_root revert
  rm -f "$SYS_DROPIN_USER" "$SYS_DROPIN_DOCKER" "$USER_DROPIN"
  rmdir --ignore-fail-on-non-empty "$(dirname "$SYS_DROPIN_USER")" "$(dirname "$SYS_DROPIN_DOCKER")" "$USER_DROPIN_DIR" 2>/dev/null || true
  systemctl daemon-reload
  # Reset live runtime properties to default (100 / unset).
  systemctl set-property user.slice    CPUWeight=100 IOWeight=100 2>/dev/null || true
  systemctl set-property docker.service CPUWeight=100 IOWeight=100 2>/dev/null || true
  run_user daemon-reload 2>/dev/null || true
  run_user set-property org.gnome.Shell@wayland.service CPUWeight=100 MemoryLow=0 2>/dev/null || true
  echo "✅ Reverted. (A re-login fully clears the user-scope drop-in.)"
  ;;

*)
  echo "Usage: $0 [apply|verify|revert]" >&2; exit 2 ;;
esac
