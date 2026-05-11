#!/usr/bin/env bash
# diagnose-flatpak-userns.sh
#
# Purpose: confirm (or rule out) that a flatpak launch failure on this machine
# is caused by Ubuntu 24.04's AppArmor unprivileged-userns restriction, rather
# than by an actual GPU/driver issue or by a global userns disable.
#
# Exits 0 if the symptoms match the runbook's scenario (safe to apply the fix).
# Exits 1 if symptoms indicate a different problem (fix would be wrong).
# Exits 2 if the diagnosis is inconclusive (e.g., no flatpak app installed to probe with).
#
# Safe to re-run. Reads only; does not modify anything.

set -u

log()  { printf '\e[1;34m[diagnose]\e[0m %s\n' "$*"; }
ok()   { printf '\e[1;32m[ok]\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m[warn]\e[0m %s\n' "$*"; }
fail() { printf '\e[1;31m[fail]\e[0m %s\n' "$*"; }

echo "=============================================================="
echo "  Flatpak + AppArmor userns restriction — diagnostic"
echo "=============================================================="

# ----- 1. Distro + kernel ---------------------------------------------------

log "Step 1: distro and kernel"
if command -v lsb_release >/dev/null 2>&1; then
    lsb_release -a 2>/dev/null | sed 's/^/    /'
else
    [[ -f /etc/os-release ]] && grep -E '^(NAME|VERSION_ID|VERSION_CODENAME)=' /etc/os-release | sed 's/^/    /'
fi
echo "    kernel: $(uname -r)"
echo

# ----- 2. The two sysctls that matter ---------------------------------------

log "Step 2: relevant kernel sysctls"
APPARMOR_RESTRICT=$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || echo MISSING)
USERNS_CLONE=$(cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null || echo MISSING)
MAX_USERNS=$(cat /proc/sys/user/max_user_namespaces 2>/dev/null || echo MISSING)

echo "    apparmor_restrict_unprivileged_userns = $APPARMOR_RESTRICT"
echo "    unprivileged_userns_clone             = $USERNS_CLONE"
echo "    user.max_user_namespaces              = $MAX_USERNS"
echo

# ----- 3. Interpret the sysctls ---------------------------------------------

log "Step 3: interpretation"

if [[ "$USERNS_CLONE" == "0" ]]; then
    fail "unprivileged_userns_clone=0 — user namespaces are globally disabled on this machine."
    echo
    echo "    This is a DIFFERENT issue from the one this runbook addresses."
    echo "    The fix in this runbook will NOT work for you."
    echo "    Look into sysctl kernel.unprivileged_userns_clone=1 instead,"
    echo "    and check whether your distro or security hardening package"
    echo "    (e.g., Lynis, CIS benchmarks) disabled it intentionally."
    exit 1
fi

if [[ "$MAX_USERNS" == "0" ]]; then
    fail "user.max_user_namespaces=0 — userns creation is capped at zero."
    echo "    Same conclusion as above: this is not the runbook's scenario."
    exit 1
fi

if [[ "$APPARMOR_RESTRICT" == "MISSING" ]]; then
    warn "apparmor_restrict_unprivileged_userns sysctl does not exist on this kernel."
    echo "    That means either:"
    echo "      (a) your kernel predates Ubuntu's 23.10 patch (6.5 or older), or"
    echo "      (b) AppArmor is not loaded."
    echo "    Either way, this runbook's fix does not apply. Your flatpak issue is elsewhere."
    exit 1
fi

if [[ "$APPARMOR_RESTRICT" == "0" ]]; then
    ok "apparmor_restrict_unprivileged_userns is already 0 — restriction is NOT active."
    echo
    echo "    This runbook's fix is already applied or was never needed."
    echo "    If a flatpak app is still failing, it is failing for a different reason."
    echo "    Look at: GPU extensions (flatpak list --user | grep GL),"
    echo "             display server (Wayland vs X11),"
    echo "             the app's specific flatpak permissions (flatpak info --show-permissions <app>)."
    exit 1
fi

if [[ "$APPARMOR_RESTRICT" == "1" ]]; then
    warn "apparmor_restrict_unprivileged_userns=1 — restriction IS active. Proceeding to step 4."
fi
echo

# ----- 4. Probe a flatpak sandbox to observe UID mapping --------------------

log "Step 4: probe sandbox UID mapping"

# Pick any installed flatpak app to use as a probe.
PROBE_APP=$(flatpak list --app --columns=application 2>/dev/null | head -1)

if [[ -z "${PROBE_APP:-}" ]]; then
    warn "No flatpak apps installed. Cannot probe sandbox UID mapping."
    echo "    Diagnosis inconclusive."
    echo "    If you are convinced a flatpak failure is the reason you're reading this,"
    echo "    install any flatpak (e.g., 'flatpak install --user flathub org.gnome.Weather')"
    echo "    and re-run this script."
    exit 2
fi

echo "    Using $PROBE_APP as sandbox probe..."
DRI_LS=$(flatpak run --command=sh "$PROBE_APP" -c 'ls -la /dev/dri/ 2>&1 | head -5' 2>&1 || true)
echo "$DRI_LS" | sed 's/^/      /'
echo

if grep -q 'nfsnobody' <<<"$DRI_LS"; then
    fail "Sandbox sees /dev/dri/ owned by nfsnobody."
    echo
    echo "    Diagnosis: user-namespace UID mapping is being denied silently,"
    echo "    exactly as described in the runbook. The AppArmor restriction is"
    echo "    the cause."
    echo
    echo "    Recommended action: apply the fix."
    echo "      Temporary:  sudo sysctl kernel.apparmor_restrict_unprivileged_userns=0"
    echo "      Persistent: sudo bash ./fix-apparmor-userns-persistent.sh"
    exit 0
elif grep -qE '^d.+ root.+root' <<<"$DRI_LS"; then
    ok "Sandbox sees /dev/dri/ owned by root. UID mapping is working."
    echo
    echo "    This contradicts the runbook's expected symptom. Whatever is breaking"
    echo "    your flatpak launches, it's not the AppArmor userns restriction —"
    echo "    even though the sysctl is at the restrictive value (1)."
    echo "    Look elsewhere: GPU extension versioning, runtime branch mismatch,"
    echo "    or the specific app's --filesystem / --socket permissions."
    exit 1
else
    warn "Sandbox probe output didn't match either pattern. Manual inspection needed:"
    echo "    $ flatpak run --command=sh $PROBE_APP -c 'ls -la /dev/dri/'"
    exit 2
fi
