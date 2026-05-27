#!/usr/bin/env bash
# Experiment 1: move the GNOME/mutter compositor OFF the discrete NVIDIA GPU by
# switching Ubuntu PRIME to on-demand. This is the highest-leverage, most
# reversible mitigation for the Xid 56 display-freeze (see README).
#
# Needs sudo (prime-select writes /etc/X11 + initramfs config). Does NOT reboot —
# you reboot when convenient. Reversible with: sudo prime-select nvidia
set -euo pipefail

echo "== Experiment 1: PRIME on-demand =="

if ! command -v prime-select >/dev/null 2>&1; then
  echo "prime-select not found (install nvidia-prime). Aborting." >&2
  exit 1
fi

current="$(prime-select query 2>/dev/null || echo unknown)"
echo "Current PRIME mode: $current"

case "$current" in
  on-demand)
    echo "Already on-demand. Nothing to apply."
    echo "If freezes persist in this mode, that is evidence Experiment 1 does NOT"
    echo "solve it → proceed to Experiment 2 (disable GSP firmware)."
    exit 0 ;;
  nvidia) : ;;  # the target case
  *)
    echo "Unexpected mode '$current'. Review manually before switching." >&2
    exit 1 ;;
esac

echo "Switching: nvidia → on-demand (sudo required)…"
sudo prime-select on-demand

echo
echo "Applied. New mode: $(prime-select query)"
echo "ACTION REQUIRED: reboot to activate. After reboot, verify with:"
echo "  prime-select query                                                    # on-demand"
echo "  nvidia-smi --query-compute-apps=pid,process_name --format=csv,noheader  # gnome-shell absent"
echo "  journalctl -b -k -g 'Xid'                                             # ideally empty under load"
echo
echo "To run a specific app on the dGPU afterwards:"
echo "  __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia <app>"
echo "Rollback: sudo prime-select nvidia && reboot"
