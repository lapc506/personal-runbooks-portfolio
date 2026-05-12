#!/usr/bin/env bash
# revert-deb-to-snap.sh
#
# Purpose: undo migrate-slack-snap-to-deb.sh. Reinstalls the Slack snap and
# restores the user's session data from either (a) the snapd auto-snapshot
# created when 'snap remove' ran, if still within snapd's retention window
# (default 30 days), or (b) the manual backup at ~/slack-snap-backup-<ts>/
# created by the migration script.
#
# Refuses to run if neither rollback artifact exists — that means migration
# wasn't done via the paired script and we can't be sure what state to
# restore to.
#
# Requires sudo for: 'apt remove slack-desktop' and 'snap install slack'.

set -euo pipefail

log()    { printf '\e[1;34m[rev]\e[0m %s\n' "$*"; }
ok()     { printf '\e[1;32m[ok]\e[0m %s\n' "$*"; }
warn()   { printf '\e[1;33m[warn]\e[0m %s\n' "$*"; }
fail()   { printf '\e[1;31m[fail]\e[0m %s\n' "$*"; exit 1; }

SNAP_DATA="$HOME/snap/slack/current/.config/Slack"
USER_APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"

echo "==============================================================="
echo "  Slack .deb → snap revert"
echo "==============================================================="
echo

# ----- 1. Guardrails --------------------------------------------------------

if [[ $EUID -eq 0 ]]; then
    fail "Do NOT run this script as root. It edits files in \$HOME and escalates to sudo only when needed."
fi

# Detect what's currently installed
SNAP_INSTALLED=0
DEB_INSTALLED=0
snap list slack >/dev/null 2>&1 && SNAP_INSTALLED=1
dpkg -l slack-desktop 2>/dev/null | grep -q '^ii' && DEB_INSTALLED=1

if [[ $SNAP_INSTALLED -eq 1 && $DEB_INSTALLED -eq 0 ]]; then
    ok "Slack snap is already installed (no .deb) — nothing to revert."
    exit 0
fi

if [[ $DEB_INSTALLED -eq 0 && $SNAP_INSTALLED -eq 0 ]]; then
    warn "Neither snap nor .deb installed. Will only reinstall the snap fresh."
fi

# ----- 2. Find rollback artifacts -------------------------------------------

log "Looking for rollback artifacts"

# 2a. snapd auto-snapshot
SNAPD_SNAPSHOT_ID=$(snap saved 2>/dev/null | awk '/slack/ {print $1}' | head -1 || true)
if [[ -n "$SNAPD_SNAPSHOT_ID" ]]; then
    ok "  snapd auto-snapshot: set #$SNAPD_SNAPSHOT_ID (preferred restore source)"
fi

# 2b. manual backup created by migration script
MANUAL_BACKUP=$(ls -td "$HOME"/slack-snap-backup-* 2>/dev/null | head -1 || true)
if [[ -n "$MANUAL_BACKUP" && -d "$MANUAL_BACKUP" ]]; then
    ok "  manual backup: $MANUAL_BACKUP ($(du -sh "$MANUAL_BACKUP" | cut -f1))"
fi

# 2c. archived user-scope .desktop overrides
USER_APPS_BACKUPS=$(ls -td "${USER_APPS_DIR}".snap-backup-* 2>/dev/null || true)
if [[ -n "$USER_APPS_BACKUPS" ]]; then
    ok "  archived .desktop overrides found: $(echo "$USER_APPS_BACKUPS" | head -1)"
fi

if [[ -z "$SNAPD_SNAPSHOT_ID" && -z "$MANUAL_BACKUP" ]]; then
    fail "No rollback artifacts found (no snapd snapshot, no manual backup). This script can only revert migrations done via migrate-slack-snap-to-deb.sh. Aborting rather than guessing."
fi
echo

# ----- 3. Confirmation ------------------------------------------------------

if [[ "${NONINTERACTIVE:-0}" != "1" ]]; then
    cat <<EOF
    This script will:
      1. sudo apt remove slack-desktop      (if installed)
      2. sudo snap install slack            (or use snapd's saved set if available)
      3. Restore session data:
           - from snapd snapshot #$SNAPD_SNAPSHOT_ID (preferred), or
           - from manual backup $MANUAL_BACKUP
      4. Restore any archived user-scope .desktop overrides.
      5. update-desktop-database.

    After this: click Slack in the dock. If the silent-exit bug from
    the README still applies, you'll be back to the original problem.
    Revert is only useful if you discovered the .deb has its own issue.

EOF
    read -r -p "    Type 'yes' to continue, anything else to abort: " REPLY
    if [[ "$REPLY" != "yes" ]]; then
        echo "    Aborted."
        exit 0
    fi
else
    warn "NONINTERACTIVE=1 set — skipping confirmation."
fi
echo

# ----- 4. Remove .deb -------------------------------------------------------

if [[ $DEB_INSTALLED -eq 1 ]]; then
    log "Step 4: sudo apt remove slack-desktop"
    sudo apt remove -y slack-desktop
    ok "  .deb uninstalled"
else
    log "Step 4: .deb not installed, skipping"
fi
echo

# ----- 5. Reinstall snap ----------------------------------------------------

if [[ $SNAP_INSTALLED -eq 0 ]]; then
    log "Step 5: sudo snap install slack"
    sudo snap install slack
    ok "  snap installed"
else
    log "Step 5: snap already installed, skipping install"
fi
echo

# ----- 6. Restore data ------------------------------------------------------

# Make sure target dir exists
mkdir -p "$(dirname "$SNAP_DATA")"

if [[ -n "$SNAPD_SNAPSHOT_ID" ]]; then
    log "Step 6: restore from snapd snapshot #$SNAPD_SNAPSHOT_ID"
    sudo snap restore "$SNAPD_SNAPSHOT_ID" slack
    ok "  snapd snapshot restored"
elif [[ -n "$MANUAL_BACKUP" && -d "$MANUAL_BACKUP" ]]; then
    log "Step 6: restore from manual backup $MANUAL_BACKUP"
    mkdir -p "$SNAP_DATA"
    for item in "$MANUAL_BACKUP"/*; do
        name=$(basename "$item")
        if [[ -e "$SNAP_DATA/$name" ]]; then
            warn "  $SNAP_DATA/$name already exists — leaving in place"
        else
            cp -a "$item" "$SNAP_DATA/"
            ok "  restored: $name"
        fi
    done
else
    warn "Step 6: no restore source — snap starts fresh (you'll need to log in)"
fi
echo

# ----- 7. Restore user-scope .desktop overrides -----------------------------

if [[ -n "$USER_APPS_BACKUPS" ]]; then
    LATEST_APPS_BACKUP=$(echo "$USER_APPS_BACKUPS" | head -1)
    log "Step 7: restore .desktop overrides from $LATEST_APPS_BACKUP"
    for f in "$LATEST_APPS_BACKUP"/slack*.desktop*; do
        if [[ -f "$f" ]]; then
            mv "$f" "$USER_APPS_DIR/"
            ok "  restored: $(basename "$f")"
        fi
    done
    rmdir "$LATEST_APPS_BACKUP" 2>/dev/null || true
else
    log "Step 7: no archived .desktop overrides to restore (snap's launcher will be used)"
fi
echo

# ----- 8. Refresh desktop DB ------------------------------------------------

if command -v update-desktop-database >/dev/null 2>&1; then
    log "Step 8: refresh desktop database"
    update-desktop-database "$USER_APPS_DIR" 2>&1 | sed 's/^/      /' || true
fi
echo

# ----- 9. Final -------------------------------------------------------------

echo "==============================================================="
echo "  Revert complete. You're back on the Slack snap."
echo
echo "  Verify:"
echo "    snap list slack                              # should show slack installed"
echo "    dpkg -l slack-desktop 2>&1 | tail -1         # should print 'no packages found'"
echo
echo "  Caveat: the bug documented in this runbook's README probably still"
echo "  applies. If Slack still fails to open, run:"
echo "    bash $(dirname "$0")/diagnose-snap-electron-silent-exit.sh"
echo "==============================================================="
