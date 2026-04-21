#!/usr/bin/env python3
"""
Cambia la contraseña maestra del keyring Login vía D-Bus.
Prompt-ea en el tty del user (getpass) — sin dependencias de GUI.

Uso:
    python3 /tmp/keyring-change-password.py

Llama al método privado:
    org.gnome.keyring.InternalUnsupportedGuiltRiddenInterface.ChangeWithMasterPassword
"""
import getpass
import sys

import secretstorage
from secretstorage.util import open_session, format_secret
from jeepney import DBusAddress, new_method_call

SECRETS_BUS = "org.freedesktop.secrets"
SECRETS_PATH = "/org/freedesktop/secrets"
INTERNAL_IFACE = "org.gnome.keyring.InternalUnsupportedGuiltRiddenInterface"


def main() -> int:
    conn = secretstorage.dbus_init()
    col = secretstorage.get_default_collection(conn)
    if col.is_locked():
        print("[info] colección bloqueada, desbloqueando primero...",
              file=sys.stderr)
        col.unlock()

    print("━" * 60)
    print("Cambio de contraseña del keyring 'Login'")
    print("━" * 60)
    print(f"  items actuales : {len(list(col.get_all_items()))}")
    print()

    try:
        old = getpass.getpass("Contraseña ACTUAL del keyring: ")
        new1 = getpass.getpass("Contraseña NUEVA (ENTER = vacía/sin protección): ")
        new2 = getpass.getpass("Confirmar nueva contraseña:       ")
    except (EOFError, KeyboardInterrupt):
        print("\n[abort] cancelado", file=sys.stderr)
        return 130

    if new1 != new2:
        print("ERROR: confirmación no coincide. Nada cambió.", file=sys.stderr)
        return 2

    if new1 == "":
        print()
        print("⚠  vas a dejar el keyring SIN CONTRASEÑA.")
        confirm = input("   Confirmás? [si/N]: ").strip().lower()
        if confirm != "si":
            print("[abort] no confirmado.", file=sys.stderr)
            return 3

    session = open_session(conn)
    old_sec = format_secret(session, old, "text/plain")
    new_sec = format_secret(session, new1, "text/plain")

    addr = DBusAddress(SECRETS_PATH, bus_name=SECRETS_BUS, interface=INTERNAL_IFACE)
    msg = new_method_call(
        addr, "ChangeWithMasterPassword", "o(oayays)(oayays)",
        (col.collection_path, old_sec, new_sec),
    )

    try:
        conn.send_and_get_reply(msg)
    except Exception as exc:
        print(f"\nERROR: {exc}", file=sys.stderr)
        print("  · password actual incorrecta?", file=sys.stderr)
        return 4

    print()
    print("✓ Contraseña del keyring cambiada.")
    if new1 == "":
        print("✓ Keyring sin contraseña — próximo autologin abre sin popup.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
