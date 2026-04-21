# Ubuntu — GNOME Keyring unlock popup under autologin

_Applies to: Ubuntu 24.04 LTS, GNOME 46, GDM 46.x. Works under X11 and Wayland sessions, on any hardware._

## Context

Under Ubuntu with `AutomaticLoginEnable=True` in `/etc/gdm3/custom.conf`, every time the user logs in (or the system reboots), some apps that try to access saved credentials trigger this popup:

```
Se necesita autenticación / Authentication required
El depósito de claves de inicio de sesión no se desbloqueó cuando
inició sesión en su equipo.
[Password field]
Cancelar    Desbloquear
```

This appears the first time an app touches the keyring (Chrome cookies, Slack, email clients, etc.). If cancelled, the app proceeds without saved secrets; if the password is typed, the keyring unlocks for this session but the popup returns next login.

The same popup appears if the user logs in with **fingerprint** (`libpam-fprintd`), **face recognition** (Howdy), **smartcard**, or any other authentication method that doesn't pass the user's text password to the PAM stack.

## Problem Statement

`login.keyring` (at `~/.local/share/keyrings/login.keyring`) is encrypted with a symmetric key derived from a password. By default, Ubuntu configures this password to match the user's login password so that `pam_gnome_keyring.so auth` (configured in `/etc/pam.d/gdm-password`, `/etc/pam.d/gdm-fingerprint`, etc.) can capture the typed password at login and forward it to `gnome-keyring-daemon`, which uses it to decrypt the keyring and serve secrets for the session.

When there is **no typed password**:

* `AutomaticLoginEnable=True` → GDM skips the interactive flow entirely, no PAM password capture happens.
* Fingerprint / face / smartcard → PAM reports "auth OK" without producing a text password.

In both cases `gnome-keyring-daemon` cannot derive the decryption key and the keyring stays locked until the first app asks for it (triggering the popup).

## Root Cause

The PAM module `pam_gnome_keyring.so auth` in `/etc/pam.d/gdm-password`:

```
session  optional     pam_gnome_keyring.so  auto_start
auth     optional     pam_gnome_keyring.so
password optional     pam_gnome_keyring.so
```

* `auth` line captures the password from the PAM conversation.
* `session` line starts the daemon and forwards the password.
* `password` line re-encrypts the keyring when the user changes their login password (keeps keyring in sync).

When PAM has no password to forward (autologin / fingerprint / face), `pam_gnome_keyring.so auth` gets nothing. The daemon starts but can't unlock the keyring. Next app that wants a secret → popup.

This is an architectural limitation of gnome-keyring's password-derived encryption, not a bug. The daemon has no way to conjure the derivation input.

## Solution options

| Option | How it works | Trade-off |
|---|---|---|
| **A. Disable autologin** | Every login requires typing password, PAM captures it, daemon unlocks normally | Lose the no-typing UX of autologin |
| **B. Empty keyring password** | Re-encrypt `login.keyring` with empty password; daemon finds derivation trivially | Keyring file readable to anyone who reads `~/.local/share/keyrings/` (live USB, stolen laptop without disk encryption) |
| **C. Accept the popup** | Leave the default config, dismiss popup or unlock once per session | Minor friction; keyring stays encrypted at rest |

**Option B is appropriate** when:

* The machine has full-disk encryption (LUKS) — the empty-password keyring is protected at rest by the disk encryption layer.
* OR the machine never leaves a trusted physical environment.
* OR the saved secrets in the keyring are not individually sensitive (session cookies, low-value tokens).

This runbook implements Option B. For Option A, just flip `AutomaticLoginEnable=False` in `custom.conf` and skip the rest. Option C requires no action.

## Solution: set keyring password to empty

See [`keyring-change-password.py`](./keyring-change-password.py).

The script:

1. Connects to D-Bus, gets the default Secret Service collection (`Login`).
2. If locked, triggers unlock (prompts the user once).
3. Prompts for the **current** keyring password via `getpass` (silent tty input).
4. Prompts for the **new** password (ENTER = empty).
5. Confirms empty-password with a `si` typed confirmation.
6. Calls the private D-Bus method `org.gnome.keyring.InternalUnsupportedGuiltRiddenInterface.ChangeWithMasterPassword` — the same method `Seahorse` uses when the user clicks "Change password" in the UI.

```bash
python3 /path/to/keyring-change-password.py
```

Required packages (Ubuntu 24.04): `python3-secretstorage`, `python3-jeepney`. Both are dependencies of GNOME + usually already installed. If not: `sudo apt install python3-secretstorage python3-jeepney`.

## Verification

After running the script:

```bash
# Logout + login (or reboot for cleanest test)
# On next login, open any app that uses saved credentials (email, Chrome).
# No keyring popup should appear.

# Also verify the keyring file was re-encrypted (mtime should be now):
stat -c '%y' ~/.local/share/keyrings/login.keyring

# Confirm daemon can auto-open:
/usr/bin/python3 -c "
import secretstorage
conn = secretstorage.dbus_init()
col = secretstorage.get_default_collection(conn)
print(f'locked={col.is_locked()} items={len(list(col.get_all_items()))}')
"
# Expected: locked=False items=<count>, no prompt
```

## The re-sync gotcha

`pam_gnome_keyring.so password` is a PAM module line that **auto-syncs the keyring password with the user's login password** whenever it detects a mismatch at password-capture time.

When does this trigger?

* **Any login where the user actually types a password** — even one manual login after autologin is disabled.
* `passwd` invoked from a graphical session (the session's PAM stack includes pam_gnome_keyring.password).

In other words: this runbook's Option B is **not permanent across password-entry events**. Scenarios that re-sync the keyring password to the user's login password (and require re-running this script):

| Scenario | Re-sync? |
|---|---|
| Normal autologin reboot cycle | ❌ No |
| Fingerprint / face / smartcard login | ❌ No |
| User disables autologin, logs in with password typed, re-enables autologin | ✅ Yes |
| User changes login password via GNOME Settings | ✅ Yes |
| User changes login password via `passwd` in TTY | ❌ No |
| User manually selects a different session via the GDM gear ⚙ (requires typed password) | ✅ Yes |

**When any re-sync event happens, re-run this script.** The script is idempotent and the "change to empty" step takes ~5 seconds.

## Rollback

To restore a protected keyring (opposite of Option B):

```bash
# Run the same script, this time:
# - Current password: (empty)
# - New password: something strong
# - Confirm: same
python3 /path/to/keyring-change-password.py
```

Or, if you want to delete the empty-password keyring and start fresh (loses all stored secrets):

```bash
rm ~/.local/share/keyrings/login.keyring
# Logout, login; GDM/gnome-keyring creates a new keyring on first
# app that touches the Secret Service API.
```

## Known constraints

* **Requires `python3-secretstorage` + `python3-jeepney`**: standard on Ubuntu 24.04. On minimal installs, `sudo apt install python3-secretstorage python3-jeepney`.
* **`gdm-runtime-config get` does not exist** (only `set`) — you cannot query what GDM's runtime state thinks about keyring. Trust this script's self-reported outcome instead.
* **The `InternalUnsupportedGuiltRiddenInterface` D-Bus interface name is intentional** — GNOME upstream explicitly marked it as "use at own risk / we may change it". In 15+ years they haven't changed the signature, but the warning is real. If you see `ChangeWithMasterPassword: no such method`, the daemon version changed the API; fall back to Seahorse GUI (`seahorse` → "Login" keyring → right-click → "Change password").

## Related runbooks

* [`Ubuntu_GDM_Force_Wayland_on_NVIDIA`](../Ubuntu_GDM_Force_Wayland_on_NVIDIA) — the Wayland-switch runbook triggers a manual login (via the gear ⚙) which in turn triggers the re-sync gotcha above. If you followed that runbook, you'll need to run this script at least once after the manual Wayland pick.

## References

* [GNOME gnome-keyring source](https://gitlab.gnome.org/GNOME/gnome-keyring) — see `daemon/dbus/gkd-secret-*.c` for `ChangeWithMasterPassword` implementation.
* [freedesktop Secret Service API](https://specifications.freedesktop.org/secret-service/latest/) — the standard interface `org.freedesktop.Secret.*`.
* [pam_gnome_keyring man page](https://manpages.ubuntu.com/manpages/noble/en/man8/pam_gnome_keyring.8.html) — module flags + behavior.
