#!/usr/bin/env bash
# enable-nvidia-drm-modeset.sh
#
# Purpose: move `nvidia_drm.modeset=1` and `nvidia_drm.fbdev=1` from
# /etc/modprobe.d/ into the kernel command line, so the parameters
# bind at module-load time regardless of whether the module is loaded
# from initramfs or by systemd-modules-load after root is mounted.
#
# Fixes: "Flip event timeout on head 0/1" NVIDIA errors under Wayland,
# GNOME Shell SIGTRAP crashes, hard-reboots triggered by mutter's
# abort path. See ./README.md for the full diagnostic story.
#
# Requires sudo. Safe to re-run — idempotent. Requires reboot to take
# effect (NVIDIA `modeset` is load-time-only).

set -euo pipefail

log()  { printf '\e[1;34m[fix]\e[0m %s\n' "$*"; }
ok()   { printf '\e[1;32m[ok]\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m[warn]\e[0m %s\n' "$*"; }
fail() { printf '\e[1;31m[fail]\e[0m %s\n' "$*"; exit 1; }

if [[ $EUID -ne 0 ]]; then
    fail "This script needs root. Re-run with: sudo bash $0"
fi

GRUB_FILE=/etc/default/grub
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="${GRUB_FILE}.bak.${TIMESTAMP}"
TOKEN_MODESET="nvidia-drm.modeset=1"
TOKEN_FBDEV="nvidia-drm.fbdev=1"

echo "=============================================================="
echo "  NVIDIA DRM modeset/fbdev — move to kernel command line"
echo "=============================================================="

# ----- 1. Guardrails --------------------------------------------------------

log "Step 1: sanity checks"

if [[ ! -f "$GRUB_FILE" ]]; then
    fail "$GRUB_FILE not found. Is this a GRUB-based system?"
fi

if ! command -v update-grub >/dev/null; then
    fail "update-grub not in PATH. Is this Ubuntu/Debian? On Fedora use 'grub2-mkconfig -o /boot/grub2/grub.cfg' instead."
fi

if ! command -v update-initramfs >/dev/null; then
    fail "update-initramfs not in PATH. On non-Debian systems use the equivalent (dracut -f, mkinitcpio -P)."
fi

if ! lspci | grep -qi 'nvidia'; then
    fail "No NVIDIA PCI device detected. This runbook does not apply to your machine."
fi

if ! lsmod | grep -q '^nvidia_drm'; then
    warn "nvidia_drm module is not currently loaded. The fix will still apply on next boot, but verify you have the NVIDIA proprietary/open driver installed (not nouveau)."
fi

ok "Environment looks like Ubuntu + NVIDIA. Proceeding."
echo

# ----- 2. Show current cmdline so the operator can sanity-check ------------

log "Step 2: current kernel command line"
echo "      /proc/cmdline: $(cat /proc/cmdline)"
echo
echo "      $GRUB_FILE current GRUB_CMDLINE_LINUX_DEFAULT line:"
grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE" | sed 's/^/          /'
echo

# ----- 3. Trade-off confirmation -------------------------------------------

log "Step 3: confirm the operator wants to proceed"
cat <<EOF

    This script will:
      1. Back up $GRUB_FILE to $BACKUP
      2. Add '$TOKEN_MODESET $TOKEN_FBDEV' to GRUB_CMDLINE_LINUX_DEFAULT
         (preserving existing tokens, skipping tokens already present)
      3. Run: update-grub
      4. Run: update-initramfs -u
      5. Remind you to reboot.

    No change takes effect until reboot — NVIDIA's 'modeset' is
    load-time-only and cannot be changed at runtime.

EOF

if [[ "${NONINTERACTIVE:-0}" != "1" ]]; then
    read -r -p "    Type 'yes' to continue, anything else to abort: " REPLY
    if [[ "$REPLY" != "yes" ]]; then
        echo "    Aborted."
        exit 0
    fi
else
    warn "NONINTERACTIVE=1 set — skipping confirmation."
fi
echo

# ----- 4. Backup ------------------------------------------------------------

log "Step 4: back up $GRUB_FILE"
cp -a "$GRUB_FILE" "$BACKUP"
ok "Backup saved to $BACKUP"
echo

# ----- 5. Edit GRUB_CMDLINE_LINUX_DEFAULT idempotently ---------------------

log "Step 5: edit GRUB_CMDLINE_LINUX_DEFAULT"

# Extract current value (everything between the quotes).
CURRENT_LINE=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE" || true)
if [[ -z "$CURRENT_LINE" ]]; then
    fail "No GRUB_CMDLINE_LINUX_DEFAULT= line in $GRUB_FILE. Unusual. Inspect manually."
fi

# Strip 'GRUB_CMDLINE_LINUX_DEFAULT=' prefix and surrounding quotes.
CURRENT_VALUE=$(echo "$CURRENT_LINE" | sed -E 's/^GRUB_CMDLINE_LINUX_DEFAULT="?([^"]*)"?$/\1/')

# Add each token if not already present.
NEW_VALUE="$CURRENT_VALUE"
for TOKEN in "$TOKEN_MODESET" "$TOKEN_FBDEV"; do
    if grep -qw "$TOKEN" <<<" $NEW_VALUE "; then
        warn "  $TOKEN already present, skipping."
    else
        NEW_VALUE="${NEW_VALUE} ${TOKEN}"
        NEW_VALUE="${NEW_VALUE# }"  # trim leading space if CURRENT_VALUE was empty
        ok "  Added $TOKEN"
    fi
done

if [[ "$NEW_VALUE" == "$CURRENT_VALUE" ]]; then
    ok "All tokens already present. No edit needed."
    SKIP_REGEN=1
else
    # Write back using a literal-safe sed (value contains no slashes on Ubuntu defaults,
    # but be careful — use | as delimiter and escape any |/& in case).
    ESCAPED_NEW=$(printf '%s' "$NEW_VALUE" | sed 's/[|\&]/\\&/g')
    sed -i -E "s|^GRUB_CMDLINE_LINUX_DEFAULT=\"?.*\"?\$|GRUB_CMDLINE_LINUX_DEFAULT=\"${ESCAPED_NEW}\"|" "$GRUB_FILE"
    ok "  New GRUB_CMDLINE_LINUX_DEFAULT=\"$NEW_VALUE\""
    SKIP_REGEN=0
fi
echo

# ----- 6. Regenerate GRUB + initramfs ---------------------------------------

if [[ "${SKIP_REGEN:-0}" == "1" ]]; then
    ok "No regeneration needed (config unchanged)."
else
    log "Step 6a: regenerate GRUB config"
    if update-grub 2>&1 | sed 's/^/      /'; then
        ok "GRUB regenerated."
    else
        fail "update-grub failed. Check output above. Your backup is at $BACKUP."
    fi
    echo

    log "Step 6b: regenerate initramfs for all installed kernels"
    if update-initramfs -u -k all 2>&1 | sed 's/^/      /'; then
        ok "Initramfs regenerated."
    else
        fail "update-initramfs failed. Check output above. Your backup is at $BACKUP."
    fi
    echo
fi

# ----- 7. Verify the token is in the regenerated grub.cfg ------------------

log "Step 7: verify the token is in grub.cfg"
if grep -qE "linux.*nvidia-drm\.modeset=1" /boot/grub/grub.cfg 2>/dev/null; then
    ok "nvidia-drm.modeset=1 found in /boot/grub/grub.cfg — will be on cmdline next boot."
else
    warn "Could not verify token in /boot/grub/grub.cfg. Inspect manually:"
    warn "    grep nvidia-drm /boot/grub/grub.cfg"
fi
echo

# ----- 8. Final instructions -----------------------------------------------

echo "=============================================================="
echo "  Done. REBOOT REQUIRED for the change to take effect."
echo
echo "  After reboot, verify:"
echo "    cat /proc/cmdline | grep -oE 'nvidia-drm\.(modeset|fbdev)=[01]'"
echo "    # → nvidia-drm.modeset=1"
echo "    # → nvidia-drm.fbdev=1"
echo
echo "  Then stress-test (drag a window around for 30s) and check:"
echo "    journalctl -b 0 --no-pager | grep -c 'nv_drm_atomic_commit'"
echo "    # → 0"
echo
echo "  Rollback (from TTY Ctrl+Alt+F3 if boot is broken):"
echo "    sudo mv $BACKUP $GRUB_FILE"
echo "    sudo update-grub && sudo update-initramfs -u"
echo "    sudo reboot"
echo "=============================================================="
