#!/usr/bin/env bash
# experiment-2-disable-gsp-firmware.sh
#
# Purpose: disable the NVIDIA GSP (GPU System Processor) firmware path by adding
# `nvidia.NVreg_EnableGpuFirmware=0` to the kernel command line, so it binds at
# module-load time regardless of whether nvidia.ko is loaded from initramfs or by
# systemd-modules-load. We use the CMDLINE method (not /etc/modprobe.d) on purpose:
# the sibling runbook ../Ubuntu_NVIDIA_Wayland_Flip_Event_Timeout proved that
# modprobe.d options are read too late for an initramfs-loaded nvidia module.
#
# Experiment 2 of the Xid 56 display-freeze runbook. ONLY run after Experiment 1
# (prime on-demand) has failed to stop the freezes — one variable at a time.
#
# Usage:
#   sudo bash experiment-2-disable-gsp-firmware.sh           # apply
#   sudo bash experiment-2-disable-gsp-firmware.sh revert    # undo
#   bash      experiment-2-disable-gsp-firmware.sh verify    # check (no root needed)
#
# Requires sudo for apply/revert. Idempotent. Requires reboot to take effect.
# ⚠ Ada caveat: on RTX 40-series GSP may be mandatory; the driver can IGNORE this
#   token. The 'verify' step tells you whether it actually took — if not, revert.

set -euo pipefail

log()  { printf '\e[1;34m[exp2]\e[0m %s\n' "$*"; }
ok()   { printf '\e[1;32m[ok]\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m[warn]\e[0m %s\n' "$*"; }
fail() { printf '\e[1;31m[fail]\e[0m %s\n' "$*"; exit 1; }

GRUB_FILE=/etc/default/grub
TOKEN="nvidia.NVreg_EnableGpuFirmware=0"
MODE="${1:-apply}"

gsp_state() { nvidia-smi -q 2>/dev/null | awk -F: '/GSP Firmware Version/{gsub(/^ +/,"",$2);print $2}'; }

# ---------- verify (read-only) ---------------------------------------------
if [[ "$MODE" == "verify" ]]; then
    log "Verifying GSP state"
    token_on_cmdline=$(grep -oE 'nvidia\.NVreg_EnableGpuFirmware=[01]' /proc/cmdline || true)
    echo "  /proc/cmdline token : ${token_on_cmdline:-(absent)}"
    state="$(gsp_state)"
    echo "  GSP Firmware Version: ${state:-unknown}"
    if [[ -z "$token_on_cmdline" || "$token_on_cmdline" == *=1 ]]; then
        warn "Token not applied (yet). Run 'sudo bash $0 apply' then reboot before verifying."
    elif [[ "$state" == "N/A" ]]; then
        ok "GSP is DISABLED — the toggle took effect. Observe under load for Xid 56."
    elif [[ -n "$state" ]]; then
        warn "Token IS on cmdline but GSP still reports a version → IGNORED (expected on Ada/RTX 40)."
        warn "This lever does not apply to this GPU. Revert: sudo bash $0 revert"
    else
        warn "Could not read GSP state (is the driver loaded?)."
    fi
    exit 0
fi

[[ $EUID -eq 0 ]] || fail "apply/revert need root. Re-run with: sudo bash $0 $MODE"
[[ -f "$GRUB_FILE" ]] || fail "$GRUB_FILE not found. Is this a GRUB-based system?"
command -v update-grub >/dev/null || fail "update-grub not in PATH (Ubuntu/Debian expected)."
command -v update-initramfs >/dev/null || fail "update-initramfs not in PATH."
modinfo nvidia 2>/dev/null | grep -q 'NVreg_EnableGpuFirmware' \
    || fail "Driver does not expose NVreg_EnableGpuFirmware. Aborting."

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="${GRUB_FILE}.bak.${TIMESTAMP}"
CURRENT_LINE=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE" || true)
[[ -n "$CURRENT_LINE" ]] || fail "No GRUB_CMDLINE_LINUX_DEFAULT= line in $GRUB_FILE."
CURRENT_VALUE=$(sed -E 's/^GRUB_CMDLINE_LINUX_DEFAULT="?([^"]*)"?$/\1/' <<<"$CURRENT_LINE")

echo "=============================================================="
echo "  Experiment 2 — GSP firmware toggle ($MODE)"
echo "=============================================================="
echo "  current cmdline: $(cat /proc/cmdline)"
echo "  current GSP    : $(gsp_state || echo unknown)  (a version = ON)"
echo

# ---------- compute new GRUB_CMDLINE value ---------------------------------
if [[ "$MODE" == "apply" ]]; then
    if grep -qw "$TOKEN" <<<" $CURRENT_VALUE "; then
        ok "Token already present in $GRUB_FILE. Nothing to change."
        echo "Reboot (if you haven't) then: bash $0 verify"
        exit 0
    fi
    NEW_VALUE="${CURRENT_VALUE:+$CURRENT_VALUE }${TOKEN}"
elif [[ "$MODE" == "revert" ]]; then
    if ! grep -qw "$TOKEN" <<<" $CURRENT_VALUE "; then
        ok "Token not present. Nothing to revert."
        exit 0
    fi
    # remove the token and squeeze spaces
    NEW_VALUE=$(sed -E "s/ ?$(printf '%s' "$TOKEN" | sed 's/[.[\*^$]/\\&/g')//; s/  +/ /g; s/^ //; s/ $//" <<<"$CURRENT_VALUE")
else
    fail "Unknown mode '$MODE'. Use: apply | revert | verify"
fi

log "Backing up $GRUB_FILE → $BACKUP"
cp -a "$GRUB_FILE" "$BACKUP"

log "Setting GRUB_CMDLINE_LINUX_DEFAULT=\"$NEW_VALUE\""
ESCAPED=$(printf '%s' "$NEW_VALUE" | sed 's/[|\&]/\\&/g')
sed -i -E "s|^GRUB_CMDLINE_LINUX_DEFAULT=\"?.*\"?\$|GRUB_CMDLINE_LINUX_DEFAULT=\"${ESCAPED}\"|" "$GRUB_FILE"

log "Regenerating GRUB config"
update-grub 2>&1 | sed 's/^/      /' || fail "update-grub failed. Backup: $BACKUP"
log "Regenerating initramfs (all kernels)"
update-initramfs -u -k all 2>&1 | sed 's/^/      /' || fail "update-initramfs failed. Backup: $BACKUP"

echo
echo "=============================================================="
echo "  Done ($MODE). REBOOT REQUIRED to take effect."
echo
echo "  After reboot, VERIFY it actually bound (Ada may ignore it):"
echo "    bash $0 verify"
echo "      GSP 'N/A'         → disabled (good; observe Xid 56 under load)"
echo "      GSP still a version → ignored on this Ada GPU → run: sudo bash $0 revert"
echo
echo "  Manual rollback: sudo mv $BACKUP $GRUB_FILE && sudo update-grub && sudo update-initramfs -u && reboot"
echo "=============================================================="
