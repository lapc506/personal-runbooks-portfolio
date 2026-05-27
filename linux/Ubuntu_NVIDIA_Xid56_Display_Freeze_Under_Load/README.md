# Ubuntu — NVIDIA `Xid 56` display freeze under sustained load (GNOME/Wayland, hybrid graphics)

_Applies to: Ubuntu 24.04 LTS, GDM 46.x, GNOME Shell (mutter) on Wayland, NVIDIA driver 580.126.09-open, hybrid graphics (Intel Iris Xe iGPU + discrete NVIDIA RTX 4050 — Ada Lovelace), kernel 6.17.x._

> **⚠ Reader's summary:** during long, heavy sessions the discrete NVIDIA GPU emits `NVRM: Xid (PCI:0000:01:00): 56, CMDre …` — a command/display-engine error. With Ubuntu PRIME in **`nvidia`** mode, the GNOME Shell (mutter) compositor renders **on the discrete GPU**, so when the GPU's command engine wedges, the **entire display freezes** and the machine needs a hard power-off. This is **not thermal** (no throttle/MCE logs, GPU idles ~45 °C). It is **distinct** from the sibling [`Ubuntu_NVIDIA_Wayland_Flip_Event_Timeout`](../Ubuntu_NVIDIA_Wayland_Flip_Event_Timeout) runbook — that fix (`nvidia-drm.modeset=1` on the kernel cmdline) is **already applied on this machine and did not resolve the Xid 56 freezes**. Mitigations, in order of leverage: **(1)** take the compositor off the dGPU with `prime-select on-demand`; **(2)** disable GSP firmware (`NVreg_EnableGpuFirmware=0`) — note this may be rejected on Ada-generation GPUs and must be verified.

## Context

Hardware: Gigabyte AORUS 15 9MF, RTX 4050 Laptop (NVIDIA 580.126.09-open, Ada Lovelace AD107M), Intel Iris Xe iGPU, kernel 6.17.0-22-generic, Ubuntu 24.04, GDM 46, GNOME Shell on Wayland.

Symptom as experienced: while working (typically a long session with Docker/Supabase + Chrome under load), **the screen freezes completely** — mouse stops, nothing repaints — and the only recovery is holding the power button. The user's framing was "se sobrecargó la gráfica" (the GPU overloaded). Forensics show it is **not an overload/overheat** but a recurring **logical GPU fault**.

This crash loses unsaved terminal state. The session-recovery side of the problem (Claude Code transcripts surviving the reboot) is handled separately by the launcher fix in [`claude-code-multi-backend`](../claude-code-multi-backend) (orphan-transcript scanning + `SessionStart` backup hook).

## Problem Statement

```bash
journalctl -b -1 -k --no-pager -g 'Xid'
```

on the boot that crashed produces:

```
kernel: NVRM: GPU at PCI:0000:01:00: GPU-f523c5c4-9f9f-f3f7-f3fe-d16cdea1405b
kernel: NVRM: Xid (PCI:0000:01:00): 56, CMDre 00000000 00002c88 000100bc 00000007 00000000
kernel: NVRM: Xid (PCI:0000:01:00): 56, CMDre 00000000 00002c8c 000100bc 00000007 00000000
```

Three corroborating signals make this a freeze, not a clean reboot:

1. **The journal ends abruptly** with no shutdown sequence (no `systemd-shutdown`, no `Reached target Power-Off`) → hard power-off.
2. **The kernel stops logging ~1 minute before the end** while userspace daemons (Supabase, Chrome, dockerd) keep logging for another ~2.5 min → the GPU/compositor wedged first; the rest of the system limped until the hard reset.
3. **The Xid fires ~40 min before the freeze** (`19:06`) and again the GPU never recovers — the error is the GPU's command engine reporting it is stuck.

### The recurrence pattern

| Boot | `Xid 56` count | When | Outcome |
|---|---|---|---|
| `-1` | 2 | 2026-05-26 19:06:13 (`…00002c88…`) | freeze ~19:47, hard reset 19:50 |
| `-2` | 1 | 2026-05-24 19:28:37 (`…00002c8c…`) | same signature |
| `-3` … `-7` | 0 | 2026-05-19 → 21 (short boots) | no incident |

Same error class, near-identical command words, only in the long heavy-load sessions. Reproducible, not random.

## Root Cause

### What `Xid 56` is

An **Xid** is the NVIDIA kernel module reporting a GPU exception to the host. Per NVIDIA's [Xid documentation](https://docs.nvidia.com/deploy/xid-errors/), Xids occur "most often due to the driver programming the GPU incorrectly or to corruption of the commands sent to the GPU," and can indicate a hardware, NVIDIA-software, or application problem. **`Xid 56` (the `CMDre` prefix is a command/host-engine error)** is documented in the field as a cause of **display freezing** on recent driver branches; see e.g. the NVIDIA forum thread [_Frequent display freezing and Xid 56 errors_](https://forums.developer.nvidia.com/t/frequent-display-freezing-and-xid-56-errors-on-arch-linux-endeavouros-575-64-and-4070-ti/337261) (RTX 40-series + 5xx driver, the same family as this machine).

It is a **logical** fault (the command stream the GPU is asked to execute wedges), **not** a thermal/physical one.

### Why it freezes the whole desktop (the configuration that turns a GPU fault into a system freeze)

Ubuntu PRIME is in **`nvidia`** mode on this machine:

```bash
prime-select query   # → nvidia
```

In `nvidia` mode the **compositor itself (GNOME Shell / mutter) renders on the discrete GPU**. Confirmed:

```bash
nvidia-smi --query-compute-apps=pid,process_name --format=csv,noheader
# 5616  /usr/bin/gnome-shell
```

So when the dGPU's command engine wedges (Xid 56), the process driving every pixel on screen is sitting on the stuck GPU → **the display freezes entirely**, and there is no second GPU in the present path to keep the desktop alive. This is the lever that converts a recoverable per-app GPU fault into a full-system freeze.

### Ruled out: thermal / overload

```bash
journalctl -b -1 -k --no-pager -g 'thermal|temperature|throttl|mce:|critical temp|clamping'
```

returns **only boot-time registration messages** (thermal governors, `Thermal Zone [TZ00] (28 C)`) — **zero runtime throttling, zero MCE, zero over-temp** across the entire 33-hour session. A real thermal event always leaves `mce:` / `clamping` / `critical temperature` traces. None exist. GPU idles at ~45 °C. **It is not overheating.**

### Ruled out: the flip-event-timeout / modeset issue

The kernel cmdline already carries the sibling runbook's fix:

```bash
cat /proc/cmdline
# … nvidia-drm.modeset=1 nvidia-drm.fbdev=1 …
```

so the flip-event-timeout root cause is already mitigated and is **not** what produces these Xid 56 freezes.

## Solution — sequenced experiments (one variable at a time)

> **Discipline:** apply **one** experiment, reboot, then run under normal heavy load for several days. Only if Xid 56 recurs do you move to the next experiment. Applying both at once makes it impossible to attribute the result.

### Experiment 1 — move the compositor off the dGPU (`prime-select on-demand`) — highest leverage, most reversible

**Hypothesis:** with the desktop rendering on the Intel iGPU and the dGPU used only on-demand, a dGPU Xid 56 can no longer freeze the compositor.

```bash
./experiment-1-prime-offload.sh        # applies on-demand mode (needs sudo); does NOT reboot
# then reboot when convenient
```

What it does: `sudo prime-select on-demand`. After reboot, mutter renders on Intel; NVIDIA is spun up only for apps that opt in via `__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia <app>`.

**Trade-off:** general desktop loses NVIDIA acceleration (irrelevant for mutter); apps that need the dGPU must request it explicitly.

**Verify (after reboot + heavy use):**
```bash
prime-select query                                   # → on-demand
nvidia-smi --query-compute-apps=pid,process_name --format=csv,noheader   # gnome-shell NOT listed
journalctl -b -k -g 'Xid'                            # ideally empty under load
```

**Rollback:** `sudo prime-select nvidia` + reboot.

### Experiment 2 — disable GSP firmware (`NVreg_EnableGpuFirmware=0`) — only if Experiment 1 fails

**Hypothesis:** the Xid originates in the GSP (GPU System Processor) firmware path that the 5xx drivers offload GPU management to; disabling it routes management back through the in-driver legacy path.

```bash
./experiment-2-disable-gsp-firmware.sh   # writes modprobe drop-in + rebuilds initramfs (needs sudo); does NOT reboot
# then reboot
```

**⚠ Ada caveat:** on Ada-generation GPUs (RTX 40-series, this 4050) GSP firmware is effectively mandatory; the driver may **ignore** `NVreg_EnableGpuFirmware=0` and keep GSP on. **You must verify it actually took effect:**
```bash
nvidia-smi -q | grep -i 'GSP Firmware'
# Disabled successfully → "GSP Firmware Version : N/A"
# Still shows a version (e.g. 580.126.09) → the toggle was ignored; revert, this lever does not apply
```

**Rollback:** `sudo rm /etc/modprobe.d/zz-disable-gsp.conf && sudo update-initramfs -u` + reboot.

## Diagnose whether this runbook applies to your machine

```bash
./diagnose-nvidia-xid-freezes.sh
```

Read-only. Scans recent boots for `Xid`, rules thermal in/out, and reports PRIME mode, GSP state, and which GPU the compositor is on.

## Test log

| Date | Experiment | Applied | Result (days under load) |
|---|---|---|---|
| 2026-05-26 | baseline | — | PRIME=`nvidia`, GSP=on, modeset cmdline fix present, gnome-shell on dGPU, 2 Xid 56 over 2 sessions |
| _pending_ | 1 — prime on-demand | _awaiting reboot_ | _observe_ |
| _pending_ | 2 — disable GSP | not started | _only if #1 fails_ |
