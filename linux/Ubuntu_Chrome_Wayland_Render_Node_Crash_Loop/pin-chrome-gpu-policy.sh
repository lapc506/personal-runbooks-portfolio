#!/usr/bin/env bash
# pin-chrome-gpu-policy.sh [--force]
#
# The durable fix. Pins an explicit GPU policy on every Chrome profile launcher
# so Ozone Wayland can no longer auto-select an unstable render node and trip
# the 3-strike GPU process supervisor.
#
# Policy:
#   default  -> NVIDIA dGPU via PRIME render offload (env vars on launch line)
#   right-click "Abrir con Intel iGPU" -> Intel iGPU fallback
#
# Touches the launcher pair atomically: every change applied to
# ~/.local/share/applications/chrome-*.desktop is mirrored to
# ~/Escritorio/chrome-*.desktop. Each file is backed up before rewrite.
#
# Idempotent. Pass --force to rewrite already-pinned launchers.
#
# Exit codes:
#   0 - pinned (or already pinned, no-op)
#   1 - prerequisite failed
#   2 - write error
#   3 - post-condition audit failed

set -euo pipefail

PROFILES=( altrupets demolabcr dojocoding habitanexus lapc506 vertivolatam )
APPDIR="$HOME/.local/share/applications"
DSKDIR="$HOME/Escritorio"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NV_ENV='env __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia __VK_LAYER_NV_optimus=NVIDIA_only VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/nvidia_icd.json'
IN_ENV='env DRI_PRIME=0 __GLX_VENDOR_LIBRARY_NAME=mesa VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/intel_icd.json MESA_VK_DEVICE_SELECT=8086:*'
NV_PREFIX_PATTERN='__NV_PRIME_RENDER_OFFLOAD=1'

FORCE=0
case "${1:-}" in
    --force) FORCE=1 ;;
    "") ;;
    *) echo "usage: $(basename "$0") [--force]" >&2; exit 1 ;;
esac

RED=$'\033[31m'; YEL=$'\033[33m'; GRN=$'\033[32m'; CYA=$'\033[36m'; RST=$'\033[0m'; BOLD=$'\033[1m'
log()    { printf '%s\n' "$*"; }
ok()     { printf '%s%s%s %s\n' "$GRN" "OK" "$RST" "$*"; }
warn()   { printf '%s%s%s %s\n' "$YEL" "WARN" "$RST" "$*" >&2; }
fail()   { printf '%s%s%s %s\n' "$RED" "FAIL" "$RST" "$*" >&2; }
section(){ printf '\n%s== %s ==%s\n' "$BOLD" "$*" "$RST"; }

# 1. Prerequisite check
section "Prerequisite check"
if ! bash "${SCRIPT_DIR}/diagnose-chrome-gpu-state.sh"; then
    fail "Diagnostic failed. Resolve the issues above before pinning the policy."
    exit 1
fi

TS="$(date +%Y%m%d-%H%M%S)"
export PIN_TS="$TS"

rewrite_one() {
    local src="$1"
    python3 - "$src" "$NV_ENV" "$IN_ENV" "$NV_PREFIX_PATTERN" "$FORCE" <<'PY'
import sys, os, re, shutil

src        = sys.argv[1]
nv_env     = sys.argv[2]
in_env     = sys.argv[3]
nv_pattern = sys.argv[4]
force      = sys.argv[5] == "1"

with open(src, 'r', encoding='utf-8') as f:
    text = f.read()

if nv_pattern in text and not force:
    print(f"  SKIP {src} - already pinned")
    sys.exit(0)

ts = os.environ.get("PIN_TS", "manual")
bak = src + ".bak." + ts
shutil.copy2(src, bak)

# Step 1: rewrite Exec= lines that invoke /usr/bin/google-chrome.
def fix_exec_line(line: str) -> str:
    m = re.match(r'^(Exec=)(.*?)(/usr/bin/google-chrome)(.*)$', line)
    if not m:
        return line
    head, prefix, binary, rest = m.group(1), m.group(2).strip(), m.group(3), m.group(4)
    if nv_pattern in prefix:
        return line
    return f"{head}{nv_env} {binary}{rest}\n"

new_lines = []
for line in text.splitlines(keepends=True):
    if line.startswith('Exec='):
        new_lines.append(fix_exec_line(line))
    else:
        new_lines.append(line)
text2 = ''.join(new_lines)

# Step 2: ensure Actions= lists open-igpu and new-window-igpu (in [Desktop Entry] only).
def fix_actions(t: str) -> str:
    lines = t.splitlines(keepends=True)
    in_entry = False
    out = []
    for ln in lines:
        s = ln.strip()
        if s == '[Desktop Entry]':
            in_entry = True
            out.append(ln); continue
        if s.startswith('[Desktop ') and s != '[Desktop Entry]':
            in_entry = False
        if in_entry and ln.startswith('Actions='):
            existing = ln[len('Actions='):].strip().rstrip(';')
            tokens = [x for x in existing.split(';') if x]
            for needed in ('open-igpu', 'new-window-igpu'):
                if needed not in tokens:
                    tokens.append(needed)
            out.append('Actions=' + ';'.join(tokens) + ';\n')
        else:
            out.append(ln)
    return ''.join(out)
text3 = fix_actions(text2)

# Step 3: append [Desktop Action open-igpu] and new-window-igpu blocks if absent.
udd_match = re.search(r'--user-data-dir=(\S+)', text3)
if not udd_match:
    print(f"  ERROR {src} - could not parse --user-data-dir", file=sys.stderr)
    sys.exit(2)
udd = udd_match.group(1)
cls_match = re.search(r'--class=(\S+)', text3)
class_arg = f' --class={cls_match.group(1)}' if cls_match else ''

needs_open = '[Desktop Action open-igpu]'       not in text3
needs_neww = '[Desktop Action new-window-igpu]' not in text3

append = ''
if needs_open:
    append += (
        '\n[Desktop Action open-igpu]\n'
        'Name=Abrir con Intel iGPU\n'
        f'Exec={in_env} /usr/bin/google-chrome --user-data-dir={udd} '
        f'--no-default-browser-check --no-first-run{class_arg} %U\n'
    )
if needs_neww:
    append += (
        '\n[Desktop Action new-window-igpu]\n'
        'Name=Nueva ventana (Intel iGPU)\n'
        f'Exec={in_env} /usr/bin/google-chrome --user-data-dir={udd} '
        f'--no-default-browser-check --no-first-run{class_arg} --new-window\n'
    )
text4 = (text3.rstrip() + '\n' + append) if append else text3

tmp = src + ".tmp"
with open(tmp, 'w', encoding='utf-8') as f:
    f.write(text4)
os.replace(tmp, src)
print(f"  REWROTE {src}  (backup: {os.path.basename(bak)})")
PY
}

# 2. Rewrite each launcher in APPDIR
section "Rewriting launchers in $APPDIR"
rewrite_count=0; skip_count=0; error_count=0
for prof in "${PROFILES[@]}"; do
    src="$APPDIR/chrome-${prof}.desktop"
    if [ ! -f "$src" ]; then
        warn "  $src does not exist - skipping"
        continue
    fi
    if rewrite_one "$src"; then
        if grep -qF "$NV_PREFIX_PATTERN" "$src"; then
            rewrite_count=$((rewrite_count+1))
        else
            skip_count=$((skip_count+1))
        fi
    else
        error_count=$((error_count+1))
    fi
done
ok "rewrote: $rewrite_count, skipped (already pinned): $skip_count, errors: $error_count"
[ "$error_count" -eq 0 ] || { fail "rewrites failed for $error_count file(s)"; exit 2; }

# 3. Mirror to DSKDIR
section "Mirroring to $DSKDIR"
mirror_count=0
for prof in "${PROFILES[@]}"; do
    src="$APPDIR/chrome-${prof}.desktop"
    dst="$DSKDIR/chrome-${prof}.desktop"
    [ -f "$src" ] || continue
    if [ -f "$dst" ]; then
        cp -p "$dst" "${dst}.bak.${TS}"
    fi
    cp -p "$src" "$dst"
    chmod +x "$dst"
    printf '  mirrored -> %s\n' "$dst"
    mirror_count=$((mirror_count+1))
done
ok "mirrored: $mirror_count file(s)"

# 4. Refresh desktop database
section "Refreshing desktop database"
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$APPDIR" 2>&1 | sed 's/^/  /' || true
    ok "desktop database refreshed"
else
    warn "update-desktop-database not installed - install desktop-file-utils"
fi

# 5. Post-condition audit
section "Post-condition audit"
if bash "${SCRIPT_DIR}/audit-chrome-launchers.sh"; then
    ok "audit clean"
else
    fail "audit reported asymmetry - investigate manually"
    exit 3
fi

# 6. User summary
section "Done"
log
log "${BOLD}Required next steps:${RST}"
log "  1. Logout and login again, so mutter re-reads the launcher directory."
log "     (Ubuntu Dock right-click menu picks up new Actions only after a"
log "      session restart - gnome-shell --replace is X11-only.)"
log
log "  2. Right-click any pinned Chrome icon in the dock. The menu should now"
log "     show 'Abrir con Intel iGPU' and 'Nueva ventana (Intel iGPU)' below"
log "     the existing 'Nueva ventana' / 'Nueva ventana incognita' entries."
log
log "  3. For any profile that was already in 3-strike-latch state, also wipe"
log "     its GPU caches:"
log "       bash ${SCRIPT_DIR}/repair-chrome-profile-gpu.sh <profile>"
log
log "  4. Verify in chrome://gpu after launching:"
log "     Graphics Feature Status: WebGL -> Hardware accelerated"
log "     GPU0 VENDOR=0x10de (default NVIDIA) or 0x8086 (when launched via iGPU Action)"
log
log "${BOLD}Rollback:${RST}"
log "  Each rewritten file has a sibling backup at *.bak.${TS}."
log "  See README.md -> Rollback section for the restore procedure."
exit 0
