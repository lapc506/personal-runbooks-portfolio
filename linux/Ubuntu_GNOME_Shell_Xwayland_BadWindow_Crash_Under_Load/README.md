# Ubuntu — GNOME Shell crashes with `BadWindow` (SIGTRAP via Xwayland) under host CPU/IO starvation

_Applies to: Ubuntu 24.04 LTS, GDM 46.x, GNOME Shell (mutter) on Wayland, NVIDIA driver 580-open, hybrid graphics (Intel Iris Xe iGPU + discrete NVIDIA RTX 4050 — Ada), kernel 6.17.x, **PRIME in `on-demand` mode** (compositor on the Intel iGPU)._

> **⚠ Reader's summary:** during a heavy multi-tasking session (4+ Claude Code terminals + Docker/Podman/Supabase + Chrome/Electron), the host runs out of schedulable CPU/IO for a few seconds. `libinput` logs `your system is too slow` and `podman`/`dockerd` log a **cascade** of `healthcheck command exceeded timeout of 2s`. Starved of CPU, GNOME Shell falls behind on its Xwayland connection, operates on an X11 window that was already destroyed, receives an asynchronous **`BadWindow`** protocol error, and — because mutter treats X errors as unrecoverable — aborts with **`signal 5` (SIGTRAP)**. On Wayland the compositor _is_ the display server, so the whole GUI session dies and every app (terminals, editors, **all your Claude Code sessions**) goes with it. **This is NOT a GPU fault** — there is **no `Xid`** (rules out [`Ubuntu_NVIDIA_Xid56_Display_Freeze_Under_Load`](../Ubuntu_NVIDIA_Xid56_Display_Freeze_Under_Load)) and **no `nv_drm_atomic_commit` / flip timeout** (rules out [`Ubuntu_NVIDIA_Wayland_Flip_Event_Timeout`](../Ubuntu_NVIDIA_Wayland_Flip_Event_Timeout)). It is **resource contention**. The fix is **not** "run less" — it is to **partition scheduler priority** (cgroup `CPUWeight`/`IOWeight`) so the desktop and your interactive work always win over background containers, plus keep the graphics stack patched and **measure** pressure with PSI.

## Context

Hardware: Gigabyte AORUS 15 9MF, RTX 4050 Laptop (NVIDIA 580.126.09-open, Ada AD107M), Intel Iris Xe iGPU, **16 logical CPUs**, **32 GiB RAM**, kernel 6.17.0-22-generic, Ubuntu 24.04.4, GDM 46, GNOME Shell on Wayland.

This machine was previously moved to `prime-select on-demand` (Experiment 1 of the [`Xid56`](../Ubuntu_NVIDIA_Xid56_Display_Freeze_Under_Load) runbook), which took the compositor **off** the discrete GPU and onto the Intel iGPU. That successfully removed the dGPU-`Xid 56` freeze class — but it also concentrated the compositor **and** every GPU-accelerated app (Chrome, Electron, terminals) onto the **same iGPU**, and left the desktop competing for CPU on equal footing with the background workload. The crash documented here is the failure mode that surfaced after that change.

Workload framing (non-negotiable per the operator — solopreneur + freelancer): **at least 4 Claude Code terminals open at all times**, plus a local Supabase stack, Docker/Podman containers, Chrome, Slack, and assorted Electron apps. "Reduce the load" is not an acceptable mitigation. The 32 GiB of RAM exists precisely to keep all of this resident. The correct lever is therefore **resource partitioning**, not reduction.

## Problem Statement

```bash
journalctl -b -1 --no-pager | grep -E "too slow|exceeded timeout|X Window System error|crashed with signal|BadWindow"
```

on the boot that crashed produces (timestamps from the 2026-06-04 incident):

```
13:34:13  gnome-shell[5433]: libinput error: client bug: timer ... scheduled expiry is in the past (-76ms), your system is too slow
13:34:28  gnome-shell[5433]: libinput error: event7 ... event processing lagging behind by 442ms, your system is too slow
13:34:43  podman[...]: Error: healthcheck command exceeded timeout of 2s
13:34:47  podman[...]: Error: healthcheck command exceeded timeout of 2s        ← cascade: many containers at once
13:34:48  dockerd[5663]: Health check for container a267... error: timed out starting health check
13:34:53  gnome-shell[5433]: Received an X Window System error.
          The error was 'BadWindow (invalid Window parameter)'.
          (Details: serial 2845366 error_code 3 request_code 25 (core protocol) minor_code 0)
13:34:53  gnome-shell[5433]: GNOME Shell crashed with signal 5
          == Stack trace for context ... resource:///org/gnome/shell/ui/init.js:21 ==
```

A crash report is also written: `/var/crash/_usr_bin_gnome-shell.1000.crash`. The boot ends with **no shutdown sequence** (hard power-off), and `journalctl --list-boots` shows two consecutive `still running` boots — the signature of an unclean stop.

### What makes this contention and not a GPU fault

| Check | Command | Result on the crash boot |
|---|---|---|
| NVIDIA `Xid` (→ `Xid56` runbook) | `journalctl -b -1 -k -g Xid` | **0** |
| Flip timeout (→ `Flip_Event_Timeout` runbook) | `journalctl -b -1 -g 'nv_drm_atomic_commit\|Flip event timeout'` | **0** |
| `nvidia-modeset: ERROR` | `journalctl -b -1 -g 'nvidia-modeset.*ERROR'` | **0** |
| OOM kill | `journalctl -b -1 -k -g 'oom\|Killed process'` | **0** (32 GiB, ~15 GiB free, swap 0 B) |
| Kernel-level stall | `journalctl -b -1 -k -g 'hung_task\|rcu.*stall\|soft lockup'` | **0** |
| Userspace "too slow" | `journalctl -b -1 -g 'your system is too slow'` | **present** |
| Container healthcheck cascade | `journalctl -b -1 -g 'exceeded timeout'` | **present, many at once** |

The two GPU runbooks and OOM are ruled out. The only positive signals are **userspace latency** indicators. The kernel never registered a hard stall (`hung_task` fires at ~120 s of blocking), so this was **scheduling-latency degradation in userspace**, not a frozen kernel.

## Root Cause

### Why a 2-second healthcheck timeout is the smoking gun, not the bug

Container healthchecks (`pg_isready`, a `curl` to `localhost`, a one-line script) are **trivial** and normally complete in milliseconds. Supabase's CLI compose files set short `timeout:` values (2 s) precisely because the check is supposed to be instant. A 2 s budget is *generous* for `pg_isready`.

So when **many** healthchecks across **different** containers blow a 2 s budget **simultaneously**, the explanation is not "the database is slow" (that would be 1 container, and a connection error, not a timeout) — it is that the trivial check **could not get scheduled / could not complete its IO** in 2 s. The 2 s timeout didn't cause the problem; it's the **canary** that made host contention visible. The same contention is what starved gnome-shell.

### Why we have scheduling latency and host contention in the first place

Two independent clocks slipping in the same window — `libinput`'s input-timer clock (442 ms behind) and the containers' 2 s healthcheck watchdog — is the textbook signature of **CPU/IO starvation**: the problem is not in either subsystem, it's in the shared resource both need.

The structural cause is that **everything runs at the same priority**. On this machine:

```
-.slice
├── user.slice           (CPUWeight default 100)   ← compositor + terminals + Claude live here
│   └── …/session.slice/org.gnome.Shell@wayland.service
│   └── …/app.slice/      (claude × 8, node × 9, rootless podman, Chrome, Slack)
└── system.slice          (CPUWeight default 100)   ← dockerd + Supabase containers
    └── docker.service     (CPUWeight = [not set])
```

`gnome-shell`, a TypeScript type-check, a Docker image layer write, and `git gc` all run at **nice 0 / CPUWeight 100**. The Linux scheduler (EEVDF) is *fair* — it splits CPU evenly among runnable tasks. "Fair" is exactly wrong here: when 8 Claude agents + a Supabase boot + a Chrome reflow all burst at once, the compositor gets its *fair share* and no more — which, with dozens of hungry tasks, is not enough to service input timers and the Xwayland connection on time. IO is the same story: a burst of container/disk writes saturates the NVMe queue and the compositor's reads block behind them.

Nothing here is "too much load" in the absolute sense (16 cores, 32 GiB, PSI at 0 when idle). It's **unprioritized** load: the desktop has no precedence over the background workload, so a burst steals its CPU/IO for the few seconds it takes to miss an Xwayland round-trip and trip the abort.

### Why the missed round-trip becomes `BadWindow` → why mutter makes it fatal → why SIGTRAP

- Under Wayland, mutter runs a child **Xwayland** server for X11 apps and is itself an **X client** of it (it manages X11 windows). Like any Xlib client, it installs an X error handler.
- X reports errors **asynchronously**. When the compositor is starved, its view of the X11 window tree lags reality: it issues a request (`request_code 25`) against a window the server already destroyed → the server replies, much later, with **`BadWindow`**. The client and server state have diverged.
- Mutter's handler is **`mtk_x_error`** (MTK = Mutter ToolKit, the namespace introduced in GNOME 46; the log literally says "break on the mtk_x_error() function"). GNOME's deliberate design choice is to **not** attempt recovery from an unexpected X error — it aborts cleanly and lets GDM/systemd respawn the session, rather than keep painting an inconsistent desktop.
- The abort runs through GLib/GJS's `G_BREAKPOINT()`, which executes the `int3` breakpoint instruction → the kernel delivers **`SIGTRAP` (signal 5)**, accompanied by a GJS stack trace (`init.js:21`). This is the fingerprint of a *deliberate assertion abort*, **not** a memory bug (which would be SIGSEGV/11). It rules out bad RAM and driver memory corruption.

> Same SIGTRAP appears in the [`Flip_Event_Timeout`](../Ubuntu_NVIDIA_Wayland_Flip_Event_Timeout) runbook, but there it is driven by a **GPU** flip-timeout. Here it is driven by an **X protocol** error from starvation. Same signal, different trigger — see that runbook's "Debugging lesson 4".

### Why the i915 `Fence expiration time out` (Chrome) is a side effect, not the cause

A single `Fence expiration time out i915-0000:00:02.0:chrome[…]` appeared on 2026-06-02 (one event, not recurring). An i915 *fence* marks when a GPU render batch finishes; the timeout means the **Intel iGPU** didn't signal completion of a **Chrome** batch in time — a soft hang of the iGPU on one client's work (typically WebGL/canvas/accelerated video). It matters here only as evidence of the `on-demand` trade-off: with the compositor moved onto the iGPU, the **iGPU now carries the desktop _and_ every accelerated app**, so it is more easily congested. It is a symptom of the same concentration of load, not the cause of the SIGTRAP crash.

## Solution — partition priority, patch the stack, and measure (you do NOT reduce load)

> **Discipline:** apply **one** script, then run under your normal heavy load for several days. The crash only appears in long bursty sessions, so a clean afternoon proves nothing. Record outcomes in the Test log.

### Experiment 1 — protect the compositor and your interactive work from starvation (`CPUWeight`/`IOWeight`) — highest leverage, fully reversible, no reboot

**Hypothesis:** the compositor crashes because it gets only a *fair* (i.e. insufficient) share of CPU/IO during bursts. If `user.slice` (your whole interactive session) outweighs `system.slice` (dockerd/Supabase), and the compositor outweighs the Claude agents *within* your session, then a burst can no longer starve gnome-shell into missing its Xwayland round-trips.

```bash
sudo bash ./protect-compositor-scheduling.sh        # applies cgroup weights (needs sudo); NO reboot
bash ./protect-compositor-scheduling.sh verify       # confirm weights are live (no root needed)
```

What it does (all via persistent systemd drop-ins; idempotent):

| Scope | Unit | Setting | Effect |
|---|---|---|---|
| System | `user.slice` | `CPUWeight=5000 IOWeight=5000` | your interactive session beats background `system.slice` (dockerd/Supabase) under contention |
| System | `docker.service` | `CPUWeight=50 IOWeight=50` | dockerd yields *within* `system.slice` when the host is busy |
| User | `org.gnome.Shell@wayland.service` | `CPUWeight=10000`, `MemoryLow=512M` | the compositor beats your own Claude agents *inside* `user.slice`, and is shielded from memory reclaim |

**Why this respects "I can't reduce load":** `CPUWeight` is **proportional, not a cap**. When CPU is plentiful (your normal state — PSI at 0), *nothing changes*; all 8 Claudes and every container run full-speed. The weights only bite **during contention**, and only to decide *who waits a few milliseconds* — and the answer becomes "the background containers wait, the desktop doesn't." You keep every terminal and container; you just stop letting a Supabase boot out-compete the process drawing your screen.

**Verify (after some heavy use):**
```bash
systemctl show user.slice -p CPUWeight                                   # CPUWeight=5000
systemctl --user show org.gnome.Shell@wayland.service -p CPUWeight        # CPUWeight=10000
cat /proc/pressure/cpu                                                    # watch 'some avgN' during a burst
journalctl -b 0 -g 'your system is too slow'                              # should be rare/absent under load now
```

**Rollback:** `sudo bash ./protect-compositor-scheduling.sh revert` (removes all drop-ins, reloads systemd). No reboot.

### Experiment 2 — patch the graphics + driver stack (close the 197 pending updates) — do alongside Experiment 1

This machine had **197 packages pending**, including the NVIDIA driver (`580.126.09 → 580.159.03`, a security update), `gnome-shell` (`46.0…13 → …14`), and a newer HWE kernel + matching `nvidia-580-open` modules. `libmutter` is already at **46.2** (so the "Mutter 46.2+" target is met); the update brings the rest.

```bash
sudo bash ./update-graphics-stack.sh                 # apt update + targeted upgrade + enables sysstat/PSI logging
# reboot when convenient (new kernel + driver need it)
```

What it does: snapshots `dpkg --get-selections`, runs `apt-get update`, upgrades the full set (`apt-get full-upgrade`), and enables **`sysstat`** collection (`/etc/default/sysstat` → `ENABLED="true"`, `systemctl enable --now sysstat`) so `sar` records CPU/IO/load history for the next incident. (`sar` is part of the `sysstat` package — there is no separate `sar` package; the operator's `apt install sar` failure is expected.)

> **Honest limit on Xwayland / explicit sync.** Explicit sync (the `linux-drm-syncobj-v1` protocol that fixed most NVIDIA-on-Wayland frame glitches) needs **Xwayland 24.1+** for the X11-app path to be fully robust. **Ubuntu 24.04 ships and caps Xwayland at 23.2.6** — `apt` will *not* give you 24.1, and pulling it from a PPA or building from source on an LTS production laptop is **not recommended** (it desyncs from the distro's mutter/Mesa ABI). What you already have — Mutter 46.2 + driver 580 + the protocol present + Xwayland 23.2.6's *initial* explicit-sync support + native-Wayland apps (run Chrome/Electron with `--ozone-platform=wayland` to bypass Xwayland entirely) — is the right target on 24.04. Crucially, **explicit sync addresses tearing/frame-desync, not this specific `BadWindow` race** — so it is good hygiene, not the fix. The fix is Experiment 1.

### Diagnose whether this runbook applies

```bash
bash ./diagnose-compositor-starvation.sh
```

Read-only. Confirms the SIGTRAP+`BadWindow` signature on a recent boot, **rules out** `Xid`/flip-timeout/OOM (so you don't mis-apply a GPU runbook), reports PRIME mode and which GPU the compositor is on, prints current `CPUWeight`s and live PSI, and exits 0 only if this runbook applies.

## Verification

After Experiment 1 (+ optional reboot for Experiment 2), run under a real heavy session for several days, then:

```bash
# 1. Weights are live
systemctl show user.slice system.slice docker.service -p CPUWeight -p IOWeight
systemctl --user show org.gnome.Shell@wayland.service -p CPUWeight -p MemoryLow

# 2. The userspace-starvation canaries are gone (or far rarer) under load
journalctl -b 0 --no-pager | grep -cE 'your system is too slow|exceeded timeout of 2s'

# 3. No new SIGTRAP/BadWindow crash
journalctl -b 0 --no-pager | grep -E 'crashed with signal|X Window System error'    # expect empty
ls -t /var/crash/_usr_bin_gnome-shell* 2>/dev/null                                   # no new dump

# 4. PSI during a deliberate burst (start your 4 Claudes + a Supabase reset at once)
watch -n1 'cat /proc/pressure/cpu /proc/pressure/io'      # 'some avg10' should stay well under saturation
```

If a SIGTRAP+`BadWindow` crash still occurs after Experiment 1 with weights confirmed live, the contention is deeper than scheduler priority (e.g. a single runaway task pinning all 16 cores, or NVMe IO saturation) — capture `sar` around the incident and consider an `io.latency` guarantee on `session.slice` and/or `systemd-oomd` pressure limits on `system.slice`.

## Rollback

```bash
sudo bash ./protect-compositor-scheduling.sh revert    # removes all cgroup drop-ins (no reboot)
# Experiment 2 (packages) rolls back like any apt upgrade; the script saves a dpkg selections snapshot
```

## Known Constraints

* **cgroup `CPUWeight` only bites under contention.** That is the whole point (you don't want to throttle idle capacity), but it means you cannot *prove* the fix on an idle machine — only a real burst exercises it. Use PSI to watch it work.
* **`IOWeight` requires the `bfq` IO scheduler to be fully effective.** On NVMe with `none`/`mq-deadline`, `io.weight` may be a no-op; the script sets it anyway (harmless) and, on NVMe, leans on `io.latency` guarantees instead where available. Check `cat /sys/block/nvme0n1/queue/scheduler`.
* **User-scope drop-in needs a re-login to fully bind** for `org.gnome.Shell@wayland.service` weights set declaratively; the script also applies them at runtime via `systemctl --user set-property` so they take effect immediately without waiting for the next login.
* **This is orthogonal to the two GPU runbooks.** If `Xid` or `nv_drm_atomic_commit` *also* appears on a future crash boot, that is a separate fault — apply the matching runbook. Priority partitioning does not fix a wedged GPU command engine.
* **Does not change PRIME mode.** Staying on `on-demand` (compositor on iGPU) is correct for avoiding the `Xid 56` dGPU freeze. If the iGPU itself starts hanging (recurring i915 `Fence expiration` — currently a single event), consider forcing heavy GPU apps onto the dGPU via `__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia` to relieve the iGPU, which is the opposite-direction lever.

## Related runbooks

* [`Ubuntu_NVIDIA_Xid56_Display_Freeze_Under_Load`](../Ubuntu_NVIDIA_Xid56_Display_Freeze_Under_Load) — **sibling / prerequisite history.** Its Experiment 1 (`prime-select on-demand`) is already applied on this machine and is *why* the compositor is on the iGPU. That runbook fixes a dGPU GPU fault; this one fixes a CPU/IO contention crash. Different layer, different fix.
* [`Ubuntu_NVIDIA_Wayland_Flip_Event_Timeout`](../Ubuntu_NVIDIA_Wayland_Flip_Event_Timeout) — same SIGTRAP symptom, GPU-flip trigger instead of starvation. Use its diagnostic grep to tell them apart.
* [`Ubuntu_Chrome_Wayland_Render_Node_Crash_Loop`](../Ubuntu_Chrome_Wayland_Render_Node_Crash_Loop) — adjacent; Chrome on the iGPU is the most common single source of the bursty GPU/CPU load that triggers this crash. Running Chrome native-Wayland (`--ozone-platform=wayland`) also takes it off Xwayland.
* [`claude-code-multi-backend`](../claude-code-multi-backend) — session recovery after the crash: the launcher's orphan-transcript scanning + `SessionStart` backup hook are what let you resume the Claude sessions this crash kills. (Its stale-heartbeat listing bug is tracked separately.)

## References

* [freedesktop.org — X protocol error handling](https://www.x.org/releases/current/doc/libX11/libX11/libX11.html#Using_the_Default_Error_Handlers) — why an unhandled X error terminates the client by default.
* [systemd.resource-control(5)](https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html) — `CPUWeight`, `IOWeight`, `MemoryLow`, and the cgroup-v2 hierarchy semantics this runbook relies on.
* [kernel.org — PSI (Pressure Stall Information)](https://docs.kernel.org/accounting/psi.html) — `/proc/pressure/{cpu,io,memory}`, the metric that was missing during the incident.
* [GNOME mutter — `mtk_x_error` abort path](https://gitlab.gnome.org/GNOME/mutter) — the compositor's "abort on unexpected X error" policy.
* [NVIDIA + Wayland explicit sync (`linux-drm-syncobj-v1`)](https://www.collabora.com/news-and-blog/news-and-events/explicit-sync-merged-upstream.html) — what explicit sync is and which component versions it needs.

## Debugging lessons

1. **A 2-second timeout reverting is a measurement, not a defect.** When a *trivial* check (a `pg_isready`) misses a generous budget, the check is a canary for host contention — don't "fix" it by raising the timeout; read it as "the host couldn't schedule a trivial task in 2 s" and look at what's competing.

2. **Two unrelated clocks slipping together = shared-resource starvation.** `libinput`'s 442 ms input lag and the containers' 2 s healthcheck cascade have nothing in common *except* the CPU/IO they both need. Correlated latency across independent subsystems localizes the fault to the shared resource, not to either subsystem.

3. **`SIGTRAP` vs `SIGSEGV` tells you the crash class before you read the stack.** SIGTRAP in mutter/GJS = a deliberate `G_BREAKPOINT()` assertion abort ("I saw inconsistent state, I'm stopping"). SIGSEGV = a memory bug. This crash being SIGTRAP ruled out bad RAM and driver memory corruption on sight.

4. **Absence of kernel stall traces is itself evidence.** Zero `hung_task`/`rcu stall`/`oom` across all boots means the freeze never reached the kernel — it was userspace scheduling latency. Knowing what *didn't* fire narrowed the cause to priority, not capacity (and 32 GiB / 16 cores confirmed capacity was never the issue).

5. **On Wayland the compositor is a single point of failure — partition for it accordingly.** In X11 a WM crash leaves the X server (and your apps) alive; in Wayland gnome-shell *is* the server, so its death takes the whole session. That asymmetry is why the desktop deserves scheduler precedence over background work that, if it stalls, merely retries.

6. **"Reduce the load" is the wrong lever when load is the job.** For a workstation deliberately running N heavy tasks, the fix is to *order* the contention (who yields to whom) via cgroup weights, not to remove tasks. Proportional weights cost nothing when idle and only arbitrate under pressure — exactly the shape of this problem.
