#!/usr/bin/env bash
# Plan B: desactivar autologin temporalmente, forzar que GDM muestre la rueda
# de selección de sesión, pickeás Wayland manual, GDM lo recuerda en
# AccountsService con los flags correctos (incluyendo XSession).
# Después re-activás autologin y los próximos logins van directo a Wayland.
#
# Correr en terminal real. Requiere sudo una vez.

set -e
CUSTOM_CONF="/etc/gdm3/custom.conf"
BACKUP="/tmp/gdm-custom.conf.bak.$(date +%Y%m%d-%H%M%S)"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Plan B · Desactivar autologin temporalmente para forzar"
echo "         la selección manual de sesión en GDM."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

echo "[1/2] Backup + desactivar autologin en $CUSTOM_CONF"
sudo cp -a "$CUSTOM_CONF" "$BACKUP"
sudo sed -i 's|^AutomaticLoginEnable=True|AutomaticLoginEnable=False|' "$CUSTOM_CONF"
grep -E "^#?AutomaticLogin" "$CUSTOM_CONF" | sed 's/^/  /'
echo "  ✓ backup en $BACKUP"

echo
echo "[2/2] Pasos siguientes (manuales)"
echo
echo "  1. Hacé LOGOUT del escritorio"
echo "  2. En la pantalla de login:"
echo "     · Click en tu usuario"
echo "     · Antes de tipear password, buscá la rueda ⚙"
echo "       (suele estar en la esquina inferior derecha"
echo "        del password field; puede ser pequeña)"
echo "     · Click → selectioná 'Ubuntu on Wayland'"
echo "     · Tipeá password y logueate"
echo "  3. Cuando ya estés en Wayland, abrí una terminal y corré:"
echo "     echo \$XDG_SESSION_TYPE   # → debe decir 'wayland'"
echo "  4. Re-activá autologin (GDM ya recuerda Wayland en"
echo "     AccountsService con los flags correctos) corriendo:"
echo
echo "     sudo sed -i 's|^AutomaticLoginEnable=False|AutomaticLoginEnable=True|' $CUSTOM_CONF"
echo
echo "En caso de emergencia (rollback a estado previo):"
echo "  sudo cp $BACKUP $CUSTOM_CONF"
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
