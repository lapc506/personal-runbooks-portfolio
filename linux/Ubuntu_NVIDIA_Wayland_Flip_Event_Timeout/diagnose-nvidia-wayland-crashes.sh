#!/usr/bin/env bash
# diagnose-nvidia-wayland-crashes.sh
#
# Purpose: determine whether "NVIDIA Wayland Flip Event Timeout" runbook
# applies to the current machine before running the fix script.
#
# Exit 0: symptoms match — safe to run enable-nvidia-drm-modeset.sh.
# Exit 1: symptoms don't match — this runbook is not your fix.
#
# No sudo required. Read-only diagnostic.

set -uo pipefail

ok()   { printf '\e[1;32m[ok]\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m[warn]\e[0m %s\n' "$*"; }
bad()  { printf '\e[1;31m[!!]\e[0m %s\n' "$*"; }
info() { printf '\e[1;34m[..]\e[0m %s\n' "$*"; }

SCORE=0
MAX=5

echo "=============================================================="
echo "  Diagnose: does NVIDIA-Wayland-Flip-Event-Timeout apply here?"
echo "=============================================================="
echo

# ----- 1. NVIDIA PCI device present ----------------------------------------

info "Check 1/5: NVIDIA PCI device present?"
if lspci 2>/dev/null | grep -qi 'vga\|3d\|display' | grep -qi 'nvidia' \
   || lspci 2>/dev/null | grep -iE 'vga|3d|display' | grep -qi 'nvidia'; then
    ok "NVIDIA GPU detected."
    SCORE=$((SCORE+1))
else
    bad "No NVIDIA GPU detected. This runbook does not apply."
    echo
    echo "Exiting with code 1."
    exit 1
fi
echo

# ----- 2. nvidia_drm module loaded + proprietary/open driver ---------------

info "Check 2/5: proprietary/open nvidia_drm module loaded? (not nouveau)"
if lsmod | grep -q '^nvidia_drm '; then
    ok "nvidia_drm is loaded."
    SCORE=$((SCORE+1))
elif lsmod | grep -q '^nouveau '; then
    bad "nouveau is loaded, not nvidia_drm. This runbook does not apply to nouveau."
    echo "    For nouveau flip-event-timeouts, investigate NOUVEAU_PSTATE or switch to the proprietary driver."
    exit 1
else
    warn "Neither nvidia_drm nor nouveau is loaded. GPU may be fully powered off (runtime PM)."
    warn "Proceeding with remaining checks."
fi
echo

# ----- 3. nvidia-drm.modeset=1 on kernel cmdline? --------------------------

info "Check 3/5: is nvidia-drm.modeset=1 already on the kernel command line?"
CMDLINE=$(cat /proc/cmdline)
if grep -qE 'nvidia-drm\.modeset=1' <<<"$CMDLINE"; then
    warn "nvidia-drm.modeset=1 is ALREADY on the cmdline."
    warn "The primary fix is already applied. If you still see flip-event-timeouts,"
    warn "the root cause is something else — investigate the hardware / driver version."
    echo "    Current cmdline: $CMDLINE"
else
    ok "nvidia-drm.modeset is NOT on the cmdline — runbook applies."
    SCORE=$((SCORE+1))
fi
echo

# ----- 4. Historical flip-event-timeouts in journal? -----------------------

info "Check 4/5: flip-event-timeouts in the previous boot's journal?"
if ! command -v journalctl >/dev/null; then
    warn "journalctl not available — skipping historical check."
else
    COUNT=$(journalctl -b -1 --no-pager 2>/dev/null | grep -c 'nv_drm_atomic_commit' || true)
    if [[ "$COUNT" -ge 3 ]]; then
        ok "Found $COUNT 'nv_drm_atomic_commit' errors in previous boot. Strong match."
        SCORE=$((SCORE+1))
    elif [[ "$COUNT" -ge 1 ]]; then
        warn "Found $COUNT 'nv_drm_atomic_commit' errors in previous boot. Weak match."
        warn "Could be an isolated incident — inspect manually before applying the fix."
    else
        info "No 'nv_drm_atomic_commit' errors in previous boot."
        info "Check current boot too:"
        CUR=$(journalctl -b 0 --no-pager 2>/dev/null | grep -c 'nv_drm_atomic_commit' || true)
        if [[ "$CUR" -ge 1 ]]; then
            ok "Found $CUR in current boot. Match."
            SCORE=$((SCORE+1))
        else
            info "No historical flip-event-timeouts found. May be a preventative install."
        fi
    fi
fi
echo

# ----- 5. modprobe.d is the only place modeset is configured? --------------

info "Check 5/5: is modprobe.d the only place modeset=1 is configured?"
MODPROBE_FILE=/etc/modprobe.d/nvidia-graphics-drivers-kms.conf
if [[ -f "$MODPROBE_FILE" ]] && grep -qE '^\s*options\s+nvidia_drm\s+.*modeset=1' "$MODPROBE_FILE"; then
    ok "modprobe.d requests modeset=1 at $MODPROBE_FILE"
    ok "  (this runbook moves it to cmdline, which is more reliable)"
    SCORE=$((SCORE+1))
else
    warn "modprobe.d does NOT request modeset=1. Your config may differ from the test machine."
    warn "The fix script still works — it adds the token to cmdline regardless — but verify"
    warn "there's no other mechanism already disabling modeset."
fi
echo

# ----- Verdict --------------------------------------------------------------

echo "=============================================================="
echo "  Score: $SCORE / $MAX matching conditions"
echo

if [[ $SCORE -ge 3 ]]; then
    ok "This runbook applies. Proceed with: sudo bash ./enable-nvidia-drm-modeset.sh"
    echo "=============================================================="
    exit 0
else
    warn "Weak match. This runbook MAY help but other causes are more likely."
    warn "Inspect manually before applying the fix:"
    warn "  journalctl -b -1 --no-pager | grep -E 'nvidia|drm|gnome-shell'"
    warn "  cat /proc/cmdline"
    warn "  lsmod | grep -E 'nvidia|nouveau'"
    echo "=============================================================="
    exit 1
fi
