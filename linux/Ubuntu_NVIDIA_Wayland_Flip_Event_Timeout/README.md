# Ubuntu — NVIDIA Wayland crashes with "Flip event timeout on head" under GNOME/mutter

_Applies to: Ubuntu 24.04 LTS, GDM 46.x, GNOME Shell (mutter) on Wayland, NVIDIA driver 580-open (also reproduced on 550/535), hybrid graphics (Intel iGPU + discrete NVIDIA), kernel 6.17.x._

> **⚠ Reader's summary:** under load or after an extension crash, the kernel emits a sustained loop of `[drm:nv_drm_atomic_commit [nvidia_drm]] *ERROR* Flip event timeout on head 0/1` and `nvidia-modeset: ERROR: GPU:0: Error while waiting for GPU progress`, GNOME Shell crashes with signal 5 (SIGTRAP), GDM fails to respawn the session cleanly, and the machine needs a hard reboot. The apparent cause ("my machine crashed while I was away") is mostly invisible in journalctl until you filter for `nv_drm_atomic_commit`. The root cause is that `nvidia_drm.modeset=1` is set only via `/etc/modprobe.d/nvidia-graphics-drivers-kms.conf`, not on the kernel command line, so the parameter is applied too late on boots where the module is loaded early (from initramfs or by the systemd-modules-load path). The fix is to move the parameter to `GRUB_CMDLINE_LINUX_DEFAULT` and regenerate both GRUB and initramfs so the value binds at module-load time regardless of who loads it. Additionally enable `nvidia-drm.fbdev=1` to stabilize the framebuffer handoff on suspend/resume.

## Context

Hardware: Gigabyte AORUS 15 9MF, RTX 4050 Laptop (NVIDIA 580.126.09-open), Intel Iris Xe iGPU, kernel 6.17.0-22-generic, Ubuntu 24.04, GDM 46, GNOME Shell on Wayland.

After completing [`Ubuntu_GDM_Force_Wayland_on_NVIDIA`](../Ubuntu_GDM_Force_Wayland_on_NVIDIA) (successfully switching the autologin GDM session from X11 to Wayland), a new failure mode appeared: the desktop freezes for 30–60 seconds, the lock screen appears blank, mouse input stops responding, and the machine eventually hard-reboots. Recovery requires holding the power button.

The first two crashes were initially blamed on a GNOME Shell extension (`lockscreen-extension@pratap.fastmail.fm` + `just-perfection-desktop@just-perfection` together emitted `JS ERROR: Error: Unknown item {"id":"ubuntu-wayland"}` — a real but separate bug, see "Related failure mode" below). Disabling those extensions eliminated that specific error but **the flip-event-timeout crashes continued**, which is the signal that those extensions were not the underlying cause, only an accelerator.

## Problem Statement

```bash
journalctl -b -1 --no-pager | grep -E "nv_drm_atomic_commit|nvidia-modeset|gnome-shell.*crashed"
```

produces a repeating sequence that looks like this:

```
kernel: [drm:nv_drm_atomic_commit [nvidia_drm]] *ERROR* [nvidia-drm] [GPU ID 0x00000100] Flip event timeout on head 0
kernel: [drm:nv_drm_atomic_commit [nvidia_drm]] *ERROR* [nvidia-drm] [GPU ID 0x00000100] Flip event timeout on head 1
gnome-shell[1177141]: Could not release device '/dev/input/event22' (13,86): Tiempo de expiración
gnome-shell[1177141]: Received an X Window System error.
gnome-shell[1177141]: GNOME Shell crashed with signal 5
gnome-shell[1177914]: (EE) failed to write to Xwayland fd: Broken pipe
kernel: [drm:nv_drm_atomic_commit [nvidia_drm]] *ERROR* Flip event timeout on head 0
kernel: [drm:nv_drm_atomic_commit [nvidia_drm]] *ERROR* Flip event timeout on head 1
kernel: nvidia-modeset: ERROR: GPU:0: Error while waiting for GPU progress: 0x0000c67e:4 2:0:2292:2284
kernel: nvidia-modeset: ERROR: GPU:0: Error while waiting for GPU progress: 0x0000c67e:4 2:0:2292:2284
kernel: nvidia-modeset: ERROR: GPU:0: Error while waiting for GPU progress: 0x0000c67e:4 2:0:2292:2284
systemd[1]: sysinit.target: Job nvidia-persistenced.service/stop deleted to break ordering cycle starting with sysinit.target/stop
systemd[1]: Stopping systemd-backlight@backlight:nvidia_0.service
```

The sequence that matters:

1. **`Flip event timeout on head N`** — NVIDIA DRM submitted an atomic page-flip to the hardware and never received the vblank-arrive interrupt that confirms the flip landed. Kernel gave up after its timeout.
2. **`GNOME Shell crashed with signal 5`** — `SIGTRAP`. mutter called `abort()` or a `g_assert*()` tripped. This happens when mutter's own frame scheduler sees a flip that was accepted but never completed, after N consecutive flips in the same state — mutter treats this as an unrecoverable protocol violation.
3. **`Error while waiting for GPU progress`** — after mutter is dead, the next consumer tries to push frames (typically `gdm-wayland-session` spawning a replacement shell), which hits the same wall. `nvidia-modeset` reports the GPU's fence counter hasn't advanced — the GPU is genuinely stuck, not just slow.
4. **`sysinit.target ordering cycle on nvidia-persistenced`** — recovery fails because `nvidia-persistenced.service` has a circular dependency with `systemd-backlight@backlight:nvidia_0.service` that systemd only detects during the emergency-reboot path. systemd deletes one of the stop jobs to break the cycle, proceeds to halt, and the machine reboots "cleanly" from systemd's perspective — but the user experiences it as a crash with no warning.

## Root Cause

### The apparent cause: NVIDIA KMS is "not fully enabled"

NVIDIA's proprietary driver exposes a kernel parameter `nvidia_drm.modeset`:

```bash
modinfo nvidia_drm | grep -E '^parm:'
# parm:   modeset:Enable atomic kernel modesetting (1 = enable, 0 = disable (default)) (bool)
# parm:   fbdev:Create a framebuffer device (1 = enable (default), 0 = disable) (bool)
```

With `modeset=0`, the kernel driver exposes the device to userspace but does **not** support atomic modesetting, which is the only way Wayland compositors can present frames. mutter running against a DRM device without atomic modesetting effectively enters a degraded path where every frame is submitted on a best-effort basis, with no guarantee of vblank synchronization — which is precisely the failure mode we see.

A healthy installation has `modeset=1`. On this machine, the Ubuntu-packaged driver installs a modprobe drop-in that requests it:

```bash
cat /etc/modprobe.d/nvidia-graphics-drivers-kms.conf
# This file was generated by nvidia-driver-580
options nvidia_drm modeset=1
options nvidia NVreg_PreserveVideoMemoryAllocations=1
options nvidia NVreg_TemporaryFilePath=/var
```

So "the config asks for modeset=1". And in the running system, userspace can observe that modeset is enabled — `nv_drm_atomic_commit` in the error message is itself evidence that atomic paths exist. The config is not obviously wrong.

### The real cause: `modprobe.d` timing vs. initramfs module-load

`modprobe.d/*.conf` files are consulted **by the `modprobe` command when it loads a module**. They are not read by the kernel directly. The chain is:

1. Kernel boots, mounts initramfs.
2. Initramfs contains a compiled-in copy of `nvidia_drm.ko` (because Ubuntu builds the NVIDIA module into the initramfs to allow early KMS for the boot splash and the GDM greeter without a flicker).
3. Initramfs loads `nvidia_drm` via a mechanism that does **not** consult `/etc/modprobe.d` on the real root — because the real root isn't mounted yet. The module loads with **kernel defaults** (`modeset=0`).
4. Real root mounts. `systemd-modules-load.service` and friends fire. `modprobe` now reads `/etc/modprobe.d/nvidia-graphics-drivers-kms.conf` and tries to apply `options nvidia_drm modeset=1`.
5. **But the module is already loaded.** `options` in modprobe.d only takes effect at module-load time. The write to `/sys/module/nvidia_drm/parameters/modeset` through procfs would work if the parameter were runtime-writable, but `modeset` is a load-time-only parameter on NVIDIA. `modprobe` silently ignores the mismatch.
6. The driver runs with `modeset=0` for the rest of the session. userspace that queries `/sys/module/nvidia_drm/parameters/modeset` gets Permission denied (the file is root-0400 on NVIDIA proprietary), so even administrators can't easily observe the real value at runtime.
7. The `nv_drm_atomic_commit` code path still runs because the NVIDIA driver has internal fallback logic that accepts atomic submissions even when modeset is off — but without the vblank-sync guarantees, frame completion becomes unreliable. This is what produces the flip-event-timeouts under sustained load.

### Why `cat /proc/cmdline | grep nvidia-drm` returns empty

This is the diagnostic that tells you the kernel-command-line path was never set up:

```bash
cat /proc/cmdline
# BOOT_IMAGE=/boot/vmlinuz-6.17.0-22-generic root=UUID=... ro quiet splash vt.handoff=7
```

No `nvidia-drm.*` anywhere. The NVIDIA package's post-install didn't add it. The Ubuntu installer didn't add it. The GRUB default config at `/etc/default/grub` is the vanilla `GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"`. Every reinstall of the driver resets the modprobe.d file but never touches `/etc/default/grub`, so the problem is stable across driver updates.

### The secondary parameter: `nvidia-drm.fbdev=1`

On top of modeset, newer NVIDIA drivers added `fbdev` for proper handoff of the console framebuffer to the NVIDIA driver during boot. Default is 1 (on), but on hybrid systems where Intel's i915 claims the console framebuffer first, the NVIDIA side of the handoff sometimes fails silently. Setting `nvidia-drm.fbdev=1` explicitly in cmdline forces the order to be well-defined and eliminates a secondary class of suspend/resume flip-event-timeouts that also hit this machine.

## Solution

Move `modeset=1` and `fbdev=1` from modprobe.d into the kernel command line, then regenerate both GRUB and initramfs so the parameter binds at every module-load entry point.

### Apply the fix

See [`enable-nvidia-drm-modeset.sh`](./enable-nvidia-drm-modeset.sh). The script:

1. Backs up `/etc/default/grub` to `/etc/default/grub.bak.<timestamp>`.
2. Edits `GRUB_CMDLINE_LINUX_DEFAULT` to add `nvidia-drm.modeset=1 nvidia-drm.fbdev=1` if not already present. Preserves existing tokens (`quiet splash vt.handoff=7` etc.) and is idempotent — re-running doesn't duplicate tokens.
3. Runs `update-grub` so the change lands in `/boot/grub/grub.cfg` for the next boot.
4. Runs `update-initramfs -u` so the initramfs copy of `nvidia_drm.ko` also picks up the kernel parameter on its cmdline-parse.
5. Prints a large warning that the machine needs a reboot — no runtime change is possible because NVIDIA's `modeset` is load-time-only and the module is already loaded with the wrong value.

```bash
sudo bash ./enable-nvidia-drm-modeset.sh
sudo reboot
```

### Diagnose whether this runbook applies to your machine

See [`diagnose-nvidia-wayland-crashes.sh`](./diagnose-nvidia-wayland-crashes.sh). The script:

1. Checks whether the machine has an NVIDIA GPU and the proprietary/open driver (skips otherwise — nouveau crashes have different root cause).
2. Greps `/proc/cmdline` for `nvidia-drm.modeset` (absent = this runbook applies).
3. Greps `journalctl -b -1` for `nv_drm_atomic_commit` and `nvidia-modeset: ERROR` and counts occurrences. Three or more in the last boot = this runbook applies.
4. Checks `/etc/modprobe.d/nvidia-graphics-drivers-kms.conf` contents to confirm modprobe.d is the *only* place modeset is configured.
5. Exits 0 if this runbook applies, 1 otherwise, so the reader doesn't apply GRUB changes for an unrelated flicker.

```bash
bash ./diagnose-nvidia-wayland-crashes.sh
```

## Verification

After reboot:

```bash
# 1. Kernel command line includes the parameters.
cat /proc/cmdline | grep -oE 'nvidia-drm\.(modeset|fbdev)=[01]'
# nvidia-drm.modeset=1
# nvidia-drm.fbdev=1

# 2. Induce load and confirm no flip-event-timeouts. Drag a window around for 30 s,
#    then check:
journalctl -b 0 --no-pager | grep -c 'nv_drm_atomic_commit'
# Expected: 0.

# 3. Run a Wayland-native load test (if `glmark2-wayland` is installed):
glmark2-wayland --run-forever &
sleep 60
kill %1
journalctl -b 0 --since "2 minutes ago" | grep -E 'nv_drm_atomic_commit|nvidia-modeset: ERROR'
# Expected: empty.

# 4. Suspend-resume cycle. Close laptop lid, wait 10 s, open. Wake up should be clean,
#    no flip timeouts in journal. This was the most common trigger before the fix.
```

If `journalctl -b 0 | grep nv_drm_atomic_commit` returns any hits after this fix, the flip timeout has a different cause (bad display cable, driver–kernel mismatch, GPU hardware failure) and this runbook's fix is not sufficient. See "Known Constraints" for the escape hatches.

## Rollback

```bash
# From TTY (Ctrl+Alt+F3) if something about the new cmdline breaks boot:
sudo mv /etc/default/grub.bak.<timestamp> /etc/default/grub
sudo update-grub
sudo update-initramfs -u
sudo reboot
```

GRUB will still boot either way because the parameters are additive and vanilla-kernel-safe — but if something unrelated to NVIDIA breaks (e.g., the user had a custom cmdline token that this script mis-parsed), the rollback restores the exact pre-change cmdline.

To revert the modprobe.d file (not necessary, since it's still correct and works alongside the cmdline parameters):

```bash
# No action needed. The cmdline parameters win over modprobe.d if they diverge,
# so leaving modprobe.d alone is safe and provides a fallback if a future GRUB
# regeneration drops the cmdline token accidentally.
```

## Post-fix troubleshooting: cursor disappears over Wayland client windows

Even after `nvidia-drm.modeset=1` is active on the kernel command line, a secondary visual artifact may remain on hybrid Intel + NVIDIA hardware: the mouse cursor becomes invisible when hovering over certain Wayland client windows (terminals using GL-accelerated rendering — GNOME Terminal with vte GL path, Ptyxis, wezterm, alacritty running native-Wayland; also some Electron apps and browsers when a GPU-accelerated video is playing) but reappears instantly when moving the cursor onto GNOME Shell-native surfaces: the Ubuntu Dock, the top panel, the activities overview, notification popups. Sliding the cursor from a terminal onto the dock makes it visible again; sliding back onto the terminal makes it vanish.

### Root cause: hardware cursor plane vs. dma-buf client buffers

Wayland compositors have two paths to present the mouse cursor:

1. **Hardware cursor plane** — the compositor submits the cursor bitmap to a dedicated DRM plane. The GPU overlays it onto the scanout directly, bypassing the main compositor composition pass. Cheap, zero-latency, always on top.
2. **Software cursor** — the compositor draws the cursor as a sprite inside the main composition pass. Slightly more CPU work but fully under mutter's control.

Mutter picks the path per-surface. For GNOME Shell-internal surfaces (dock, overview, top panel) — which are drawn directly by mutter as part of the shell scene graph — it uses software cursor, because it's already composing those pixels anyway. For external Wayland clients (terminals, browsers, games) that hand mutter a pre-rendered dma-buf, mutter tries to use the hardware cursor plane because the client buffer is opaque to the compositor.

On NVIDIA under Wayland, the hardware cursor plane submission is subject to the same atomic-modeset-dependent vblank synchronization as the main page flip. When the client's dma-buf is a GL-rendered texture (terminals render their glyph atlas with OpenGL for performance), the NVIDIA DRM driver sometimes accepts the cursor-plane submit but fails to sync it with the client buffer update in the same vblank. Observed end results vary: the cursor plane gets composited against a stale client buffer, or with alpha ≈ 0, or positioned outside the visible rect. Visually, the cursor "disappears".

On GNOME Shell-native surfaces, mutter is drawing the surface AND the cursor in software, so it blends the cursor into the same composition pass — no hardware plane, no desync. That's why the dock "protects" the cursor: not because of anything special about the dock, but because mutter never handed the cursor to the hardware plane in that region.

This also explains why the bug is worse under Wayland than under X11. X11's cursor is always software-rendered by the X server as part of the root window composition; NVIDIA's X driver never uses a hardware cursor plane for client windows.

### Fix: force mutter to use software cursor everywhere

See [`fix-hw-cursor-desync.sh`](./fix-hw-cursor-desync.sh). The script writes a user-scope environment override:

```
~/.config/environment.d/90-mutter-nvidia-swcursor.conf
```

containing:

```ini
# Force mutter to use simple-copy KMS mode, which bypasses hardware cursor
# planes across all surfaces. Workaround for NVIDIA hardware cursor plane
# desync on Wayland clients using dma-buf + GL rendering.
MUTTER_DEBUG_FORCE_KMS_MODE=simple-copy
```

`environment.d/*.conf` is read by `systemd --user` at session startup, so the variable is in the environment of every subsequent process mutter spawns — including mutter itself when GDM launches the Wayland session. A full logout/login (not just `killall -3 gnome-shell`) is required for the session's systemd-user instance to re-read the directory.

```bash
bash ./fix-hw-cursor-desync.sh
# then: logout → login
```

### Verify

After logout/login:

```bash
# 1. Env var is in the session
env | grep MUTTER_DEBUG_FORCE_KMS_MODE
# → MUTTER_DEBUG_FORCE_KMS_MODE=simple-copy

# 2. Hover the cursor over a GL-accelerated terminal window (GNOME Terminal,
#    Ptyxis, etc.). Cursor should remain visible continuously as you cross
#    from the dock into the terminal and back.
```

### Trade-offs of `simple-copy`

* **Software cursor rendering cost is negligible.** It's a few-microsecond sprite composite per frame. Not measurable on anything newer than a 2015 laptop.
* **Direct-scanout optimizations are disabled.** Mutter falls back to "composite everything to a scratch buffer, copy to scanout". Any optimization that relied on zero-copy client buffer scanout (notably YUV video direct-scanout used by some video players) is replaced by the composited path. For typical desktop browsing / terminal / IDE work this is invisible; for full-screen 4K video playback, expect a 1–3 watt higher power draw.
* **No effect on GPU compute performance.** The env var only changes mutter's compositor mode, not anything GL/CUDA/Vulkan clients are doing with the GPU.

### Per-terminal alternative (narrower scope)

If you don't want to force software cursor globally, the disappearance only affects terminal emulators that render via GL. Terminal emulators that draw via Cairo/GTK software path do not trigger the bug. Options:

* **xterm** under XWayland — always software-drawn. Workaround is intrusive (different UX).
* **gnome-terminal** with `VTE_DISABLE_A11Y=0 GTK_USE_PORTAL=1 GSK_RENDERER=cairo` — forces the VTE backend to use the Cairo renderer instead of GL. Loses vte's fast scrollback.
* Kitty / WezTerm / Alacritty — all GL-rendered, all affected. No per-app toggle.

The per-terminal approach is only worth it if you can't afford the direct-scanout regression `simple-copy` introduces for video playback. For most workstations, the global env var is the right trade.

## Known Constraints

* **Fix requires a reboot.** There is no way to change NVIDIA's `modeset` parameter at runtime because it's load-time-only, and unloading `nvidia_drm` to reload it requires killing the display server, the GDM greeter, and every userspace GL client — which is indistinguishable from a reboot from the user's perspective and more fragile. A scheduled reboot is the clean path.

* **This fix does not address nouveau.** If the machine is running the open-source `nouveau` driver instead of NVIDIA's proprietary/open driver, `nvidia_drm` isn't loaded and these parameters are ignored. Flip-event-timeouts under nouveau have a different root cause (usually reclocking / clock-speed-negotiation bugs) and a different fix (`NOUVEAU_PSTATE` kernel parameter, or switching to the proprietary driver).

* **Hybrid graphics (PRIME) still needs per-app offload configuration.** This runbook stabilizes the primary display path (GNOME Shell → NVIDIA → Intel scanout). Applications that want to render on the NVIDIA GPU (e.g., games, blender, CUDA workloads) still need `__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia` or the equivalent `prime-run` wrapper. This runbook does not replace that configuration.

* **The `fbdev=1` parameter can interact with plymouth on some kernels.** If the boot splash (plymouth) flickers, shows garbled output, or briefly drops to text mode during boot after applying this fix, try removing only `nvidia-drm.fbdev=1` while keeping `nvidia-drm.modeset=1`. The `modeset` parameter alone is sufficient to fix the flip-event-timeout; `fbdev` is an additional stability win on suspend/resume. Re-enable `fbdev` after the next kernel update, when the plymouth issue is likely fixed upstream.

* **Extension-induced GNOME Shell crashes are a separate failure mode.** On the test machine, two GNOME Shell extensions (`just-perfection-desktop` and `lockscreen-extension`) emitted `JS ERROR: Error: Unknown item {"id":"ubuntu-wayland"}` after the switch from X11 to Wayland, independently of the flip-event-timeout issue. Disabling those extensions is a prerequisite (otherwise they mask the real signal by producing their own crash loop) but not a fix. If the test machine sees a GNOME Shell crash with SIGTRAP **and** `JS ERROR: Unknown item "ubuntu-wayland"` in the preceding journal lines, disable both extensions **and** apply this runbook. If the crash has SIGTRAP but no JS ERROR, only this runbook applies.

* **The `org.gnome.Shell@wayland.service: Killing process ... mutter-x11-fram) with signal SIGKILL` line in the journal is downstream noise, not a cause.** It's systemd cleaning up the XWayland-compatibility helper that mutter spawns for legacy X11 clients, after mutter itself is already dead. Don't chase it.

## Related runbooks

* [`Ubuntu_GDM_Force_Wayland_on_NVIDIA`](../Ubuntu_GDM_Force_Wayland_on_NVIDIA) — **prerequisite**. This runbook assumes the session is already running on Wayland. If `echo $XDG_SESSION_TYPE` returns `x11`, the flip-event-timeouts in this runbook are literally impossible (X11 uses a different presentation path that doesn't depend on atomic modesetting). Complete that runbook first.
* [`GNOME_Keyring_Empty_Password_Under_Autologin`](../GNOME_Keyring_Empty_Password_Under_Autologin) — adjacent, runs in the same session setup. If after this reboot the autologin keyring popup re-appears, apply that runbook's fix to eliminate it.

## References

* [NVIDIA driver README — `nvidia_drm` parameters](https://download.nvidia.com/XFree86/Linux-x86_64/580.82.07/README/kernel_open.html) — upstream docs on `modeset` and `fbdev`, including the "load-time only" constraint.
* [freedesktop.org — atomic modesetting API](https://www.kernel.org/doc/html/latest/gpu/drm-kms.html) — the API mutter uses and that fails silently on non-atomic drivers.
* [Arch Wiki — NVIDIA/Tips and tricks/Fixing terminal resolution and Enabling DRM kernel mode setting](https://wiki.archlinux.org/title/NVIDIA#DRM_kernel_mode_setting) — the canonical community-tested cmdline invocation this runbook ultimately reuses, with distro-specific wrapping.
* [Ubuntu launchpad bug #2032126 — "Flip event timeout on head" with NVIDIA 535+ on 23.10+](https://bugs.launchpad.net/ubuntu/+source/linux/+bug/2032126) — long-running upstream bug, many reporters, same fix.
* [NVIDIA developer forum — "GPU progress" errors and their meaning](https://forums.developer.nvidia.com/t/gpu-progress-error-on-modeset/) — official NVIDIA engineer response clarifying that these errors indicate vblank desync, not hardware failure.

## Debugging lessons

1. **A silent policy-vs-reality mismatch between config files is the hardest class of bug to spot.** `/etc/modprobe.d/nvidia-graphics-drivers-kms.conf` says `modeset=1` in plain text. The Ubuntu package installer wrote it. Every doc assumes it works. The only way to discover it doesn't is to observe a downstream symptom (flip event timeouts) and then reason backward about *when* the config is consulted relative to *when* the module is loaded. Grepping config files for the expected value is not evidence the value is in effect.

2. **"Load-time only" is a category of parameter that deserves its own mental model.** Most kernel-module parameters are runtime-writable through `/sys/module/<mod>/parameters/<param>`. NVIDIA's `modeset` is not, for good reasons (it changes the device's DRM capabilities, which would invalidate every open file descriptor against it). Whenever a driver's docs say "can only be set at module load time", treat it as equivalent to "must be on the kernel command line" — modprobe.d is unreliable by design for this category because the kernel may load the module before modprobe runs.

3. **`/proc/cmdline` is the only authoritative record of what the kernel received.** Not `/etc/default/grub`, not `/boot/grub/grub.cfg`, not `update-grub --help`. The pipeline from GRUB config to active cmdline passes through `grub-mkconfig` → `grub.cfg` → GRUB-at-boot → kernel — any step can drop a token silently (e.g., a shell-metacharacter in the value, a line ending the wrong way, an unescaped quote). Always verify the actual cmdline the live kernel has, not what you asked GRUB to produce.

4. **GNOME Shell signal-5 (SIGTRAP) under Wayland is almost always a driver-layer crash propagating up.** mutter has a hard-assert policy: any frame-presentation protocol violation is treated as unrecoverable and trips `g_assert()`, which lands as SIGTRAP on Linux. Signal-11 (SIGSEGV) in mutter typically means an extension crashed the shell via a JS exception that walked out of a native callback; signal-5 means the shell deliberately aborted because it saw inconsistent state from DRM/Wayland. Different signal, different root cause, different fix.

5. **When two issues look related but one is noise, disable the noisy one first to confirm.** The `JS ERROR: Unknown item "ubuntu-wayland"` from the two extensions was real and did cause a separate class of shell crashes. After disabling those extensions, the shell still crashed — at which point it was clear the extension fix was necessary but not sufficient. Disabling the noisy component is cheap and makes the signal from the real cause observable. Doing it in the other order (fixing the real cause first, with the noisy component still generating crashes) leaves the operator unable to verify whether the real fix worked.

6. **`sysinit.target ordering cycle on nvidia-persistenced.service` in the journal after a crash is a symptom of the crash path, not a cause.** systemd only computes ordering cycles during the shutdown transaction when some units are refusing to stop cleanly. A driver hang triggers systemd-shutdown, which finds the cycle because `nvidia-persistenced` and `systemd-backlight@backlight:nvidia_0` are both blocked waiting for `nvidia_drm` to be healthy. Don't chase this entry — fix the driver.

7. **Driver documentation distributed per-kernel-version is easy to mis-reference.** The `modeset` parameter is documented in every NVIDIA driver release README, but the cross-referenced "how to enable this on Ubuntu" instructions vary — some releases tell you to edit modprobe.d, some tell you GRUB. Both work, with different reliability. For NVIDIA specifically, the kernel-command-line path is the one that's been documented longest and has the fewest edge cases. If a newer driver's README says "we handle this for you via modprobe.d", verify empirically (by looking at `/proc/cmdline` vs. the running driver's observable behavior) before trusting it.
