#!/usr/bin/env bash
# webview-disable-gpu.sh — force `--disable-gpu` on Electron/Chromium webview
# desktop apps (and QtWebEngine flatpaks) so they survive a NVIDIA-primary
# (reverse-PRIME) compositor.
#
# Why: when mutter renders primary on the NVIDIA dGPU (udev mutter-device-
# preferred-primary, see ../Ubuntu_GNOME_Mutter_Force_Primary_GPU_NVIDIA/), the
# GBM/dma-buf GL interop that webview engines use for zero-copy textures fails on
# the NVIDIA driver (ANGLE `texStorageMem2DEXT` -> GL_INVALID_OPERATION 0x0502
# "Unexpected driver error", "Framebuffer is incomplete: zero size"). The webview
# never paints and the app hangs (ZapZap was the first casualty). Intel handled
# GBM fine; NVIDIA does not. `--disable-gpu` makes the webview render in software
# (negligible cost for chat/editor apps), sidestepping the broken path.
#
# Idempotent. Reversible: `webview-disable-gpu.sh --revert`.
# USER-SPACE ONLY: writes .desktop overrides under ~/.local/share/applications and
# `flatpak --user` overrides. Never touches system files; never needs sudo.
#
# Standalone browsers (Chrome/Opera/Edge) are intentionally NOT here: Chrome is
# pinned to the dGPU via EGL and works; browsers are not embedded-webview apps.
# Native-Qt apps (Telegram Desktop) are not webview and don't apply.
set -euo pipefail

APPDIR="$HOME/.local/share/applications"
SYSDIRS=(/usr/share/applications /var/lib/snapd/desktop/applications)
mkdir -p "$APPDIR"

GRN=$'\033[32m'; YEL=$'\033[33m'; CYA=$'\033[36m'; RST=$'\033[0m'
ok(){   printf '%s✔%s %s\n' "$GRN" "$RST" "$*"; }
info(){ printf '%s•%s %s\n' "$CYA" "$RST" "$*"; }
warn(){ printf '%s⚠%s %s\n' "$YEL" "$RST" "$*" >&2; }

# Electron/Chromium webview apps by .desktop basename (snap + deb). url-handler
# variants included so deep-links also launch with the flag.
ELECTRON_DESKTOPS=(
  slack.desktop
  claude-desktop.desktop
  cursor.desktop cursor-url-handler.desktop
  antigravity.desktop antigravity-url-handler.desktop
  kiro.desktop kiro-url-handler.desktop
  spotify.desktop
  notion-app-enhanced.desktop
  code_code.desktop code_code-url-handler.desktop
  discord_discord.desktop
  notion-snap-reborn_notion-snap-reborn.desktop
  termius-app_termius-app.desktop
  gitkraken_gitkraken.desktop
)
# QtWebEngine flatpaks (need the env flag, not an argv flag).
FLATPAK_QT=( com.rtosta.zapzap )

# Insert --disable-gpu into every Exec= line lacking it. Handles a quoted first
# token ("…/Notion Enhanced/…") and a bare path/name. NOTE: does not handle an
# `env VAR=x /bin/app` Exec prefix — none of the targeted apps use that form.
add_flag(){ sed -i -E '/^Exec=/{/--disable-gpu/b; s/^(Exec="[^"]*")/\1 --disable-gpu/; t; s/^(Exec=[^ ]+)/\1 --disable-gpu/}' "$1"; }

src_of(){ local bn="$1" d; for d in "${SYSDIRS[@]}"; do [ -f "$d/$bn" ] && { echo "$d/$bn"; return 0; }; done; return 1; }

if [ "${1:-}" = "--revert" ]; then
  info "Revirtiendo…"
  for bn in "${ELECTRON_DESKTOPS[@]}"; do
    [ -f "$APPDIR/$bn" ] || continue
    if src_of "$bn" >/dev/null 2>&1; then
      rm -f "$APPDIR/$bn"; ok "override de usuario quitado (vuelve al del sistema): $bn"
    else
      sed -i -E 's/ --disable-gpu//g' "$APPDIR/$bn"; ok "flag removido: $bn"
    fi
  done
  for app in "${FLATPAK_QT[@]}"; do flatpak override --user --reset "$app" 2>/dev/null && ok "flatpak reset: $app" || true; done
  update-desktop-database "$APPDIR" 2>/dev/null || true
  info "Revertido. Reabrí las apps para que tomen la config original."
  exit 0
fi

for bn in "${ELECTRON_DESKTOPS[@]}"; do
  if [ -f "$APPDIR/$bn" ]; then
    add_flag "$APPDIR/$bn"; ok "patch (override ya existía): $bn"
  elif s=$(src_of "$bn"); then
    cp "$s" "$APPDIR/$bn"; add_flag "$APPDIR/$bn"; ok "override creado + patch: $bn"
  else
    warn "no instalado / .desktop no hallado (saltado): $bn"
  fi
done

for app in "${FLATPAK_QT[@]}"; do
  flatpak override --user --env=QTWEBENGINE_CHROMIUM_FLAGS="--disable-gpu" "$app" && ok "flatpak override: $app"
done

update-desktop-database "$APPDIR" 2>/dev/null || true
echo
info "Listo. Reabrí cada app (cerrá TODAS sus ventanas primero — una instancia viva reusa el proceso e ignora el launcher)."
info "Verificar: chrome://gpu en las Electron, o que la app deje de colgarse. Revert: $0 --revert"
