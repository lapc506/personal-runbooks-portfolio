#!/usr/bin/env bash
# migrate-vscode-snap-to-deb.sh — reemplaza el snap de VS Code por el .deb oficial
# de Microsoft (Mesa/GL del host, consistente con los otros editores deb del equipo:
# Cursor/Kiro/Antigravity). Esto deja a VS Code listo para la receta EGL de
# aceleración en NVIDIA-primary sin el asterisco del snap.
#
# Correr con sudo:  sudo ./migrate-vscode-snap-to-deb.sh
#
# - Idempotente (repo/clave/install/remove se saltan si ya están).
# - SALVAGUARDA: no remueve el snap hasta confirmar que el .deb quedó instalado.
# - Config y extensiones (~/.config/Code, ~/.vscode) son compartidas → se preservan.
#
# Pasos de USUARIO posteriores (NO sudo, los hace el asistente): limpiar el override
# stale code_code.desktop (apuntaba al snap), repuntear el favorito del dock a
# code.desktop, y aplicar la receta EGL al nuevo code.desktop.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Tenés que correrlo con sudo: sudo $0" >&2; exit 1; }

KEYRING=/usr/share/keyrings/packages.microsoft.gpg
LIST=/etc/apt/sources.list.d/vscode.list

echo "==> 1/4  Repo + clave de Microsoft"
if [ ! -s "$KEYRING" ]; then
  tmp="$(mktemp)"
  if command -v wget >/dev/null 2>&1; then
    wget -qO- https://packages.microsoft.com/keys/microsoft.asc > "$tmp"
  else
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc > "$tmp"
  fi
  gpg --dearmor < "$tmp" > "$KEYRING"
  rm -f "$tmp"
  echo "    clave instalada en $KEYRING"
else
  echo "    clave ya presente"
fi

if [ ! -f "$LIST" ]; then
  echo "deb [arch=amd64,arm64,armhf signed-by=$KEYRING] https://packages.microsoft.com/repos/code stable main" > "$LIST"
  echo "    repo agregado: $LIST"
else
  echo "    repo ya presente: $LIST"
fi

echo "==> 2/4  apt update + install code (.deb)"
apt-get update
apt-get install -y code

echo "==> 3/4  Verificar el .deb ANTES de tocar el snap"
if ! dpkg-query -W -f='${Status}' code 2>/dev/null | grep -q 'install ok installed'; then
  echo "ERROR: el paquete .deb 'code' NO quedó instalado. No toco el snap. Abortando." >&2
  exit 1
fi
echo "    .deb OK: code $(dpkg-query -W -f='${Version}' code)  ->  $(command -v code)"

echo "==> 4/4  Remover el snap 'code'"
if snap list code >/dev/null 2>&1; then
  snap remove code
  echo "    snap 'code' removido"
else
  echo "    snap 'code' ya no estaba"
fi

echo
echo "✔ VS Code migrado a .deb."
echo "  Binario: $(command -v code)   ·   .desktop: /usr/share/applications/code.desktop"
echo "  Config/extensiones: ~/.config/Code y ~/.vscode (preservadas)."
echo "  Avisale al asistente: queda el cleanup user-space (override stale, favorito del dock, receta EGL)."
