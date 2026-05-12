# Ubuntu — Chrome on Wayland disables WebGL after a 3-strike GPU process crash loop on hybrid Intel+NVIDIA laptops

_Applies to: Ubuntu 24.04 LTS, Google Chrome 147.x (stable), Ozone Wayland, GNOME 46 / mutter on Wayland, hybrid Intel iGPU (Iris Xe / Alder Lake-P) + discrete NVIDIA (RTX 40-series Optimus), kernel 6.17.x, NVIDIA proprietary/open driver 580.x. Reproduced on a Gigabyte AORUS 15 9MF with six per-workspace Chrome profile launchers._

> **⚠ Reader's summary:** Chrome's Ozone Wayland backend reads the compositor's preferred DRM device (advertised by `wl_drm` on mutter) and self-injects `--render-node-override=/dev/dri/renderD129` when the compositor advertises the discrete NVIDIA GPU. On a system whose NVIDIA stack is not fully stabilized for Wayland (no `nvidia-drm.modeset=1` on the kernel command line, see [Ubuntu\_NVIDIA\_Wayland\_Flip\_Event\_Timeout](../Ubuntu_NVIDIA_Wayland_Flip_Event_Timeout) — **prerequisite**), Chrome's GPU process trips three flip-completion or EGL-init failures in a row, and Chrome's "frequent crashes" supervisor latches `Disabled Features: all`. The visible symptom is `Los efectos visuales requieren WebGL` in Google Meet — but every hardware-accelerated feature is dead, not just WebGL. The fix is **not** `--ignore-gpu-blocklist` (the bypass is for the static blocklist, not the dynamic crash supervisor). The fix is to (a) apply the prerequisite kernel-cmdline runbook, (b) wipe `GPUCache` + `ShaderCache` + `GrShaderCache` to reset the 3-strike counter, and (c) pin an explicit GPU policy by injecting PRIME / Vulkan ICD environment variables directly into the `Exec=` line of each `.desktop` launcher — making Chrome bind to a known-good device instead of the compositor's heuristic pick. A per-launcher `[Desktop Action]` provides an Intel-iGPU fallback for when NVIDIA is in a degraded state (battery save, post-suspend, driver mismatch).

## Context

Hardware: Gigabyte AORUS 15 9MF, RTX 4050 Laptop (NVIDIA 580.126.09-open) + Intel Iris Xe iGPU (Alder Lake-P), kernel 6.17.0-22-generic, Ubuntu 24.04, GDM 46, GNOME Shell on Wayland.

Workflow: six independent Chrome profiles backed by six pairs of `.desktop` launchers (one in `~/.local/share/applications/`, one duplicated to `~/Escritorio/` for direct double-click access — Ubuntu Dock pins from the former, Files runs the latter). Each profile maps to a different work context (personal, two consultancies, three side projects) and receives its own browsing session, cookies, and extensions:

```
~/.config/google-chrome-altrupets
~/.config/google-chrome-demolabcr
~/.config/google-chrome-dojocoding
~/.config/google-chrome-habitanexus
~/.config/google-chrome-lapc506
~/.config/google-chrome-vertivolatam
```

Trigger: during a Google Meet call, the "Background blur" / "Visual effects" panel returned `Los efectos visuales requieren WebGL` with the helper link "Por qué WebGL podría no estar disponible". Every `chrome://gpu` row read `Disabled` and the `Problems Detected` block ended with `GPU process was unable to boot: GPU access is disabled due to frequent crashes`. The user had previously toggled `chrome://flags/#ignore-gpu-blocklist` hoping to force WebGL back on; this had no effect because the blocklist is not the gating mechanism in this state.

## Problem Statement

A `chrome://gpu` dump from the affected profile shows the cascade end-to-end:

```
Graphics Feature Status
=======================
*   Canvas: Software only. Hardware acceleration disabled
*   Compositing: Software only. Hardware acceleration disabled
*   OpenGL: Disabled
*   Rasterization: Software only. Hardware acceleration disabled
*   Video Decode: Software only. Hardware acceleration disabled
*   Video Encode: Software only. Hardware acceleration disabled
*   Vulkan: Disabled
*   WebGL: Disabled
*   WebGPU: Disabled

Driver Information
==================
GPU0                            : VENDOR= 0x0000, DEVICE=0x0000
GL implementation parts         : (gl=disabled,angle=none)
GPU process crash count         : 3

Command Line               : /usr/bin/google-chrome --user-data-dir=...
                             --class=chrome-lapc506
                             --flag-switches-begin --flag-switches-end
                             --ozone-platform=wayland
                             --render-node-override=/dev/dri/renderD129

Problems Detected
=================
*   Accelerated rasterization has been disabled, either via blocklist, about:flags or the command line.
*   Accelerated video encode has been disabled, either via blocklist, about:flags or the command line.
*   Accelerated video decode has been disabled, either via blocklist, about:flags or the command line.
*   WebGL has been disabled via blocklist or the command line.
*   Gpu compositing has been disabled, either via blocklist, about:flags or the command line.
*   Accelerated 2D canvas is unavailable: either disabled via blocklist or the command line.
*   GPU process was unable to boot: GPU access is disabled due to frequent crashes.
    Disabled Features: all
```

The signals that matter, in order:

1. **`--render-node-override=/dev/dri/renderD129`** sits on the GPU process command line *after* `--flag-switches-end`. On this system `renderD128` is the Intel iGPU and `renderD129` is the NVIDIA dGPU. The user did not set this flag — Chrome injected it during Ozone Wayland initialization.
2. **`GPU0: VENDOR=0x0000, DEVICE=0x0000`** — the GPU process did not survive long enough to read PCI vendor/device IDs. The crash happened during EGL/GBM bring-up, before PCI enumeration.
3. **`GPU process crash count: 3`** — Chrome's supervisor latches at three. The counter is per-profile, persisted in `Local State`, and survives Chrome restarts. Once latched, the supervisor refuses to spawn a GPU process at all and the entire feature matrix collapses to `Disabled`.
4. **`GL implementation parts: (gl=disabled,angle=none)`** — ANGLE never loaded, which is the proximate reason WebGL is dead (Chrome's WebGL goes through ANGLE, not directly through GL).
5. The **per-feature "Disabled via blocklist or command line"** lines are misleading. The blocklist did not match anything here. The "command line" the message refers to is the post-supervisor injection of `--disable-*` flags into the renderer's GPU surface — a downstream consequence of the supervisor latch, not a user-set flag.

## Root Cause

### The apparent cause: "Chrome decided to use NVIDIA"

The `--render-node-override` flag in the command line is the most visible signal. The user's first instinct — "remove that flag from my launcher" — fails because the flag is **not** in the launcher. The launchers are clean:

```bash
$ grep -E '^Exec=' ~/.local/share/applications/chrome-*.desktop
# no --render-node-override anywhere
$ grep -E '^Exec=' ~/Escritorio/chrome-*.desktop
# no --render-node-override anywhere
$ diff ~/.local/share/applications/chrome-lapc506.desktop ~/Escritorio/chrome-lapc506.desktop
# identical
```

`enabled_labs_experiments` in `Local State` is empty for every profile. `~/.config/chrome-flags.conf`, `~/.config/chromium-flags.conf`, environment.d, and shell aliases all return empty. The flag has no static origin in any user-controlled file.

### The real cause, part 1: Ozone Wayland's compositor-preferred-device negotiation

Chrome ≥ 113 ships an Ozone Wayland backend that, on session startup, queries the compositor for its preferred render node:

1. Chrome binds to the `wl_drm` global advertised by the compositor (visible in `chrome://gpu` as part of the compositor's interface list — on this system, `wl_drm:2` is exposed by mutter).
2. The compositor responds with the path to the DRM device it considers "primary" for client buffer rendering. mutter on hybrid Intel+NVIDIA Optimus laptops returns the **discrete NVIDIA card** when `nvidia-drm.modeset=1` is active, because the NVIDIA proprietary driver advertises higher capabilities (PRIME modifiers, `dma-buf` import for compressed formats).
3. Chrome rewrites this path internally and **injects** `--render-node-override=/dev/dri/<node>` into its own GPU process command line. This is why the flag appears after `--flag-switches-end` (which marks the end of *user* flags) — it's a programmatic post-injection, not a user-controlled switch.
4. The GPU process forks with the injected flag, opens the override path, and tries to initialize EGL/GBM against it.

This negotiation is by design and works correctly on stable NVIDIA-Wayland setups. The bug emerges only when step 4 fails repeatedly.

### The real cause, part 2: NVIDIA Wayland flip fragility without `nvidia-drm.modeset=1` on cmdline

If the kernel command line is missing `nvidia-drm.modeset=1` (the failure mode documented in [Ubuntu\_NVIDIA\_Wayland\_Flip\_Event\_Timeout](../Ubuntu_NVIDIA_Wayland_Flip_Event_Timeout)), the NVIDIA DRM driver loaded from initramfs runs with `modeset=0`. EGL surfaces against `renderD129` are accepted but their flip completion is unsynchronized, and any client that does a sustained sequence of presents (Chrome's GPU process repeatedly re-creating and resizing offscreen surfaces during its initial paint) is at high risk of hitting a flip-event-timeout. The GPU process crashes, Chrome's supervisor logs strike 1.

Chrome's supervisor relaunches the GPU process. Same path. Same failure. Strike 2.

Third launch: same failure. Strike 3 latches.

### The real cause, part 3: the 3-strike supervisor is per-profile and persists across launches

Chrome's `gpu::GpuWatchdogThread` and the `GpuProcessHost` reuse-policy together implement a counter:

* On every GPU process exit-with-error, increment `Local State` → `gpu_data_manager.crash_count`.
* On launch, read the counter. If `>= 3`, set `forced_software_compositing = true` and skip GPU process creation entirely.
* The counter is reset only by (a) a successful GPU process boot that survives N seconds, or (b) deletion of the cache directories the GPU process inspects on boot (`GPUCache`, `ShaderCache`, `GrShaderCache`, `GraphiteDawnCache`, `ANGLECache` depending on the version) — because their absence is treated as "fresh profile, give it another chance".

Restarting Chrome alone does not reset. Restarting the system alone does not reset. `chrome://flags/#ignore-gpu-blocklist` does not reset (it only bypasses the static blocklist, which is checked **before** the supervisor latch). The supervisor must be reset explicitly.

### Why `--ignore-gpu-blocklist` does not help (and may make things worse)

The flag suppresses entries from `gpu/config/software_rendering_list.json`. That list is consulted by `GpuDataManagerImplPrivate::UpdateGpuFeatureInfo` early in startup, **before** the supervisor latch is checked. With the flag, Chrome will more aggressively attempt the unstable path — burn through more crashes faster — without ever escaping the latch, because the latch is a separate mechanism with no command-line bypass. Any documentation that recommends `--ignore-gpu-blocklist` for "WebGL disabled after crash" is wrong; it was written for a different failure mode (blocklist-match on shipping Chrome with experimental drivers) and doesn't apply here.

## Solution

Three layers, applied in order, and only after the prerequisite is satisfied.

### Prerequisite (do this first, reboot-required)

Apply [`Ubuntu_NVIDIA_Wayland_Flip_Event_Timeout`](../Ubuntu_NVIDIA_Wayland_Flip_Event_Timeout/README.md). Without `nvidia-drm.modeset=1` and `nvidia-drm.fbdev=1` on `/proc/cmdline`, this runbook's GPU policy is not safe — the flip fragility that caused the original 3-strike will re-trigger on the next sustained GL workload. The diagnostic script below refuses to proceed if the cmdline parameters are missing.

```bash
# In the sibling runbook directory:
sudo bash ./enable-nvidia-drm-modeset.sh
sudo reboot
# Verify after reboot:
grep -oE 'nvidia-drm\.(modeset|fbdev)=[01]' /proc/cmdline
# Expected: nvidia-drm.modeset=1 and nvidia-drm.fbdev=1
```

### Layer 1 — Diagnose

See [`diagnose-chrome-gpu-state.sh`](./diagnose-chrome-gpu-state.sh). The script:

1. Confirms a Wayland session (`$XDG_SESSION_TYPE` = `wayland`).
2. Confirms hybrid Intel + NVIDIA via `lspci`.
3. **Hard-aborts** if `/proc/cmdline` does not contain both `nvidia-drm.modeset=1` and `nvidia-drm.fbdev=1`, with a pointer to the prerequisite runbook.
4. Confirms `nvidia-smi` succeeds (driver loaded, GPU enumerable).
5. Confirms `/usr/share/vulkan/icd.d/nvidia_icd.json` and `/usr/share/vulkan/icd.d/intel_icd.json` exist (both ICDs are required — NVIDIA for the default policy, Intel for the iGPU fallback Action).
6. Inventories `~/.config/google-chrome-*` profiles, reports per-profile cache size and the age of the most recent `GPUCache` entry (older = supervisor probably already reset itself; recent = explicit reset still needed).
7. Greps `journalctl -b 0` for `nv_drm_atomic_commit` errors as a sanity check that NVIDIA is currently healthy. Non-zero in the current boot is a warning that the prerequisite is applied but failing for an additional reason.

```bash
bash ./diagnose-chrome-gpu-state.sh
# Exit codes:
#   0 — runbook applies, prerequisites OK, ready to proceed
#   1 — prerequisite cmdline parameters missing (apply sibling runbook first)
#   2 — hardware not eligible (no hybrid Intel+NVIDIA detected)
#   3 — session type not Wayland
#   4 — Vulkan ICDs incomplete
```

### Layer 2 — Audit the launcher pair

See [`audit-chrome-launchers.sh`](./audit-chrome-launchers.sh). Walks the launcher pair (`~/.local/share/applications/chrome-*.desktop` ↔ `~/Escritorio/chrome-*.desktop`) and reports:

* Whether each pair is byte-identical (these should always be in lock-step).
* Whether the `Exec=` line already has the NVIDIA env-var prefix (i.e., this runbook has already been applied).
* Whether the `[Desktop Action open-igpu]` and `[Desktop Action new-window-igpu]` blocks already exist.
* Which profiles are referenced in `~/.config/google-chrome-*` directories, so an orphan `.desktop` whose profile dir was deleted is surfaced.

The script is read-only. It exits 0 if everything is in a coherent state (whether already-pinned or not-yet-pinned), and 1 if it finds asymmetries (e.g. a launcher in `~/.local/share/applications/` without a twin in `~/Escritorio/`, or with the env-var prefix in one copy but not the other).

```bash
bash ./audit-chrome-launchers.sh
```

### Layer 3 — Reset the 3-strike supervisor for an affected profile

See [`repair-chrome-profile-gpu.sh`](./repair-chrome-profile-gpu.sh). For a single profile:

1. Verifies the profile directory exists.
2. Checks whether Chrome is currently running with that profile and refuses to proceed if so (the user must close those windows; the script does not kill processes).
3. Removes the GPU caches that gate the supervisor reset:
   ```
   ~/.config/google-chrome-<profile>/GPUCache/
   ~/.config/google-chrome-<profile>/ShaderCache/
   ~/.config/google-chrome-<profile>/GrShaderCache/
   ~/.config/google-chrome-<profile>/GraphiteDawnCache/
   ~/.config/google-chrome-<profile>/Default/GPUCache/
   ~/.config/google-chrome-<profile>/Default/ShaderCache/
   ```
4. Backs up `Local State` to `Local State.bak.<timestamp>` and clears the `gpu` block (drops the persisted crash counter explicitly, in case the cache-deletion heuristic is not enough on this Chrome version).
5. Prints a verification command for after the next launch.

```bash
bash ./repair-chrome-profile-gpu.sh lapc506
# or to repair all six in sequence:
for p in altrupets demolabcr dojocoding habitanexus lapc506 vertivolatam; do
  bash ./repair-chrome-profile-gpu.sh "$p"
done
```

### Layer 4 — Pin the GPU policy on every launcher

See [`pin-chrome-gpu-policy.sh`](./pin-chrome-gpu-policy.sh). This is the durable fix.

For each `chrome-*.desktop` in `~/.local/share/applications/`:

1. Backs up the file to `<file>.bak.<timestamp>`.
2. Rewrites every `Exec=` line (the main one and the existing `[Desktop Action new-window]` / `[Desktop Action new-private-window]` ones) to wrap the binary invocation in `env`:
   ```
   Exec=env __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia \
            __VK_LAYER_NV_optimus=NVIDIA_only \
            VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/nvidia_icd.json \
            /usr/bin/google-chrome --user-data-dir=... %U
   ```
3. Adds two new Actions to the file:
   ```
   Actions=new-window;new-private-window;open-igpu;new-window-igpu;
   
   [Desktop Action open-igpu]
   Name=Abrir con Intel iGPU
   Exec=env DRI_PRIME=0 __GLX_VENDOR_LIBRARY_NAME=mesa \
            VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/intel_icd.json \
            MESA_VK_DEVICE_SELECT=8086:* \
            /usr/bin/google-chrome --user-data-dir=... %U
   
   [Desktop Action new-window-igpu]
   Name=Nueva ventana (Intel iGPU)
   Exec=env DRI_PRIME=0 __GLX_VENDOR_LIBRARY_NAME=mesa \
            VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/intel_icd.json \
            MESA_VK_DEVICE_SELECT=8086:* \
            /usr/bin/google-chrome --user-data-dir=... --new-window
   ```
4. Mirrors every change to `~/Escritorio/chrome-*.desktop` so the dock-side and desktop-side launchers stay in sync.
5. Runs `update-desktop-database ~/.local/share/applications/` so GNOME Shell picks up the new Actions in the dock right-click menu without requiring a full logout — the change is visible after `killall -3 gnome-shell` on X11, or after `gnome-shell --replace` (impossible on Wayland) or a logout/login on Wayland.
6. Re-runs `audit-chrome-launchers.sh` automatically and exits non-zero if the audit fails (post-condition check).

```bash
bash ./pin-chrome-gpu-policy.sh
# Then logout and login again so mutter re-reads the .desktop directory.
```

The script is idempotent: re-running detects the env-var prefix and the Action blocks and skips files that already match the target shape. A `--force` flag overrides idempotency for cases where the policy itself has changed and old launchers need rewriting.

### Why these specific environment variables

| Variable | What it does | Why it's set |
|---|---|---|
| `__NV_PRIME_RENDER_OFFLOAD=1` | Tells GLX to route drawing to the discrete GPU regardless of the system default | Necessary on PRIME systems where Intel is the primary scanout — without it, GL clients land on Intel even if NVIDIA is targeted by render-node selection |
| `__GLX_VENDOR_LIBRARY_NAME=nvidia` | Forces libglvnd to dispatch to the NVIDIA GLX driver | Disambiguates when both `nvidia` and `mesa` ICDs are installed and libglvnd's auto-selection is unreliable |
| `__VK_LAYER_NV_optimus=NVIDIA_only` | Suppresses NVIDIA's Optimus auto-fallback to Intel for Vulkan | Ensures Vulkan apps (including Chrome's ANGLE backend, which is Vulkan-on-Linux) commit to NVIDIA without per-frame branch logic |
| `VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/nvidia_icd.json` | Restricts Vulkan ICD enumeration to a single ICD | Prevents the loader from picking up the Intel ICD as a co-equal alternative; Chrome's `VkPhysicalDevice` selection becomes deterministic |
| `DRI_PRIME=0` (Action only) | Tells Mesa to bind the primary card, not the offload card | Mirror image of `__NV_PRIME_RENDER_OFFLOAD=1`; routes back to Intel iGPU for the fallback path |
| `MESA_VK_DEVICE_SELECT=8086:*` (Action only) | Filters Mesa's Vulkan device list by PCI vendor ID | `0x8086` = Intel; restricts Vulkan to the iGPU even when NVIDIA's ICD is also present |

These are user-space environment variables only — no kernel module reload, no driver swap, no reboot. The `Exec=` rewrite takes effect on the next launch of each `.desktop`.

## Verification

After applying the prerequisite + this runbook + a logout/login cycle:

```bash
# 1. New flags are in the dock launcher's Exec line
grep -E '^Exec=' ~/.local/share/applications/chrome-lapc506.desktop | head -1
# Expected: starts with `Exec=env __NV_PRIME_RENDER_OFFLOAD=1 ...`

# 2. The desktop-side launcher matches byte-for-byte
diff ~/.local/share/applications/chrome-lapc506.desktop ~/Escritorio/chrome-lapc506.desktop
# Expected: empty

# 3. The new Actions are visible to the dock. Right-click any pinned Chrome
#    icon — the menu should now include "Abrir con Intel iGPU" and
#    "Nueva ventana (Intel iGPU)" alongside the existing two.

# 4. Launch Chrome from the dock and visit chrome://gpu. The expected state:
#    Graphics Feature Status:
#      Canvas: Hardware accelerated
#      WebGL: Hardware accelerated
#      WebGPU: Hardware accelerated
#      Compositing: Hardware accelerated
#      Vulkan: Enabled
#      OpenGL: Enabled
#    Driver Information:
#      GPU0: VENDOR=0x10de, DEVICE=<your-RTX-product-id>
#      GL_VENDOR: NVIDIA Corporation
#      GL_RENDERER: NVIDIA GeForce RTX 4050 Laptop GPU/PCIe/SSE2
#      GPU process crash count: 0
#    Problems Detected:
#      (none related to "frequent crashes")

# 5. Smoke test WebGL with a real workload — go to https://meet.google.com,
#    join a test call, open the Visual Effects panel. The blur and replacement
#    backgrounds should now be available.

# 6. Smoke test the Intel fallback. Right-click the dock launcher, choose
#    "Abrir con Intel iGPU", then in that window visit chrome://gpu:
#    Driver Information should now read VENDOR=0x8086 and the GL_RENDERER
#    should be "Mesa Intel(R) Graphics (ADL GT2)" or similar. WebGL still
#    accelerated, but on the iGPU.
```

If `chrome://gpu` after the fix still reads `Disabled Features: all` with `GPU process was unable to boot`, the cache wipe in Layer 3 was incomplete. Run `repair-chrome-profile-gpu.sh <profile>` again and verify there are no Chrome processes from that profile in the background (`pgrep -af google-chrome | grep <profile>`).

## Rollback

The full rollback is reversible without reboot:

```bash
# Restore each .desktop from its newest backup
for f in ~/.local/share/applications/chrome-*.desktop; do
  newest_bak="$(ls -t "${f}.bak."* 2>/dev/null | head -1)"
  [ -n "$newest_bak" ] && cp -p "$newest_bak" "$f"
done
# Mirror to ~/Escritorio/
for f in ~/.local/share/applications/chrome-*.desktop; do
  base="$(basename "$f")"
  cp -p "$f" "$HOME/Escritorio/$base"
done
update-desktop-database ~/.local/share/applications/
```

To roll back only the supervisor reset (rare — the cache wipe is harmless):

```bash
# The Local State backup created by repair-chrome-profile-gpu.sh
cd ~/.config/google-chrome-<profile>
newest_bak="$(ls -t 'Local State.bak.'* 2>/dev/null | head -1)"
[ -n "$newest_bak" ] && cp -p "$newest_bak" "Local State"
```

Logout/login after rollback so mutter re-reads the launcher directory.

## Known Constraints

* **Logout/login required after applying.** mutter caches parsed `.desktop` files at session start. `update-desktop-database` updates the on-disk index but does not reload mutter's parse cache. Ubuntu 24.04 on Wayland has no equivalent of `gnome-shell --replace` (X11-only), so a full session restart is the only way to make the new Actions appear in the dock right-click menu. Until logout/login, the new launcher's `Exec=` line is honored on next launch (the dock executes it via `gio launch`, which always reads the current file) but the Action menu shows the old set.

* **`__NV_PRIME_RENDER_OFFLOAD=1` is sufficient only on a single-NVIDIA system.** If the laptop has a *third* GPU (e.g., USB external GPU enclosure) the variable does not disambiguate among multiple NVIDIA cards. This system has exactly one NVIDIA GPU (RTX 4050), so the variable is unambiguous. If a future setup adds a second NVIDIA, switch to `__NV_PRIME_RENDER_OFFLOAD_PROVIDER="NVIDIA-G0"` (or `NVIDIA-G1`, etc.) which is per-PCI-ID.

* **Chrome version drift.** The flag injection name (`--render-node-override`) is a Chromium implementation detail and has been renamed once before (`--gpu-preferences` → `--render-node-override` between 113 and 124). If a future Chrome release renames it again, the symptoms will look the same but the diagnostic command-line greps in the audit script will need updating. The audit script is structured so that the search pattern is a single variable at the top.

* **Profile name embedded in launchers.** This runbook hard-codes the six profile names (`altrupets`, `demolabcr`, `dojocoding`, `habitanexus`, `lapc506`, `vertivolatam`) into the audit and policy scripts. Adding or renaming a profile requires editing the profile list at the top of each script. A future enhancement would auto-discover via `~/.config/google-chrome-*` directory scan; for now, explicit-list keeps the operations auditable.

* **Other Chromium-family browsers are not covered.** Microsoft Edge, Brave, Opera, Vivaldi, and Chromium are all on the dock too but use different launcher paths (e.g., snap-managed for some) and different config root directories. The Ozone Wayland heuristic affects them identically, but the script does not touch them. If symptoms appear there, port the policy by adapting `pin-chrome-gpu-policy.sh` — most variables transfer unchanged, only the binary path and config dir change.

* **Per-app Action visibility depends on the dock.** Ubuntu Dock 90.x (Ubuntu 24.04 default) honors Actions on right-click. Vanilla GNOME's Dash-to-Dock fork has the same behavior. Plain `dash-to-panel` on a different distro may not — verify the menu shows up before relying on it as a fallback. The fallback is also reachable from `gtk-launch chrome-lapc506.desktop open-igpu` for scripted use.

## Related runbooks

* [`Ubuntu_NVIDIA_Wayland_Flip_Event_Timeout`](../Ubuntu_NVIDIA_Wayland_Flip_Event_Timeout) — **hard prerequisite**. The cmdline parameters from that runbook are what makes the NVIDIA path stable enough to be the default GPU policy here. Without it, the supervisor latch will re-trigger.
* [`Ubuntu_GDM_Force_Wayland_on_NVIDIA`](../Ubuntu_GDM_Force_Wayland_on_NVIDIA) — **transitive prerequisite**. This runbook assumes the session is on Wayland; if `$XDG_SESSION_TYPE` is `x11`, the Ozone heuristic that injects `--render-node-override` doesn't run, the failure mode doesn't appear, and the policy in this runbook is unnecessary (though harmless — Chrome ignores the env vars on X11 if the X server already binds Intel).
* [`toolkits/NVIDIA_Intel_Hybrid_Graphics_Baseline`](../../toolkits/NVIDIA_Intel_Hybrid_Graphics_Baseline) — diagnostic baseline for hybrid laptops. The "what hardware do I have, what driver, what session" snapshot taken there is also collected here on each `diagnose-chrome-gpu-state.sh` run; if a regression appears later, the baseline is the reference state to compare against.

## References

* [Chromium Source — Ozone Wayland render node selection](https://source.chromium.org/chromium/chromium/src/+/main:ui/ozone/platform/wayland/host/wayland_drm.cc) — the file where the compositor's `wl_drm` advertisement is read and `--render-node-override` is constructed.
* [Chromium Source — `GpuDataManagerImplPrivate::OnGpuProcessCrashed`](https://source.chromium.org/chromium/chromium/src/+/main:content/browser/gpu/gpu_data_manager_impl_private.cc) — the supervisor implementing the 3-strike latch.
* [Chromium Source — `software_rendering_list.json`](https://chromium.googlesource.com/chromium/src/+/main/gpu/config/software_rendering_list.json) — the *static* blocklist that `--ignore-gpu-blocklist` bypasses (and that, as documented above, is not what's gating WebGL after a 3-strike).
* [Wayland protocol — `wl_drm` interface](https://wayland.app/protocols/wl_drm) — the protocol Chrome consults to learn the compositor's preferred render node.
* [NVIDIA driver README — PRIME render offload](https://download.nvidia.com/XFree86/Linux-x86_64/580.82.07/README/primerenderoffload.html) — the `__NV_PRIME_RENDER_OFFLOAD` family of variables and their interaction with libglvnd.
* [Mesa documentation — `MESA_VK_DEVICE_SELECT`](https://docs.mesa3d.org/envvars.html#envvar-MESA_VK_DEVICE_SELECT) — the syntax for selecting Vulkan devices by PCI vendor ID.
* [Khronos Vulkan-Loader — `VK_ICD_FILENAMES`](https://github.com/KhronosGroup/Vulkan-Loader/blob/main/docs/LoaderInterfaceArchitecture.md#table-of-debug-environment-variables) — the precedence rules for ICD discovery, including how `VK_ICD_FILENAMES` overrides everything else.
* [freedesktop.org — Desktop Entry Specification, Additional Application Actions](https://specifications.freedesktop.org/desktop-entry-spec/latest/extra-actions.html) — the spec for the `Actions=` and `[Desktop Action <name>]` blocks this runbook uses for the iGPU fallback.

## Debugging lessons

1. **A user-set flag and an auto-injected flag look identical in `chrome://gpu`.** The "Command Line" row concatenates everything the GPU process was launched with — there is no visual distinction between flags the user typed, flags from `chrome://flags`, and flags Chrome injected programmatically post-startup. The only way to tell them apart is to grep the user's launcher and config files; if the flag is not in any of them, it's auto-injected. Treating every flag in `chrome://gpu` as user-controlled was the original misdiagnosis here.

2. **`Disabled Features: all` is its own failure category.** Most of the `Disabled` lines in `chrome://gpu` are routine — features can be disabled per-driver, per-blocklist-entry, per-feature-flag. The `Disabled Features: all` line is *qualitatively* different: it means the supervisor refused to spawn the GPU process. Whenever this line is present, every other `Disabled` reason is downstream noise, and chasing them individually wastes time. The supervisor latch is the only thing to fix.

3. **`--ignore-gpu-blocklist` and the runtime crash supervisor are unrelated.** The blocklist is a static JSON file consulted at startup. The supervisor is a runtime watchdog. They share zero state. Documentation that conflates them — particularly forum answers from 2018-2020 era — predates the supervisor's introduction and should be treated as obsolete. Always check Chromium source for the *current* gating mechanism before applying a flag-based remedy.

4. **Compositor-driven device negotiation is invisible to the user.** Wayland's design assumes the compositor knows best about hardware. Chrome's Ozone backend respects this and asks. The user has no diagnostic for "what device did mutter recommend" — the only signal is the post-injected `--render-node-override` in the GPU process command line, and only if the user knows to look there. This is a class of failure where the symptom (Chrome crashes) is a long way from the cause (compositor advertised a fragile device). Defending against it requires pinning the device explicitly with environment variables, which is what this runbook does.

5. **`Local State` is not the only gate; the cache directories are also a gate.** Reading the Chromium source revealed that the supervisor reset path checks for the existence of GPU cache directories as a "fresh profile, give it another try" heuristic. Editing only `Local State` to clear the counter does not always reset the state; deleting only the cache directories does. This runbook does both, redundantly, because the relative reliability of the two paths varies between Chrome major versions and the cost of doing both is zero.

6. **Sync the launcher pair, always.** The `~/.local/share/applications/` and `~/Escritorio/` copies of every `.desktop` are indistinguishable to the user — both icons look the same, both work the same most of the time. But they're independent files, edited by different tools in different contexts. Any script that touches one must touch the other and assert post-condition equality. This runbook's `pin-chrome-gpu-policy.sh` runs `audit-chrome-launchers.sh` at the end specifically to enforce this invariant.

7. **The `env` prefix in `Exec=` is the cleanest way to inject environment variables for a single launcher.** Alternatives (a wrapper shell script, a `~/.config/environment.d/*.conf` entry, a `systemd --user` drop-in) all have larger blast radius — they affect more processes than just the one Chrome instance. `Exec=env VAR=val /usr/bin/google-chrome ...` is XDG-spec-compliant, idempotent, easy to grep for, and cleanly reversible. When a fix needs to apply to one specific launcher and only that launcher, `env` is the right tool.

8. **A 3-strike counter is a reasonable default but a hostile default for users with ambient flakiness.** The supervisor was designed for the case where a Chrome user has a genuinely broken driver and shouldn't be allowed to keep crashing the GPU process indefinitely. On a hybrid Optimus laptop where the underlying NVIDIA-Wayland integration is *almost* stable but occasionally trips a flip-event-timeout, the user can hit the latch by accident — once latched, the only path back to acceleration is full cache deletion, which is effectively invisible to a non-technical user. This is why "WebGL doesn't work in my Chrome" is a recurring complaint in Linux help channels with no good first-line answer; the answer requires understanding the supervisor exists.
