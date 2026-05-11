# NVIDIA + Intel Hybrid Graphics Baseline Toolkit

_Applies to: hybrid Intel iGPU + discrete NVIDIA (Optimus/PRIME) laptops. Tested baseline capture on Ubuntu 24.04 + GDM 46 + NVIDIA 580-open + kernel 6.17.x. The baseline script should work on any systemd-based Linux; the hypothesis list is Wayland-specific._

## What this toolkit is

A proactive diagnostic kit for a class of hardware where many things will break on hybrid GPUs under Wayland — in ways that are individually hard to debug because each failure mode's symptoms appear **far from the cause**. The goal of the toolkit is to front-load the diagnostic work:

1. **Capture a known-good baseline now**, while the machine is healthy.
2. **When something breaks**, diff against the baseline to see exactly what changed — module versions, kernel params, power state, display topology.
3. **Match the symptoms against the hypothesis list** ([`hypotheses.md`](./hypotheses.md)) to jump to the likely category without a cold debugging start.

This is explicitly a **Tier 2 toolkit**. The fix sections in the hypothesis list are marked "⚠ NOT YET EMPIRICALLY VALIDATED" where applicable — they're collected from upstream NVIDIA docs, the Arch Wiki, mutter's issue tracker, and Ubuntu bug reports, but the author of this portfolio hasn't walked each debugging path firsthand. When one of them gets validated in practice, the relevant section migrates to a Tier 1 runbook in `../../linux/`.

## Contents

| File | Purpose |
|---|---|
| [`baseline-hybrid-state.sh`](./baseline-hybrid-state.sh) | Captures a JSON snapshot of everything that could drift and cause a hybrid-GPU bug. Run when the machine is healthy. |
| [`detect-hybrid-regressions.sh`](./detect-hybrid-regressions.sh) | Compares current state to the saved baseline and reports deltas. Run when something breaks. |
| [`hypotheses.md`](./hypotheses.md) | Eight known failure categories for hybrid Wayland systems. Each with symptoms, first-line diagnostics, and candidate fixes (cited to upstream, not empirically validated here unless marked). |

## Quickstart

```bash
# One-time, when the machine is working correctly:
bash ./baseline-hybrid-state.sh
# writes ~/.local/share/hybrid-graphics-baseline/baseline-YYYY-MM-DD-HHMMSS.json
# and updates a symlink ~/.local/share/hybrid-graphics-baseline/latest.json

# When something breaks (or monthly, as a drift check):
bash ./detect-hybrid-regressions.sh
# reads latest.json, captures current state, prints a human-readable diff
```

## What the baseline captures

Everything the author has seen drift silently on hybrid-GPU systems and later correlate with user-visible breakage:

**GPU hardware & drivers**
- `lspci -nnk` for each GPU — vendor, device, kernel driver in use, kernel modules available
- Loaded kernel modules (`nvidia`, `nvidia_drm`, `nvidia_modeset`, `nvidia_uvm`, `i915`)
- `nvidia-smi` summary: driver version, firmware, persistence mode
- `/proc/driver/nvidia/version`

**Kernel & boot**
- `/proc/cmdline` — the only authoritative record of what the kernel received
- `uname -r`, kernel module versions
- `/etc/default/grub` GRUB_CMDLINE_LINUX_DEFAULT (diffs against /proc/cmdline indicate a GRUB regeneration was needed but didn't happen)

**Module configuration**
- Full contents of `/etc/modprobe.d/*nvidia*.conf`, `*i915*.conf`, `*drm*.conf`
- `/etc/modules-load.d/` relevant files

**Power management**
- Per-PCI-device runtime power state: `/sys/bus/pci/devices/*/power/runtime_status` and `.../power/control`
- NVIDIA persistence daemon status
- `/proc/acpi/wakeup` relevant devices

**Display topology**
- Number and identifiers of connected outputs (eDP-*, HDMI-*, DP-*)
- Which GPU owns each connector (via `/sys/class/drm/`)
- Current mode per output (resolution, refresh rate, scale factor)
- Primary output

**Session**
- `$XDG_SESSION_TYPE`, `$WAYLAND_DISPLAY`, `$DISPLAY`
- Mutter / gnome-shell versions
- `$GDMSESSION`
- Enabled GNOME Shell extensions
- Active `environment.d` drop-ins that set GL/EGL/Vulkan variables (`MUTTER_*`, `__NV_PRIME_*`, `__GLX_*`, `VK_*`, `LIBGL_*`)

**PipeWire / screen capture**
- `pactl info` and sink list (HDMI-audio routing)
- `pw-cli list-objects` for Screen-related nodes

**AccountsService**
- `/var/lib/AccountsService/users/<user>` — which session type is recorded for autologin

## Why JSON and not a flat text diff

Because "something changed in power management" is a different category of concern than "the kernel cmdline changed". When the diff comes out, you want to see "the nvidia module version changed from 580.126.09 to 580.130.02" as a single semantic field, not a line diff of 40 lines of `modinfo` output. The regression detector uses the JSON structure to produce a semantic report:

```
[power] nvidia PCI device 0000:01:00.0 runtime_status: 'suspended' → 'active'
[display] HDMI-0 now connected (was: disconnected)
[module] nvidia_drm parameter `fbdev` unset (was: 1)
[env] MUTTER_DEBUG_FORCE_KMS_MODE removed from environment
```

A flat-text diff would bury each of these in context changes.

## What this toolkit will NOT catch

* **Transient hangs** — if your GPU locks up for 30 seconds and recovers, the baseline and the post-incident capture may look identical. The journal (`journalctl -b`) is still the source of truth for hangs; this toolkit is for state-based drift, not time-based incidents.
* **Firmware-level regressions** — if NVIDIA's GPU firmware (GSP / VBIOS) changes after a driver update, the baseline may record the same driver version but a different runtime behavior. Add a manual note when you suspect this.
* **User-space app GL backend selection** — this toolkit doesn't probe what GL context Chrome or Electron apps picked on startup. For that, `glxinfo` + per-app `chrome://gpu` inspection is still needed.

## Integration with the Tier 1 runbooks

When a hypothesis in [`hypotheses.md`](./hypotheses.md) gets validated by actually happening to you:

1. Run `detect-hybrid-regressions.sh` to capture the delta.
2. Save the baseline delta into the incident's record.
3. Follow the hypothesis's first-line diagnostics.
4. If the candidate fix works, write the Tier 1 runbook using the delta + journal output + the actual attempted fixes, not the speculative version from the hypothesis list.

The delta is gold for the Tier 1 runbook because it makes the "what changed" section concrete and replicable.
