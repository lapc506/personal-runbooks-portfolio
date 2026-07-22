# Ubuntu — rtkit canary starvation collapses the GNOME session (autologin respawn kills every terminal) on hybrid graphics under reverse-PRIME + zram-churn load

_Applies to: Ubuntu 24.04 LTS, GNOME Shell (mutter) on Wayland with GDM **autologin**, hybrid graphics (Intel iGPU + discrete NVIDIA RTX 4050, driver 580.x) with the **NVIDIA dGPU forced as mutter's primary/compositing GPU**, zram swap active with `vm.swappiness=150`, kernel 6.17.x, Gigabyte AORUS 15 9MF._

> **⚠ Reader's summary:** under heavy CPU/memory load the machine "crashed the whole Ubuntu session" — but there was **no reboot** (`uptime` intact) and **zero GPU errors** (no `Xid`, no `nv_drm_atomic_commit`, no `i915` faults). What actually happened: `rtkit-daemon` was **SIGKILLed** (`code=killed, status=9/KILL`), immediately followed by `gnome-shell: Failed to make thread 'KMS thread' realtime scheduled`, then a clean `gdm-autologin` **logout + session respawn** (`gnome-shell` PID changed). The respawn **kills every terminal emulator**, which kills every long-running CLI in them (here: all open Claude Code sessions — orphaned but recoverable from disk). Root cause: `rtkit`'s watchdog **canary thread was starved of CPU** by two coincident load sources — (1) **`swap_discard_work`/`swap_reclaim_work` churn** from the aggressive `swappiness=150` zram tuning, and (2) **simultaneous reverse-PRIME page-flips** (mutter's KMS thread copying NVIDIA-rendered frames to the Intel iGPU for the two i915-owned heads) during a workspace-switch animation across 3 monitors. rtkit reacted to the starved canary by cancelling RT priorities, the compositor's KMS thread lost realtime scheduling, and mutter's session tore down. **The fix keeps the NVIDIA-primary topology** (that rule is intentional and must not be reverted): reduce simultaneous flip load (static workspace switch) and reduce zram-churn CPU (`swappiness 150 → 120`).

## Context

Hardware: Gigabyte AORUS 15 9MF.

| Output | DRM node | GPU | Driver | Scanout path |
|---|---|---|---|---|
| internal panel `eDP-1` | `card1` (PCI `00:02.0`) | Intel Iris Xe | `i915` | **reverse-PRIME sink** (NVIDIA renders → copied to i915) |
| USB-C portable `DP-1` | `card1` (PCI `00:02.0`) | Intel Iris Xe | `i915` | **reverse-PRIME sink** |
| external `HDMI-A-1` | `card2` (PCI `01:00.0`) | NVIDIA RTX 4050 | `nvidia` | **direct scanout** (primary GPU) |

The NVIDIA dGPU is forced as mutter's primary/compositing GPU by [`../Ubuntu_GNOME_Mutter_Force_Primary_GPU_NVIDIA`](../Ubuntu_GNOME_Mutter_Force_Primary_GPU_NVIDIA) (udev tag `mutter-device-preferred-primary`). **This is deliberate and load-bearing — do not revert it as a "fix" for this crash.** A direct consequence of the topology: 2 of the 3 heads (both i915-owned) are reached over reverse-PRIME, so any operation that flips all heads at once (workspace-switch animation, overview) makes mutter's KMS thread issue two GPU→GPU buffer copies plus one direct flip **per frame**.

Symptom as experienced: "se me crasheó la sesión entera de Ubuntu, tuve que perder todas mis terminales / sesiones de Claude Code."

## This is the 4th crash family documented for this machine

| Family | Signature | System state |
|---|---|---|
| [`Ubuntu_NVIDIA_Xid56_Display_Freeze_Under_Load`](../Ubuntu_NVIDIA_Xid56_Display_Freeze_Under_Load) | `NVRM: Xid … 56, CMDre` | real freeze (dGPU wedged) |
| [`Ubuntu_NVIDIA_Wayland_Flip_Event_Timeout`](../Ubuntu_NVIDIA_Wayland_Flip_Event_Timeout) | `nv_drm_atomic_commit … Flip event timeout on head` | crash + hard reboot |
| [`Ubuntu_GNOME_Mutter_Internal_Panel_Drop_False_Freeze`](../Ubuntu_GNOME_Mutter_Internal_Panel_Drop_False_Freeze) | `no configuration which is-current` | **alive** — panel off, session up |
| **this runbook** | `rtkit-daemon … status=9/KILL` + `Failed to make thread 'KMS thread'` → autologin respawn | **session died & respawned** — no reboot, GPU healthy |

The distinguishing thesis: unlike the panel-drop family (session stays alive), here **the graphical session actually goes down and comes back** — but below the reboot line, so the kernel, disk, and all `.jsonl`/file state survive.

## Incident timeline (forensics from `journalctl -b 0`, 2026-07-21)

| Time | Event | Evidence |
|---|---|---|
| 00:11:44–00:17:36 | **zram reclaim storm** (independent of any user gesture) — escalating 4→131 hogs in ~6 min | `kernel: workqueue: swap_reclaim_work hogged CPU for >10000us … 131 times` |
| 15:15:59 | last workspace-switch animation before the crash (a 3-finger swipe) — churn across 3 `MonitorGroup`s | `Gjs … workspaceAnimation_MonitorGroup … has been already disposed` |
| **18:00:34–35** | mutter's **KMS thread RT priority flaps ~10×/s**, then `rtkit-daemon` is **SIGKILLed** | `rtkit-daemon.service: Main process exited, code=killed, status=9/KILL` |
| 18:00:35 | KMS thread can no longer get realtime scheduling | `gnome-shell[5637]: Failed to make thread 'KMS thread' realtime scheduled: Message recipient disconnected from message bus` |
| 18:00:56, 18:01:00 | **zram discard churn** at the moment of collapse | `kernel: workqueue: swap_discard_work hogged CPU for >10000us` |
| 18:01:01 | **session logout** (clean, autologin) | `gdm-autologin: session closed for user …`; `systemd-logind: Removed session 1` |
| 18:01:41 | **session respawn** — new `gnome-shell` PID; every prior terminal already dead | `gnome-shell[450274]: GNOME Shell started` |

`uptime -s` still points at the previous day's boot → **no reboot occurred**; `journalctl --list-boots` shows the same boot 0 spanning the incident.

## Problem statement — the signatures

The one-line smoking gun (search the current boot):

```bash
journalctl -b 0 --no-pager | grep -E 'rtkit-daemon.service: Main process exited, code=killed' 
# systemd[1]: rtkit-daemon.service: Main process exited, code=killed, status=9/KILL
```

Corroborating signals, in order of diagnostic value:

1. **KMS thread loses realtime scheduling the instant rtkit dies:**
   ```bash
   journalctl -b 0 --no-pager | grep -E "Failed to make thread 'KMS thread'"
   ```
2. **zram churn hogging CPU** — the memory-pressure lever, independent of the swipe:
   ```bash
   journalctl -b 0 -k --no-pager | grep -E 'swap_(discard|reclaim)_work hogged CPU'
   ```
3. **Autologin session respawn** — the GNOME session PID changes with no reboot:
   ```bash
   journalctl -b 0 --no-pager | grep -E 'gdm-autologin.*session closed|GNOME Shell started'
   ```
4. **What is ABSENT is load-bearing — this rules out the other three families:**
   ```bash
   journalctl -b 0 -k --no-pager | grep -cE 'Xid|nv_drm_atomic_commit|Flip event timeout'   # -> 0
   journalctl -b 0    --no-pager | grep -c  'no configuration which is-current'              # panel-drop, may be >0 earlier but is not the 18:00 trigger
   uptime -s   # unchanged across the incident -> not a reboot
   ```

## Root cause

### Why did the session die if the GPU was healthy?

`rtkit-daemon` (RealtimeKit) grants realtime/high scheduling priority to threads that ask for it. On Wayland, **mutter's `KMS thread` requests RT** so page-flips are submitted on time. rtkit protects the system from a runaway RT thread with a **watchdog canary**: a low-priority thread it expects to run periodically. If the canary is starved (the machine is so CPU-contended that even a normal-priority thread can't get scheduled), rtkit concludes that RT threads are hogging the CPU and **cancels all the RT priorities it granted** (and its service can exit / be killed). The moment mutter's KMS thread loses RT, its frame scheduler misses the vblank cadence, and the session's compositor path becomes unrecoverable → `gnome-session` logs out and GDM autologin respawns it.

### What starved the canary?

Two coincident CPU sinks, neither of which is a GPU fault:

1. **zram churn.** `vm.swappiness=150` (correct-in-isolation for zram; see [`../Ubuntu_zram_oomd_Memory_Pressure_Tuning`](../Ubuntu_zram_oomd_Memory_Pressure_Tuning)) makes the kernel push cold pages into compressed RAM aggressively. Under a large workload (many big editor/CLI sessions + Chrome) the zstd compress/decompress and page reclaim/discard run as `swap_reclaim_work`/`swap_discard_work` kernel workqueue items that **hog CPU in bursts** (observed escalating to 131 hogs at 00:11–00:17, and again at the 18:00 collapse).
2. **Simultaneous reverse-PRIME flips.** With NVIDIA primary, the two i915-owned heads (`eDP-1`, `DP-1`) are reverse-PRIME sinks. A workspace-switch animation instantiates one `MonitorGroup` **per monitor** and drives a sustained high-framerate flip stream on **all 3 at once**; 2 of those require a NVIDIA→i915 buffer copy per frame. This is the single most flip-intensive routine mutter runs, and it lands squarely on the KMS thread.

When both peak together, the canary can't get a scheduling slot → rtkit demotes/dies → KMS thread loses RT → session collapse. The 18:00 event correlated with **(1)** (zram discard at 18:00:56/18:01:00); the 3-finger swipe is the **(2)** accelerant seen at other times (15:15, 19:21, 19:34, 01:53).

### Why did the terminals (and Claude Code sessions) die?

The GNOME session respawn tears down `user@…`'s graphical session; every child of it — `gnome-terminal`/`alacritty` windows and the `claude` processes inside them — is killed. But Claude Code writes each turn incrementally to `~/.claude/projects/<project>/<uuid>.jsonl`, so the transcripts survive on disk and are fully resumable. Sessions killed before their asynchronous **title/summary** record was written show up **"(sin nombre)"** in the resume picker until re-opened.

## Recovery — get your work back (no reboot needed)

The machine never went down, so nothing is lost:

1. **Find the orphaned sessions** (IDs + last activity) — see [`../claude-code-multi-backend`](../claude-code-multi-backend) (orphan-transcript scanning + heartbeat backups). The `[respaldo]` tag marks sessions the heartbeat caught mid-flight = the ones open at the crash.
2. **Resume the ones you want** from the matching directory:
   ```bash
   cd <the session's cwd>
   claude --resume <session-uuid>
   ```
3. Sessions showing **"(sin nombre)"** get a title once you resume and send one more message.

## Mitigations — reduce the load that starves the canary (keeps NVIDIA-primary)

None of these touch the NVIDIA-primary udev rule; they attack the two CPU sinks and the flip storm.

### 1. Make the workspace switch static (kills the swipe flip storm)

Stock GNOME has no toggle for "only the workspace switch is static", so the robust CLI option disables the eased animations globally (instant/static switch, no slide):

```bash
gsettings set org.gnome.desktop.interface enable-animations false
#   revert: gsettings reset org.gnome.desktop.interface enable-animations
```

Narrower alternatives:
- **Animate only the primary head** (keeps other animations): `gsettings set org.gnome.mutter workspaces-only-on-primary true` — on a 3-finger swipe only the HDMI/NVIDIA head animates; the two reverse-PRIME heads hold their windows static.
- **Extension** for granular "static workspace switch only" if you want to keep overview/window animations.

### 2. Reduce zram-churn CPU (`swappiness 150 → 120`)

Justified **only** because there is evidence of memory-pressure churn independent of the swipe (the 00:11–00:17 reclaim storm). Keeps zram as the primary swap tier; slightly less aggressive reclaim so the workqueue hogs less CPU.

```bash
# edit the drop-in installed by the zram runbook
sudo sed -i 's/vm.swappiness *= *150/vm.swappiness = 120/' /etc/sysctl.d/99-zram-swappiness.conf
sudo sysctl --system
cat /proc/sys/vm/swappiness   # -> 120
#   revert: restore 150 in that file + sudo sysctl --system
```

> If you ever remove zram, revert this **and** the oomd relaxations together (see the zram runbook's coupling note).

### 3. Behavioral: unplug the USB-C portable during heavy work

DisplayPort-over-USB-C (`DP-1`) is both a **second reverse-PRIME head** (extra per-frame copy) and the **most hotplug-prone connector** (cable/power jitter → monitor reconfiguration races, the panel-drop trigger). Running on `eDP-1` + `HDMI-A-1` only during heavy build/CLI sessions removes one copy stream and one class of hotplug races.

## Diagnose whether this runbook applies

```bash
./diagnose-rtkit-scheduling-collapse.sh        # current boot
./diagnose-rtkit-scheduling-collapse.sh -1     # the boot that "crashed" (if it was a reboot; usually same boot)
```

Read-only. Confirms the rtkit-SIGKILL + KMS-thread-RT signature, quantifies the zram-churn hogs, verifies **no reboot** and **no GPU errors** (ruling the other three families out), and prints the reverse-PRIME head map.

## Test log

| Date | Event | Outcome |
|---|---|---|
| 2026-07-21 | baseline incident — 3-monitor session (`eDP-1` + `DP-1` USB-C on i915 + `HDMI-A-1` on NVIDIA), heavy load | `rtkit-daemon` SIGKILL 18:00:35 + `KMS thread` RT failure; `swap_discard_work` hogs 18:00:56/18:01:00; autologin respawn 18:01:41; **no reboot, 0 `Xid`/`nv_drm_atomic_commit`/`i915` errors**; all terminals + Claude Code sessions orphaned (recovered from disk) |
| _pending_ | after `enable-animations false` + `swappiness=120` | _watch `journalctl -b 0 -k \| grep swap_.*_work` and rtkit deaths over a heavy 3-monitor session; expect no rtkit SIGKILL_ |

## Decision tree

```
"Ubuntu crashed" — terminals/apps gone, but you're back at your desktop
│
├─ Did it reboot?  uptime -s changed? journalctl --list-boots shows a new boot?
│   ├─ YES → this is NOT this runbook. Check Xid56 / Flip-Event-Timeout families.
│   └─ NO (same boot, uptime intact) → session respawn. Continue.
│
├─ journalctl -b 0 | grep 'rtkit-daemon.*status=9/KILL'  AND  "Failed to make thread 'KMS thread'"
│   ├─ match → THIS runbook.
│   │   ├─ journalctl -b 0 -k | grep 'swap_.*_work hogged'  → present → apply Mitigation §2 (swappiness 120)
│   │   ├─ crash near a 3-finger swipe / on 3 monitors      → apply Mitigation §1 (static switch)
│   │   └─ recover work: claude --resume (§Recovery). No reboot was ever needed.
│   └─ no match:
│       ├─ 'no configuration which is-current' + panel black, session ALIVE → Internal_Panel_Drop family
│       ├─ 'Xid' → Xid56 family (real dGPU freeze)
│       └─ 'nv_drm_atomic_commit … Flip event timeout' → Flip_Event_Timeout family
```

## References

- `rtkit` canary / RT-priority cancellation design: <https://github.com/heftig/rtkit> (`rtkit-daemon`, the `--our-realtime-priority` / canary watchdog logic)
- askubuntu — "why is rtkit-daemon eating 100% of my CPU": <https://askubuntu.com/questions/48888/why-is-rtkit-daemon-eating-100-of-my-cpu>
- PSI / memory pressure that drives zram reclaim: <https://docs.kernel.org/accounting/psi.html>
- mutter reverse-PRIME (secondary-GPU scanout) presentation path: <https://gitlab.gnome.org/GNOME/mutter> (`MetaKmsImplDevice`, secondary GPU copy path)
- Sibling runbooks on this machine: [`Ubuntu_GNOME_Mutter_Force_Primary_GPU_NVIDIA`](../Ubuntu_GNOME_Mutter_Force_Primary_GPU_NVIDIA) (the intentional NVIDIA-primary rule — **do not revert**), [`Ubuntu_zram_oomd_Memory_Pressure_Tuning`](../Ubuntu_zram_oomd_Memory_Pressure_Tuning) (the `swappiness=150` source), [`Ubuntu_GNOME_Mutter_Internal_Panel_Drop_False_Freeze`](../Ubuntu_GNOME_Mutter_Internal_Panel_Drop_False_Freeze) (sibling compositor failure), [`claude-code-multi-backend`](../claude-code-multi-backend) (orphan-session recovery)

## Debugging lessons

1. **"The whole OS crashed" is a claim to verify, not accept.** `uptime -s` and `journalctl --list-boots` decide in one line whether you're debugging a kernel/hardware event or a userspace session respawn. Here it was the latter — which meant every "lost" session was actually intact on disk.
2. **A SIGKILL of an unrelated daemon can be the load-bearing clue.** `rtkit-daemon` has nothing to do with the user's workload, but its death is the hinge: it's the scheduling authority for the compositor's KMS thread. Filtering for the dramatic (GPU errors) would have missed it; the crash left **zero** GPU errors.
3. **Correlate triggers on the timeline before naming a single cause.** The 3-finger swipe was a real accelerant, but the 18:00 collapse correlated with zram churn, not a swipe (last swipe was ~3h earlier). Two independent levers, each worth its own mitigation — conflating them would have fixed only half.
4. **A "correct in isolation" tuning can be a co-conspirator.** `swappiness=150` is right for zram *for memory outcomes*, yet its workqueue CPU cost helped starve rtkit's canary. Global optima per-subsystem don't compose for free on a contended machine.
