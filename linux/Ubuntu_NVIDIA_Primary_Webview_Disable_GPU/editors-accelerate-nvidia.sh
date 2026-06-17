#!/usr/bin/env bash
# editors-accelerate-nvidia.sh — give the Electron editors GPU ACCELERATION on the
# NVIDIA dGPU under NVIDIA-primary, via the EGL offload recipe (NOT --disable-gpu).
#
# Editors benefit from the GPU (smooth UI, scrolling, minimap, webviews); chat apps
# don't, so those stay on --disable-gpu (webview-disable-gpu.sh). The recipe is the
# same one verified working on Chrome and on VS Code:
#   env __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia \
#       __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/10_nvidia.json \
#       <editor-bin> --use-angle=gl-egl ...
# Verified: `code --status` → GPU0 VENDOR=0x10de (NVIDIA) *ACTIVE*, gpu_compositing
# enabled, on XWayland (no --ozone-platform=wayland, which avoids the Wayland GBM break).
#
# REQUIRES the deb builds (host Mesa). For VS Code, migrate off the snap first with
# ../Ubuntu_VSCode_Snap_to_Deb/migrate-vscode-snap-to-deb.sh (snap code's bundled GL
# is the variable that made this murky to verify).
#
# Idempotent (rebuilds each override from the pristine system .desktop). Reversible:
# `--revert` removes the overrides (back to system default GPU behaviour).
# User-space, no sudo.
set -euo pipefail

APPDIR="$HOME/.local/share/applications"
SYS=/usr/share/applications
EGL='env __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/10_nvidia.json'
mkdir -p "$APPDIR"

# editor .desktop id : its binary (the string that starts Exec= in the system file)
EDITORS=(
  "code.desktop:/usr/share/code/code"
  "code-url-handler.desktop:/usr/share/code/code"
  "cursor.desktop:/usr/share/cursor/cursor"
  "cursor-url-handler.desktop:/usr/share/cursor/cursor"
  "kiro.desktop:/usr/share/kiro/kiro"
  "kiro-url-handler.desktop:/usr/share/kiro/kiro"
  "antigravity.desktop:/usr/share/antigravity/antigravity"
  "antigravity-url-handler.desktop:/usr/share/antigravity/antigravity"
)

GRN=$'\033[32m'; YEL=$'\033[33m'; RST=$'\033[0m'
ok(){ printf '%s✔%s %s\n' "$GRN" "$RST" "$*"; }
warn(){ printf '%s⚠%s %s\n' "$YEL" "$RST" "$*" >&2; }

if [ "${1:-}" = "--revert" ]; then
  for e in "${EDITORS[@]}"; do f="$APPDIR/${e%%:*}"; [ -f "$f" ] && { rm -f "$f"; ok "override quitado: ${e%%:*}"; }; done
  update-desktop-database "$APPDIR" 2>/dev/null || true
  echo "Revertido: los editores vuelven al comportamiento GPU por defecto del sistema."
  exit 0
fi

for e in "${EDITORS[@]}"; do
  id="${e%%:*}"; bin="${e##*:}"
  if [ ! -f "$SYS/$id" ]; then warn "no instalado (saltado): $id"; continue; fi
  cp "$SYS/$id" "$APPDIR/$id"                                   # pristine -> idempotente
  sed -i "s#^Exec=$bin#Exec=$EGL $bin --use-angle=gl-egl#" "$APPDIR/$id"
  ok "acelerado: $id"
done
update-desktop-database "$APPDIR" 2>/dev/null || true
echo
echo "Listo. Cerrá del todo cada editor y reabrilo. Verificá con:  code --status   (GPU0 0x10de *ACTIVE*)"
echo "Para Cursor/Kiro/Antigravity (forks de VS Code):  cursor --status / kiro --status / antigravity --status"
echo "Revertir a software/sistema:  $0 --revert"
