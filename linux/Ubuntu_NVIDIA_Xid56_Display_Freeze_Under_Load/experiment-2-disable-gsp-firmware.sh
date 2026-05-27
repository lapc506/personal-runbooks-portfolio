#!/usr/bin/env bash
# Experiment 2: disable NVIDIA GSP firmware (NVreg_EnableGpuFirmware=0).
# ONLY run this if Experiment 1 (prime on-demand) failed to stop the Xid 56
# freezes. More invasive (rebuilds initramfs) and may be ignored on Ada GPUs.
#
# Needs sudo. Does NOT reboot. Reversible (see bottom).
set -euo pipefail

DROPIN=/etc/modprobe.d/zz-disable-gsp.conf

echo "== Experiment 2: disable GSP firmware =="

if ! modinfo nvidia 2>/dev/null | grep -q 'NVreg_EnableGpuFirmware'; then
  echo "Driver does not expose NVreg_EnableGpuFirmware. Aborting." >&2
  exit 1
fi

cur="$(nvidia-smi -q 2>/dev/null | awk -F: '/GSP Firmware Version/{gsub(/^ +/,"",$2);print $2}')"
echo "Current GSP firmware: ${cur:-unknown}  (a version = ON)"

echo "Writing $DROPIN (sudo)…"
printf '# Experiment 2 (Xid 56 runbook): route GPU mgmt off the GSP path\noptions nvidia NVreg_EnableGpuFirmware=0\n' \
  | sudo tee "$DROPIN" >/dev/null

echo "Rebuilding initramfs (sudo)…"
sudo update-initramfs -u

echo
echo "Applied. ACTION REQUIRED: reboot, then VERIFY it actually took effect:"
echo "  nvidia-smi -q | grep -i 'GSP Firmware'"
echo "    → 'N/A'           = GSP disabled (good, observe under load)"
echo "    → still a version = IGNORED on this Ada GPU; this lever does not apply → ROLL BACK"
echo
echo "Rollback: sudo rm $DROPIN && sudo update-initramfs -u && reboot"
