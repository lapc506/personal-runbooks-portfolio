#!/usr/bin/env bash
# Aplica el color RGB de SteelSeries con confirmación/selector por zenity.
# Uso: desde el servicio systemd `ssgg.service` o el launcher del menú.
set -euo pipefail

SSGG=/usr/bin/ssgg
DEFAULT="#00FF00"

# Selector de color. Si el usuario cancela (o no hay display), usa el verde por defecto.
COLOR="$(zenity --color-selection \
    --title="ssgg — Confirmá o cambiá el color RGB" \
    --width=420 --height=320 \
    --color="${DEFAULT}")" || COLOR="${DEFAULT}"

# Normaliza a hex de 6 dígitos (p. ej. 00FF00) desde #RRGGBB o rgb(r,g,b).
normalize_hex() {
    local c="$1"

    # #RRGGBB o #RRGGBBAA (se descarta el alpha)
    if [[ "$c" =~ ^\#([0-9a-fA-F]{6})([0-9a-fA-F]{2})?$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
        return
    fi

    # rgb(r,g,b), RGB(r,g,b) o rgba(...), con o sin espacios y alpha opcional
    if [[ "$c" =~ ^[rR][gG][bB][aA]?\(([0-9]+)[[:space:]]*,[[:space:]]*([0-9]+)[[:space:]]*,[[:space:]]*([0-9]+)([[:space:]]*,[[:space:]]*[0-9]+)?\)$ ]]; then
        printf '%02X%02X%02X' \
            "$(( 10#${BASH_REMATCH[1]} ))" \
            "$(( 10#${BASH_REMATCH[2]} ))" \
            "$(( 10#${BASH_REMATCH[3]} ))"
        return
    fi
}

HEX="$(normalize_hex "${COLOR}")"
if [[ -z "${HEX}" ]]; then
    HEX="00FF00"
fi

exec "${SSGG}" rgb color "${HEX}"
