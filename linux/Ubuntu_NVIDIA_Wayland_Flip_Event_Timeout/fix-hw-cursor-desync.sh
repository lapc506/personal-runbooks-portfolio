#!/usr/bin/env bash
# fix-hw-cursor-desync.sh
#
# Purpose: force mutter to use software cursor rendering across all
# surfaces, via MUTTER_DEBUG_FORCE_KMS_MODE=simple-copy, as a workaround
# for the NVIDIA hardware-cursor-plane desync on Wayland dma-buf clients
# (cursor becomes invisible over GL-rendered terminal windows but stays
# visible over the dock / top panel / overview).
#
# See ./README.md "Post-fix troubleshooting: cursor disappears over
# Wayland client windows" for the full diagnostic story.
#
# No sudo required — writes under $HOME. Requires full logout/login to
# take effect; systemd --user reads environment.d at session startup.

set -euo pipefail

log()  { printf '\e[1;34m[fix]\e[0m %s\n' "$*"; }
ok()   { printf '\e[1;32m[ok]\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m[warn]\e[0m %s\n' "$*"; }
fail() { printf '\e[1;31m[fail]\e[0m %s\n' "$*"; exit 1; }

if [[ $EUID -eq 0 ]]; then
    fail "Run as your normal user, NOT with sudo. The target file is under \$HOME."
fi

DROPIN_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/environment.d"
DROPIN_FILE="$DROPIN_DIR/90-mutter-nvidia-swcursor.conf"

echo "=============================================================="
echo "  Mutter: force software cursor (NVIDIA hw-plane desync fix)"
echo "=============================================================="

# ----- 1. Sanity checks ---------------------------------------------------

log "Step 1: sanity checks"

if [[ "${XDG_SESSION_TYPE:-}" != "wayland" ]]; then
    warn "Current session is '${XDG_SESSION_TYPE:-unset}', not 'wayland'."
    warn "This workaround only matters under Wayland. Skip if you're on X11."
fi

if ! lspci 2>/dev/null | grep -iE 'vga|3d|display' | grep -qi 'nvidia'; then
    warn "No NVIDIA GPU detected. This workaround is specific to NVIDIA. Proceeding anyway in case of dual-GPU misdetection."
fi

if ! pgrep -x gnome-shell >/dev/null && ! pgrep -x mutter >/dev/null; then
    warn "Neither gnome-shell nor mutter is running. The env var will still be set for the next session."
fi

ok "Proceeding."
echo

# ----- 2. Ensure target dir exists ---------------------------------------

log "Step 2: ensure $DROPIN_DIR exists"
mkdir -p "$DROPIN_DIR"
ok "Directory ready."
echo

# ----- 3. Write drop-in idempotently -------------------------------------

log "Step 3: write drop-in at $DROPIN_FILE"

EXPECTED_LINE='MUTTER_DEBUG_FORCE_KMS_MODE=simple-copy'

if [[ -f "$DROPIN_FILE" ]] && grep -qE "^${EXPECTED_LINE}\$" "$DROPIN_FILE"; then
    ok "Drop-in already contains the correct setting. No change needed."
else
    if [[ -f "$DROPIN_FILE" ]]; then
        BACKUP="${DROPIN_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
        cp -a "$DROPIN_FILE" "$BACKUP"
        warn "Existing file backed up to $BACKUP"
    fi
    cat > "$DROPIN_FILE" <<EOF
# Written by fix-hw-cursor-desync.sh on $(date -Iseconds)
# See: personal-runbooks-portfolio / linux / Ubuntu_NVIDIA_Wayland_Flip_Event_Timeout
#
# Force mutter to use simple-copy KMS mode, which bypasses hardware cursor
# planes across all surfaces. Workaround for the NVIDIA hardware-cursor-plane
# desync on Wayland dma-buf clients — symptom: cursor disappears over
# GL-rendered terminal windows but stays visible over GNOME Shell surfaces.
#
# Trade-off: mutter falls back to "composite to scratch, copy to scanout"
# mode, which disables direct-scanout optimizations (notably YUV video
# direct-scanout). Expect +1-3 W power draw on full-screen 4K video only.
${EXPECTED_LINE}
EOF
    chmod 644 "$DROPIN_FILE"
    ok "Wrote $DROPIN_FILE"
fi
echo

# ----- 4. Verify systemd --user will pick it up --------------------------

log "Step 4: verify systemd --user sees the new drop-in"

# systemd-environment-d-generator materializes environment.d into the user
# instance's environment at session start. We can invoke it standalone to
# preview what will be exported on next login.
if command -v /usr/lib/systemd/user-environment-generators/30-systemd-environment-d-generator >/dev/null; then
    PREVIEW=$(/usr/lib/systemd/user-environment-generators/30-systemd-environment-d-generator 2>/dev/null | grep '^MUTTER_DEBUG_FORCE_KMS_MODE=' || true)
    if [[ -n "$PREVIEW" ]]; then
        ok "Next login will export: $PREVIEW"
    else
        warn "Generator ran but didn't emit the expected var. Check file contents:"
        warn "  cat $DROPIN_FILE"
    fi
else
    warn "systemd-environment-d-generator not at the expected path. Skipping preview."
    warn "After logout/login, verify manually: env | grep MUTTER_DEBUG_FORCE_KMS_MODE"
fi
echo

# ----- 5. Final instructions ---------------------------------------------

echo "=============================================================="
echo "  Done. Full LOGOUT/LOGIN required."
echo
echo "  'killall -3 gnome-shell' does NOT pick up the new env var —"
echo "  the existing session's systemd --user instance has its"
echo "  environment frozen from when GDM spawned the session."
echo
echo "  After logging back in, verify:"
echo
echo "    env | grep MUTTER_DEBUG_FORCE_KMS_MODE"
echo "    # → MUTTER_DEBUG_FORCE_KMS_MODE=simple-copy"
echo
echo "  Then hover the cursor across a terminal window. Should remain"
echo "  visible continuously, no flicker/disappearance."
echo
echo "  Rollback:"
echo "    rm $DROPIN_FILE"
echo "    # then logout/login"
echo "=============================================================="
