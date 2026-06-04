#!/usr/bin/env bash
# diagnose-compositor-starvation.sh — READ-ONLY.
#
# Decides whether THIS runbook applies: GNOME Shell SIGTRAP via an Xwayland
# BadWindow under host CPU/IO starvation — as opposed to the GPU-fault runbooks
# (Xid56, Flip_Event_Timeout) or OOM. Exits 0 if it applies, 1 otherwise, so you
# don't apply scheduler-priority changes for an unrelated crash.
#
# No root needed. No side effects.
set -uo pipefail

YES=0   # accumulates positive signals for "this runbook applies"
say()  { printf '%s\n' "$*"; }
hdr()  { printf '\n=== %s ===\n' "$*"; }

# Look at the most recent crashed boot. Default to -1; allow override: $1 = boot offset.
BOOT="${1:--1}"

hdr "Boot under inspection: $BOOT  ($(journalctl --list-boots 2>/dev/null | grep " ${BOOT#-}\? " | head -1))"
journalctl --list-boots 2>/dev/null | tail -3

# --- 1. Positive signature: SIGTRAP + X error + BadWindow ---
hdr "1. Crash signature (SIGTRAP via Xwayland BadWindow)"
sig=$(journalctl -b "$BOOT" --no-pager 2>/dev/null \
      | grep -cE 'crashed with signal 5|Received an X Window System error|BadWindow')
say "  matches (signal 5 / X error / BadWindow): $sig"
if [ "$sig" -ge 2 ]; then say "  -> PRESENT"; YES=$((YES+1)); else say "  -> not present"; fi

# --- 2. Starvation canaries in userspace ---
hdr "2. Userspace starvation canaries"
slow=$(journalctl -b "$BOOT" --no-pager 2>/dev/null | grep -c 'your system is too slow')
hc=$(journalctl -b "$BOOT" --no-pager 2>/dev/null | grep -c 'exceeded timeout')
say "  libinput 'your system is too slow': $slow"
say "  healthcheck 'exceeded timeout'    : $hc"
if [ "$slow" -ge 1 ] || [ "$hc" -ge 2 ]; then say "  -> PRESENT"; YES=$((YES+1)); else say "  -> not present"; fi

# --- 3. Rule OUT the GPU runbooks and OOM (must be ~0) ---
hdr "3. Differential — these MUST be ~0 for this runbook to apply"
xid=$(journalctl -b "$BOOT" -k --no-pager 2>/dev/null | grep -c 'Xid')
flip=$(journalctl -b "$BOOT" --no-pager 2>/dev/null | grep -ciE 'nv_drm_atomic_commit|Flip event timeout')
nvm=$(journalctl -b "$BOOT" --no-pager 2>/dev/null | grep -ciE 'nvidia-modeset.*ERROR')
oom=$(journalctl -b "$BOOT" -k --no-pager 2>/dev/null | grep -ciE 'Out of memory|oom-killer|Killed process')
stall=$(journalctl -b "$BOOT" -k --no-pager 2>/dev/null | grep -ciE 'hung_task|blocked for more than|rcu.*stall|soft lockup')
say "  NVIDIA Xid (-> Xid56 runbook)              : $xid"
say "  nv_drm_atomic_commit/Flip (-> Flip runbook): $flip"
say "  nvidia-modeset ERROR                        : $nvm"
say "  OOM kill                                    : $oom"
say "  kernel stall (hung_task/rcu/softlockup)     : $stall"
if [ "$xid" -eq 0 ] && [ "$flip" -eq 0 ] && [ "$oom" -eq 0 ]; then
  say "  -> clean: not a GPU fault, not OOM"; YES=$((YES+1))
else
  say "  -> a GPU/OOM signal is present: a DIFFERENT runbook likely applies"
fi

# --- 4. Context: PRIME mode, compositor GPU, current weights, live PSI ---
hdr "4. Current configuration (context, not pass/fail)"
say "  PRIME mode      : $(prime-select query 2>/dev/null || echo '(prime-select n/a)')"
gs=$(pgrep -x gnome-shell | head -1)
say "  gnome-shell PID : ${gs:-<not running>}"
if [ -n "${gs:-}" ]; then
  if grep -q libEGL_nvidia "/proc/$gs/maps" 2>/dev/null && [ "$(prime-select query 2>/dev/null)" = nvidia ]; then
    say "  compositor GPU  : NVIDIA dGPU (PRIME=nvidia)"
  else
    say "  compositor GPU  : Intel iGPU (PRIME=on-demand; libEGL_nvidia may be mapped via glvnd)"
  fi
fi
say "  user.slice  CPUWeight : $(systemctl show user.slice -p CPUWeight --value 2>/dev/null)"
say "  docker.svc  CPUWeight : $(systemctl show docker.service -p CPUWeight --value 2>/dev/null)"
say "  gnome-shell CPUWeight : $(systemctl --user show org.gnome.Shell@wayland.service -p CPUWeight --value 2>/dev/null)"
say "  PSI cpu : $(cat /proc/pressure/cpu 2>/dev/null | head -1)"
say "  PSI io  : $(cat /proc/pressure/io  2>/dev/null | head -1)"

# --- Verdict ---
hdr "Verdict"
if [ "$YES" -ge 3 ]; then
  say "✅ THIS runbook applies (SIGTRAP+BadWindow + starvation canaries, GPU/OOM ruled out)."
  say "   Next: sudo bash ./protect-compositor-scheduling.sh"
  exit 0
else
  say "❌ This runbook does NOT clearly apply (score $YES/3)."
  say "   If Xid>0 -> Ubuntu_NVIDIA_Xid56_Display_Freeze_Under_Load"
  say "   If flip>0 -> Ubuntu_NVIDIA_Wayland_Flip_Event_Timeout"
  say "   If oom>0  -> investigate memory, not scheduling."
  exit 1
fi
