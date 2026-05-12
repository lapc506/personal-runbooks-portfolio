#!/usr/bin/env bash
# diagnose-snap-electron-silent-exit.sh
#
# Purpose: read-only scan of every Electron-based snap on the system, looking
# for the specific failure pattern documented in this runbook:
#   - last entry in the snap's browser.log (or equivalent) is inside the
#     collectSystemInfo / getLinuxDistro init path
#   - Crashpad directory has no .dmp files newer than that log entry
#   - the audit log shows io_uring_setup (syscall 425) interception around the
#     failed launch timestamp
#
# Exit codes:
#   0 = no Electron snaps match the failure pattern (or no Electron snaps at all)
#   1 = at least one Electron snap matches (migration recommended)
#   2 = system is not Ubuntu-style snap-based (runbook doesn't apply)
#
# No writes to disk. No sudo required. Safe to run repeatedly.

set -euo pipefail

log()    { printf '\e[1;34m[scan]\e[0m %s\n' "$*"; }
ok()     { printf '\e[1;32m[ok]\e[0m %s\n' "$*"; }
warn()   { printf '\e[1;33m[warn]\e[0m %s\n' "$*"; }
match()  { printf '\e[1;31m[match]\e[0m %s\n' "$*"; }

MATCHES=0

echo "==============================================================="
echo "  Electron-snap silent-exit pattern scan"
echo "==============================================================="
echo

# ----- 1. Sanity check the platform -----------------------------------------

if ! command -v snap >/dev/null 2>&1; then
    warn "'snap' command not found — this system isn't snap-based. Runbook doesn't apply."
    exit 2
fi

if ! snap list >/dev/null 2>&1; then
    warn "'snap list' failed — snapd not running or user lacks access."
    exit 2
fi

# ----- 2. Known Electron snaps to inspect -----------------------------------

# (snap-name, expected-app-name-for-config-dir, expected-log-name)
# Add entries here when new Electron snaps appear in the wild.
ELECTRON_SNAPS=(
    "slack:Slack:browser.log"
    "discord:discord:main.log"
    "code:Code:main.log"
    "code-insiders:Code - Insiders:main.log"
    "cursor:Cursor:main.log"
    "obsidian:obsidian:main.log"
    "element-desktop:Element:main.log"
    "signal-desktop:Signal:main.log"
    "mattermost-desktop:Mattermost:main.log"
)

log "Scanning $(echo "${ELECTRON_SNAPS[@]}" | wc -w) known Electron snaps"
echo

# ----- 3. For each Electron snap, check the failure pattern ----------------

for entry in "${ELECTRON_SNAPS[@]}"; do
    snap_name="${entry%%:*}"
    rest="${entry#*:}"
    app_dir_name="${rest%:*}"
    log_name="${rest##*:}"

    if ! snap list "$snap_name" >/dev/null 2>&1; then
        continue
    fi

    snap_ver=$(snap list "$snap_name" 2>/dev/null | awk 'NR==2 {print $2}')
    snap_rev=$(snap list "$snap_name" 2>/dev/null | awk 'NR==2 {print $3}')

    log "Found snap: $snap_name $snap_ver (rev $snap_rev)"

    # Locate the config dir + log file
    config_dir="$HOME/snap/$snap_name/current/.config/$app_dir_name"
    log_file="$config_dir/logs/default/$log_name"

    # Some Electron apps don't have logs/default/; try fallback paths
    if [[ ! -f "$log_file" ]]; then
        for alt in "$config_dir/$log_name" "$config_dir/logs/$log_name" "$config_dir/logs/main.log"; do
            if [[ -f "$alt" ]]; then
                log_file="$alt"
                break
            fi
        done
    fi

    if [[ ! -f "$log_file" ]]; then
        warn "  No log file found at expected paths under $config_dir — skipping"
        continue
    fi

    log "  Inspecting $log_file"

    # ----- 3a. Look at the last 20 lines for init-path keywords -----
    last_lines=$(tail -20 "$log_file" 2>/dev/null || echo "")
    last_entry_inside_init=0

    if echo "$last_lines" | grep -qiE 'getLinuxDistro|collectSystemInfo|gpu-info-update.*event'; then
        # Heuristic: if the failure keyword appears in the last 10 lines and
        # nothing newer (no app.before-quit, no Network status check, no
        # web-contents loaded), treat as truncated-during-init.
        if echo "$last_lines" | tail -10 | grep -qE 'getLinuxDistro|collectSystemInfo'; then
            last_entry_inside_init=1
        fi
    fi

    # ----- 3b. Check Crashpad for recent dumps -----
    crashpad_dir="$config_dir/Crashpad"
    recent_dumps=0
    if [[ -d "$crashpad_dir" ]]; then
        recent_dumps=$(find "$crashpad_dir" -name "*.dmp" -mmin -30 2>/dev/null | wc -l)
    fi

    # ----- 3c. Check audit log for io_uring_setup interception ON THIS SNAP -----
    audit_io_uring=0
    if journalctl --since "1 hour ago" --no-pager 2>/dev/null | \
       grep -qE "audit.*snap\.$snap_name\.$snap_name.*syscall=425"; then
        audit_io_uring=1
    fi

    # ----- 3d. Verdict for this snap -----
    echo
    echo "    Last log entry inside init path:  $([[ $last_entry_inside_init -eq 1 ]] && echo 'YES (matches pattern)' || echo 'no')"
    echo "    Crashpad recent dumps:            $recent_dumps $([[ $recent_dumps -eq 0 ]] && echo '(no crash signal received)' || echo '(crash dump present — different failure)')"
    echo "    io_uring_setup intercepted:       $([[ $audit_io_uring -eq 1 ]] && echo 'YES (recent run)' || echo 'no (or too old)')"

    if [[ $last_entry_inside_init -eq 1 && $recent_dumps -eq 0 ]]; then
        match "  >>> PATTERN MATCH: $snap_name silent-exit during init <<<"
        match "  Recommendation: migrate $snap_name from snap to its native .deb (or Flathub equivalent)"
        if [[ "$snap_name" == "slack" ]]; then
            match "  For Slack: bash ./migrate-slack-snap-to-deb.sh"
        else
            match "  For $snap_name: adapt the migration script in this directory — the structure"
            match "  (backup → snap remove → install alternative → restore) generalizes; only"
            match "  download URL and \$HOME/.config path differ."
        fi
        MATCHES=$((MATCHES+1))
    elif [[ $last_entry_inside_init -eq 1 ]]; then
        warn "  Log pattern suggests init failure, but Crashpad shows a crash — different runbook"
    elif [[ $audit_io_uring -eq 1 && $recent_dumps -eq 0 ]]; then
        warn "  io_uring interception happened but log doesn't show init failure — partial match"
        warn "  If app fails to open intermittently, this runbook still likely applies"
    else
        ok "  No failure pattern detected for $snap_name"
    fi
    echo
done

# ----- 4. Final verdict -----------------------------------------------------

echo "==============================================================="
if [[ $MATCHES -eq 0 ]]; then
    ok "No Electron snaps match the silent-exit pattern."
    echo "  Either you don't have Electron snaps installed, or they're working correctly."
    echo "  (If a snap IS failing but didn't match, it might be a different runbook —"
    echo "   check Crashpad for .dmp files, or look in journalctl for explicit errors.)"
    echo "==============================================================="
    exit 0
else
    match "$MATCHES Electron snap(s) match the silent-exit-during-init pattern."
    echo
    echo "  See README.md in this directory for full root-cause analysis."
    echo "  For Slack specifically, run:"
    echo "      bash ./migrate-slack-snap-to-deb.sh"
    echo "==============================================================="
    exit 1
fi
