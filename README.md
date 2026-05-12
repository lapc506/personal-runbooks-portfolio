# Personal Runbooks Portfolio

Bash and PowerShell runbooks I've implemented during my career, organized by operating system.

The repo has two tiers:

- **Tier 1 — Runbooks** (`linux/`, `macos/`, `windows/`, `cross-platform/`): empirically validated fixes. Each documents the full debugging journey on a specific machine, including attempts that failed. These are the reference docs I come back to when a problem I've already solved returns somewhere else.
- **Tier 2 — Toolkits** (`toolkits/`): diagnostic tools, baseline-capture scripts, and skeleton runbooks for known failure categories I haven't yet hit on my own machine. Content here is cited to upstream (vendor docs, Arch Wiki, issue trackers) and marked with its validation status. When a skeleton gets validated by actually happening to me, it migrates to Tier 1 with the real journey captured.

See [`toolkits/README.md`](./toolkits/README.md) for the full rationale behind the separation.

## Tier 1 — Runbooks

### Linux

- [`Ubuntu_GDM_Force_Wayland_on_NVIDIA`](./linux/Ubuntu_GDM_Force_Wayland_on_NVIDIA) — override Ubuntu's default `gdm_prefer_xorg` udev rule to force a Wayland session on GDM autologin with NVIDIA proprietary/open driver, without reboot.
- [`Ubuntu_NVIDIA_Wayland_Flip_Event_Timeout`](./linux/Ubuntu_NVIDIA_Wayland_Flip_Event_Timeout) — eliminate `nv_drm_atomic_commit *ERROR* Flip event timeout on head` kernel errors that cause GNOME Shell SIGTRAP crashes under Wayland on hybrid Intel+NVIDIA systems; the root cause is `nvidia_drm.modeset=1` being configured only in `/etc/modprobe.d/`, which is consulted too late when the module is loaded from initramfs — move the parameter to the GRUB kernel command line.
- [`GNOME_Keyring_Empty_Password_Under_Autologin`](./linux/GNOME_Keyring_Empty_Password_Under_Autologin) — eliminate the "El depósito de claves de inicio de sesión no se desbloqueó" popup on autologin/fingerprint/face systems by setting the keyring password to empty via D-Bus `ChangeWithMasterPassword`.
- [`Ubuntu_Flatpak_AppArmor_Userns_Restriction`](./linux/Ubuntu_Flatpak_AppArmor_Userns_Restriction) — diagnose and fix flatpak apps (ZapZap, Slack, Discord, Element, Obsidian) that fail on Ubuntu 24.04 with cascading EGL/ANGLE/QRhi errors; the root cause is `apparmor_restrict_unprivileged_userns=1` breaking bwrap's UID mapping, not GPU drivers.
- [`Ubuntu_Snap_Slack_XWayland_Jitter`](./linux/Ubuntu_Snap_Slack_XWayland_Jitter) — rewrite the user-scope Slack snap launcher that silently forces `--ozone-platform=x11` + blanks `WAYLAND_DISPLAY=`, so Slack runs on native Wayland via Chromium Ozone `hint=auto` instead of jittering through XWayland on GNOME 46 + mutter triple-buffering. Registers right-click Actions for the X11 and GPU-debug fallback paths. Ships a general `diagnose-electron-wayland-launchers.sh` that also covers Discord, VSCode, Cursor, Obsidian, Element, Teams, Zoom, Signal and a dozen other Electron apps on the same machine.
- [`Ubuntu_Chrome_Wayland_Render_Node_Crash_Loop`](./linux/Ubuntu_Chrome_Wayland_Render_Node_Crash_Loop) — recover Google Chrome from `Disabled Features: all` after Ozone Wayland auto-injects `--render-node-override=/dev/dri/renderD129` (NVIDIA dGPU), Chrome's GPU process trips three flip-completion failures, and the 3-strike supervisor latches every hardware-accelerated feature off. Symptom: `Los efectos visuales requieren WebGL` in Google Meet across all six per-workspace Chrome profile launchers. The fix is **not** `--ignore-gpu-blocklist`. The fix is to wipe `GPUCache` to reset the supervisor, then pin an explicit GPU policy via `env __NV_PRIME_RENDER_OFFLOAD=1 ... /usr/bin/google-chrome ...` injected into every `Exec=` line, with a paired `[Desktop Action open-igpu]` for an Intel iGPU fallback. Mirrors changes across the `~/.local/share/applications/` ↔ `~/Escritorio/` launcher pair.

### macOS

- [`macOS_Upgrade_Reboot_Deferral`](./macos/macOS_Upgrade_Reboot_Deferral) — silent macOS major-upgrade deployment with delayed-reboot UX on Intel Macs, for Jamf-managed fleets.

### Windows

_(Placeholder for future PowerShell runbooks.)_

### Cross-platform

_(Placeholder for future tooling that applies to multiple OSes.)_

## Tier 2 — Toolkits

- [`toolkits/NVIDIA_Intel_Hybrid_Graphics_Baseline`](./toolkits/NVIDIA_Intel_Hybrid_Graphics_Baseline) — baseline capture + regression detector for hybrid Intel + NVIDIA Optimus laptops under Wayland. Also hosts the hypothesis list of known Wayland/Optimus problem categories (cursor desync, runtime PM drain, HDMI routing, suspend/resume VRAM save-restore, PipeWire screen-capture GPU confusion, module-load ordering, fractional scaling at mixed DPI) with first-line diagnostics for each.
