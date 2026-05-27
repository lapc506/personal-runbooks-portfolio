#!/usr/bin/env bash
# Read-only diagnosis for the NVIDIA Xid 56 display-freeze runbook.
# Scans recent boots for Xid errors, rules thermal in/out, and reports the
# configuration levers (PRIME mode, GSP firmware, which GPU the compositor uses).
# Safe to run anytime — touches nothing.
set -uo pipefail

hr(){ printf '\n===== %s =====\n' "$1"; }

hr "GPU(s) and driver"
lspci -nnk 2>/dev/null | grep -iEA2 'vga|3d' || true
nvidia-smi --query-gpu=name,driver_version,temperature.gpu,utilization.gpu --format=csv 2>/dev/null || echo "nvidia-smi unavailable"

hr "Xid errors per recent boot (the recurrence signal)"
printf '%-6s %-6s\n' 'boot' 'Xid'
for b in 0 -1 -2 -3 -4 -5; do
  n=$(timeout 25 journalctl -b "$b" -k --no-pager -q -g 'Xid' 2>/dev/null | wc -l)
  printf '%-6s %-6s\n' "$b" "${n:-?}"
done
echo "--- Xid lines, current + previous boot ---"
for b in 0 -1; do
  timeout 25 journalctl -b "$b" -k --no-pager -q -o short -g 'Xid|fallen off the bus' 2>/dev/null
done

hr "Thermal events on the crashed boot (boot -1) — expect NONE at runtime"
timeout 25 journalctl -b -1 -k --no-pager -q -g 'mce:|throttl|clamping|critical temp|over.?temp|temperature above' 2>/dev/null \
  || true
echo "(empty above = no runtime thermal/throttle event = not overheating)"

hr "Clean shutdown vs hard freeze on boot -1"
if timeout 25 journalctl -b -1 --no-pager -q -g 'systemd-shutdown' 2>/dev/null | grep -q .; then
  echo "found systemd-shutdown → ended cleanly"
else
  echo "no systemd-shutdown trace → ended abruptly (freeze / hard reset)"
fi

hr "Configuration levers"
echo "PRIME mode      : $(prime-select query 2>/dev/null || echo 'prime-select n/a')"
echo "kernel cmdline  : $(cat /proc/cmdline)"
echo "GSP firmware    : $(nvidia-smi -q 2>/dev/null | awk -F: '/GSP Firmware Version/{gsub(/^ +/,"",$2);print $2; f=1} END{if(!f)print "unknown"}')"
echo "  (a version = GSP ON; 'N/A' = GSP off)"

hr "Which GPU is the compositor on?"
apps=$(nvidia-smi --query-compute-apps=pid,process_name --format=csv,noheader 2>/dev/null)
# graphics apps don't always show under compute-apps; also scan the table
gfx=$(nvidia-smi 2>/dev/null | grep -iE 'gnome-shell|mutter|Xorg|gnome-shell-cal')
if echo "$apps$gfx" | grep -qiE 'gnome-shell|mutter|Xorg'; then
  echo "COMPOSITOR IS ON THE dGPU → Experiment 1 (prime on-demand) applies."
  echo "$apps$gfx"
else
  echo "compositor does not appear on the NVIDIA GPU (good, or already on-demand)."
fi
