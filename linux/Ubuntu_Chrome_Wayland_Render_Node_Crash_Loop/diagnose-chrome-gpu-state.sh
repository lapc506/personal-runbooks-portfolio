#!/usr/bin/env bash
# diagnose-chrome-gpu-state.sh
#
# Decides whether Ubuntu_Chrome_Wayland_Render_Node_Crash_Loop applies to
# this machine, and validates the prerequisites of the rest of the runbook.
#
# Read-only. No side effects.
#
# Exit codes:
#   0 — runbook applies, prerequisites OK, ready for layers 2-4
#   1 — prerequisite cmdline parameters missing (apply sibling runbook first:
#       ../Ubuntu_NVIDIA_Wayland_Flip_Event_Timeout/enable-nvidia-drm-modeset.sh
#       then reboot, then re-run this script)
#   2 — hardware not eligible (no hybrid Intel+NVIDIA detected)
#   3 — session type not Wayland
#   4 — Vulkan ICDs incomplete (one of nvidia_icd.json / intel_icd.json missing)

set -euo pipefail

# ---- pretty output ---------------------------------------------------------
RED=$'\033[31m'; YEL=$'\033[33m'; GRN=$'\033[32m'; CYA=$'\033[36m'; RST=$'\033[0m'
BOLD=$'\033[1m'
log()   { printf '%s\n' "$*"; }
ok()    { printf '%s✔%s %s\n'   "$GRN" "$RST" "$*"; }
warn()  { printf '%s⚠%s %s\n'   "$YEL" "$RST" "$*" >&2; }
fail()  { printf '%s✘%s %s\n'   "$RED" "$RST" "$*" >&2; }
section(){ printf '\n%s== %s ==%s\n' "$BOLD" "$*" "$RST"; }

# ---- 1. Wayland session ----------------------------------------------------
section "Session type"
SESSION_TYPE="${XDG_SESSION_TYPE:-unknown}"
log "XDG_SESSION_TYPE = ${SESSION_TYPE}"
if [ "$SESSION_TYPE" != "wayland" ]; then
    fail "Not a Wayland session. The Ozone Wayland heuristic that triggers this bug only runs on Wayland."
    fail "If your session is X11, the failure mode in this runbook does not apply. Stop here."
    exit 3
fi
ok "Wayland session confirmed."

# ---- 2. Hybrid Intel + NVIDIA hardware -------------------------------------
section "GPU hardware"
# `-w` forces word-boundary matching so PCI vendor:device IDs that happen to
# contain "3d" as a substring (e.g. 8086:463d) do not get picked up here.
INTEL_GPU="$(lspci -nn 2>/dev/null | grep -iEw 'vga|3d|display' | grep -i intel || true)"
NVIDIA_GPU="$(lspci -nn 2>/dev/null | grep -iEw 'vga|3d|display' | grep -i nvidia || true)"
if [ -z "$INTEL_GPU" ] || [ -z "$NVIDIA_GPU" ]; then
    fail "Hybrid Intel + NVIDIA configuration not detected."
    [ -z "$INTEL_GPU" ]  && warn "  Intel GPU not found via lspci."
    [ -z "$NVIDIA_GPU" ] && warn "  NVIDIA GPU not found via lspci."
    fail "This runbook is specific to Optimus-style laptops. Stop here."
    exit 2
fi
ok "Intel iGPU:  ${INTEL_GPU#*: }"
ok "NVIDIA dGPU: ${NVIDIA_GPU#*: }"

# ---- 3. DRI render nodes present -------------------------------------------
section "DRI render nodes"
for node in /dev/dri/renderD128 /dev/dri/renderD129; do
    if [ -e "$node" ]; then
        ok "$node present ($(stat -c '%U:%G %a' "$node"))"
    else
        warn "$node missing — Chrome's Ozone selection may pick an unexpected device."
    fi
done

# ---- 4. nvidia-drm cmdline (the HARD prerequisite) -------------------------
section "Kernel command line — nvidia-drm parameters"
CMDLINE="$(cat /proc/cmdline)"
log "/proc/cmdline = ${CMDLINE}"
MODESET_PRESENT=0; FBDEV_PRESENT=0
grep -qE 'nvidia-drm\.modeset=1' /proc/cmdline && MODESET_PRESENT=1
grep -qE 'nvidia-drm\.fbdev=1'   /proc/cmdline && FBDEV_PRESENT=1
if [ "$MODESET_PRESENT" -ne 1 ] || [ "$FBDEV_PRESENT" -ne 1 ]; then
    fail "Prerequisite NOT satisfied:"
    [ "$MODESET_PRESENT" -ne 1 ] && fail "  Missing nvidia-drm.modeset=1 on /proc/cmdline"
    [ "$FBDEV_PRESENT"   -ne 1 ] && fail "  Missing nvidia-drm.fbdev=1   on /proc/cmdline"
    log
    log "${CYA}Apply the sibling runbook first:${RST}"
    log "  cd ../Ubuntu_NVIDIA_Wayland_Flip_Event_Timeout"
    log "  sudo bash ./enable-nvidia-drm-modeset.sh"
    log "  sudo reboot"
    log "  # then re-run this diagnostic"
    exit 1
fi
ok "nvidia-drm.modeset=1 and nvidia-drm.fbdev=1 are active on cmdline."

# ---- 5. nvidia-smi enumerable ---------------------------------------------
section "NVIDIA driver state"
if command -v nvidia-smi >/dev/null 2>&1; then
    if SMI_OUT="$(nvidia-smi --query-gpu=name,driver_version,pstate --format=csv,noheader 2>&1)"; then
        ok "nvidia-smi: ${SMI_OUT}"
    else
        fail "nvidia-smi failed: ${SMI_OUT}"
        warn "NVIDIA driver loaded but not responsive. Reboot or reload modules before applying the policy."
        exit 1
    fi
else
    fail "nvidia-smi not installed. Install nvidia-driver-580 (or later) before proceeding."
    exit 1
fi

# ---- 6. Vulkan ICDs available ---------------------------------------------
section "Vulkan ICDs"
NV_ICD=/usr/share/vulkan/icd.d/nvidia_icd.json
IN_ICD=/usr/share/vulkan/icd.d/intel_icd.json
ICD_OK=1
[ -f "$NV_ICD" ] && ok "nvidia_icd.json present" || { fail "nvidia_icd.json missing — install nvidia-driver-* or libnvidia-gl-*"; ICD_OK=0; }
[ -f "$IN_ICD" ] && ok "intel_icd.json present"  || { fail "intel_icd.json missing  — install mesa-vulkan-drivers";       ICD_OK=0; }
[ "$ICD_OK" -eq 1 ] || exit 4

# ---- 7. Recent NVIDIA flip-event-timeout errors ----------------------------
section "Journal scan for nv_drm_atomic_commit errors"
THIS_BOOT="$(journalctl -b 0 --no-pager 2>/dev/null | grep -cE 'nv_drm_atomic_commit|nvidia-modeset: ERROR' || true)"
PREV_BOOT="$(journalctl -b -1 --no-pager 2>/dev/null | grep -cE 'nv_drm_atomic_commit|nvidia-modeset: ERROR' || true)"
log "this boot: ${THIS_BOOT} hits"
log "prev boot: ${PREV_BOOT} hits"
if [ "$THIS_BOOT" -gt 0 ]; then
    warn "NVIDIA flip-event-timeouts are happening RIGHT NOW. Even with the cmdline fix, something else is degrading."
    warn "Check for a kernel update mismatch, suspended GPU, or external display cable issues before pinning the policy."
fi

# ---- 8. Per-profile Chrome state ------------------------------------------
section "Chrome profile inventory"
PROFILE_DIRS=( "$HOME"/.config/google-chrome-* )
if [ ! -e "${PROFILE_DIRS[0]}" ]; then
    warn "No google-chrome-* profile directories found in ~/.config/. Nothing to repair."
else
    printf '%-22s  %-10s  %-22s  %s\n' 'profile' 'GPUCache' 'last cache write' 'crash_count'
    printf '%-22s  %-10s  %-22s  %s\n' '-------' '--------' '----------------' '-----------'
    for dir in "${PROFILE_DIRS[@]}"; do
        prof="$(basename "$dir")"
        prof="${prof#google-chrome-}"
        gpucache="${dir}/GPUCache"
        if [ -d "$gpucache" ]; then
            sz="$(du -sh "$gpucache" 2>/dev/null | awk '{print $1}')"
            mtime="$(stat -c '%y' "$gpucache" | cut -d. -f1)"
        else
            sz="-"; mtime="(none)"
        fi
        # Crash count is in Local State under gpu.gpu_count (varies by Chrome version).
        # We just report whether Chrome marked the profile as crashed last exit.
        crash="?"
        if [ -f "${dir}/Default/Preferences" ]; then
            crash="$(python3 -c "
import json,sys
try:
    d=json.load(open('${dir}/Default/Preferences'))
    print(d.get('profile',{}).get('exit_type','Normal'))
except Exception:
    print('?')
" 2>/dev/null)"
        fi
        printf '%-22s  %-10s  %-22s  %s\n' "$prof" "$sz" "$mtime" "$crash"
    done
fi

# ---- 9. Verdict -----------------------------------------------------------
section "Verdict"
ok "Prerequisites satisfied. Runbook applies."
log
log "Next steps:"
log "  bash ./audit-chrome-launchers.sh                           # read-only sanity check"
log "  bash ./repair-chrome-profile-gpu.sh <profile>              # one profile at a time"
log "  bash ./pin-chrome-gpu-policy.sh                            # durable fix, all six profiles"
log "  # then logout/login so mutter re-reads the launcher dir"
exit 0
