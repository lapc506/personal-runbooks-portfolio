# 2026-08-19 — eDP-1 permanently disconnected (suspected overheating)

**Date:** 2026-08-19
**Reporter:** kvttvrsis
**Suspected cause:** Overheating of the internal panel / eDP connector
**Status:** Open — hardware diagnosis pending

## Symptom

The internal laptop panel (`eDP-1`) is **permanently disconnected** at the DRM level. Unlike the previous incident (2026-06-10) where the panel was administratively dropped by mutter, this time the kernel itself reports the connector as physically disconnected. The panel does not recover after lid close/open events.

## Environment

- **Laptop:** Gigabyte AORUS 15 9MF
- **OS:** Ubuntu (GNOME Shell on Wayland)
- **Kernel:** 6.17.x
- **NVIDIA driver:** 580.x
- **Session ID:** `ses_fe4c448c8ffeXZjXQpD9YUk6kV`

## Hardware state

| Component | Status |
|-----------|--------|
| Intel Iris Xe (Alder Lake-P, PCI 00:02.0) | Present, `i915` + `xe` drivers loaded |
| NVIDIA RTX 4050 Max-Q (AD107M, PCI 01:00.0) | Present, `nvidia` driver loaded |
| eDP-1 (internal panel) | **Disconnected** (on card2 / NVIDIA) |
| HDMI-1 (external) | Connected, 1920×1080, primary |
| DP-1 (USB-C) | Connected, 1920×1080 |
| Laptop lid | Open (`/proc/acpi/button/lid/LID0/state: open`) |

### GPU/connector topology (from diagnostics)

```
card1-DP-1                   connected    (PCI 0000:00:02.0)   ← Intel iGPU
card1-DP-2                   disconnected (PCI 0000:00:02.0)
card1-DP-3                   disconnected (PCI 0000:00:02.0)
card1-DP-4                   disconnected (PCI 0000:00:02.0)
card2-DP-5                   disconnected (PCI 0000:01:00.0)   ← NVIDIA dGPU
card2-eDP-1                  disconnected (PCI 0000:01:00.0)   ← NVIDIA dGPU ← PROBLEM
card2-HDMI-A-1               connected    (PCI 0000:01:00.0)   ← NVIDIA dGPU
```

**Key observation:** The eDP-1 is routed through `card2` (NVIDIA dGPU), not `card1` (Intel iGPU). This is atypical — eDP panels are usually wired to the iGPU. This may indicate a MUX switch or BIOS-level routing configuration.

### Additional observations

- `xrandr --listproviders` returns **0 providers** — Intel GPU is not exposed to X11
- `/sys/class/drm/card2-eDP-1/enabled` → `disabled`
- `/sys/class/drm/card2-eDP-1/status` → `disconnected`
- Writing to `enabled` via sysfs fails even with sudo (kernel restriction)
- `fbcon` primary device: `i915drmfb (fb0)` — VT console renders on Intel fb, which is invisible when eDP is black
- No `monitors.xml` found at `~/.config/monitors.xml`

## Diagnostic output (2026-08-19, boot 0)

### Signature 1 — panel dropped from active monitor configuration
```
(none) — panel was never dropped from the config on this boot
```

### Signature 2 — Embedded Controller reset
```
Runtime USB disconnects:
  ago 19 12:23:35 kvttvrsis-AORUS-15-9MF kernel: usb 3-6: USB disconnect, device number 4
  ago 19 12:23:35 kvttvrsis-AORUS-15-9MF kernel: usb 3-7: USB disconnect, device number 5

GIGABYTE USB-HID re-enumerations:
  2 ago 19 06:11:26   (boot-time)
  2 ago 19 12:23:50   (runtime — EC reset triggered by lid event)
```

### Signature 3 — monitor reconfiguration storm
```
keybinding re-grab lines this boot: 72

Timestamps:
  18 ago 19 12:23:50   (after lid close/open)
  18 ago 19 12:23:36   (after lid close/open)
  18 ago 19 12:12:34
  15 ago 19 06:11:41   (boot)
   3 ago 19 06:11:42   (boot)
```

### Signature 4 — backlight accounting broken
```
(none)
```

### Counter-evidence A — AC power drop
```
ago 19 06:11:26 ACPI: AC: AC Adapter [ADP1] (on-line)
```
No power loss detected.

### Counter-evidence B — Xid (dGPU crash)
```
(no Xid) — not the dGPU-wedge family
```

### Counter-evidence C — system liveness
```
last journal line: ago 19 12:24:01 CRON[44300]: session closed for user root
no systemd-shutdown trace → ended abruptly (hard power-off)
```

## Lid close/open test

**Action:** Closed and reopened the laptop lid to force display re-detection.

**Result:** Triggered EC reset (USB HID disconnect/re-enumerate at 12:23:35–12:23:50) and reconfig storm (72 keybinding re-grabs), but **eDP-1 remained disconnected**. The lid event did not recover the panel.

## Differentiation from previous incident (2026-06-10)

| Aspect | 2026-06-10 | 2026-08-19 |
|--------|-----------|-----------|
| Trigger | UPS transfer transient | Unknown (overheating suspected) |
| eDP-1 status | `disabled` (mutter dropped it) | `disconnected` (kernel-level) |
| eDP-1 GPU | card1 (Intel iGPU) | card2 (NVIDIA dGPU) |
| Recovery via lid close/open | Yes (预期) | **No** |
| `no configuration which is-current` | Yes (×3) | **No** |
| Panel hardware | Healthy | **Suspected faulty** |
| BIOS mode | — | **SG→PEG tested, no recovery** |

## BIOS change test — SG Mode → PEG Mode

**Time:** After reboot on 2026-08-19
**BIOS setting changed:** SG Mode (Selective Graphics / Switchable Graphics) → PEG Mode (PCI Express Graphics, discrete GPU only)

### Result: eDP still disconnected — no recovery

The PEG mode change did not recover the internal panel. The eDP remains physically disconnected at the DRM level.

### Post-PEG-mode GPU/connector topology

```
card1-DP-2                   connected    (PCI 0000:00:02.0)   ← Intel iGPU
card1-DP-3                   disconnected (PCI 0000:00:02.0)
card1-DP-4                   disconnected (PCI 0000:00:02.0)
card1-DP-5                   disconnected (PCI 0000:00:02.0)
card2-DP-1                   disconnected (PCI 0000:01:00.0)   ← NVIDIA dGPU
card2-eDP-2                  disconnected (PCI 0000:01:00.0)   ← NVIDIA dGPU ← STILL BROKEN
card2-HDMI-A-1               connected    (PCI 0000:01:00.0)   ← NVIDIA dGPU
```

### Display output (xrandr)

| Monitor | Resolution | Position | Notes |
|---------|-----------|----------|-------|
| HDMI-1 | 1920×1080 | 0+0 (left, primary) | NVIDIA dGPU |
| DP-2 | 1920×1080 | 1920+0 (right) | Intel iGPU (USB-C) |
| **eDP-2** | — | — | **disconnected / disabled** |

Total: **2 monitors detected**, same as before BIOS change.

### Key changes from SG Mode

| Aspect | SG Mode (before) | PEG Mode (after) |
|--------|-----------------|-------------------|
| eDP-1/eDP-2 | disconnected | **disconnected** (unchanged) |
| eDP connector naming | card2-eDP-1 | card2-eDP-2 (renumbered) |
| HDMI position | 1920+0 (right) | 0+0 (left, now primary) |
| DP naming | DP-1 (Intel) | DP-2 (Intel) |
| Intel GPU in xrandr | Not visible | Not visible (`listproviders: 0`) |

### Analysis

The BIOS mode switch (SG→PEG) changed GPU routing and connector naming but did **not** restore the eDP link. This rules out software/driver-level causes and points to a **hardware-level fault**:

- The eDP connector is not detected by the kernel regardless of GPU routing mode
- The panel, cable, or connector may be physically damaged (user reports overheating)
- A MUX switch in the BIOS does not bypass the physical disconnect

## Recommended next steps

1. ~~BIOS inspection: Check for MUX switch / Hybrid Graphics / iGPU settings~~ **Done** — tested SG→PEG, no recovery
2. **Thermal inspection:** Check eDP connector and cable for heat damage (user reports overheating) — **priority**
3. **External monitor test:** Connect an external display to the Intel iGPU DP ports to verify Intel GPU output works
4. **Live USB test:** Boot a live USB to rule out OS/driver configuration issue
5. **Hardware service:** If panel remains disconnected across BIOS reset and live USB, the eDP cable, connector, or panel itself may need physical inspection/replacement

## References

- Runbook: `README.md` (mutter panel-drop false-freeze, 2026-06-10)
- Sibling runbook: `../Ubuntu_NVIDIA_Xid56_Display_Freeze_Under_Load` (dGPU crash family)
- `fbcon` documentation: [kernel.org/doc/Documentation/fb/fbcon.rst](https://www.kernel.org/doc/Documentation/fb/fbcon.rst)
