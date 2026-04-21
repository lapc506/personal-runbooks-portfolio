#!/usr/bin/env bash
# Scan + clean stale SingletonLock files de Electron apps (snap y no-snap)
# que apuntan a PIDs muertos. Esos locks impiden que la app arranque post-crash.

set -e

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Scan singleton locks (Electron apps / Chromium-based)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

declare -A seen
cleaned=0
alive=0

# Paths donde Electron apps guardan SingletonLock
patterns=(
    "$HOME/snap/*/current/.config/*/SingletonLock"
    "$HOME/.config/*/SingletonLock"
    "$HOME/.var/app/*/config/*/SingletonLock"  # flatpak
)

for pattern in "${patterns[@]}"; do
    for lock in $pattern; do
        [ -L "$lock" ] || continue
        app_dir=$(dirname "$lock")
        app_name=$(basename "$app_dir")
        target=$(readlink "$lock")

        # PID extraction: target format is usually "hostname-PID" or just a PID
        pid=$(echo "$target" | grep -oE '[0-9]+$' | head -1)

        if [ -z "$pid" ]; then
            printf "  %-25s  %s\n" "$app_name" "(can't parse PID from: $target — skip)"
            continue
        fi

        if [ -e "/proc/$pid" ]; then
            # Verificar que realmente es un proceso del app, no random PID
            cmdline=$(cat /proc/$pid/comm 2>/dev/null || echo "unknown")
            printf "  %-25s  PID %s VIVO (cmd: %s) — dejando lock intacto\n" "$app_name" "$pid" "$cmdline"
            alive=$((alive+1))
        else
            printf "  %-25s  PID %s MUERTO → limpiando lock/cookie/socket\n" "$app_name" "$pid"
            rm -f "$lock" "$app_dir/SingletonCookie" "$app_dir/SingletonSocket"
            cleaned=$((cleaned+1))
        fi
    done
done

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Limpieza completa:"
echo "  · Locks con PID vivo (preservados): $alive"
echo "  · Locks zombie (eliminados): $cleaned"
echo
echo "Ahora probá abrir las apps del dock — las que tenían lock zombie"
echo "deberían arrancar normal."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
