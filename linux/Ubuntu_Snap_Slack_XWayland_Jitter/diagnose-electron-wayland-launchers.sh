#!/usr/bin/env bash
# diagnose-electron-wayland-launchers.sh
#
# Purpose: scan every .desktop file in the XDG lookup path, identify the
# ones that launch Electron-based apps, and report whether each one is
# forcing XWayland (--ozone-platform=x11 / WAYLAND_DISPLAY= blanking) or
# letting Electron auto-pick the backend.
#
# Also flags cases where a user-scope .desktop file is shadowing a
# system-scope one -- a common source of silent "why does this app still
# run on X11" head-scratching.
#
# Exit codes:
#   0  = no Electron launcher forces XWayland (all good, or no Electron apps found)
#   1  = at least one Electron launcher forces XWayland on a Wayland session
#   2  = session is not Wayland, runbook does not apply
#
# No sudo required. Read-only diagnostic.

set -uo pipefail

ok()   { printf '\e[1;32m[ok]\e[0m   %s\n' "$*"; }
warn() { printf '\e[1;33m[warn]\e[0m %s\n' "$*"; }
bad()  { printf '\e[1;31m[!!]\e[0m   %s\n' "$*"; }
info() { printf '\e[1;34m[..]\e[0m   %s\n' "$*"; }
sep()  { printf '\e[2m%s\e[0m\n' '--------------------------------------------------------------'; }

# ---------------------------------------------------------------------------
# List of Electron-based apps (regex patterns matched against the Exec line).
# Each entry is: "<pretty name>|<grep -E pattern>"
# ---------------------------------------------------------------------------

ELECTRON_APPS=(
    "Slack|(/snap/bin/slack|/usr/bin/slack\b|com\.slack\.Slack)"
    "Discord|(/snap/bin/discord|/usr/bin/discord\b|com\.discordapp\.Discord)"
    "VSCode|(/snap/bin/code\b|/usr/bin/code\b|/usr/share/code/code\b|com\.visualstudio\.code)"
    "VSCodium|(/snap/bin/codium|/usr/bin/codium|com\.vscodium\.codium)"
    "Cursor|(/usr/bin/cursor\b|/opt/cursor|Cursor\.AppImage)"
    "Obsidian|(/snap/bin/obsidian|/usr/bin/obsidian\b|md\.obsidian\.Obsidian)"
    "Element|(/snap/bin/element-desktop|/usr/bin/element-desktop|im\.riot\.Riot|io\.element\.Element)"
    "Signal|(/snap/bin/signal-desktop|/usr/bin/signal-desktop|org\.signal\.Signal)"
    "Teams|(/snap/bin/teams|/usr/bin/teams-for-linux|com\.microsoft\.Teams)"
    "Zoom|(/usr/bin/zoom\b|/snap/bin/zoom-client|us\.zoom\.Zoom)"
    "Mattermost|(/snap/bin/mattermost-desktop|/usr/bin/mattermost-desktop|com\.mattermost\.Desktop)"
    "Rocket.Chat|(/snap/bin/rocketchat-desktop|/usr/bin/rocketchat-desktop|chat\.rocket\.RocketChat)"
    "Joplin|(/snap/bin/joplin-desktop|/usr/bin/joplin-desktop|net\.cozic\.joplin_desktop)"
    "WhatsApp|(/snap/bin/whatsdesk|/snap/bin/whatsapp-for-linux|com\.github\.eneshecan\.WhatsAppForLinux)"
    "Figma|(/snap/bin/figma-linux|/usr/bin/figma-linux|io\.github\.Figma_Linux\.figma_linux)"
    "Postman|(/snap/bin/postman|/usr/bin/postman|com\.getpostman\.Postman)"
    "Notion|(/snap/bin/notion-snap|/opt/Notion|notion-app-enhanced)"
    "Todoist|(/snap/bin/todoist|/usr/bin/todoist|com\.todoist\.Todoist)"
    "Trello|(/snap/bin/trello|/usr/bin/trello-desktop|com\.trello\.Trello)"
    "GitHub Desktop|(/snap/bin/github-desktop|/usr/bin/github-desktop|io\.github\.shiftey\.Desktop)"
)

XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"

SEARCH_PATHS=(
    "$XDG_DATA_HOME/applications"
    "$XDG_DATA_HOME/flatpak/exports/share/applications"
    "/var/lib/flatpak/exports/share/applications"
    "/var/lib/snapd/desktop/applications"
    "/usr/share/applications"
    "/usr/local/share/applications"
)

echo "=============================================================="
echo "  Diagnose: Electron apps forcing XWayland on this session"
echo "=============================================================="
echo

# ----- 0. Session type ------------------------------------------------------

info "Session: XDG_SESSION_TYPE='${XDG_SESSION_TYPE:-unset}'"
if [[ "${XDG_SESSION_TYPE:-}" != "wayland" ]]; then
    warn "This diagnostic is only relevant on a Wayland session."
    warn "On X11, Electron running through X11 is the expected path (there is no XWayland to avoid)."
    echo
    echo "Exiting with code 2."
    exit 2
fi
ok "Wayland session confirmed."
echo

# ----- 1. Scan all search paths --------------------------------------------

info "Scanning XDG desktop-entry paths for Electron app launchers..."
echo

declare -a FOUND_FILES=()

for DIR in "${SEARCH_PATHS[@]}"; do
    if [[ ! -d "$DIR" ]]; then continue; fi
    while IFS= read -r -d '' FILE; do
        FOUND_FILES+=("$FILE")
    done < <(find "$DIR" -maxdepth 2 -name '*.desktop' -print0 2>/dev/null)
done

if [[ "${#FOUND_FILES[@]}" -eq 0 ]]; then
    warn "No .desktop files found in any XDG path. Nothing to diagnose."
    exit 0
fi

info "Found ${#FOUND_FILES[@]} total .desktop files across all paths."
echo

# ----- 2. Filter to Electron launchers + classify each ---------------------

PROBLEMS=0
SHADOWED=0
TOTAL_ELECTRON=0

classify_launcher_cmd() {
    local cmd_line="$1"
    if grep -qE '\-\-ozone-platform=wayland\b' <<<"$cmd_line"; then
        echo "WAYLAND_FORCED"
    elif grep -qE '\-\-ozone-platform-hint=(auto|wayland)\b' <<<"$cmd_line"; then
        echo "WAYLAND_HINT"
    elif grep -qE '(WAYLAND_DISPLAY=\s|--ozone-platform=x11)' <<<"$cmd_line"; then
        echo "X11_FORCED"
    else
        echo "UNSPECIFIED"
    fi
}

read_launcher_cmd() {
    local file="$1" line
    line=$(grep -m1 '^Exec=' "$file" 2>/dev/null | sed 's/^Exec=//')
    printf '%s\n' "$line"
}

declare -A SEEN_BY_BASENAME=()

for APP_ENTRY in "${ELECTRON_APPS[@]}"; do
    PRETTY="${APP_ENTRY%%|*}"
    # Use shortest-match trim (#*|) because PATTERN itself contains '|' for regex alternation.
    PATTERN="${APP_ENTRY#*|}"

    MATCHED_FILES=()
    for FILE in "${FOUND_FILES[@]}"; do
        LAUNCH_LINE=$(grep -m1 '^Exec=' "$FILE" 2>/dev/null || true)
        [[ -z "$LAUNCH_LINE" ]] && continue
        if grep -qE "$PATTERN" <<<"$LAUNCH_LINE"; then
            MATCHED_FILES+=("$FILE")
        fi
    done

    [[ "${#MATCHED_FILES[@]}" -eq 0 ]] && continue
    TOTAL_ELECTRON=$((TOTAL_ELECTRON + 1))

    sep
    echo "  App: $PRETTY"
    for FILE in "${MATCHED_FILES[@]}"; do
        BASENAME=$(basename "$FILE")
        LAUNCH_CMD=$(read_launcher_cmd "$FILE")
        KIND=$(classify_launcher_cmd "$LAUNCH_CMD")

        SCOPE="system"
        case "$FILE" in
            "$XDG_DATA_HOME"/*) SCOPE="user" ;;
        esac

        if [[ -n "${SEEN_BY_BASENAME[$BASENAME]:-}" ]]; then
            PREV="${SEEN_BY_BASENAME[$BASENAME]}"
            PREV_SCOPE="system"
            case "$PREV" in
                "$XDG_DATA_HOME"/*) PREV_SCOPE="user" ;;
            esac
            if [[ "$SCOPE" != "$PREV_SCOPE" ]]; then
                warn "  (shadow) user-scope and system-scope both exist for $BASENAME"
                warn "          the user-scope one wins the XDG lookup."
                SHADOWED=$((SHADOWED + 1))
            fi
        else
            SEEN_BY_BASENAME[$BASENAME]="$FILE"
        fi

        case "$KIND" in
            X11_FORCED)
                bad "  [$SCOPE] $FILE"
                bad "         Launcher forces XWayland:"
                echo "           $LAUNCH_CMD" | fold -s -w 74 | sed 's/^/           /'
                PROBLEMS=$((PROBLEMS + 1))
                ;;
            WAYLAND_FORCED)
                ok "  [$SCOPE] $FILE"
                echo "           (explicit --ozone-platform=wayland; works but will fail if launched from X11)"
                ;;
            WAYLAND_HINT)
                ok "  [$SCOPE] $FILE"
                echo "           (modern --ozone-platform-hint=auto -- recommended)"
                ;;
            UNSPECIFIED)
                warn "  [$SCOPE] $FILE"
                warn "         Launcher does not specify Ozone backend. Electron auto-picks:"
                echo "           $LAUNCH_CMD" | fold -s -w 74 | sed 's/^/           /'
                ;;
        esac
    done
done

sep
echo

# ----- 3. Final verdict -----------------------------------------------------

echo "=============================================================="
echo "  Summary"
echo "    Electron launchers found:          $TOTAL_ELECTRON"
echo "    Forcing XWayland on Wayland:       $PROBLEMS  (fix needed)"
echo "    User-shadowing-system cases:       $SHADOWED"
echo "=============================================================="
echo

if [[ "$PROBLEMS" -gt 0 ]]; then
    bad "At least one Electron launcher is forcing XWayland on a Wayland session."
    echo
    echo "  For Slack specifically, run:"
    echo "      bash ./repair-slack-launcher.sh"
    echo
    echo "  For other Electron apps (Discord, Obsidian, etc.), the pattern is the same:"
    echo "    1. Locate the user-scope .desktop at \$XDG_DATA_HOME/applications/<name>.desktop"
    echo "    2. Remove 'WAYLAND_DISPLAY=' and '--ozone-platform=x11' from its launcher line"
    echo "    3. Add '--ozone-platform-hint=auto --enable-features=WaylandWindowDecorations'"
    echo "    4. Run: update-desktop-database ~/.local/share/applications/"
    echo
    exit 1
fi

if [[ "$TOTAL_ELECTRON" -eq 0 ]]; then
    info "No known Electron apps detected on this system. Nothing to fix."
else
    ok "All detected Electron launchers use Wayland-compatible invocation."
fi

exit 0
