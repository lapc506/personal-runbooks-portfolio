#!/usr/bin/env bash
# audit-chrome-launchers.sh
#
# Walks the Chrome-profile launcher pair and reports their state. Read-only.
#
# Each Chrome profile in this setup has TWO .desktop files that must stay in
# byte-exact sync:
#   ~/.local/share/applications/chrome-<profile>.desktop   (used by Ubuntu Dock)
#   ~/Escritorio/chrome-<profile>.desktop                  (used by Files double-click)
#
# This script:
#   - lists each pair
#   - confirms identity (asymmetry = failure)
#   - reports whether the NVIDIA env-var prefix is present in Exec= (i.e., this
#     runbook has been applied)
#   - reports whether the [Desktop Action open-igpu] / [Desktop Action
#     new-window-igpu] blocks exist
#   - cross-checks against the actual ~/.config/google-chrome-<profile>/
#     directories (orphan launcher, missing launcher)
#
# Exit codes:
#   0 — coherent state (whether already-pinned or not-yet-pinned)
#   1 — asymmetry detected: one of the pair differs from the other, or one
#       half is missing, or env-var prefix is in one copy but not the other

set -euo pipefail

PROFILES=( altrupets demolabcr dojocoding habitanexus lapc506 vertivolatam )
APPDIR="$HOME/.local/share/applications"
DSKDIR="$HOME/Escritorio"

# Pattern that identifies the NVIDIA env-var prefix this runbook injects.
# If a future Chrome / NVIDIA driver release renames a variable, change here.
NV_PREFIX_PATTERN='__NV_PRIME_RENDER_OFFLOAD=1'

RED=$'\033[31m'; YEL=$'\033[33m'; GRN=$'\033[32m'; RST=$'\033[0m'; BOLD=$'\033[1m'
ok()    { printf '  %s✔%s %s\n' "$GRN" "$RST" "$*"; }
warn()  { printf '  %s⚠%s %s\n' "$YEL" "$RST" "$*"; }
fail()  { printf '  %s✘%s %s\n' "$RED" "$RST" "$*"; }

asymmetry=0
total_pinned=0
total_unpinned=0

printf '%sAuditing Chrome launcher pairs...%s\n' "$BOLD" "$RST"
printf '  application dir: %s\n' "$APPDIR"
printf '  desktop dir:     %s\n\n' "$DSKDIR"

for prof in "${PROFILES[@]}"; do
    a="$APPDIR/chrome-${prof}.desktop"
    b="$DSKDIR/chrome-${prof}.desktop"
    cfg="$HOME/.config/google-chrome-${prof}"
    printf '%schrome-%s.desktop%s\n' "$BOLD" "$prof" "$RST"

    # 1. Both halves must exist
    a_present=0; b_present=0
    [ -f "$a" ] && a_present=1
    [ -f "$b" ] && b_present=1
    if [ "$a_present" -eq 0 ] && [ "$b_present" -eq 0 ]; then
        warn "neither half exists (profile not installed)"
        printf '\n'; continue
    fi
    if [ "$a_present" -eq 0 ]; then
        fail "missing in $APPDIR/ (only $DSKDIR/ has it). Dock will not show this launcher."
        asymmetry=1
    elif [ "$b_present" -eq 0 ]; then
        fail "missing in $DSKDIR/ (only $APPDIR/ has it). Desktop double-click will fail."
        asymmetry=1
    else
        ok "both halves present"
    fi

    # 2. Halves must be byte-identical
    if [ "$a_present" -eq 1 ] && [ "$b_present" -eq 1 ]; then
        if diff -q "$a" "$b" >/dev/null 2>&1; then
            ok "halves are byte-identical"
        else
            fail "halves DIFFER — they have drifted out of sync:"
            diff "$a" "$b" | sed 's/^/      /'
            asymmetry=1
        fi
    fi

    # 3. NVIDIA env-var prefix presence (this runbook applied?)
    pinned_a=0; pinned_b=0
    [ "$a_present" -eq 1 ] && grep -qF "$NV_PREFIX_PATTERN" "$a" && pinned_a=1
    [ "$b_present" -eq 1 ] && grep -qF "$NV_PREFIX_PATTERN" "$b" && pinned_b=1
    if [ "$pinned_a" -eq 1 ] && [ "$pinned_b" -eq 1 ]; then
        ok "GPU policy pinned (NVIDIA-by-default env vars present)"
        total_pinned=$((total_pinned+1))
    elif [ "$pinned_a" -eq 0 ] && [ "$pinned_b" -eq 0 ]; then
        warn "GPU policy NOT pinned (run pin-chrome-gpu-policy.sh)"
        total_unpinned=$((total_unpinned+1))
    else
        fail "GPU policy is pinned in only one half — asymmetric"
        asymmetry=1
    fi

    # 4. Intel-iGPU fallback Action presence
    action_a=0; action_b=0
    [ "$a_present" -eq 1 ] && grep -q '^\[Desktop Action open-igpu\]' "$a" && action_a=1
    [ "$b_present" -eq 1 ] && grep -q '^\[Desktop Action open-igpu\]' "$b" && action_b=1
    if [ "$action_a" -eq 1 ] && [ "$action_b" -eq 1 ]; then
        ok "Intel iGPU fallback Action is registered"
    elif [ "$action_a" -eq 0 ] && [ "$action_b" -eq 0 ]; then
        warn "Intel iGPU fallback Action not registered"
    else
        fail "Intel iGPU fallback Action is in only one half — asymmetric"
        asymmetry=1
    fi

    # 5. Cross-check with profile config dir
    if [ -d "$cfg" ]; then
        ok "profile dir exists: $cfg"
    else
        warn "profile dir MISSING: $cfg (orphan launcher — Chrome will create it on first launch)"
    fi
    printf '\n'
done

printf '%sSummary%s\n' "$BOLD" "$RST"
printf '  pinned:   %d / %d profiles\n' "$total_pinned"   "${#PROFILES[@]}"
printf '  unpinned: %d / %d profiles\n' "$total_unpinned" "${#PROFILES[@]}"

if [ "$asymmetry" -ne 0 ]; then
    printf '\n%s✘%s Asymmetry detected. Run pin-chrome-gpu-policy.sh to re-sync.\n' "$RED" "$RST"
    exit 1
fi

if [ "$total_pinned" -eq "${#PROFILES[@]}" ]; then
    printf '\n%s✔%s Coherent state: all profiles pinned. No action needed.\n' "$GRN" "$RST"
elif [ "$total_unpinned" -eq "${#PROFILES[@]}" ]; then
    printf '\n%s✔%s Coherent state: no profiles pinned yet. Run pin-chrome-gpu-policy.sh when ready.\n' "$GRN" "$RST"
else
    printf '\n%s✔%s Coherent state per profile, but mixed (some pinned, some not). pin-chrome-gpu-policy.sh is idempotent — it will pin only the ones that need it.\n' "$GRN" "$RST"
fi
exit 0
