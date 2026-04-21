#!/usr/bin/env bash
# Fix 1: re-aplicar favorite-apps a dconf (vía gsettings) preservando pins existentes
#        pero con nuestros 6 chrome-* al inicio y sin los obsoletos google-chrome/chromium.
# Fix 2: desactivar Chrome CSD (Use system title bar and borders) en cada chrome-* profile
#        editando su Preferences JSON — aplica al próximo launch.

set -e

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Fix 1 · favorite-apps re-aplicación (gsettings→dconf)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

/usr/bin/python3 - <<'PYEOF'
import subprocess, json

# Nuestros 6 chrome-* que deben ir al inicio
OUR_LAUNCHERS = [
    "chrome-lapc506.desktop",
    "chrome-dojocoding.desktop",
    "chrome-altrupets.desktop",
    "chrome-vertivolatam.desktop",
    "chrome-habitanexus.desktop",
    "chrome-demolabcr.desktop",
]

# Launchers obsoletos a remover (los reemplazan los nuestros)
OBSOLETE = {
    "google-chrome.desktop",
    "com.google.Chrome.desktop",
    "chromium_chromium.desktop",
    "chromium-browser.desktop",
    "chrome.desktop",
}

# Leer el estado REAL desde dconf (no gsettings, que tiene cache)
raw = subprocess.check_output(
    ["dconf", "read", "/org/gnome/shell/favorite-apps"],
    text=True,
).strip()

# dconf format: ['app1', 'app2', ...]. Convertir a lista Python.
if raw.startswith("["):
    current = [s.strip().strip("'\"") for s in raw.strip("[]").split(",")]
    current = [s for s in current if s]
else:
    current = []

print(f"  dconf actual ({len(current)} apps):")
for a in current:
    print(f"    · {a}")

# Quitar obsoletos + cualquier chrome-* (si tuviéramos un chrome-x repetido)
current = [x for x in current if x not in OBSOLETE and x not in OUR_LAUNCHERS]

# Prepend nuestros 6
new_favs = OUR_LAUNCHERS + current

print(f"\n  nueva lista ({len(new_favs)} apps):")
for a in new_favs:
    marker = " ← nuevo" if a in OUR_LAUNCHERS else ""
    print(f"    · {a}{marker}")

# gsettings set con Python-style repr (comillas simples)
def py_repr(lst):
    return "[" + ", ".join("'" + s.replace("'", "\\'") + "'" for s in lst) + "]"

subprocess.run(
    ["gsettings", "set", "org.gnome.shell", "favorite-apps", py_repr(new_favs)],
    check=True,
)

# Verificar que dconf ahora refleja el cambio
verify = subprocess.check_output(
    ["dconf", "read", "/org/gnome/shell/favorite-apps"],
    text=True,
).strip()
if "chrome-lapc506" in verify:
    print("\n  ✓ dconf actualizado (ahora sí contiene nuestros chrome-*)")
else:
    print("\n  ⚠ dconf todavía no refleja el cambio — hay algo más profundo")
PYEOF

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Fix 2 · Desactivar Chrome CSD en cada profile"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Matar cualquier Chrome vivo antes de editar Preferences
pkill -TERM -f "google-chrome.*--user-data-dir=.*google-chrome-" 2>/dev/null || true
sleep 1

/usr/bin/python3 - <<'PYEOF'
import json
import os
import glob

# custom_chrome_frame:
#   true  = Chrome dibuja su propia title bar (CSD, botones custom)
#   false = Sistema dibuja la title bar (respeta gnome-decoration-layout)
# Ubuntu/GNOME preference: false → botones vuelven a la derecha siguiendo org.gnome.desktop.wm.preferences

profile_dirs = sorted(glob.glob(os.path.expanduser("~/.config/google-chrome-*/Default/Preferences")))

if not profile_dirs:
    print("  (no se encontraron profiles ~/.config/google-chrome-*/Default/Preferences)")
else:
    for prefs_path in profile_dirs:
        profile = os.path.basename(os.path.dirname(os.path.dirname(prefs_path))).replace("google-chrome-", "")
        try:
            with open(prefs_path) as f:
                data = json.load(f)
            data.setdefault("browser", {})["custom_chrome_frame"] = False
            with open(prefs_path, "w") as f:
                json.dump(data, f, separators=(",", ":"))
            print(f"  ✓ {profile:<15} custom_chrome_frame = false")
        except Exception as exc:
            print(f"  ⚠ {profile}: {exc}")
PYEOF

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Verificar ahora:"
echo "  · Dock debería mostrar los 6 emojis al inicio"
echo "  · Al lanzar cualquier chrome-* profile, la title bar tendrá los"
echo "    controles a la derecha (nativa del sistema)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
