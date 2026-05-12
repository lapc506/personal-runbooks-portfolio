#!/usr/bin/env bash
# migrate-slack-snap-to-deb.sh
#
# Purpose: replace the Slack snap with Slack's official .deb in a way that
# preserves the user's session (cookies, IndexedDB, Local Storage, Preferences)
# and is fully reversible via the snapd auto-snapshot OR a manual backup.
#
# Trigger: clicking the Slack launcher does nothing visible; the snap's
# browser.log truncates inside collectSystemInfo / getLinuxDistro. See the
# README.md in this directory for the root cause.
#
# Idempotency:
#   - If Slack is already installed as a .deb (no snap), exits 0 with a message.
#   - If the snap was removed but the .deb was not installed (mid-migration
#     interrupted), resumes from the install step.
#   - Re-running after a successful migration is a no-op.
#
# Requires sudo for two commands: 'snap remove slack' and 'apt install <deb>'.
# The script will prompt once and reuse the cached sudo credential.
#
# No reboot, no logout — close any running Slack window when prompted, the
# .deb takes over the launcher entry immediately.

set -euo pipefail

log()    { printf '\e[1;34m[mig]\e[0m %s\n' "$*"; }
ok()     { printf '\e[1;32m[ok]\e[0m %s\n' "$*"; }
warn()   { printf '\e[1;33m[warn]\e[0m %s\n' "$*"; }
fail()   { printf '\e[1;31m[fail]\e[0m %s\n' "$*"; exit 1; }

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
SNAP_DATA="$HOME/snap/slack/current/.config/Slack"
DEB_DATA="$HOME/.config/Slack"
BACKUP_DIR="$HOME/slack-snap-backup-$TIMESTAMP"
DOWNLOADS_DIR="${XDG_DOWNLOAD_DIR:-$HOME/Descargas}"
[[ -d "$DOWNLOADS_DIR" ]] || DOWNLOADS_DIR="$HOME/Downloads"
[[ -d "$DOWNLOADS_DIR" ]] || mkdir -p "$DOWNLOADS_DIR"
USER_APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
USER_APPS_BACKUP="${USER_APPS_DIR}.snap-backup-$TIMESTAMP"

echo "==============================================================="
echo "  Slack snap → .deb migration"
echo "==============================================================="
echo

# ----- 1. Guardrails --------------------------------------------------------

if [[ $EUID -eq 0 ]]; then
    fail "Do NOT run this script as root. It backs up files in \$HOME, then escalates to sudo only for the two commands that need it (snap remove, apt install)."
fi

if ! command -v snap >/dev/null 2>&1; then
    fail "'snap' command not found — this system isn't snap-based. Nothing to migrate from."
fi

# Detect current state
SNAP_INSTALLED=0
DEB_INSTALLED=0
snap list slack >/dev/null 2>&1 && SNAP_INSTALLED=1
dpkg -l slack-desktop 2>/dev/null | grep -q '^ii' && DEB_INSTALLED=1

log "Current state: snap=$SNAP_INSTALLED, deb=$DEB_INSTALLED"

if [[ $SNAP_INSTALLED -eq 0 && $DEB_INSTALLED -eq 1 ]]; then
    ok "Slack is already installed as a .deb — nothing to do. Exiting cleanly."
    exit 0
fi

if [[ $SNAP_INSTALLED -eq 1 && $DEB_INSTALLED -eq 1 ]]; then
    fail "Both snap and .deb are installed simultaneously. This script doesn't know which is active. Resolve manually: 'sudo snap remove slack' OR 'sudo apt remove slack-desktop' first."
fi

if [[ $SNAP_INSTALLED -eq 0 && $DEB_INSTALLED -eq 0 ]]; then
    warn "Neither snap nor .deb is installed. Will install fresh .deb (no backup possible)."
fi

# Determine version to install
if [[ $SNAP_INSTALLED -eq 1 ]]; then
    SLACK_VERSION=$(snap list slack 2>/dev/null | awk 'NR==2 {print $2}')
    log "Snap Slack version: $SLACK_VERSION (will install matching .deb)"
else
    SLACK_VERSION="${SLACK_VERSION_OVERRIDE:-4.49.89}"
    warn "Snap not installed — defaulting to version $SLACK_VERSION (override with SLACK_VERSION_OVERRIDE env)"
fi

DEB_URL="https://downloads.slack-edge.com/desktop-releases/linux/x64/${SLACK_VERSION}/slack-desktop-${SLACK_VERSION}-amd64.deb"
DEB_FILE="$DOWNLOADS_DIR/slack-desktop-${SLACK_VERSION}-amd64.deb"

ok "Plan: back up snap data → download .deb → remove snap → install .deb → restore data"
echo

# ----- 2. Trade-off confirmation --------------------------------------------

if [[ "${NONINTERACTIVE:-0}" != "1" ]]; then
    cat <<EOF
    This script will:
      1. Back up $SNAP_DATA to:
         $BACKUP_DIR
         (~600 MB for a typical heavy user. Restored to $DEB_DATA after install.)
      2. Download $DEB_URL
         to $DEB_FILE (~88 MB, may take 30s–2min on broadband).
      3. sudo snap remove slack         ← prompts for sudo password
         (preserves snapd auto-snapshot for 30 days as rollback path)
      4. sudo apt install -y "$DEB_FILE"
      5. Restore data from backup to $DEB_DATA.
      6. Archive any user-scope .desktop overrides to:
         $USER_APPS_BACKUP/
         (so they don't shadow the new system-wide .deb launcher)
      7. update-desktop-database on the user apps dir.

    No reboot. After step 7, click Slack in the dock — should open normally.

    Trade-offs (see README.md "Known Constraints"):
      • The .deb has NO APT repo — future updates are manual (re-download .deb).
      • The .deb runs unconfined — no AppArmor/seccomp/cgroups sandbox.
      • Rollback path: bash ./revert-deb-to-snap.sh (works within 30 days).

EOF
    read -r -p "    Type 'yes' to continue, anything else to abort: " REPLY
    if [[ "$REPLY" != "yes" ]]; then
        echo "    Aborted. No changes made."
        exit 0
    fi
else
    warn "NONINTERACTIVE=1 set — skipping confirmation."
fi
echo

# ----- 3. Backup snap data --------------------------------------------------

if [[ $SNAP_INSTALLED -eq 1 && -d "$SNAP_DATA" ]]; then
    log "Step 3: backup snap data → $BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
    for item in "Local Storage" "IndexedDB" "Cookies" "Cookies-journal" "Preferences" "Local State" "Network" "storage" "Session Storage" "Service Worker"; do
        if [[ -e "$SNAP_DATA/$item" ]]; then
            cp -a "$SNAP_DATA/$item" "$BACKUP_DIR/"
            ok "  copied: $item"
        fi
    done
    ok "Backup total: $(du -sh "$BACKUP_DIR" | cut -f1)"
else
    warn "Step 3: no snap data to back up (snap was already removed or empty)"
fi
echo

# ----- 4. Download .deb -----------------------------------------------------

log "Step 4: download .deb for version $SLACK_VERSION"
if [[ -f "$DEB_FILE" ]]; then
    EXISTING_SIZE=$(stat -c%s "$DEB_FILE")
    if [[ $EXISTING_SIZE -gt 50000000 ]]; then
        ok "  .deb already downloaded ($(du -h "$DEB_FILE" | cut -f1)), reusing"
    else
        warn "  Existing .deb is suspiciously small ($EXISTING_SIZE bytes), re-downloading"
        rm -f "$DEB_FILE"
    fi
fi

if [[ ! -f "$DEB_FILE" ]]; then
    if ! curl -L --fail -o "$DEB_FILE" "$DEB_URL"; then
        rm -f "$DEB_FILE"
        fail "Download from $DEB_URL failed. Check URL or your network. (If Slack pulled this version, try a newer one with SLACK_VERSION_OVERRIDE.)"
    fi
    ok "  downloaded $(du -h "$DEB_FILE" | cut -f1)"
fi

# Verify the file is a real .deb
if ! file "$DEB_FILE" | grep -q 'Debian binary package'; then
    fail "$DEB_FILE is not a valid Debian package. Aborting before sudo step."
fi
echo

# ----- 5. Remove snap (preserves snapd auto-snapshot) -----------------------

if [[ $SNAP_INSTALLED -eq 1 ]]; then
    log "Step 5: sudo snap remove slack (will prompt for password if not cached)"
    sudo snap remove slack
    ok "  snap removed (data preserved by snapd auto-snapshot for ~30 days; see 'snap saved')"
else
    log "Step 5: snap already removed, skipping"
fi
echo

# ----- 6. Install .deb ------------------------------------------------------

if [[ $DEB_INSTALLED -eq 0 ]]; then
    log "Step 6: sudo apt install -y $DEB_FILE"
    sudo apt install -y "$DEB_FILE"
    ok "  .deb installed: $(dpkg -l slack-desktop | awk 'NR==6 {print $2, $3}')"
else
    log "Step 6: .deb already installed, skipping"
fi
echo

# ----- 7. Restore data ------------------------------------------------------

if [[ -d "$BACKUP_DIR" ]]; then
    log "Step 7: restore data → $DEB_DATA"
    mkdir -p "$DEB_DATA"
    # Only copy items that don't already exist (so re-runs after a manual login
    # don't blow away fresh data)
    for item in "$BACKUP_DIR"/*; do
        name=$(basename "$item")
        if [[ -e "$DEB_DATA/$name" ]]; then
            warn "  $DEB_DATA/$name already exists — leaving in place (not overwriting)"
        else
            cp -a "$item" "$DEB_DATA/"
            ok "  restored: $name"
        fi
    done
    ok "  data total in $DEB_DATA: $(du -sh "$DEB_DATA" | cut -f1)"
else
    warn "Step 7: no backup to restore from (fresh install)"
fi
echo

# ----- 8. Archive user-scope .desktop overrides -----------------------------

log "Step 8: archive user-scope Slack .desktop overrides (point at removed snap)"
ARCHIVED=0
mkdir -p "$USER_APPS_BACKUP"
for f in "$USER_APPS_DIR"/slack_slack.desktop* "$USER_APPS_DIR"/slack.desktop.bak.* ; do
    if [[ -f "$f" ]]; then
        mv "$f" "$USER_APPS_BACKUP/"
        ok "  archived: $(basename "$f") → $USER_APPS_BACKUP/"
        ARCHIVED=$((ARCHIVED+1))
    fi
done
if [[ $ARCHIVED -eq 0 ]]; then
    rmdir "$USER_APPS_BACKUP" 2>/dev/null || true
    ok "  no user-scope overrides found (system-wide /usr/share/applications/slack.desktop will be used)"
fi
echo

# ----- 9. Refresh desktop DB ------------------------------------------------

if command -v update-desktop-database >/dev/null 2>&1; then
    log "Step 9: refresh desktop database"
    update-desktop-database "$USER_APPS_DIR" 2>&1 | sed 's/^/      /' || true
    ok "  desktop DB refreshed"
fi
echo

# ----- 10. Final ------------------------------------------------------------

echo "==============================================================="
echo "  Migration complete. No reboot required."
echo
echo "  Verify:"
echo "    snap list slack                  # should print 'no matching snaps installed'"
echo "    dpkg -l slack-desktop | tail -1  # should show 'ii  slack-desktop  $SLACK_VERSION'"
echo "    ls /usr/share/applications/slack.desktop   # should exist"
echo
echo "  Test:"
echo "    Click Slack in the dock. Should open within ~3 seconds."
echo "    Or from terminal: /usr/bin/slack &"
echo
echo "  Rollback (within 30 days, while snapd auto-snapshot is still around):"
echo "    bash $(dirname "$0")/revert-deb-to-snap.sh"
echo
echo "  Cleanup (when you're confident the .deb is working long-term):"
echo "    rm -rf $BACKUP_DIR    # the manual backup, $(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)"
echo "    rm -rf ~/snap/slack/  # the leftover snap data dir (snapd snapshot is separate)"
echo "    sudo snap forget <set-id>  # see 'snap saved' for the ID"
echo "==============================================================="
