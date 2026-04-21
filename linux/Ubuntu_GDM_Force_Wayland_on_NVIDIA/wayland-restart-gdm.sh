#!/usr/bin/env bash
# Approach agresivo sin reboot:
# 1. Mueve /usr/share/xsessions/ubuntu.desktop fuera del path para que
#    "Name=Ubuntu" solo matchee la version Wayland.
# 2. Restart gdm3 para forzar re-enumeración + re-leer custom.conf.
#
# WARNING: mata la sesión X11 actual. Guarda todo antes de correr.

set -e

X_UBUNTU="/usr/share/xsessions/ubuntu.desktop"
BACKUP="${X_UBUNTU}.claude-bak.$(date +%Y%m%d-%H%M%S)"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "⚠  ADVERTENCIA: esto mata la sesión X11 actual."
echo "   Guarda TODO trabajo pendiente ahora."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

read -rp "Confirmar? [si/N]: " ans
[ "${ans,,}" = "si" ] || { echo "Cancelado."; exit 2; }

echo
echo "[1/2] Moviendo $X_UBUNTU fuera del path"
if [ -f "$X_UBUNTU" ]; then
    sudo mv "$X_UBUNTU" "$BACKUP"
    echo "  ✓ backup en $BACKUP"
else
    echo "  (ya no existe, skip)"
fi

echo
echo "[2/2] Restart gdm3 en 3 segundos..."
echo "  · tu sesión actual va a morir"
echo "  · GDM te va a mostrar login screen con las sesiones re-enumeradas"
echo "  · vas a ver 'Ubuntu on Wayland' + 'Ubuntu en Xorg'"
echo "  · (la antigua 'Ubuntu' X11 ya no aparece porque su .desktop esta movido)"
echo
echo "Rollback si todo se rompe (desde TTY — Ctrl+Alt+F3):"
echo "  sudo mv $BACKUP $X_UBUNTU"
echo "  sudo systemctl restart gdm3"
echo
sleep 3
sudo systemctl restart gdm3
