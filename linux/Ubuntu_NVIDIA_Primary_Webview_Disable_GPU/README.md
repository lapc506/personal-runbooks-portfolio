# NVIDIA-primary breaks webview apps → force `--disable-gpu`

When the GNOME/mutter compositor is forced **primary on the NVIDIA dGPU**
(reverse-PRIME via the udev `mutter-device-preferred-primary` rule — see
`../Ubuntu_GNOME_Mutter_Force_Primary_GPU_NVIDIA/`), **embedded-webview desktop
apps hang or render blank**. This runbook patches them with `--disable-gpu`.

## Symptom

App (ZapZap was first) opens but the web content never paints / the window stops
responding. Journal at session login on the NVIDIA primary:

```
GBM is not supported with the current configuration. Fallback to Vulkan rendering in Chromium.
ANGLE ... texStorageMem2DEXT ... GL_INVALID_OPERATION 0x0502: Unexpected driver error
GL_INVALID_FRAMEBUFFER_OPERATION: Framebuffer is incomplete: Attachment has zero size
<app>, failed to provide activation token: timeout
```

## Root cause

Webview engines (QtWebEngine, Electron/Chromium) use **GBM / dma-buf** to import
GL textures zero-copy for the compositor. That path **works on the Intel iGPU but
fails on the NVIDIA driver** when NVIDIA is the primary render device: ANGLE's
external-memory texture allocation errors out, the framebuffer ends up zero-size,
and the webview never composites → the app wedges.

This is the hidden cost of NVIDIA-primary. Remember NVIDIA-primary does **not**
reduce gnome-shell CPU; weigh this breakage against the (marginal) benefit of the
dGPU compositing the desktop. The clean global escape hatch is to revert the udev
rule (back to Intel-primary); this runbook is the per-app alternative if you keep
NVIDIA-primary.

### Why not all Chromium apps?
Standalone **Chrome works** on NVIDIA — it's pinned to the dGPU via the EGL offload
(see `../Ubuntu_Chrome_Wayland_Render_Node_Crash_Loop/`). Browsers and Chrome are
out of scope here. The casualties are **embedded webviews** that don't negotiate
the GPU as gracefully.

## Fix

`--disable-gpu` makes the webview render in **software** — negligible for chat /
editor apps, and it sidesteps the broken GBM/dma-buf path entirely.

```bash
./webview-disable-gpu.sh            # patch all known webview apps
./webview-disable-gpu.sh --revert   # undo
```

Then **fully quit and reopen** each app (a live instance reuses its process and
ignores the launcher).

### What the script does (user-space, no sudo)
- **Electron apps** (snap + deb): writes a user `.desktop` override under
  `~/.local/share/applications/` (shadows the system one, incl. the dock) with
  `--disable-gpu` added to every `Exec=`. Covered (all Chromium-based, verified by
  `app.asar` / `libcef.so` / `chrome_crashpad_handler` markers): Slack, Claude
  Desktop, Notion (deb + snap), VS Code, Discord, Termius, GitKraken = **Electron**;
  Cursor, Kiro, Antigravity = **Electron** (VS Code forks, crashpad/ffmpeg);
  **Spotify = CEF** (Chromium Embedded, not Electron — same Chromium, so the flag
  applies). All take `--disable-gpu` as an argv flag.
- **QtWebEngine flatpaks**: `flatpak override --user --env=QTWEBENGINE_CHROMIUM_FLAGS="--disable-gpu"`. Covered: ZapZap.

### Scope notes
- **Slack is a `.deb`** (`/usr/bin/slack`), not a snap — it's here because it's
  Electron, not because of packaging. (Its dock favorite is the stale snap-style
  id `slack_slack.desktop`; the real entry is `slack.desktop`.)
- **Discord** already shipped a user override with `--disable-gpu`; the script is
  idempotent and leaves it.
- Excluded by design: **Chrome/Opera/Edge** (browsers, GPU wanted/works) and
  **Telegram Desktop** (native Qt, not a webview).
- Limitation: `add_flag` doesn't rewrite an `Exec=env VAR=x /bin/app` prefix form
  — none of the targeted apps use it. If a future app does, patch its `Exec=` by
  hand (insert `--disable-gpu` right after the real binary).

## Editors — accelerate, don't disable

Code editors (VS Code, Cursor, Kiro, Antigravity) are Electron too, but you *want*
the GPU there (smooth UI/scroll/minimap/webviews). Instead of `--disable-gpu`, give
them the **EGL offload recipe** that routes Chromium to the NVIDIA dGPU — the same
recipe verified on Chrome:

```bash
./editors-accelerate-nvidia.sh           # GPU-accelerate the editors on NVIDIA
./editors-accelerate-nvidia.sh --revert  # back to system default
```

It writes user `.desktop` overrides with
`env __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia __EGL_VENDOR_LIBRARY_FILENAMES=…/10_nvidia.json <bin> --use-angle=gl-egl`
on **XWayland** (no `--ozone-platform=wayland`, which avoids the Wayland GBM break).

**Verified** on VS Code: `code --status` → `GPU0 VENDOR=0x10de … NVIDIA … *ACTIVE*`,
`gpu_compositing: enabled`, `webgl: enabled`. Forks support `cursor/kiro/antigravity --status`.
(Minor: `vaInitialize failed` = VA-API video decode doesn't apply on NVIDIA — it uses
NVDEC — harmless for editing.)

Requires the **deb** builds (host Mesa). For VS Code, migrate off the snap first with
`../Ubuntu_VSCode_Snap_to_Deb/migrate-vscode-snap-to-deb.sh`. The editors are therefore
**excluded** from `webview-disable-gpu.sh` so the two scripts don't fight.

## Revert / per-app opt-out
- All at once: `./webview-disable-gpu.sh --revert`.
- One app: delete its `~/.local/share/applications/<id>.desktop` override (Electron)
  or `flatpak override --user --reset <app-id>` (flatpak). Reopen the app.
- Global: remove the NVIDIA-primary udev rule and go back to Intel-primary — then
  none of this is needed.
