#!/usr/bin/env bash
# fix-apparmor-userns-persistent.sh
#
# Purpose: persistently disable Ubuntu 24.04's `kernel.apparmor_restrict_unprivileged_userns=1`
# sysctl, restoring flatpak (bwrap) sandbox UID mapping for apps that ship
# Chromium or QtWebEngine.
#
# SECURITY TRADE-OFF: applying this script reverts the mitigation for
# CVE-2023-2640 / CVE-2023-32629 (OverlayFS local root via user namespaces).
# Appropriate for a developer workstation. NOT appropriate for servers or
# shared hosts. Read the runbook's "Known Constraints and Security Trade-offs"
# section before running.
#
# Requires sudo. Safe to re-run — idempotent.

set -euo pipefail

log()  { printf '\e[1;34m[fix]\e[0m %s\n' "$*"; }
ok()   { printf '\e[1;32m[ok]\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m[warn]\e[0m %s\n' "$*"; }
fail() { printf '\e[1;31m[fail]\e[0m %s\n' "$*"; exit 1; }

if [[ $EUID -ne 0 ]]; then
    fail "This script needs root. Re-run with: sudo bash $0"
fi

DROPIN=/etc/sysctl.d/60-apparmor-userns.conf
SYSCTL_KEY=kernel.apparmor_restrict_unprivileged_userns

echo "=============================================================="
echo "  Flatpak + AppArmor userns restriction — persistent fix"
echo "=============================================================="

# ----- 1. Guardrails --------------------------------------------------------

log "Step 1: sanity checks"

if [[ ! -e /proc/sys/kernel/apparmor_restrict_unprivileged_userns ]]; then
    fail "This kernel does not expose apparmor_restrict_unprivileged_userns. Nothing to fix."
fi

CURRENT=$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns)
if [[ "$CURRENT" == "0" ]]; then
    ok "sysctl is already 0. No runtime change needed."
    RUNTIME_ALREADY_OFF=1
else
    RUNTIME_ALREADY_OFF=0
fi
echo

# ----- 2. Confirm the operator accepts the trade-off ------------------------

log "Step 2: trade-off confirmation"

cat <<EOF

    You are about to disable Ubuntu 24.04's mitigation for CVE-2023-2640 and
    CVE-2023-32629 on THIS machine, persistently.

    In exchange, flatpak apps that use Chromium or QtWebEngine will be able
    to create their bwrap sandbox correctly again.

    Do NOT proceed if this machine:
      - is a shared host with untrusted local users
      - runs production services reachable from the network
      - is in a fleet where central security policy mandates the mitigation

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

# ----- 3. Write the drop-in file --------------------------------------------

log "Step 3: write drop-in at $DROPIN"

if [[ -f "$DROPIN" ]] && grep -q "^${SYSCTL_KEY}=0$" "$DROPIN"; then
    ok "Drop-in already contains the correct setting. Leaving it alone."
else
    if [[ -f "$DROPIN" ]]; then
        BACKUP="${DROPIN}.bak.$(date +%Y%m%d-%H%M%S)"
        cp -a "$DROPIN" "$BACKUP"
        warn "Existing drop-in found. Backed up to $BACKUP."
    fi
    cat > "$DROPIN" <<EOF
# Written by fix-apparmor-userns-persistent.sh on $(date -Iseconds)
# See: personal-runbooks-portfolio / linux / Ubuntu_Flatpak_AppArmor_Userns_Restriction
#
# Disables Ubuntu 24.04's AppArmor restriction on unprivileged user namespaces
# so that flatpak (bwrap) sandboxes can set up UID mapping correctly.
#
# SECURITY: this reverts the mitigation for CVE-2023-2640 / CVE-2023-32629.
# Keep this file only on developer workstations where the trade-off is accepted.
${SYSCTL_KEY}=0
EOF
    chmod 644 "$DROPIN"
    ok "Wrote $DROPIN."
fi
echo

# ----- 4. Apply without reboot ---------------------------------------------

log "Step 4: apply --system so the change takes effect now"
sysctl --system >/dev/null
NEW=$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns)

if [[ "$NEW" == "0" ]]; then
    ok "Runtime sysctl is now 0."
else
    fail "Runtime sysctl is still $NEW. Another drop-in with a higher-priority filename may be overriding us. Check: grep -r apparmor_restrict_unprivileged_userns /etc/sysctl.d/ /usr/lib/sysctl.d/"
fi
echo

# ----- 5. Smoke test --------------------------------------------------------

log "Step 5: smoke test via any installed flatpak"

PROBE_APP=$(sudo -u "${SUDO_USER:-$USER}" flatpak list --app --columns=application 2>/dev/null | head -1 || true)
if [[ -z "${PROBE_APP:-}" ]]; then
    warn "No flatpak apps installed — can't run smoke test."
    echo "    Install any flatpak and inspect: flatpak run --command=sh <app> -c 'ls -la /dev/dri/'"
    echo "    Expected: root:root on entries. If you see nfsnobody, something else is broken."
else
    echo "    Using $PROBE_APP as probe..."
    OUT=$(sudo -u "${SUDO_USER:-$USER}" flatpak run --command=sh "$PROBE_APP" -c 'ls -la /dev/dri/ 2>&1 | head -3' 2>&1 || true)
    echo "$OUT" | sed 's/^/      /'
    if grep -q 'nfsnobody' <<<"$OUT"; then
        fail "Sandbox still shows nfsnobody. The fix did not resolve the issue. See runbook for alternate causes (unprivileged_userns_clone=0, custom AppArmor profiles, etc.)."
    elif grep -qE ' root.+root' <<<"$OUT"; then
        ok "Sandbox UID mapping is working. Fix successful."
    else
        warn "Unexpected output from smoke test. Inspect manually."
    fi
fi
echo

echo "=============================================================="
echo "  Done. You can now launch flatpak apps that were previously"
echo "  failing with EGL / ANGLE / QRhi errors."
echo
echo "  To reverse this change later:"
echo "    sudo rm $DROPIN"
echo "    sudo sysctl ${SYSCTL_KEY}=1"
echo "=============================================================="
