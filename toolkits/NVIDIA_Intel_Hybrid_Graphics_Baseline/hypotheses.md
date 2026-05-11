# Known failure categories — NVIDIA + Intel hybrid graphics under Wayland

Eight categories of hybrid-GPU Wayland bugs with symptoms, first-line diagnostics, and candidate fixes. **Fixes are cited to upstream sources and marked with their validation status.** When a fix gets empirically validated on the author's machine, the category gets promoted to a Tier 1 runbook at `../../linux/` and this entry gets a link to it.

## Epistemic status key

- **✅ Empirically validated** — the author hit this bug on their own machine and applied the fix. See the linked Tier 1 runbook for the full journey.
- **🟡 Upstream-documented, not validated here** — the fix is published in official docs (NVIDIA README, Arch Wiki, mutter issue tracker, Ubuntu launchpad) but the author hasn't walked the path. The fix is likely correct; treat as "known-good starting point".
- **🔴 Speculative** — the fix direction is the author's inference from adjacent knowledge. Could be wrong. Validate before applying on anything other than a scratch machine.

---

## 1. Display / presentation

### 1.1 Flip event timeout → GNOME Shell SIGTRAP crash ✅

- **Symptom**: freeze → kernel log floods with `[drm:nv_drm_atomic_commit [nvidia_drm]] *ERROR* Flip event timeout on head N` → gnome-shell crashes with signal 5 → hard reboot required.
- **First-line diagnostic**: `journalctl -b -1 --no-pager | grep -c 'nv_drm_atomic_commit'` returning 3+ confirms the category.
- **Fix**: see [`../../linux/Ubuntu_NVIDIA_Wayland_Flip_Event_Timeout/`](../../linux/Ubuntu_NVIDIA_Wayland_Flip_Event_Timeout/) — move `nvidia-drm.modeset=1 nvidia-drm.fbdev=1` from modprobe.d to kernel cmdline.

### 1.2 Cursor disappears over Wayland client windows ✅

- **Symptom**: mouse cursor invisible over GL-rendered terminals / browsers, reappears over GNOME Shell surfaces (dock, top panel, overview).
- **First-line diagnostic**: visual only. If sliding the cursor from the dock into a terminal makes it vanish and back makes it reappear, it's this.
- **Fix**: see the "Post-fix troubleshooting: cursor disappears over Wayland client windows" section of [`../../linux/Ubuntu_NVIDIA_Wayland_Flip_Event_Timeout/`](../../linux/Ubuntu_NVIDIA_Wayland_Flip_Event_Timeout/) — `MUTTER_DEBUG_FORCE_KMS_MODE=simple-copy` in `environment.d`.

### 1.3 Tearing / flickering on external monitor 🟡

- **Symptom**: visible horizontal tear line when dragging windows on an HDMI/DP-connected external monitor, despite the internal panel being tear-free.
- **First-line diagnostic**: `/sys/class/drm/card*/card*-HDMI-*/` identifies which card owns the HDMI output. On gaming laptops like AORUS, HDMI is usually wired to the NVIDIA card directly; the tear comes from Intel iGPU compositing the frame and handing it off to NVIDIA's scanout without vblank sync.
- **Candidate fix direction** (upstream): enable NVIDIA's `ForceCompositionPipeline` metamode — historically an X11-only fix; on Wayland the equivalent is mutter's `clone` monitor layout plus forcing the external as primary so mutter composes in NVIDIA's context. Reference: [NVIDIA forum thread on Wayland tearing](https://forums.developer.nvidia.com/t/wayland-tearing-on-hybrid-hdmi/).
- **Status**: 🟡 cited, not validated here. External monitor hasn't been connected long enough on the test machine to observe.

---

## 2. Power management

### 2.1 dGPU drains battery because it doesn't enter runtime PM idle 🟡

- **Symptom**: laptop battery drops ~15%/hr with lid closed or idle. Fan spins up periodically. `nvidia-smi` shows Persistence-Mode: Off but power draw stays > 5W when it should be < 1W.
- **First-line diagnostic**:
  ```bash
  cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status    # expected: suspended
  cat /sys/bus/pci/devices/0000:01:00.0/power/control            # expected: auto
  nvidia-smi --query-gpu=pstate --format=csv                     # expected: P8 when idle
  ```
  If `runtime_status=active` or `pstate` is not P8 when nothing should be using the GPU, it's this.
- **Candidate fix direction** (upstream NVIDIA [Chapter 22](https://download.nvidia.com/XFree86/Linux-x86_64/580.82.07/README/dynamicpowermanagement.html)):
  1. Verify `nvidia-powerd.service` is enabled and running.
  2. Udev rule `/lib/udev/rules.d/80-nvidia-pm.rules` should write `auto` to `power/control` at boot. If the dGPU is still `on`, the rule didn't fire — reload with `udevadm control --reload-rules && udevadm trigger`.
  3. Check for processes holding GL/CUDA contexts: `lsof /dev/nvidia*`. Common culprits: Chrome's GPU process, Electron apps, `nvidia-persistenced`.
  4. If all of the above are clean and it's still on, the cause may be an external DP-connected device holding the dGPU active (see category 3).
- **Status**: 🟡 upstream-documented flow, not yet hit empirically on this machine.

### 2.2 Black screen on resume from suspend 🟡

- **Symptom**: close lid / suspend to RAM → open lid / resume → black screen, backlight on but no visible output. Keyboard unresponsive. Requires hard reboot.
- **First-line diagnostic**:
  ```bash
  # After the crash, on next boot:
  journalctl -b -1 | grep -iE 'nvidia|pm_suspend|pm_resume|gpu' | tail -50
  ```
  Look for `nvidia-modeset: ERROR: GPU:0: Failed to restore GPU state` or `Failed to allocate memory for save/restore buffer`.
- **Candidate fix direction** (upstream):
  1. Verify `NVreg_PreserveVideoMemoryAllocations=1` is in `/etc/modprobe.d/`. Our baseline config has it.
  2. Enable the three systemd services that coordinate VRAM save/restore:
     ```bash
     sudo systemctl enable nvidia-suspend.service nvidia-resume.service nvidia-hibernate.service
     ```
  3. Ensure `/var` has enough free space for VRAM dump (up to `VRAM size` of free space needed; 6 GB for a 4050).
  4. If still failing, `NVreg_EnableGpuFirmware=0` disables the GSP firmware path — some 580-series drivers have suspend bugs specific to GSP mode on Ada Lovelace GPUs.
- **Status**: 🟡 upstream-documented. Inevitable to hit; expect to validate within weeks of daily use.

---

## 3. External displays

### 3.1 External monitor not detected until dGPU wakes up 🔴

- **Symptom**: plug in HDMI cable → nothing happens for 30+ seconds → monitor eventually appears in display settings. Or: monitor never appears, requires `sudo modprobe -r nvidia_drm && modprobe nvidia_drm`.
- **First-line diagnostic**:
  ```bash
  cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status   # at time of plug
  # If 'suspended', dGPU can't enumerate connectors until runtime PM wakes it.
  ```
- **Candidate fix direction** (speculative): a udev rule that wakes the dGPU on HDMI hotplug. Reference: [NVIDIA forum — PRIME + runtime PM + hotplug](https://forums.developer.nvidia.com/t/external-monitor-not-detected-with-runtime-pm/). Partial fix from some reporters: disable runtime PM while docked (`echo on > /sys/bus/pci/devices/0000:01:00.0/power/control`), re-enable on undock.
- **Status**: 🔴 speculative — solution pattern varies by reporter, no clear consensus upstream.

### 3.2 HDMI audio not produced 🟡

- **Symptom**: HDMI/DisplayPort video works but no sound from external monitor or TV speakers.
- **First-line diagnostic**:
  ```bash
  pactl list cards short | grep -i nvidia    # expected: HDA NVidia card present
  pactl list sinks short | grep -i hdmi      # expected: hdmi-stereo or hdmi-surround
  ```
  If the NVIDIA HDA card is missing entirely, `snd_hda_codec_hdmi` didn't bind — likely the dGPU is in runtime suspend and its HDMI-audio device is hidden.
- **Candidate fix direction** (upstream): ensure `snd_hda_intel` module is loaded and `options snd-hda-intel enable=1` covers all HDMI codecs. If the dGPU is the HDMI source, its audio may need `nvidia-drm` to be active (see 3.1). In PipeWire, set the HDMI sink as default via `pactl set-default-sink <name>`.
- **Status**: 🟡 upstream-documented.

---

## 4. GPU selection per application (PRIME Render Offload)

### 4.1 Blender / DaVinci / Vulkan app picks Intel, runs slow 🟡

- **Symptom**: app launches and renders, but performance is a fraction of what the dGPU should provide. `nvidia-smi` shows 0% GPU utilization while the app is clearly GPU-bound.
- **First-line diagnostic**:
  ```bash
  # Inside the app's GL context:
  glxinfo | grep -E 'OpenGL renderer|OpenGL vendor'
  # If it says Mesa / Intel, app is on iGPU.
  ```
- **Candidate fix direction** (upstream [NVIDIA PRIME Render Offload](https://download.nvidia.com/XFree86/Linux-x86_64/580.82.07/README/primerenderoffload.html)):
  ```bash
  __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia <app>
  # or the prime-run wrapper shipped in the nvidia-prime package:
  prime-run <app>
  ```
  For Vulkan apps: `__NV_PRIME_RENDER_OFFLOAD=1 __VK_LAYER_NV_optimus=NVIDIA_only <app>`. Launchers can embed this in the `.desktop` file's `Exec=` line.
- **Status**: 🟡 standard upstream flow, well-documented.

### 4.2 Chrome / Electron video playback choppy despite dGPU present 🟡

- **Symptom**: 4K YouTube drops frames, `chrome://gpu` shows "Video Decode: Hardware accelerated" but decoder is Intel QSV even though NVDEC would be faster.
- **First-line diagnostic**:
  ```bash
  vainfo                   # check which driver VAAPI uses
  ls /usr/lib/x86_64-linux-gnu/dri/*.so     # iHD_drv (Intel) vs nvidia_drv
  ```
- **Candidate fix direction** (upstream): `nvidia-vaapi-driver` package + `LIBVA_DRIVER_NAME=nvidia` in Chrome's environment. Chrome flag `--use-gl=egl` may be required alongside.
- **Status**: 🟡 upstream; expect cross-cutting configuration with Chrome flags.

---

## 5. Screen capture / screen sharing (PipeWire + Portal)

### 5.1 Screen share in Discord/Zoom is black or flickering 🟡

- **Symptom**: start screen share in conferencing app → remote viewers see black / frozen / heavily flickering image while the presenter's own screen is fine.
- **First-line diagnostic**:
  ```bash
  # Check which PipeWire node is exposing the screen:
  pw-cli list-objects | grep -iE 'screen|portal|gnome.*remote'
  # Check the portal backend:
  systemctl --user status xdg-desktop-portal xdg-desktop-portal-gnome
  ```
- **Candidate fix direction** (upstream [xdg-desktop-portal-gnome#1097](https://gitlab.gnome.org/GNOME/xdg-desktop-portal-gnome/-/issues/1097)):
  1. Ensure only one portal backend is installed: `xdg-desktop-portal-gnome`, not also `xdg-desktop-portal-gtk` or `-kde`. Multiple backends confuse the frame-source selection.
  2. Remove `pipewire-media-session` if installed; use only `wireplumber` as session manager.
  3. For Electron apps (Discord), force use of the portal: `--enable-features=WebRTCPipeWireCapturer`.
- **Status**: 🟡 upstream-documented; expect several iterations before stable.

### 5.2 OBS drops frames or captures wrong monitor 🔴

- **Symptom**: OBS recording shows high frame drops at the encoder stage even though the preview is fluid. Or the captured output is from the wrong monitor.
- **First-line diagnostic**: `obs-studio` console output on launch — look for PipeWire-related warnings about format negotiation.
- **Candidate fix direction** (speculative): OBS + hybrid GPU issues usually come down to encoder placement. Force NVENC via "Settings → Output → Encoder: NVIDIA NVENC H.264", and ensure the capture source is "Screen Capture (PipeWire)", not "XSHM" (which won't work on Wayland). If OBS is running under XWayland, the capture path is completely different — launch with `QT_QPA_PLATFORM=wayland obs` to force native.
- **Status**: 🔴 speculative — OBS hybrid issues have many overlapping causes.

---

## 6. Suspend / resume

Already covered under 2.2 (black screen on resume). Two related variants:

### 6.1 Suspend hangs for 30+ seconds before completing 🟡

- **Symptom**: close lid → HDD/SSD light stays on for a long time → fan runs → finally suspends. Resume works but suspend itself is slow.
- **First-line diagnostic**:
  ```bash
  systemd-analyze --user blame   # won't include kernel-side pm_suspend work
  journalctl -b 0 -k | grep -E 'PM:|suspend' | tail -30
  ```
  Look for `PM: suspend entry (deep)` → `PM: suspend exit` delta. On healthy hardware this should be < 3 s total.
- **Candidate fix direction** (upstream): `NVreg_EnableS0ixPowerManagement=1` for modern laptops that support S0ix (modern standby) instead of S3. Or the opposite — force S3 via `mem_sleep_default=deep` in cmdline if S0ix is unstable on this chipset.
- **Status**: 🟡 cited upstream; trade-off between S0ix battery life and S3 reliability.

### 6.2 Hibernate not available or fails silently 🔴

- **Symptom**: `systemctl hibernate` returns immediately with no visible effect, or the machine appears to hibernate but on resume the session is lost.
- **First-line diagnostic**: `cat /sys/power/disk` — should include `platform` among the modes.
- **Candidate fix direction** (speculative): `NVreg_PreserveVideoMemoryAllocations=1` is necessary but not sufficient. Hibernate also needs `resume=UUID=<swap-uuid>` in the kernel cmdline and a swap partition/file big enough for RAM + VRAM combined.
- **Status**: 🔴 speculative — hibernate on NVIDIA is a known-fragile area upstream.

---

## 7. Kernel module loading order

### 7.1 External display connectors orphaned because i915 claimed them first 🟡

- **Symptom**: monitor connected at boot but not detected until `modprobe -r nvidia_drm && modprobe nvidia_drm` or reboot.
- **First-line diagnostic**:
  ```bash
  journalctl -b 0 -k | grep -E 'drm|nvidia|i915' | head -40
  # Look at the relative order of 'i915 probe' and 'nvidia-drm probe'.
  # If i915 fully completes before nvidia_drm even starts, the dGPU's
  # connectors may have been snatched.
  ```
- **Candidate fix direction** (upstream / Arch Wiki): force module load order via `softdep` in modprobe.d:
  ```bash
  # /etc/modprobe.d/nvidia-first.conf
  softdep nvidia_drm pre: i915
  ```
  Then `sudo update-initramfs -u`.
- **Status**: 🟡 cited upstream, not needed so far on this specific machine.

---

## 8. Fractional scaling with mixed DPI

### 8.1 Text blurry or cursor wrong size when crossing between monitors 🟡

- **Symptom**: internal panel at 100%, external 4K at 150% or 200%. Text on one monitor appears blurry; cursor briefly resizes to wrong pixel dimensions when crossing monitors.
- **First-line diagnostic**:
  ```bash
  gsettings get org.gnome.mutter experimental-features
  # If 'scale-monitor-framebuffer' is not in the list, fractional scaling
  # is in legacy mode — pre-rendered at integer scale then downsampled.
  ```
- **Candidate fix direction** (upstream [GNOME fractional scaling RFC](https://gitlab.gnome.org/GNOME/mutter/-/merge_requests/1545)):
  ```bash
  gsettings set org.gnome.mutter experimental-features "['scale-monitor-framebuffer', 'x11-randr-fractional-scaling']"
  ```
  This enables per-monitor framebuffer scaling — each monitor gets its own framebuffer at its native scale, which eliminates the crossing-monitor artifact. Requires logout/login.
- **Status**: 🟡 upstream-documented, widely deployed on non-NVIDIA. Has had bugs on hybrid where Intel scanout of a native-fractional NVIDIA framebuffer produces moire. Validate on each GNOME version.

---

## Hypothesis lifecycle

Each entry above has a status field. When you hit one of these bugs and either:

- **Confirm the candidate fix works** → promote to a Tier 1 runbook at `../../linux/<descriptive_name>/`, write the empirical journey, and update this file to change status to ✅ with a link.
- **Discover the candidate fix doesn't apply** → update this file with the new root cause and what the actual fix turned out to be. Downgrade 🟡 to "upstream fix didn't work, here's what did" and document that contradiction explicitly — disconfirmations are high-signal data.

Try not to let entries age too long at 🟡/🔴 without either validation or deletion — a stale "known-good fix" that hasn't been tested in 2 years is worse than no entry, because it pretends to be more reliable than it is.
