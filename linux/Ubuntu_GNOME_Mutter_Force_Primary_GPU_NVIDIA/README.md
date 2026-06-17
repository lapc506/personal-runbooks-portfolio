# Ubuntu — Force Mutter to use the NVIDIA dGPU as the primary (compositing) GPU

_Applies to: Ubuntu 24.04 LTS, GNOME 46 Wayland (mutter 46.2 + Xwayland), hybrid graphics (Intel Iris Xe iGPU + discrete NVIDIA RTX 4050 Mobile), PRIME on-demand, dual monitor (internal eDP on Intel, external HDMI on NVIDIA)._

> **⚠ Reader's summary:** On a dual-GPU laptop where the internal panel hangs off the Intel iGPU and an external monitor hangs off the NVIDIA dGPU, mutter 46 picks **Intel** as the primary (compositing) GPU because of a "builtin panel presence" heuristic. You can override that choice **surgically with a single udev rule** that tags the NVIDIA DRM card as `mutter-device-preferred-primary` — no `prime-select`, no leaving PRIME on-demand. This runbook documents **Option C (udev — try this first)** and a heavier **Option A (reverse-PRIME via `prime-select nvidia`)** fallback. **Honest caveat up front:** making the dGPU primary does NOT reduce the ~32% CPU that gnome-shell spends — that is JS / input / window-management CPU, unrelated to which GPU composites. What it changes is _which_ GPU does the compositing/blits, with its own tradeoffs (see Caveats).

## Context

This is a Gigabyte AORUS 15 9MF with two GPUs:

| GPU | PCI | Driver | DRM card | Render node | Drives |
|-----|-----|--------|----------|-------------|--------|
| Intel Iris Xe | `0000:00:02.0` | `i915` | `card1` | `renderD128` | internal panel `card1-eDP-1` |
| NVIDIA RTX 4050 Mobile | `0000:01:00.0` | `nvidia` | `card2` | `renderD129` | external `card2-HDMI-A-1` |

PRIME is set to **on-demand**. Kernel cmdline already has `nvidia-drm.modeset=1 nvidia-drm.fbdev=1`.

Mutter 46 is genuinely multi-GPU: it composites on one "primary" GPU and, for outputs attached to the other GPU, copies (blits) the composited framebuffer across the PCIe bus to that secondary GPU's scanout engine. Which GPU is "primary" is decided once at session start.

### Why mutter picks Intel

Mutter's native backend (`MetaBackendNative`) selects the primary GPU with a heuristic that prefers the GPU driving the **builtin panel**. On this machine the eDP panel is on Intel, so mutter logs:

```
GPU /dev/dri/card1 selected primary from builtin panel presence
```

Verify on the running session:

```bash
journalctl _PID=$(pgrep -x gnome-shell) | grep 'selected primary'
# → GPU /dev/dri/card1 selected primary from builtin panel presence
```

(Scope by the **live gnome-shell PID** — `_PID=$(pgrep -x gnome-shell)`. This matters: gnome-shell logs "selected primary" to the **system** journal, NOT `--user` (an earlier draft used `journalctl --user` and only ever returned the *original* login's `card1` line, falsely reading as "udev didn't work"). Scoping by PID also shows only the **current** session's choice, not stale lines from prior logins in the same boot. **Do not** run an unbounded `journalctl -b 0 | grep` on this machine — over a multi-day uptime it hangs.)

## Root Cause

Mutter 46 honors an **explicit udev override** that beats the builtin-panel heuristic. A DRM device tagged `mutter-device-preferred-primary` is chosen as primary regardless of which GPU owns the panel.

Both the tag name and the two distinct log strings are present in the shipped `libmutter-14.so.0.0.0` (mutter 46.2):

```bash
strings /usr/lib/x86_64-linux-gnu/libmutter-14.so.0.0.0 \
  | grep -iE 'selected primary|preferred-primary|mutter-device-preferred-primary'
# → mutter-device-preferred-primary
# → preferred-primary
# → GPU %s selected primary from builtin panel presence
# → GPU %s selected primary given udev rule
```

That second log line — `selected primary given udev rule` — is the success signal for Option C.

The same `mutter-device-*` tag family is already used by Canonical's own `/usr/lib/udev/rules.d/61-mutter.rules` (it sets `mutter-device-disable-kms-modifiers` on a long list of Intel devices, and `mutter-device-ignore` on `platform-vkms`). So tagging a DRM device for mutter via udev is the **supported, in-tree mechanism**, not a hack — we are just adding the `preferred-primary` tag for the NVIDIA card.

## Option C — udev primary override (TRY THIS FIRST)

This is the surgical fix: NVIDIA becomes the compositing GPU, you stay in PRIME on-demand, nothing in `prime-select` changes.

### The rule

See [`61-mutter-primary-nvidia.rules`](./61-mutter-primary-nvidia.rules):

```udev
ACTION=="add|change", SUBSYSTEM=="drm", KERNEL=="card[0-9]*", ENV{DEVTYPE}=="drm_minor", DRIVERS=="nvidia", ATTRS{vendor}=="0x10de", TAG+="mutter-device-preferred-primary"
```

Match rationale (each clause earns its place):

- `SUBSYSTEM=="drm"` — DRM subsystem only.
- `KERNEL=="card[0-9]*"` — the **card** node. This excludes the render node `renderD129`, which shares `DEVTYPE=drm_minor` but is named `renderD12x`.
- `ENV{DEVTYPE}=="drm_minor"` — the DRM minor device, not connector children like `card1-eDP-1`.
- `DRIVERS=="nvidia"` — bound to the proprietary nvidia driver. On this box `card1` (Intel) returns **0** matches for this, so Intel is never tagged.
- `ATTRS{vendor}=="0x10de"` — PCI vendor NVIDIA. Belt-and-suspenders against a future second non-NVIDIA card also on the `nvidia` driver chain.

**Why not `KERNEL=="card2"`?** The `cardN` index is assigned at probe time and is not guaranteed stable across boots (driver load order, hotplug). Matching by driver + vendor + node-type is boot-stable; matching by `card2` is not.

The rule was validated read-only on the test machine:

- `card2` (NVIDIA): satisfies `DEVTYPE=drm_minor` + `DRIVERS=="nvidia"` + `ATTRS{vendor}=="0x10de"` → **tagged**.
- `card1` (Intel): `DRIVERS=="nvidia"` → 0 matches → **not tagged**.
- `renderD129`: `KERNEL` is `renderD129`, not `card[0-9]*` → **not tagged**.

### Install + apply

```bash
# 1. Install the rule (file is in the repo; copy it to /etc)
sudo install -m 0644 \
  ./61-mutter-primary-nvidia.rules \
  /etc/udev/rules.d/61-mutter-primary-nvidia.rules

# 2. Reload udev rules and re-trigger the DRM subsystem so the tag is
#    applied to the already-present card2 without a reboot.
sudo udevadm control --reload
sudo udevadm trigger --subsystem-match=drm --action=change

# 3. Confirm the NVIDIA card now carries the tag (read-only check)
udevadm info /sys/class/drm/card2 | grep -i 'mutter-device-preferred-primary'
# expected: TAGS / CURRENT_TAGS line now contains :mutter-device-preferred-primary:
```

> Mutter only reads the primary-GPU choice **at session start**. The tag being present is necessary but not sufficient — you must start a fresh session for mutter to act on it.

```bash
# 4. Log out and log back in (full GNOME session restart).
#    A reboot also works and is the cleanest test.
```

### Verify Option C

After logging back in:

```bash
journalctl _PID=$(pgrep -x gnome-shell) | grep 'selected primary'
# SUCCESS → GPU /dev/dri/card2 selected primary given udev rule
# (was:   → GPU /dev/dri/card1 selected primary from builtin panel presence)
```

If you see `selected primary given udev rule` pointing at `card2`, Option C worked — mutter is now compositing on the NVIDIA dGPU while staying in PRIME on-demand.

### Rollback Option C

```bash
sudo rm /etc/udev/rules.d/61-mutter-primary-nvidia.rules
sudo udevadm control --reload
sudo udevadm trigger --subsystem-match=drm --action=change
# then log out / log back in (or reboot)
```

After relog, the log line reverts to `GPU /dev/dri/card1 selected primary from builtin panel presence`.

## Option A — reverse-PRIME via `prime-select nvidia` (FALLBACK)

Use this only if Option C does not produce `selected primary given udev rule` (e.g. a future mutter that drops the tag, or a regression). This is the bigger hammer: it takes the machine out of PRIME on-demand and makes NVIDIA render everything, with Intel reduced to scanning out the eDP panel (reverse-PRIME).

```bash
# Make NVIDIA the rendering GPU for the whole session.
sudo prime-select nvidia

# prime-select rewrites Xorg/GLX config and requires a full logout
# (some setups require a reboot) for the new mode to take effect.
```

After logout/login (or reboot), the dGPU renders the desktop and the iGPU only drives the internal panel's scanout.

### Rollback Option A

```bash
sudo prime-select on-demand
# logout/login (or reboot) to return to the original hybrid on-demand mode
```

Confirm you are back:

```bash
prime-select query
# → on-demand
```

## Caveats (honest)

These apply to **both** options — once the dGPU is primary, the compositor topology changes:

- **A per-frame blit/copy is added for the internal panel.** With NVIDIA primary, the composited frame for the eDP panel (which physically hangs off Intel) must be copied across PCIe to the Intel scanout engine every frame. That adds latency and can introduce mild tearing on the internal panel. The external HDMI monitor — physically on NVIDIA — becomes the "free" path with no cross-GPU copy.
- **Higher dGPU power draw / thermals.** The 4050 now stays active to composite the desktop continuously instead of idling under on-demand. Expect higher idle power, more fan, shorter battery on this laptop. This is the main reason reverse-PRIME is not the laptop default out of the box.
- **It does NOT reduce gnome-shell CPU.** The observed ~32% gnome-shell CPU is JavaScript execution, input handling, and window management running on the CPU — it is independent of which GPU composites. Neither Option C nor Option A will move that number. If CPU is the real complaint, this runbook is the wrong lever; look at extensions, animations, and input-event rate instead.
- **Option C is reversible in seconds; Option A reconfigures the X stack.** Option C is just a tag + relog. Option A rewrites display-server config via `prime-select` and is a heavier, slower round-trip. Prefer C.

## Test + rollback procedure (summary)

1. Baseline: `journalctl _PID=$(pgrep -x gnome-shell) | grep 'selected primary'` → confirm `card1 ... builtin panel presence`.
2. Install the udev rule, `udevadm control --reload`, `udevadm trigger --subsystem-match=drm --action=change`.
3. Confirm the tag: `udevadm info /sys/class/drm/card2 | grep mutter-device-preferred-primary`.
4. Log out / log in.
5. Verify: `journalctl _PID=$(pgrep -x gnome-shell) | grep 'selected primary'` → expect `card2 ... given udev rule`.
6. If it did not switch, fall back to Option A (`sudo prime-select nvidia` + logout).
7. Rollback C: delete the rule + reload + trigger + relog. Rollback A: `sudo prime-select on-demand` + relog.

## Known Constraints

- **Tag name is mutter-version-specific.** `mutter-device-preferred-primary` and the `selected primary given udev rule` log string are verified for mutter 46.2 (Ubuntu 24.04). A major mutter bump could rename the tag or the heuristic. Re-verify with the `strings libmutter-14.so` grep above after any GNOME upgrade before trusting the rule.
- **`cardN` numbering is not stable; the rule deliberately does not depend on it.** But the *verification* commands above hard-code `/sys/class/drm/card2`. If after a kernel/driver change the NVIDIA card is no longer `card2`, resolve it first: `for c in /sys/class/drm/card[0-9]*; do echo "$c -> $(basename $(readlink -f $c/device))"; done` and match the one at PCI `0000:01:00.0` (or use the stable symlink `/dev/dri/by-path/pci-0000:01:00.0-card`).
- **Mutter reads the choice only at session start.** Reloading udev rules mid-session tags the device but does not move the compositor. A relog (or reboot) is mandatory.
- **`nvidia-drm.modeset=1` required.** Already set in cmdline here. Without KMS modeset on NVIDIA, mutter cannot use the dGPU as a Wayland primary at all.

## Related runbooks

- [`Ubuntu_GDM_Force_Wayland_on_NVIDIA`](../Ubuntu_GDM_Force_Wayland_on_NVIDIA) — getting the session onto Wayland in the first place (prerequisite for the mutter native multi-GPU path this runbook relies on).
- [`Ubuntu_GNOME_Mutter_Internal_Panel_Drop_False_Freeze`](../Ubuntu_GNOME_Mutter_Internal_Panel_Drop_False_Freeze) — related mutter / eDP-on-Intel behavior on the same machine after a power transient.
- [`Ubuntu_NVIDIA_Wayland_Flip_Event_Timeout`](../Ubuntu_NVIDIA_Wayland_Flip_Event_Timeout) — NVIDIA Wayland scanout flip-event failure mode, relevant once the dGPU is in the scanout/compositing path.

## References

- [mutter — MetaBackendNative / primary GPU selection (GNOME GitLab)](https://gitlab.gnome.org/GNOME/mutter) — `src/backends/native/meta-backend-native.c`, `meta-udev.c` (`mutter-device-*` tags, `is_gpu_platform_device`).
- [Ubuntu `61-mutter.rules`](https://gitlab.gnome.org/GNOME/mutter/-/blob/main/src/backends/native/) — in-tree precedent for `mutter-device-*` tagging via udev.
- [freedesktop.org — udev(7) rule syntax and ordering](https://www.freedesktop.org/software/systemd/man/latest/udev.html)
- [Arch Wiki — PRIME / reverse-PRIME](https://wiki.archlinux.org/title/PRIME) — background on the per-frame cross-GPU blit tradeoff.

## Debugging lessons

1. **Prefer the in-tree override to the global switch.** Mutter exposes a udev tag specifically to override its primary-GPU heuristic. Tagging one DRM node is far more surgical than `prime-select nvidia`, which reconfigures the whole display stack and leaves on-demand. When an app ships its own override mechanism, reach for that before the OS-wide hammer.
2. **Verify the magic string against the installed binary, not the blog post.** The tag name `mutter-device-preferred-primary` and the `selected primary given udev rule` log were confirmed with `strings` on the actual `libmutter-14.so` on this box. Tag names drift between GNOME versions; a rule copied from a different release can silently no-op.
3. **Match DRM devices by driver + vendor + node type, never by `cardN`.** The card index is probe-order-dependent and not boot-stable. `DRIVERS=="nvidia"` + `ATTRS{vendor}=="0x10de"` + `KERNEL=="card[0-9]*"` + `DEVTYPE=="drm_minor"` is stable and also cleanly excludes the render node and connector children.
4. **Separate "what the change does" from "what the user actually wants."** The user's pain was CPU. This change moves the *compositing GPU*, not CPU load. Saying so up front — instead of letting the dGPU switch masquerade as a CPU fix — is the honest call, even though it means the headline change won't move the number they were watching.
5. **A tag applied mid-session is inert until relog.** `udevadm trigger` updates the device's tags immediately, but mutter only consults them at session start. Confirming the tag is present (`udevadm info`) and confirming mutter *acted* on it (`journalctl ... selected primary`) are two different checks; do both.
