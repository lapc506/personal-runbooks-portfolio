#!/usr/bin/env bash
# Read-only diagnosis for the mutter panel-drop / false-freeze runbook.
# Checks the four signatures (panel dropped from config, EC reset, monitor
# reconfig storm, broken backlight accounting), rules the other two crash
# families in/out (Xid, kernel-silence starvation), and maps which GPU drives
# which connector. Safe to run anytime — touches nothing.
#
# Usage:  ./diagnose-panel-drop-false-freeze.sh        # current boot
#         ./diagnose-panel-drop-false-freeze.sh -1     # the boot that "froze"
set -uo pipefail

BOOT="${1:-0}"
hr(){ printf '\n===== %s =====\n' "$1"; }
jc(){ timeout 30 journalctl -b "$BOOT" --no-pager -q "$@" 2>/dev/null; }

echo "Analyzing boot: $BOOT  (pass -1 to analyze the boot that 'froze')"

hr "Signature 1 — panel dropped from the active monitor configuration"
hits=$(jc -g 'no configuration which is-current')
if [ -n "$hits" ]; then
  echo "$hits"
  echo ">>> MATCH — mutter dropped a monitor from the active config. This runbook applies."
else
  echo "(none) — panel was never dropped from the config on this boot"
fi

hr "Signature 2 — Embedded Controller reset (internal USB-HID re-enumeration)"
echo "runtime USB disconnects (boot-time enumeration has none — any line here is an event):"
jc -k -g 'USB disconnect' || echo "(none)"
echo "GIGABYTE USB-HID (re-)enumerations — first burst at boot is normal; a later burst = EC reset:"
jc -k -g 'Manufacturer: GIGABYTE' | awk '{print $1, $2, $3}' | uniq -c || true
echo "(a runtime disconnect+re-enumeration of the laptop's own HID = EC reset; on AC-powered"
echo " incidents this is the trace the electrical transient leaves even when ADP1 never drops)"

hr "Signature 3 — monitor reconfiguration storm"
n=$(jc | grep -c 'Overwriting existing binding' || true)
echo "keybinding re-grab lines this boot: ${n:-0}"
echo "(mutter re-grabs keybindings on every monitor layout change; bursts of these within"
echo " seconds of each other = displays flapping. Timestamps:)"
jc -g 'Overwriting existing binding' | awk '{print $1, $2, $3}' | uniq -c | sort -rn | head -8 || true

hr "Signature 4 — backlight accounting broken (gsd-power)"
jc -g 'gsd_power_backlight_percentage_to_abs' || echo "(none)"

hr "Counter-evidence A — did AC actually drop? (expect NONE if charger is on a UPS)"
jc -k -g 'ADP1' || echo "(no ADP1 events at runtime)"

hr "Counter-evidence B — rule out the Xid family (sibling runbook)"
x=$(jc -k -g 'Xid|fallen off the bus')
if [ -n "$x" ]; then
  echo "$x"
  echo ">>> Xid present → see ../Ubuntu_NVIDIA_Xid56_Display_Freeze_Under_Load instead"
else
  echo "(no Xid) — not the dGPU-wedge family"
fi

hr "Counter-evidence C — was the system actually alive? (journal tail of this boot)"
last=$(jc -o short | tail -1)
echo "last journal line: ${last:-?}"
if jc -g 'systemd-shutdown' | grep -q .; then
  echo "systemd-shutdown present → ended cleanly"
else
  echo "no systemd-shutdown trace → ended abruptly (hard power-off). If signatures 1-4"
  echo "matched and the journal kept flowing after the 'freeze', the power-off was likely"
  echo "unnecessary: the console was invisible, not frozen."
fi

hr "GPU/connector topology (which GPU drives which output, right now)"
for c in /sys/class/drm/card*-*/; do
  dev=$(readlink -f "$c/../device" 2>/dev/null)
  printf '%-28s %-12s (PCI %s)\n' "$(basename "$c")" "$(cat "$c/status" 2>/dev/null)" "${dev##*/}"
done
echo "fbcon primary device:"
dmesg 2>/dev/null | grep -m1 'is primary device' || journalctl -b 0 -k -q -g 'is primary device' --no-pager | head -1
echo "(the VT console renders on the primary fb — if that is the eDP/i915 fb and the panel"
echo " is black, a VT switch produces an INVISIBLE console, not a freeze)"

hr "Backlight state (now)"
for b in /sys/class/backlight/*/; do
  echo "$(basename "$b"): $(cat "$b/brightness" 2>/dev/null)/$(cat "$b/max_brightness" 2>/dev/null)"
done

hr "Stored monitor configs (does any saved layout disable the panel?)"
python3 - <<'PY' 2>/dev/null || echo "(could not parse ~/.config/monitors.xml)"
import os
try:
    import defusedxml.ElementTree as ET   # hardened parser if available
except ImportError:
    import xml.etree.ElementTree as ET   # local, user-owned file; acceptable fallback
p = os.path.expanduser('~/.config/monitors.xml')
try:
    root = ET.parse(p).getroot()
except Exception as e:
    print('no monitors.xml:', e); raise SystemExit
for i, cfg in enumerate(root.findall('configuration')):
    mons = [c.text for c in cfg.findall('logicalmonitor/monitor/monitorspec/connector')]
    dis  = [c.text for c in cfg.findall('disabled/monitorspec/connector')]
    print(f'config {i}: active={mons} disabled={dis}')
print('(a config with the eDP in "disabled" would explain the drop legitimately;')
print(' none = mutter raced into an invalid state — the runbook root cause)')
PY
