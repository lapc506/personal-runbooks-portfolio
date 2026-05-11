#!/usr/bin/env bash
# repair-slack-launcher.sh
#
# Purpose: rewrite ~/.local/share/applications/slack_slack.desktop to run
# Slack on native Wayland via Chromium Ozone hint=auto, instead of forcing
# XWayland with --ozone-platform=x11 and a blanked WAYLAND_DISPLAY.
#
# Also registers two named XDG Actions as right-click fallbacks:
#   - X11Fallback: the old forced-XWayland invocation, for when a Slack or
#     Electron release regresses the Wayland path.
#   - DebugGPU:    Wayland + GPU disabled + verbose logging, for debugging
#     rendering issues without editing files.
#
# Fixes: Slack UI "jumping" / "jitter" / "breathing" on GNOME Wayland. See
# ./README.md for the full diagnostic story.
#
# No sudo required — all writes are in $HOME. Safe to re-run (idempotent).
# No reboot, no logout: close and relaunch Slack for the change to take
# effect.

set -euo pipefail

log()  { printf '\e[1;34m[fix]\e[0m %s\n' "$*"; }
ok()   { printf '\e[1;32m[ok]\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m[warn]\e[0m %s\n' "$*"; }
fail() { printf '\e[1;31m[fail]\e[0m %s\n' "$*"; exit 1; }

SYSTEM_LAUNCHER=/var/lib/snapd/desktop/applications/slack_slack.desktop
USER_APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
USER_LAUNCHER="$USER_APPS_DIR/slack_slack.desktop"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="${USER_LAUNCHER}.bak.${TIMESTAMP}"

echo "=============================================================="
echo "  Slack snap launcher — rewrite for native Wayland on GNOME"
echo "=============================================================="

# ----- 1. Guardrails --------------------------------------------------------

log "Step 1: sanity checks"

if [[ $EUID -eq 0 ]]; then
    fail "Do NOT run this script as root. It edits files in \$HOME; running as root would write them as root-owned and break the user's dock."
fi

if [[ "${XDG_SESSION_TYPE:-}" != "wayland" ]]; then
    fail "XDG_SESSION_TYPE is '${XDG_SESSION_TYPE:-unset}', not 'wayland'. This runbook's fix is only needed on Wayland sessions. On X11, Slack's default launcher is fine."
fi

if [[ ! -e /snap/bin/slack ]]; then
    fail "/snap/bin/slack not found. This script handles the Snap packaging of Slack. For .deb or Flathub installs, see the README's 'Known Constraints' section."
fi

if ! command -v snap >/dev/null 2>&1; then
    fail "'snap' command not found. Is snapd installed?"
fi

if ! snap list slack >/dev/null 2>&1; then
    fail "'snap list slack' failed — the snap is not installed or is in a broken state. Run 'snap install slack' or 'snap refresh slack' first."
fi

if [[ ! -f "$SYSTEM_LAUNCHER" ]]; then
    fail "System launcher $SYSTEM_LAUNCHER not found. Snap install may be corrupt; try 'sudo snap refresh slack'."
fi

ok "Wayland session + Slack snap installed + system launcher present."
echo

# ----- 2. Show current state so the operator can sanity-check --------------

log "Step 2: current launcher state"

echo "      System launcher ($SYSTEM_LAUNCHER):"
grep -E '^(Exec|Icon|StartupWMClass|MimeType)=' "$SYSTEM_LAUNCHER" | sed 's/^/          /'
echo

if [[ -f "$USER_LAUNCHER" ]]; then
    echo "      User launcher ($USER_LAUNCHER):"
    grep -E '^(Exec|Icon|StartupWMClass|MimeType)=' "$USER_LAUNCHER" | sed 's/^/          /'
    if grep -qE '(WAYLAND_DISPLAY=\s|--ozone-platform=x11)' "$USER_LAUNCHER"; then
        warn "  ^ This file is currently forcing XWayland. Fix applies."
    else
        warn "  ^ This file does NOT currently force XWayland. Fix is re-entrant safe but"
        warn "    double-check you actually have the jitter symptom before applying."
    fi
else
    echo "      User launcher ($USER_LAUNCHER): (does not exist — will be created)"
fi
echo

# ----- 3. Extract fields from system launcher to inherit --------------------

log "Step 3: extract inheritable fields from system launcher"

SYS_ICON=$(grep -m1 '^Icon=' "$SYSTEM_LAUNCHER" | cut -d= -f2-)
SYS_MIMETYPE=$(grep -m1 '^MimeType=' "$SYSTEM_LAUNCHER" | cut -d= -f2- || true)
SYS_WMCLASS=$(grep -m1 '^StartupWMClass=' "$SYSTEM_LAUNCHER" | cut -d= -f2- || echo "Slack")

if [[ -z "$SYS_ICON" ]]; then
    warn "Could not read Icon= from system launcher. Defaulting to 'slack'."
    SYS_ICON="slack"
fi

ok "  Icon:            $SYS_ICON"
ok "  StartupWMClass:  $SYS_WMCLASS"
ok "  MimeType:        ${SYS_MIMETYPE:-<none>}"
echo

# ----- 4. Trade-off confirmation --------------------------------------------

log "Step 4: confirm the operator wants to proceed"
cat <<EOF

    This script will:
      1. If $USER_LAUNCHER exists, back it up to:
         $BACKUP
      2. Write a new $USER_LAUNCHER with:
         - Main Exec line using --ozone-platform-hint=auto (native Wayland)
         - XDG Action 'X11Fallback' with the old forced-XWayland invocation
         - XDG Action 'DebugGPU' with --disable-gpu and logging enabled
      3. Run update-desktop-database ~/.local/share/applications/
      4. Validate the result with desktop-file-validate (if installed).

    No reboot, no logout. Close Slack (Ctrl+Q) and relaunch from the dock.

EOF

if [[ "${NONINTERACTIVE:-0}" != "1" ]]; then
    read -r -p "    Type 'yes' to continue, anything else to abort: " REPLY
    if [[ "$REPLY" != "yes" ]]; then
        echo "    Aborted. No changes made."
        exit 0
    fi
else
    warn "NONINTERACTIVE=1 set — skipping confirmation."
fi
echo

# ----- 5. Backup ------------------------------------------------------------

mkdir -p "$USER_APPS_DIR"

if [[ -f "$USER_LAUNCHER" ]]; then
    log "Step 5: back up existing user launcher"
    cp -a "$USER_LAUNCHER" "$BACKUP"
    ok "Backup saved to $BACKUP"
else
    log "Step 5: no existing user launcher to back up (skipped)"
fi
echo

# ----- 6. Write the new launcher --------------------------------------------

log "Step 6: write new launcher at $USER_LAUNCHER"

# Using a quoted heredoc so $VARS inside the .desktop literal are not expanded.
# We build the file with expanded variables injected at the top via printf.
{
    cat <<HEADER
[Desktop Entry]
# Generated by repair-slack-launcher.sh on ${TIMESTAMP}
# Runbook: https://github.com/kvttvrsis/personal-runbooks-portfolio/tree/main/linux/Ubuntu_Snap_Slack_XWayland_Jitter
# Rewrites the default Snap user-launcher to run Slack on native Wayland via
# Chromium Ozone hint=auto, instead of forcing XWayland with --ozone-platform=x11.
X-SnapInstanceName=slack
X-SnapAppName=slack
Name=Slack
GenericName=Slack Client for Linux
Comment=Slack Desktop
Type=Application
StartupNotify=true
StartupWMClass=${SYS_WMCLASS}
Icon=${SYS_ICON}
Categories=GNOME;GTK;Network;InstantMessaging;
HEADER

    if [[ -n "${SYS_MIMETYPE:-}" ]]; then
        printf 'MimeType=%s\n' "$SYS_MIMETYPE"
    fi

    cat <<EXEC
Exec=env BAMF_DESKTOP_FILE_HINT=${SYSTEM_LAUNCHER} /snap/bin/slack --ozone-platform-hint=auto --enable-features=WaylandWindowDecorations %U
Actions=X11Fallback;DebugGPU;

[Desktop Action X11Fallback]
Name=Open in X11 fallback mode (XWayland)
Exec=env BAMF_DESKTOP_FILE_HINT=${SYSTEM_LAUNCHER} WAYLAND_DISPLAY= /snap/bin/slack --ozone-platform=x11 %U
Icon=${SYS_ICON}

[Desktop Action DebugGPU]
Name=Open in debug mode (Wayland, GPU disabled, verbose logs to stderr)
Exec=env BAMF_DESKTOP_FILE_HINT=${SYSTEM_LAUNCHER} /snap/bin/slack --ozone-platform-hint=auto --disable-gpu --enable-logging=stderr --v=1 %U
Icon=${SYS_ICON}
EXEC
} > "$USER_LAUNCHER"

chmod 644 "$USER_LAUNCHER"
ok "Wrote new launcher ($(wc -c < "$USER_LAUNCHER") bytes)."
echo

# ----- 7. Validate + refresh desktop DB -------------------------------------

log "Step 7: validate + refresh desktop database"

if command -v desktop-file-validate >/dev/null 2>&1; then
    if desktop-file-validate "$USER_LAUNCHER" 2>&1 | sed 's/^/      /'; then
        ok "desktop-file-validate passed clean."
    else
        warn "desktop-file-validate printed warnings (see above). Cosmetic warnings are common; only abort if you see 'error:'."
    fi
else
    warn "desktop-file-validate not installed — skipping validation."
    warn "Install via: sudo apt install desktop-file-utils"
fi
echo

if command -v update-desktop-database >/dev/null 2>&1; then
    if update-desktop-database "$USER_APPS_DIR" 2>&1 | sed 's/^/      /'; then
        ok "Desktop database refreshed."
    else
        warn "update-desktop-database returned non-zero. Usually harmless; MIME re-indexing may be delayed until next login."
    fi
else
    warn "update-desktop-database not installed — skipping refresh."
fi
echo

# ----- 8. Final instructions -----------------------------------------------

echo "=============================================================="
echo "  Done. No reboot required."
echo
echo "  Next steps:"
echo "    1. Close any running Slack window (Ctrl+Q, or right-click"
echo "       the dock icon → Quit)."
echo "    2. Relaunch Slack from the dock or Activities."
echo "    3. Verify the jitter is gone — scroll a busy channel; text"
echo "       should be stable, sidebar edges crisp."
echo
echo "  Fallbacks (right-click Slack in the dock):"
echo "    • 'Open in X11 fallback mode' — if a Slack update breaks"
echo "      the Wayland path and you need XWayland temporarily."
echo "    • 'Open in debug mode'        — Wayland + GPU off + verbose"
echo "      logs, for filing bugs upstream."
echo
echo "  Verify native Wayland is active (launch Slack first, then):"
echo "    tr '\\0' ' ' < /proc/\$(pgrep -x slack | head -1)/cmdline"
echo "    # Should include --ozone-platform-hint=auto and NOT --ozone-platform=x11."
echo
if [[ -f "$BACKUP" ]]; then
    echo "  Rollback:"
    echo "    mv '$BACKUP' '$USER_LAUNCHER'"
    echo "    update-desktop-database '$USER_APPS_DIR'"
else
    echo "  Rollback:"
    echo "    rm '$USER_LAUNCHER'"
    echo "    update-desktop-database '$USER_APPS_DIR'"
    echo "    # (system launcher at $SYSTEM_LAUNCHER takes over.)"
fi
echo "=============================================================="
