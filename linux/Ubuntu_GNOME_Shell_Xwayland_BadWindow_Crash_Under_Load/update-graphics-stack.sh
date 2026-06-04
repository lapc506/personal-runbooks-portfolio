#!/usr/bin/env bash
# update-graphics-stack.sh — close pending updates (driver/shell/kernel) and turn
# on sysstat/PSI history so the NEXT incident is measurable. Reboot afterwards
# (new kernel + NVIDIA modules). See README.md, "Experiment 2".
#
#   sudo bash update-graphics-stack.sh           # snapshot + full-upgrade + enable sysstat
#   sudo bash update-graphics-stack.sh dry-run    # show what WOULD upgrade, change nothing
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "ERROR: run with sudo." >&2; exit 2; }

STAMP="$(date +%Y%m%d-%H%M%S)"
SNAP="/var/backups/dpkg-selections.$STAMP"
mode="${1:-apply}"

echo "==> Snapshotting current package selections -> $SNAP"
mkdir -p /var/backups
dpkg --get-selections > "$SNAP"
echo "    (rollback reference; apt upgrades are not auto-reverted)"

echo "==> apt-get update"
apt-get update

echo "==> Graphics/driver/kernel packages with updates pending:"
apt list --upgradable 2>/dev/null | grep -iE 'mutter|gnome-shell|xwayland|xorg|mesa|nvidia|linux-(image|modules|headers)|gjs|libgl' || echo "  (none)"

if [ "$mode" = "dry-run" ]; then
  echo "==> DRY RUN — full-upgrade simulation:"
  apt-get -s full-upgrade | tail -25
  echo "==> Dry run only. Nothing changed."
  exit 0
fi

echo "==> Full upgrade (this pulls the NVIDIA driver, gnome-shell, kernel + nvidia modules)"
DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade

echo "==> Enabling sysstat collection (so 'sar' records CPU/IO/load for the next incident)"
if [ -f /etc/default/sysstat ]; then
  sed -i 's/^ENABLED=.*/ENABLED="true"/' /etc/default/sysstat
else
  echo 'ENABLED="true"' > /etc/default/sysstat
fi
systemctl enable --now sysstat 2>/dev/null || true
# Tighten the sampling interval to 2 min so bursts are captured (default is 10 min).
if [ -f /etc/cron.d/sysstat ]; then
  sed -i 's#5-55/10#*/2#; s#\b10\b#2#' /etc/cron.d/sysstat 2>/dev/null || true
fi

echo
echo "✅ Done. Snapshot: $SNAP"
echo "   NOTE: 'sar' ships INSIDE the 'sysstat' package — there is no separate 'sar' package."
echo "   Query history later with:  sar -u   (CPU)   sar -b   (IO)   sar -q   (load/runqueue)"
echo "   ⚠ Reboot to activate the new kernel + NVIDIA modules:  sudo reboot"
