#!/usr/bin/env bash
# repair-chrome-profile-gpu.sh <profile>
#
# Resets Chrome's 3-strike GPU process supervisor for a single profile.
#
# When Chrome's GPU process has crashed three times for a given profile, the
# supervisor latches `Disabled Features: all` until the on-disk caches the
# supervisor inspects on boot are gone. This script clears those caches and
# the persisted gpu state in `Local State`, so Chrome's next launch treats
# the profile as fresh and re-attempts hardware acceleration.
#
# Refuses to operate while Chrome is running for the target profile — the user
# must close those windows first. The script does NOT kill processes, so an
# interrupted operation cannot corrupt an in-flight Chrome session.
#
# Idempotent. Safe to re-run. Always backs up Local State before clearing.
#
# Exit codes:
#   0 — repair completed (or nothing was needed)
#   1 — invalid arguments / profile not found
#   2 — Chrome is currently running for this profile (close it and retry)

set -euo pipefail

usage() {
    cat <<EOF
usage: $(basename "$0") <profile-suffix>

  profile-suffix is the part after "google-chrome-" in the config directory
  name. The directory must already exist.

Examples:
  $(basename "$0") lapc506
  $(basename "$0") dojocoding

To repair every profile in this setup:
  for p in altrupets demolabcr dojocoding habitanexus lapc506 vertivolatam; do
      bash $(basename "$0") "\$p"
  done
EOF
}

if [ "$#" -ne 1 ] || [ -z "${1:-}" ]; then
    usage >&2
    exit 1
fi

PROF="$1"
DIR="$HOME/.config/google-chrome-${PROF}"

RED=$'\033[31m'; YEL=$'\033[33m'; GRN=$'\033[32m'; CYA=$'\033[36m'; RST=$'\033[0m'; BOLD=$'\033[1m'
ok()    { printf '%s✔%s %s\n' "$GRN" "$RST" "$*"; }
warn()  { printf '%s⚠%s %s\n' "$YEL" "$RST" "$*" >&2; }
fail()  { printf '%s✘%s %s\n' "$RED" "$RST" "$*" >&2; }

if [ ! -d "$DIR" ]; then
    fail "Profile directory does not exist: $DIR"
    fail "Available profiles:"
    ls -d "$HOME"/.config/google-chrome-* 2>/dev/null | sed 's|.*/google-chrome-|  |' >&2 || true
    exit 1
fi

# ---- safety: refuse if Chrome is running for this profile ------------------
# `pgrep -af` matches the full command line; we look specifically for the
# --user-data-dir path of this profile so other profiles' Chrome instances
# don't trigger a false positive.
if pgrep -af -- "--user-data-dir=${DIR}\b" >/dev/null 2>&1; then
    fail "Chrome is currently running with profile '${PROF}'."
    fail "Close every window of that profile first, then re-run this script."
    fail "Matching processes:"
    pgrep -af -- "--user-data-dir=${DIR}\b" | sed 's/^/  /' >&2
    exit 2
fi
ok "No running Chrome for profile '${PROF}'."

# ---- backup Local State ----------------------------------------------------
TS="$(date +%Y%m%d-%H%M%S)"
LS="$DIR/Local State"
if [ -f "$LS" ]; then
    BAK="${LS}.bak.${TS}"
    cp -p "$LS" "$BAK"
    ok "Local State backed up to: $(basename "$BAK")"
else
    warn "No Local State file in $DIR (profile may have never launched). Continuing."
fi

# ---- clear the GPU caches the supervisor inspects --------------------------
# The set of cache directories has grown across Chrome versions. Clear all
# known names — missing ones are no-ops.
CACHES=(
    "$DIR/GPUCache"
    "$DIR/ShaderCache"
    "$DIR/GrShaderCache"
    "$DIR/GraphiteDawnCache"
    "$DIR/Default/GPUCache"
    "$DIR/Default/ShaderCache"
    "$DIR/Default/GrShaderCache"
    "$DIR/Default/GraphiteDawnCache"
    "$DIR/ANGLECache"
)
removed=0
for c in "${CACHES[@]}"; do
    if [ -e "$c" ]; then
        rm -rf -- "$c"
        printf '  cleared %s\n' "$c"
        removed=$((removed+1))
    fi
done
if [ "$removed" -gt 0 ]; then
    ok "${removed} cache director(y/ies) cleared."
else
    ok "No GPU cache directories present (already clean)."
fi

# ---- clear the persisted gpu block in Local State --------------------------
# The cache deletion above is the primary reset path on modern Chrome, but
# older builds also consult Local State.gpu for the crash counter. Clearing
# both is redundant and zero-cost.
if [ -f "$LS" ]; then
    python3 - <<PY
import json, sys, os
path = "$LS"
with open(path, 'r') as f:
    d = json.load(f)
changed = False
if 'gpu' in d:
    del d['gpu']
    changed = True
# Some Chrome versions also persist forced_software_compositing here:
if 'browser' in d and 'forced_software_compositing' in d.get('browser', {}):
    del d['browser']['forced_software_compositing']
    changed = True
# Reset the exit_type guard so Chrome doesn't restore-tabs-after-crash either:
prof = d.get('profile', {})
# Iterate any per-profile sub-dicts inside browser.profile (Chromium variant):
if isinstance(prof, dict):
    for k, v in list(prof.items()):
        if isinstance(v, dict) and v.get('exit_type') == 'Crashed':
            v['exit_type'] = 'Normal'
            changed = True
if changed:
    tmp = path + ".tmp"
    with open(tmp, 'w') as f:
        json.dump(d, f, indent=2)
    os.replace(tmp, path)
    print("  Local State: gpu block dropped, exit_type normalized")
else:
    print("  Local State: nothing to clean (no gpu block, no Crashed exit)")
PY
fi

# ---- final status ----------------------------------------------------------
printf '\n%s✔%s Repair complete for profile %s%s%s.\n' "$GRN" "$RST" "$BOLD" "$PROF" "$RST"
printf '\n%sNext launch:%s\n' "$CYA" "$RST"
printf '  1. Open the profile from the dock.\n'
printf '  2. Visit chrome://gpu and confirm:\n'
printf '       Graphics Feature Status: WebGL → Hardware accelerated\n'
printf '       GPU0: VENDOR=0x10de (NVIDIA) or 0x8086 (Intel iGPU)\n'
printf '       GPU process crash count: 0\n'
printf '       Problems Detected: no "GPU access is disabled due to frequent crashes" line\n'
printf '\n'
exit 0
