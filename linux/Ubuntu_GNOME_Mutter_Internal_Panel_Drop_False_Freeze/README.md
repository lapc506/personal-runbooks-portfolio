# Ubuntu — GNOME/mutter drops the internal panel after a mains power transient (false "system freeze", hybrid graphics)

_Applies to: Ubuntu 24.04 LTS, GNOME Shell (mutter) on Wayland, hybrid graphics (internal eDP panel on Intel iGPU + HDMI hard-wired to discrete NVIDIA RTX 4050, driver 580.x), kernel 6.17.x, Gigabyte AORUS 15 9MF, laptop charger behind a UPS._

> **⚠ Reader's summary:** during a mains outage the laptop never lost AC (charger on a UPS — zero `ADP1 (off-line)` events), but the UPS transfer transient **reset the laptop's Embedded Controller** (its internal GIGABYTE USB-HID devices disconnected and re-enumerated). The resulting hotplug storm made mutter **reconfigure the monitor layout 3× in 13 seconds** and it landed in an invalid state with the internal eDP panel **outside the active monitor configuration** → internal panel black, session fully alive on the NVIDIA HDMI output. A later `Ctrl+Alt+F3` *looked* like a total system freeze but **was not one**: the VT switch succeeded (`getty@tty3` started, journal kept logging), but the kernel console lives on `fb0 = i915drmfb` = **the black panel**, so the tty was invisible while the NVIDIA HDMI head kept showing the last frozen GNOME frame. The hard power-off that followed was unnecessary. **Zero** `i915`/`drm`/`Xid` kernel errors: the panel hardware was healthy the whole time — the compositor turned it off.

## Context

Hardware: Gigabyte AORUS 15 9MF, internal panel `eDP-1` on the Intel iGPU (`card1`, PCI `00:02.0`), external monitor on `HDMI-A-1` hard-wired to the RTX 4050 (`card2`, PCI `01:00.0`). GNOME Shell (mutter) on Wayland. The external monitor is powered by a UPS; the laptop charger is plugged into the same UPS.

Symptom as experienced: "se fue la luz y se apagó la pantalla principal (el panel de la laptop), pero seguía teniendo video vivo por el HDMI". Later, switching to a virtual terminal with `Ctrl+Alt+F3` appeared to freeze everything (mouse dead, HDMI image static), forcing a hard power-off.

This runbook is the **third crash family** documented for this machine, and the only one where the system is *not actually down*:

| Family | Signature | System state |
|---|---|---|
| [`Ubuntu_NVIDIA_Xid56_Display_Freeze_Under_Load`](../Ubuntu_NVIDIA_Xid56_Display_Freeze_Under_Load) | `NVRM: Xid … 56, CMDre` | real freeze (dGPU wedged) |
| host starvation (kubelet snap churn) | kernel silent, IO/CPU starved | real freeze |
| **this runbook** | `no configuration which is-current` | **alive — console invisible** |

## Incident timeline (forensics from `journalctl -b -1`, 2026-06-10)

| Time | Event | Evidence |
|---|---|---|
| ~20:50 | Mains outage; UPS takes over | user report |
| 21:06:47 | **Embedded Controller resets**: internal GIGABYTE USB-HID devices (`0414:7a43`, `0414:7a44`) disconnect and re-enumerate | `usb 3-6: USB disconnect` → full re-enumeration |
| **21:06:48** | **Internal panel dropped from the active config → black** — one second after the EC reset; recurs 21:07:54 and 21:08:07 | `xdg-desktop-por[…]: Monitor 'Pantalla integrada' has no configuration which is-current!` (×3) + `gnome-shell: meta_display_get_monitor_in_fullscreen: assertion 'monitor >= 0 && monitor < n_logical_monitors' failed` |
| 21:07:55–21:08:08 | mutter keeps reconfiguring the monitor layout (≥3 bursts in 13 s) | bursts of `Overwriting existing binding of keysym …` (mutter re-grabs keybindings on every monitor reconfig) |
| 21:13–22:22 | gsd-power fails **32×** computing brightness — backlight state inconsistent for over an hour | `gsd-power: gsd_power_backlight_percentage_to_abs: assertion 'value <= 100' failed` |
| 22:29:13 | `Ctrl+Alt+F3` — **VT switch succeeds at kernel level** | `Started getty@tty3.service`, `rfkill: input handler enabled`; journal keeps writing for 30+ s |
| 22:29:42 | last journal entry → hard power-off (unnecessary) | journal ends with no shutdown sequence |

## Problem statement — the signatures

The one-line smoking gun (search the crashed boot):

```bash
journalctl -b -1 -g 'no configuration which is-current' --no-pager
# xdg-desktop-por[…]: Monitor 'Pantalla integrada' has no configuration which is-current!
```

Corroborating signals, in order of diagnostic value:

1. **EC reset at the moment of the electrical event** — the laptop's own internal USB-HID hub re-enumerates:
   ```bash
   journalctl -b -1 -k -g 'USB disconnect|GIGABYTE USB-HID' --no-pager
   ```
2. **Monitor reconfiguration storm** — mutter re-registers keybindings on every layout change; several bursts within seconds means displays were flapping:
   ```bash
   journalctl -b -1 --no-pager | grep -c 'Overwriting existing binding'
   ```
3. **Backlight accounting broken afterwards** — gsd-power computes a percentage > 100 against the now-inconsistent display state:
   ```bash
   journalctl -b -1 -g 'gsd_power_backlight_percentage_to_abs' --no-pager
   ```
4. **What is ABSENT is equally load-bearing:**
   - no `ADP1 (off-line)` → AC never dropped (charger on UPS);
   - no `i915`/`drm` errors, no `Xid` → both GPUs and the eDP link healthy;
   - journal keeps flowing after the "freeze" → kernel alive, this is **not** the Xid 56 or starvation family.

## Root cause

Three distinct questions, three answers:

### 1. Why did the internal panel go black if the laptop never lost power?

The UPS transfer window (a few ms of switchover, plus whatever transient rides through the charger) was enough to **reboot the Embedded Controller** — proven by its USB-HID interfaces disconnecting at 21:06:47. The EC reset (and likely a simultaneous blink of the external monitor's electronics) produced a burst of display hotplug events. Mutter re-evaluated the monitor configuration on each one, raced, and finished in a state where the integrated panel **has no `is-current` configuration** — i.e. mutter administratively disabled the panel. `~/.config/monitors.xml` was checked: **no stored configuration disables the panel**, so this was not a legitimate saved layout being applied — it is a mutter hotplug-race bug. The panel hardware never faulted.

### 2. Why did the HDMI output keep working?

Hybrid topology: the eDP panel hangs off the Intel iGPU; the HDMI port is hard-wired to the discrete NVIDIA GPU. Mutter kept compositing the session on the logical monitor it still had (HDMI/NVIDIA). Only the panel's logical monitor vanished — the session, input, and apps stayed fully live (mouse moving, windows responding).

### 3. Why did `Ctrl+Alt+F3` "freeze everything"?

It didn't. The VT switch **worked**: `getty@tty3` started and the journal kept logging. But:

- the kernel console (fbcon) renders on the **primary framebuffer** `fb0 = i915drmfb`, which scans out on the eDP panel — the display that was black (and whose backlight state gsd-power had left inconsistent);
- the NVIDIA HDMI head, abandoned by the compositor on VT switch, kept showing the **last rendered GNOME frame**, static.

Net effect: an invisible console on one screen plus a frozen image on the other = a perfect imitation of a hard freeze on a machine that was alive. Pressing `Ctrl+Alt+F2`/`F1` (back to the GNOME VT) would most likely have restored the session.

```
boot-time hint the kernel already gave (relevant if backlight ever misbehaves):
i915 …: [CONNECTOR:262:eDP-1] Panel is missing HDR static metadata.
        … If your backlight controls don't work try booting with i915.enable_dpcd_backlight=3.
```

## Recovery — without rebooting

In order of preference, **from the still-alive HDMI session**:

1. **Settings → Displays** → re-enable "Pantalla integrada" (the panel re-joins the layout immediately).
2. **Close and reopen the lid** — the lid event forces mutter to rebuild the monitor configuration.
3. If you already switched to a VT and "everything froze": **`Ctrl+Alt+F2` or `Ctrl+Alt+F1`** to return to the GNOME VT. The session is still there.
4. Last resort before a hard power-off — blind-type into the invisible tty (it *is* accepting input):
   ```bash
   chvt 2        # or: sudo systemctl restart gdm   (kills the session, but cleanly)
   ```

A hard power-off is **never** the right move for this family — check liveness first: does the Caps Lock LED toggle? Does `ping` from another machine answer? Both said "alive" here.

## Diagnose whether this runbook applies

```bash
./diagnose-panel-drop-false-freeze.sh        # current boot
./diagnose-panel-drop-false-freeze.sh -1     # the boot that "froze"
```

Read-only. Checks the four signatures above, rules the other two crash families in/out (`Xid`, kernel-silence gap), and maps which GPU drives which connector on this machine.

## Test log

| Date | Event | Outcome |
|---|---|---|
| 2026-06-10 | baseline incident (mains outage ~20:50 CST) | panel dropped 21:08:07; session alive 81 min on HDMI; VT switch 22:29:13 → invisible console; hard power-off 22:29:42+ (unnecessary) |
| 2026-07-21 | **scheduling-collapse variant** (no power event) — 3-monitor session (eDP-1 + DP-1 USB-C on i915 + HDMI-A-1 on NVIDIA, NVIDIA forced primary via `61-mutter-primary-nvidia.rules`) under heavy load | **new trigger, same family.** No `ADP1`, no `Xid`, no `i915`/`nv_drm_atomic_commit` errors, no reboot (uptime intact). `rtkit-daemon` SIGKILLed ×4 in-boot, each paired with `gnome-shell: Failed to make thread 'KMS thread' realtime scheduled`; `kernel: workqueue: swap_discard_work hogged CPU` ×2 (zram churn from `swappiness=150`); prior panel-drops 05:33 (`logical_monitor != NULL`) & 14:39 (`no configuration which is-current` ×819). Session logged out 18:00→autologin respawn 18:01, killing every terminal (orphaned all Claude Code sessions). Root cause = **rtkit canary starved by zram-churn CPU + simultaneous reverse-PRIME flips** during workspace-switch animation on 3 heads (`workspaces-only-on-primary=false` → all 3 animate). Mitigation (keeps NVIDIA-primary): `gsettings set org.gnome.mutter workspaces-only-on-primary true` to cut the flip storm from the 3-finger swipe. |
| _pending_ | next mains outage / UPS transfer | _try Recovery §1–3 before any power button_ |

## Decision tree

```
Internal panel black, but external monitor still shows a LIVE session
│
├─ Is the session really alive? (mouse moves, clock ticks, apps respond)
│   ├─ YES → this runbook. journalctl -b -g 'no configuration which is-current'
│   │   ├─ match → Recovery §1 (Settings→Displays) or §2 (lid close/open). DONE, no reboot.
│   │   └─ no match → check backlight: brightness keys respond? i915.enable_dpcd_backlight=3 hint
│   └─ NO (image static, input dead) → NOT this runbook:
│       ├─ journalctl -b -1 -k -g Xid  → hits → Xid 56 family (sibling runbook)
│       └─ kernel log gap / IO starvation → host-starvation family
│
└─ Already pressed Ctrl+Alt+F3 and "everything froze"?
    ├─ Caps Lock LED toggles / machine pings → console is INVISIBLE, not frozen:
    │   Ctrl+Alt+F2 (GNOME VT) — or blind `chvt 2` — recovers the session.
    └─ No LED, no ping → real freeze → other families; hard power-off as last resort.
```

## References

- Kernel framebuffer console binding (`fbcon`, which fb a VT renders on): [kernel.org fbcon documentation](https://www.kernel.org/doc/Documentation/fb/fbcon.rst)
- `i915.enable_dpcd_backlight` module parameter: `modinfo -p i915 | grep dpcd`
- mutter monitor-configuration issue tracker (hotplug races): [gitlab.gnome.org/GNOME/mutter/-/issues](https://gitlab.gnome.org/GNOME/mutter/-/issues)
- Sibling runbooks on this machine: [`Ubuntu_NVIDIA_Xid56_Display_Freeze_Under_Load`](../Ubuntu_NVIDIA_Xid56_Display_Freeze_Under_Load) (real freeze, dGPU), [`Ubuntu_NVIDIA_Wayland_Flip_Event_Timeout`](../Ubuntu_NVIDIA_Wayland_Flip_Event_Timeout)
- Session recovery after hard power-offs: [`claude-code-multi-backend`](../claude-code-multi-backend) (orphan-transcript scanning + heartbeat backups)
