#!/usr/bin/env bash
# Read-only diagnostic for the zram + systemd-oomd memory-pressure setup.
# Reports the current state of: zram, swap devices, swappiness, and the two
# oomd knobs (per-user pressure limit + global pressure duration). Prints what
# this runbook would CHANGE vs. what is already in place. Mutates nothing.
#
# Usage:  ./diagnose-memory-pressure.sh        (current boot)
#         ./diagnose-memory-pressure.sh oomd   (just the oomd recent kills)
set -u

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
miss() { printf '  \033[31m✗\033[0m %s\n' "$1"; }

bold "== RAM / swap snapshot =="
free -h
echo

bold "== zram =="
if lsmod | grep -q '^zram'; then
  ok "zram module loaded"
  zramctl 2>/dev/null || warn "zramctl produced no devices"
else
  miss "zram module NOT loaded — this runbook is not applied yet"
fi
if dpkg -l 2>/dev/null | grep -q systemd-zram-generator; then
  ok "systemd-zram-generator installed"
else
  miss "systemd-zram-generator NOT installed (sudo apt install systemd-zram-generator)"
fi
if [ -f /etc/systemd/zram-generator.conf ]; then
  ok "/etc/systemd/zram-generator.conf present"
else
  miss "/etc/systemd/zram-generator.conf missing"
fi
echo

bold "== swap devices (priority matters: zram must outrank /swap.img) =="
swapon --show 2>/dev/null || warn "no swap active"
echo

bold "== swappiness / page-cluster =="
sw=$(cat /proc/sys/vm/swappiness 2>/dev/null)
pc=$(cat /proc/sys/vm/page-cluster 2>/dev/null)
printf '  vm.swappiness = %s   ' "$sw"
if [ "${sw:-0}" -ge 100 ]; then ok "(zram-appropriate, high)"; else warn "(low — disk-swap value; raise for zram)"; fi
printf '  vm.page-cluster = %s\n' "$pc"
echo

bold "== systemd-oomd: per-user pressure limit (the knob that killed chrome) =="
lim=$(systemctl cat user@.service 2>/dev/null | grep -i ManagedOOMMemoryPressureLimit | tail -1)
printf '  user@.service -> %s\n' "${lim:-<unset>}"
echo

bold "== systemd-oomd: global pressure duration =="
systemd-analyze cat-config systemd/oomd.conf 2>/dev/null | grep -v '^#' | grep -v '^$'
echo

bold "== oomd live view (oomctl) =="
oomctl 2>/dev/null | sed 's/^/  /'
echo

bold "== recent oomd kills (last boot) =="
journalctl -b 0 -u systemd-oomd --no-pager 2>/dev/null | grep -i 'killed\|pressure' | tail -10 \
  || warn "no oomd kill lines this boot"
