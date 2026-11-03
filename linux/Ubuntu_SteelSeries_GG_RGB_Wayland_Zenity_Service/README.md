# Ubuntu — SteelSeries GG (steelseriesgg-rs): RGB con servicio de usuario + selector zenity

_Applies to: Ubuntu 24.04 LTS con sesión Wayland (GNOME), teclado SteelSeries Apex 3, binario `ssgg` v0.1.11 compilado desde la fuente. Escrito en una Gigabyte AORUS 15 9MF._

> **⚠ Reader's summary:** `steelseriesgg-rs` reemplaza a SteelSeries GG en Linux. El binario `ssgg` controla el RGB; este runbook instala el binario en `/usr/bin/ssgg`, crea un **servicio de sistema (``d --user`** que aplica el color al iniciar sesión mediante un **selector de color zenity** (confirmás o cambiás el color), y deja un launcher en el menú de apps. Dos trampas reales quedan documentadas: (1) **el daemon `ssgg daemon` pisa el color estático y deja los LEDs en blanco**, así que el servicio es un `oneshot` que solo aplica el color (sin daemon); (2) **zenity devuelve el color en formato `rgb(r,g,b)`** en este sistema, no `#RRGGBB`, y `ssgg` rechaza ese formato si se pasa tal cual — el script lo normaliza.

## External dependency

- Repositorio: <https://github.com/Ven0m0/steelseriesgg-rs> (MIT).
- Binario: compilado desde la fuente con `cargo build --release` → `target/release/ssgg`.
- El proyecto trae (en `assets/`): unidad `ssgg.service` (daemon), `ssgg-gui.desktop`, y reglas udev `70-steelseries.rules`; y `ssgg.install` para empaquetado Arch. Este runbook **no** usa el daemon ni el paquete de la: hace una instalación manual del binario + un servicio propio con selector de color.

## Context

El autor quiere su SteelSeries (Apex 3) en **verde** (`#00FF00`), aplicado automáticamente al iniciar sesión, con la posibilidad de confirmar/cambiar el color. El `ssgg` compilado funciona, pero la integración "de fábrica" (daemon) no coincide con el objetivo de un color fijo.

## Lo que se monta

Tres piezas (todas sin `sudo` salvo la instalación del binario):

| Pieza | Ruta | Rol |
|---|---|---|
| Binario | `/usr/bin/ssgg` | El CLI instalado globalmente (requiere una sola vez `sudo install`). |
| Script selector | `~/.local/bin/ssgg-color-prompt.sh` | Abre zenity, normaliza el color y ejecuta `ssgg rgb color <hex>`. |
| Unidad de servicio | `~/.config/systemd/user/ssgg.service` | `Type=oneshot`, corre el script al iniciar sesión (`default.target`). |
| Launcher | `~/.local/share/applications/ssgg-color.desktop` | Entrada de menú que abre el mismo selector. |

## La trampa nº 1: el daemon pisa el color (LEDs en blanco)

La unidad de factoábrica` (`assets/ssgg.service`) corre `ssgg daemon` en primer plano (`Type=simple`). En el Apex 3, el daemon **sobrescribe el color estático**: al combinar `ExecStartPre=... rgb color` + `ExecStart=... daemon`, los LEDs quedaban **blancos** y el journal se llenaba de `WARN Unknown command byte: 0x0b` y `RGB performance degraded ... FPS: 0.0/30.3`. El experimento decisivo: detener el daemon y aplicar `ssgg rgb color 00FF00` a mano → quedaba verde. Conclusión: **no usar el daemon** si se quiere un color fijo; el servicio es un `oneshot` que aplica el color y termina.

## La trampa nº 2: el formato del color de zenity

`zenity --color-selection` en este sistema devuelve `rgb(r,g,b)` (p. ej. `RGB(3,6,116)`), no `#RRGGBB`. Pasar `RGB(3,6,116)` a `ssgg rgb color` falla con `Error: Other("Invalid color: RGB(3,6,116)")`. El script normaliza ambos formatos (y descarta alpha).

## El script — `ssgg-color-prompt.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

SSGG=/usr/bin/ssgg
DEFAULT="#00FF00"

COLOR="$(zenity --color-selection \
    --title="ssgg — Confirmá o cambiá el color RGB" \
    --width=420 --height=320 \
    --color="${DEFAULT}")" || COLOR="${DEFAULT}"

normalize_hex() {
    local c="$1"
    if [[ "$c" =~ ^\#([0-9a-fA-F]{6})([0-9a-fA-F]{2})?$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
        return
    fi
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
```

Comportamiento: si el usuario **acepta** se aplica el color elegido; si **cancela** (o no hay display) se aplica el verde por defecto; cualquier formato irreconocible cae al verde.

## La unidad — `~/.config/systemd/user/ssgg.service`

```ini
[Unit]
Description=SteelSeries GG - elegir y aplicar color RGB
Documentation=https://github.com/Ven0m0/steelseriesgg-rs
After=graphical-session.target

[Service]
Type=oneshot
Environment=DISPLAY=:0
Environment=WAYLAND_DISPLAY=wayland-0
ExecStart=/home/<usuario>/.local/bin/ssgg-color-prompt.sh
TimeoutStartSec=0

[Install]
WantedBy=default.target
```

Notas:
- `Environment=DISPLAY=:0` + `Environment=WAYLAND_DISPLAY=wayland-0`: necesarios para que zenity vea la sesión gráfica desde el servicio (ajustar al entorno real).
- `TimeoutStartSec=0`: el diálogo puede esperar al usuario sin que systemd mate el servicio.
- `After=graphical-session.target`: arranca cuando ya existe sesión gráfica.

## Instalación

```bash
# 1) Instalar el binario (único paso con sudo, pide contraseña)
sudo install -m755 ~/steelseriesgg-rs/target/release/ssgg /usr/bin/ssgg

# 2) Copiar el script y hacerlo ejecutable
mkdir -p ~/.local/bin
install -m755 ssgg-color-prompt.sh ~/.local/bin/ssgg-color-prompt.sh

# 3) Crear la unidad (contenido de arriba) en ~/.config/systemd/user/ssgg.service

# 4) Recargar, habilitar y arrancar
systemctl --user daemon-reload
systemctl --user enable --now ssgg.service   # abre el selector ahora mismo

# (opcional) launcher de menú — DEBE quedar ejecutable o GNOME lo ignora en el menú
cp ssgg-color.desktop ~/.local/share/applications/ssgg-color.desktop
chmod +x ~/.local/share/applications/ssgg-color.desktop
update-desktop-database ~/.local/share/applications
```

Para que el servicio arranque **sin iniciar sesión** (headless): `sudo loginctl enable-linger $USER`.

## Permisos del dispositivo (si el teclado no responde)

- El usuario debe estar en el grupo `input`: `sudo usermod -aG input $USER` (re-login).
- Reglas udev: `assets/70-steelseries.rules` de `steelseriesgg-rs` → `/etc/udev/rules.d/70-steelseries.rules`, luego `sudo udevadm control --reload-rules && sudo udevadm trigger`.

## Verificación

```bash
/usr/bin/ssgg --version          # esperado: ssgg 0.1.x
systemctl --user status ssgg.service   # tras cerrar el diálogo: inactive (oneshot OK)
systemctl --user is-enabled ssgg.service  # enabled
```

Y visualmente: al ejecutar `~/.local/bin/ssgg-color-prompt.sh`, el selector aparece con `#00FF00` preseleccionado; al aceptar, los LEDs se ponen del color elegido. Si el journal muestra `Invalid color: RGB(...)`, el script no normalizó (usar la versión de este runbook).

## Solución de problemas

| Síntoma | Causa | Fix |
|---|---|---|
| LEDs en blanco | Daemon compitiendo con el color | Usar el servicio `oneshot` (sin `daemon`). |
| `Error: Invalid color: RGB(3,6,116)` | zenity devuelve `rgb(r,g,b)` | Normalizar a hex (el script lo hace). |
| El diálogo no aparece | Falta `DISPLAY`/`WAYLAND_DISPLAY` en la unidad | Establecer `Environment=` en la unidad. |
| El teclado no aplica | Permisos udev/grupo `input` | Ver sección de permisos. |
| El launcher no aparece en el menú de apps (ni Super, ni dock) | El `.desktop` no es ejecutable (permisos `-rw-rw-r--`), o la caché de aplicaciones está vieja. GNOME ignora los `.desktop` sin bit de ejecución. | `chmod +x ~/.local/share/applications/ssgg-color.desktop` y `update-desktop-database ~/.local/share/applications`. Si aun así no aparece, cerrar sesión/reiniciar. Nota: el **dock** solo muestra apps en ejecución o ancladas; anclar manualmente. |
