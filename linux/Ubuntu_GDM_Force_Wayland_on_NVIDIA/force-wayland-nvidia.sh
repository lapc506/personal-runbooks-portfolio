#!/usr/bin/env bash
# Override de la Ubuntu NVIDIA→xorg preference para GDM.
# 3 capas de defensa: udev rule (boot), custom.conf (persistent), runtime-config (inmediato).
# Correr en terminal real. Requiere sudo.
set -e

UDEV_OVERRIDE="/etc/udev/rules.d/62-gdm-prefer-wayland.rules"
CUSTOM_CONF="/etc/gdm3/custom.conf"
BACKUP="/tmp/gdm-custom.conf.bak.$(date +%Y%m%d-%H%M%S)"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Forzar Wayland en GDM (override de la rule 61-gdm)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

# ─── 1. udev rule override (persistent, each boot) ──────────
echo "[1/3] Escribiendo udev rule override: $UDEV_OVERRIDE"
sudo tee "$UDEV_OVERRIDE" > /dev/null <<'EOF'
# Override de /usr/lib/udev/rules.d/61-gdm.rules "gdm_prefer_xorg" label.
# Esa rule corre primero (número 61 < 62) y setea PreferredDisplayServer=xorg
# cuando detecta NVIDIA driver >= 470 sin ser Dell-whitelisted.
# Este archivo corre DESPUÉS y re-overridea el valor a wayland.
ACTION=="add", SUBSYSTEM=="drm", RUN+="/usr/libexec/gdm-runtime-config set daemon PreferredDisplayServer wayland"
EOF
echo "  ✓ $UDEV_OVERRIDE"
sudo udevadm control --reload-rules
echo "  ✓ udev rules reloaded"

# ─── 2. custom.conf persistent (belt-and-suspenders) ────────
echo
echo "[2/3] Agregando PreferredDisplayServer=wayland a $CUSTOM_CONF"
sudo cp -a "$CUSTOM_CONF" "$BACKUP"
echo "  · backup: $BACKUP"

if sudo grep -qE "^PreferredDisplayServer=" "$CUSTOM_CONF"; then
    sudo sed -i 's|^PreferredDisplayServer=.*|PreferredDisplayServer=wayland|' "$CUSTOM_CONF"
    echo "  · línea ya existía, cambiada a wayland"
else
    # Insertar justo después de [daemon]
    sudo sed -i '/^\[daemon\]/a PreferredDisplayServer=wayland' "$CUSTOM_CONF"
    echo "  · línea nueva insertada"
fi

echo "  · estado final:"
grep -E "^PreferredDisplayServer" "$CUSTOM_CONF" | sed 's/^/      /'

# ─── 3. runtime override para el boot actual ────────────────
echo
echo "[3/3] Aplicar override en runtime para que no tengas que reboot"
sudo /usr/libexec/gdm-runtime-config set daemon PreferredDisplayServer wayland
echo "  · valor actual:"
sudo /usr/libexec/gdm-runtime-config get daemon PreferredDisplayServer 2>&1 | sed 's/^/      /'

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Listo. Tres capas de defensa contra la preferencia xorg:"
echo "  · udev rule /etc/udev/rules.d/62-gdm-prefer-wayland.rules"
echo "  · /etc/gdm3/custom.conf con PreferredDisplayServer=wayland"
echo "  · runtime-config YA seteado a wayland"
echo
echo "Ahora:"
echo "  1. Logout del desktop"
echo "  2. Autologin te re-mete → debería ser Wayland esta vez"
echo "  3. Verificar: echo \$XDG_SESSION_TYPE   # → wayland"
echo
echo "Rollback total:"
echo "  sudo rm $UDEV_OVERRIDE"
echo "  sudo cp $BACKUP $CUSTOM_CONF"
echo "  sudo /usr/libexec/gdm-runtime-config set daemon PreferredDisplayServer xorg"
echo "  sudo udevadm control --reload-rules"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
