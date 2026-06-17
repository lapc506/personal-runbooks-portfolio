# Addendum — Forcing the dGPU render node on Wayland via the EGL path (not GLX)

*Date: 2026-06-17. Scope: the six per-profile launchers `~/.local/share/applications/chrome-<profile>.desktop` for `altrupets demolabcr dojocoding habitanexus lapc506 vertivolatam`.*

## Symptom this addendum fixes

The launchers already carried the NVIDIA PRIME offload environment block:

```
env __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia \
    __VK_LAYER_NV_optimus=NVIDIA_only VK_ICD_FILENAMES=.../nvidia_icd.json \
    /usr/bin/google-chrome ...
```

Despite that, `chrome://gpu` reported `GL_RENDERER` as **Intel Iris Xe**, and the GPU process command line showed `--render-node-override=/dev/dri/renderD128` (the Intel node). Chrome was rendering and compositing on the **iGPU**, not the RTX 4050, even though every variable above *looks* like it should select NVIDIA.

## Why the GLX offload env block is a no-op here

`__NV_PRIME_RENDER_OFFLOAD` and `__GLX_VENDOR_LIBRARY_NAME` are interpreted by **libglvnd's GLX dispatch layer** — the X11/GLX code path. They tell the GLX loader "for this process, route `glX*` calls to the NVIDIA vendor library and offload to the discrete GPU."

This Chrome instance is not on GLX. It runs under **GNOME 46 Wayland** with the **Ozone/Wayland** backend, which uses **EGL + GBM** for context creation and buffer allocation, never GLX. Under Wayland:

* There is no GLX dispatch to govern, so `__GLX_VENDOR_LIBRARY_NAME=nvidia` selects a vendor for an API path Chrome never calls.
* `__NV_PRIME_RENDER_OFFLOAD=1` still sets the offload *intent*, but with no GLX consumer it does not, on its own, move the EGL device selection. (It is kept anyway — it is the documented companion to the EGL vendor filename below, and harmless.)
* The render node is instead chosen by **compositor negotiation**: Chrome reads mutter's `wl_drm`/dmabuf-feedback advertisement and, on this hybrid laptop, mutter advertises the Intel node as the primary scanout device. Ozone honors it and injects `--render-node-override=renderD128` automatically. (This is the same compositor-driven device negotiation documented in the main runbook's "Debugging lessons" #4.)

Net: the GLX env block governs a code path that does not exist in this session, so it cannot change the GPU. The decision is happening one layer down, in EGL.

## Why the EGL vendor-filename path *does* apply

libglvnd has a **separate** dispatch layer for EGL, configured by a different variable:

```
__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/10_nvidia.json
```

This restricts the EGL loader's vendor enumeration to **only** the NVIDIA ICD (`libEGL_nvidia.so.0`, as declared in that JSON). With Mesa's `50_mesa.json` excluded from enumeration for this process, EGL's `eglGetPlatformDisplay` resolves to the NVIDIA implementation, and the GBM device backing it is the NVIDIA render node — regardless of what mutter advertised as the scanout preference. This is the EGL-path equivalent of what `__GLX_VENDOR_LIBRARY_NAME` does for GLX, and it is the variable that actually has a consumer under Wayland/EGL/GBM.

Paired with two Chrome flags that pin the backend explicitly rather than leaving it to heuristic detection:

```
--ozone-platform=wayland   # assert Wayland/Ozone (do not fall back to X11/XWayland)
--use-angle=gl-egl         # ANGLE's GL backend over EGL (consumes the NVIDIA EGL vendor)
```

`--use-angle=gl-egl` is the key half: it forces ANGLE — which Chrome uses for its GL/WebGL command translation — onto the **EGL** backend, which is exactly the loader path that `__EGL_VENDOR_LIBRARY_FILENAMES` governs. Without it, ANGLE may pick a backend whose device selection the EGL vendor filename does not reach.

## What was changed

For each of the six launchers, **only the three dGPU lines** (`Exec=` in `[Desktop Entry]`, plus the `[Desktop Action new-window]` and `[Desktop Action new-private-window]` blocks — all identified by the presence of `__NV_PRIME_RENDER_OFFLOAD=1`):

* added `__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/10_nvidia.json` immediately after `__NV_PRIME_RENDER_OFFLOAD=1` in the `env` block;
* added `--ozone-platform=wayland --use-angle=gl-egl` immediately after `/usr/bin/google-chrome` in the argument list.

The two **Intel iGPU** actions (`[Desktop Action open-igpu]`, `[Desktop Action new-window-igpu]`, identified by `DRI_PRIME=0`) were left **untouched** — they intentionally select the iGPU and must keep doing so.

Conceptual one-line diff (main `Exec=`):

```
- Exec=env __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia __VK_LAYER_NV_optimus=NVIDIA_only VK_ICD_FILENAMES=.../nvidia_icd.json /usr/bin/google-chrome --user-data-dir=... %U
+ Exec=env __NV_PRIME_RENDER_OFFLOAD=1 __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/10_nvidia.json __GLX_VENDOR_LIBRARY_NAME=nvidia __VK_LAYER_NV_optimus=NVIDIA_only VK_ICD_FILENAMES=.../nvidia_icd.json /usr/bin/google-chrome --ozone-platform=wayland --use-angle=gl-egl --user-data-dir=... %U
```

The edits are **idempotent**: each insertion is guarded so re-running it changes nothing (verified — re-applying the same `sed` left the file md5 unchanged). Timestamped backups were taken first as `chrome-<profile>.desktop.bak.<YYYYMMDD-HHMMSS>`.

## Verification (run by the user)

1. **Close every window of the target profile** — a running Chrome process for that `--user-data-dir` will be reused and ignore the new launcher; the change only takes effect on a cold start.
2. Relaunch the profile from the dock.
3. Open `chrome://gpu` and check **`GL_RENDERER`** in the "Graphics Feature Status" / "Driver Information" section: it should now read **NVIDIA GeForce RTX 4050** (or the ANGLE-wrapped NVIDIA string), **not** Intel Iris Xe.
4. Confirm the crash count / "GPU process crash count" is **0** and there is no `Disabled Features: all` line (see main runbook).

## Honest caveat — this does not lower the ~40% CPU

Moving Chrome's render/compositing to the dGPU is a **GPU-path** change. It does **not** reduce the steady ~40% CPU load. That CPU is the 25+ **renderer processes** (V8/JS execution, layout, style) spread across many tabs and six profiles — work that runs on the CPU regardless of which GPU composites the frames. The levers for CPU/RAM are **Chrome Memory Saver** (discard idle tabs) and **running fewer profiles concurrently**, not the GPU selection. Expect smoother compositing/WebGL from this change, not a lower CPU figure.

## Related

* Main runbook: [`README.md`](./README.md) — especially "Debugging lessons" #4 (compositor-driven device negotiation) and #7 (the `env` prefix in `Exec=`).
* The render-node-override symptom this addendum addresses is the *inverse* of the crash-loop the main runbook fixes: there the goal was a stable device; here it is the *correct* (discrete) device, reached through the EGL loader instead of GLX.
