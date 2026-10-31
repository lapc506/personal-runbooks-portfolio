# Linux Runbooks

Index of Tier 1 Linux runbooks in this portfolio (see the root [`README.md`](../README.md) for the macOS, Windows, cross-platform, and toolkit tiers). Each entry links to a directory containing the full runbook.

- [`claude-code-multi-backend`](./claude-code-multi-backend)
- [`GNOME_Keyring_Empty_Password_Under_Autologin`](./GNOME_Keyring_Empty_Password_Under_Autologin) — eliminate the "El depósito de claves de inicio de sesión no se desbloqueó" popup on autologin/fingerprint/face systems by setting the keyring password to empty via D-Bus `ChangeWithMasterPassword`.
- [`Ubuntu_Chrome_Memory_Saver_All_Profiles`](./Ubuntu_Chrome_Memory_Saver_All_Profiles)
- [`Ubuntu_Chrome_Wayland_Render_Node_Crash_Loop`](./Ubuntu_Chrome_Wayland_Render_Node_Crash_Loop) — recover Google Chrome from `Disabled Features: all` after Ozone Wayland auto-injects `--render-node-override=/dev/dri/renderD129` (NVIDIA dGPU), Chrome's GPU process trips three flip-completion failures, and the 3-strike supervisor latches every hardware-accelerated feature off.
- [`Ubuntu_Flatpak_AppArmor_Userns_Restriction`](./Ubuntu_Flatpak_AppArmor_Userns_Restriction) — diagnose and fix flatpak apps (ZapZap, Slack, Discord, Element, Obsidian) that fail on Ubuntu 24.04 with cascading EGL/ANGLE/QRhi errors; the root cause is `apparmor_restrict_unprivileged_userns=1` breaking bwrap's UID mapping, not GPU drivers.
- [`Ubuntu_GDM_Force_Wayland_on_NVIDIA`](./Ubuntu_GDM_Force_Wayland_on_NVIDIA) — override Ubuntu's default `gdm_prefer_xorg` udev rule to force a Wayland session on GDM autologin with NVIDIA proprietary/open driver, without reboot.
- [`Ubuntu_GNOME_Mutter_Force_Primary_GPU_NVIDIA`](./Ubuntu_GNOME_Mutter_Force_Primary_GPU_NVIDIA)
- [`Ubuntu_GNOME_Mutter_Internal_Panel_Drop_False_Freeze`](./Ubuntu_GNOME_Mutter_Internal_Panel_Drop_False_Freeze)
- [`Ubuntu_GNOME_rtkit_KMS_Scheduling_Collapse_Session_Respawn`](./Ubuntu_GNOME_rtkit_KMS_Scheduling_Collapse_Session_Respawn) — diagnose "the whole Ubuntu session crashed and I lost all my terminals" when there was **no reboot** and **zero GPU errors**; root cause is `rtkit-daemon` SIGKILL under CPU starvation from swap-reclaim churn (`swappiness=150`) plus reverse-PRIME page-flips; mitigates with `swappiness 150→120`.
- [`Ubuntu_GNOME_Shell_Xwayland_BadWindow_Crash_Under_Load`](./Ubuntu_GNOME_Shell_Xwayland_BadWindow_Crash_Under_Load)
- [`Ubuntu_Inotify_Exhaustion_ENOSPC_Freeze_Crash`](./Ubuntu_Inotify_Exhaustion_ENOSPC_Freeze_Crash)
- [`Ubuntu_NVIDIA_Primary_Webview_Disable_GPU`](./Ubuntu_NVIDIA_Primary_Webview_Disable_GPU)
- [`Ubuntu_NVIDIA_Wayland_Flip_Event_Timeout`](./Ubuntu_NVIDIA_Wayland_Flip_Event_Timeout) — eliminate `nv_drm_atomic_commit *ERROR* Flip event timeout on head` kernel errors that cause GNOME Shell SIGTRAP crashes under Wayland on hybrid Intel+NVIDIA systems; root cause is `nvidia_drm.modeset=1` being configured only in `/etc/modprobe.d/`; move the parameter to the GRUB kernel command line.
- [`Ubuntu_NVIDIA_Xid56_Display_Freeze_Under_Load`](./Ubuntu_NVIDIA_Xid56_Display_Freeze_Under_Load)
- [`Ubuntu_Snap_Alacritty_User_Font_Persistence`](./Ubuntu_Snap_Alacritty_User_Font_Persistence) — persist a user-installed font in a snap-confined Alacritty 0.17, applied live with no restart, without bricking the config; captures five back-to-back font swaps and the trap each exposed.
- [`Ubuntu_Snap_Alacritty_Wayland_Scroll_Artifacts`](./Ubuntu_Snap_Alacritty_Wayland_Scroll_Artifacts)
- [`Ubuntu_Snap_Slack_Silent_Exit_During_Init`](./Ubuntu_Snap_Slack_Silent_Exit_During_Init) — migrate Slack off the snap and onto the official `.deb` when clicking the dock launcher does nothing visible because the snap's `browser.log` truncates inside `getLinuxDistro`; root cause is snapd 2.75 intercepting `io_uring_setup` via `SECCOMP_RET_USER_NOTIF`.
- [`Ubuntu_Snap_Slack_XWayland_Jitter`](./Ubuntu_Snap_Slack_XWayland_Jitter) — rewrite the user-scope Slack snap launcher that silently forces `--ozone-platform=x11` + blanks `WAYLAND_DISPLAY=`, so Slack runs on native Wayland via Chromium Ozone `hint=auto` instead of jittering through XWayland.
- [`Ubuntu_Supabase_Selfhosted_Docker_Autostart_Control`](./Ubuntu_Supabase_Selfhosted_Docker_Autostart_Control)
- [`Ubuntu_VSCode_Snap_to_Deb`](./Ubuntu_VSCode_Snap_to_Deb)
- [`Ubuntu_zram_oomd_Memory_Pressure_Tuning`](./Ubuntu_zram_oomd_Memory_Pressure_Tuning) — stop systemd-oomd from killing apps on memory-pressure spikes: add a 16 GB zram device and relax the oomd pressure thresholds (50%→80%, 20s→30s), with the two changes coupled. Ships `diagnose-memory-pressure.sh`.
- [`ubuntu-overcommit-committed-as`](./ubuntu-overcommit-committed-as) — diagnose and reason about kernel memory overcommit (`Committed_AS`, `vm.overcommit_memory`, `CommitLimit`) and `vm.swappiness=120`; explains why committed address space can far exceed physical RAM under the heuristic policy, which numbers actually matter, and when (and how) to tighten overcommit. Ships `diagnose-overcommit.sh`.
