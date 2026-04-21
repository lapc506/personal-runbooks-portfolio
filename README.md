# Personal Runbooks Portfolio

Bash and PowerShell runbooks I've implemented during my career, organized by operating system.

## Runbooks

### Linux

- [`Ubuntu_GDM_Force_Wayland_on_NVIDIA`](./linux/Ubuntu_GDM_Force_Wayland_on_NVIDIA) — override Ubuntu's default `gdm_prefer_xorg` udev rule to force a Wayland session on GDM autologin with NVIDIA proprietary/open driver, without reboot.
- [`GNOME_Keyring_Empty_Password_Under_Autologin`](./linux/GNOME_Keyring_Empty_Password_Under_Autologin) — eliminate the "El depósito de claves de inicio de sesión no se desbloqueó" popup on autologin/fingerprint/face systems by setting the keyring password to empty via D-Bus `ChangeWithMasterPassword`.
- [`Ubuntu_Flatpak_AppArmor_Userns_Restriction`](./linux/Ubuntu_Flatpak_AppArmor_Userns_Restriction) — diagnose and fix flatpak apps (ZapZap, Slack, Discord, Element, Obsidian) that fail on Ubuntu 24.04 with cascading EGL/ANGLE/QRhi errors; the root cause is `apparmor_restrict_unprivileged_userns=1` breaking bwrap's UID mapping, not GPU drivers.

### macOS

- [`macOS_Upgrade_Reboot_Deferral`](./macos/macOS_Upgrade_Reboot_Deferral) — silent macOS major-upgrade deployment with delayed-reboot UX on Intel Macs, for Jamf-managed fleets.

### Windows

_(Placeholder for future PowerShell runbooks.)_

### Cross-platform

_(Placeholder for future tooling that applies to multiple OSes.)_
