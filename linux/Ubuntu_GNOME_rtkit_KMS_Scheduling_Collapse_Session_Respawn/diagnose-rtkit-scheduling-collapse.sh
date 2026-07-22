#!/usr/bin/env bash
# diagnose-rtkit-scheduling-collapse.sh
#
# Read-only. Mutates nothing. Decides whether a "the whole Ubuntu session
# crashed" event was the rtkit-canary-starvation / GNOME-session-respawn family
# (this runbook) rather than a reboot, a GPU wedge (Xid56), a flip-event-timeout,
# or a mutter panel-drop.
#
# Usage:
#   ./diagnose-rtkit-scheduling-collapse.sh        # current boot (0)
#   ./diagnose-rtkit-scheduling-collapse.sh -1     # a previous boot, if it rebooted
#
# Exit 0 if this runbook applies, 1 otherwise.

set -u
BOOT="${1:-0}"
J=(journalctl -b "$BOOT" --no-pager)
JK=(journalctl -b "$BOOT" -k --no-pager)

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
no()   { printf '  \033[31m✗\033[0m %s\n' "$1"; }
info() { printf '    %s\n' "$1"; }

applies=0

bold "== Boot / reboot check (this family never reboots) =="
if [ "$BOOT" = "0" ]; then
  echo "  uptime since: $(uptime -s)"
  nboots=$(journalctl --list-boots 2>/dev/null | wc -l)
  info "recorded boots: $nboots (a session respawn does NOT add a boot)"
  ok "inspecting current boot — if the 'crash' left you on the same boot, it was a respawn, not a reboot"
else
  no "inspecting a PREVIOUS boot ($BOOT) — only relevant if the machine actually rebooted (then it is probably a different family)"
fi
echo

bold "== Primary signature: rtkit-daemon SIGKILLed =="
rtkill=$("${J[@]}" 2>/dev/null | grep -cE 'rtkit-daemon\.service: Main process exited, code=killed')
if [ "$rtkill" -gt 0 ]; then
  ok "rtkit-daemon killed ${rtkill}× this boot"
  "${J[@]}" 2>/dev/null | grep -E 'rtkit-daemon\.service: Main process exited, code=killed' | tail -4 | sed 's/^/    /'
  applies=1
else
  no "no rtkit-daemon SIGKILL found — this family's hinge event is absent"
fi
echo

bold "== Corroborating: mutter KMS thread lost realtime scheduling =="
kmsfail=$("${J[@]}" 2>/dev/null | grep -cE "Failed to make thread 'KMS thread' realtime scheduled")
if [ "$kmsfail" -gt 0 ]; then
  ok "KMS thread RT-scheduling failures: ${kmsfail}"
else
  info "no 'KMS thread' RT failures (weaker signal; rtkit SIGKILL is the primary one)"
fi
echo

bold "== The load lever: zram churn hogging CPU (swappiness=150 cost) =="
churn=$("${JK[@]}" 2>/dev/null | grep -cE 'swap_(discard|reclaim)_work hogged CPU')
if [ "$churn" -gt 0 ]; then
  ok "zram workqueue CPU hogs: ${churn} (memory-pressure lever, independent of the swipe)"
  "${JK[@]}" 2>/dev/null | grep -E 'swap_(discard|reclaim)_work hogged CPU' | tail -3 | sed 's/^/    /'
  info "current vm.swappiness = $(cat /proc/sys/vm/swappiness 2>/dev/null) (runbook suggests 120 if this is high)"
else
  info "no swap_*_work hogs this boot (the swipe/reverse-PRIME lever may be dominant instead)"
fi
echo

bold "== The flip lever: reverse-PRIME head map + workspace-animation churn =="
for c in /sys/class/drm/card*-*; do
  [ -e "$c/status" ] || continue
  st=$(cat "$c/status" 2>/dev/null)
  [ "$st" = "connected" ] || continue
  base=$(basename "$c")
  card=${base%%-*}   # card1-DP-1 -> card1
  drv=$(grep -m1 '^DRIVER=' "/sys/class/drm/$card/device/uevent" 2>/dev/null | cut -d= -f2)
  case "$drv" in
    i915)   role="i915 → reverse-PRIME sink (per-frame GPU copy)";;
    nvidia) role="nvidia → DIRECT scanout (primary GPU)";;
    *)      role="$drv";;
  esac
  info "$base  connected  [$role]"
done
wsanim=$("${J[@]}" 2>/dev/null | grep -c 'workspaceAnimation_MonitorGroup')
info "workspace-switch animation churn events this boot: ${wsanim} (3-finger swipe; one MonitorGroup per monitor)"
if [ "$(gsettings get org.gnome.desktop.interface enable-animations 2>/dev/null)" = "true" ]; then
  info "enable-animations=true → workspace switch still animates (runbook §1: set false for a static switch)"
else
  ok "enable-animations=false → workspace switch is static (flip storm mitigated)"
fi
echo

bold "== Rule OUT the other three families (must be ~absent) =="
gpuerr=$("${JK[@]}" 2>/dev/null | grep -cE 'Xid|nv_drm_atomic_commit|Flip event timeout')
if [ "$gpuerr" -eq 0 ]; then
  ok "0 GPU errors (no Xid / nv_drm_atomic_commit / flip-timeout) → not the Xid56 or Flip-Event-Timeout family"
else
  no "GPU errors present (${gpuerr}) → check Xid56 / Flip-Event-Timeout families FIRST — those outrank this one"
fi
paneldrop=$("${J[@]}" 2>/dev/null | grep -c 'no configuration which is-current')
info "panel-drop signature ('no configuration which is-current'): ${paneldrop} (may be >0 from a separate earlier event; not this family's trigger)"
echo

bold "== Verdict =="
if [ "$applies" -eq 1 ] && [ "$gpuerr" -eq 0 ]; then
  ok "This runbook APPLIES: rtkit scheduling collapse → GNOME session respawn (no reboot, GPU healthy)."
  echo "     → Recover work with 'claude --resume' (nothing was lost). Apply mitigations §1 (static switch) / §2 (swappiness 120)."
  exit 0
else
  no "This runbook does NOT cleanly apply — see the Decision tree in README.md."
  exit 1
fi
