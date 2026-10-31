# Ubuntu — kernel memory overcommit (Committed_AS ≫ physical RAM) and `vm.swappiness=120`

_Applies to: Ubuntu 24.04 LTS (kernel 6.8), MemTotal 31,762,328 kB ≈ 31.7 GB RAM, swap tier = 8 GB `/swap.img` (prio −1) + 4 GB `/dev/zram0` (prio 100), `vm.overcommit_memory=0` (heuristic default), `vm.overcommit_ratio=50`, `vm.swappiness=120`. Host: kvttvrsis-AORUS-15-9MF._

> **⚠ Reader's summary:** `Committed_AS` is the kernel's **promise of address space**, not current usage. On this machine it runs far above physical RAM — observed at **~134 GB vs ~31.7 GB physical** during the incident that motivated this runbook, and ~37.9 GB vs ~31.7 GB at evidence-capture time. That is **by design** under the default heuristic overcommit policy (`vm.overcommit_memory=0`): the kernel lets processes reserve enormous virtual address spaces and only refuses an allocation when it is obviously wild. A large Committed_AS is **not** a memory leak, and it is **not** an OOM condition — the health metrics that matter are `MemAvailable` (18.1 GB right now, i.e. healthy) and whether the OOM killer / systemd-oomd is actually firing. This runbook explains how to read the commit numbers, what each knob does, and — importantly — when **no action is needed** vs. when tightening overcommit to a hard cap (mode 2) is justified.

---

## Symptoms (the motivating observation)

- `grep Committed_AS /proc/meminfo` showed **Committed_AS ≈ 134 GB** while `MemTotal` ≈ 31.7 GB — a commit ratio of ≈ **4.2× physical RAM**.
- The machine also carried a non-default **`vm.swappiness=120`** (left over from earlier zram/swap tuning; see sibling runbooks).
- User-visible correlates to watch for: `free` reporting healthy "available" memory while process virtual sizes (`VmSize`/`VSZ`) look gigantic; occasional `Out of memory: Killed process ...` journal lines only if **real** demand ever exceeds RAM+swap; reservation-heavy apps (Electron, browsers, containers, JVMs) failing `mmap`/alloc when the heuristic guesses wrong.

Committed_AS is workload-dependent and churns constantly. At this runbook's evidence capture it measured ≈ 37.9 GB (≈ 1.2× RAM) — same host, same physical RAM, much smaller committed figure — because the workload at capture time reserved less address space than during the peak incident.

---

## Live diagnostic snapshot (this machine — exact captured values)

Collected 2026-10-31 on this host. First, the three commands the runbook is built around:

```console
$ sysctl vm.swappiness vm.overcommit_memory
vm.swappiness = 120
vm.overcommit_memory = 0

$ grep -E 'MemTotal|Committed_AS' /proc/meminfo
MemTotal:       31762328 kB
Committed_AS:   37912532 kB

$ free -h
               total       usado       libre  compartido   búf/caché  disponible
Mem:            30Gi        13Gi       6,5Gi       2,4Gi        13Gi        17Gi
Inter:          11Gi       7,2Gi       4,8Gi
```

Notes on the exact output:
- `free -h` headers are locale-dependent (Spanish here): `usado` = used, `búf/caché` = buff/cache, `disponible` = available, `Inter` = Intercambio (Swap).
- The full capture (including `CommitLimit`, swap devices, and the diagnostic script's computed ratios) is in [`diagnose-overcommit.sh`](./diagnose-overcommit.sh) and reproduced in the **Diagnostics** section below.

---

## Diagnostics

Run the bundled read-only script — it does nothing but read sysctls, `/proc/meminfo`, swap state, and the kernel journal:

```bash
./diagnose-overcommit.sh        # read-only; mutates nothing; no sudo needed
```

Script output on this machine (verbatim):

```
== 1. sysctl: overcommit policy + ratio + swappiness ==
vm.overcommit_memory = 0
vm.overcommit_ratio = 50
vm.swappiness = 120

== 2. /proc/meminfo: totals, availability, commit accounting ==
MemTotal:       31762328 kB
MemFree:         6946400 kB
MemAvailable:   18087340 kB
SwapTotal:      12582904 kB
SwapFree:        5042524 kB
CommitLimit:    28464068 kB
Committed_AS:   37907532 kB

== 3. swap devices ==
NAME       TYPE      SIZE USED PRIO
/swap.img  file        8G 4,6G   -1
/dev/zram0 partition   4G 2,6G  100

== 4. free -h (human-readable; headers follow your locale) ==
               total       usado       libre  compartido   búf/caché  disponible
Mem:            30Gi        13Gi       6,6Gi       2,4Gi        13Gi        17Gi
Inter:          11Gi       7,2Gi       4,8Gi

== 5. ratios (kB, from /proc/meminfo) ==
Committed_AS / MemTotal   = 1,19 x physical RAM
Committed_AS / CommitLimit = 1,33
CommitLimit / MemTotal     = 0,90

== 6. recent kernel OOM events (current boot, if any) ==
oct 26 19:05:52 kvttvrsis-AORUS-15-9MF kernel: NVRM: nvCheckOkFailedNoLog: Check failed: Out of memory [NV_ERR_NO_MEMORY] (0x00000051) returned from _memdescAllocInternal(pMemDesc) @ mem_desc.c:1359
oct 26 19:05:52 kvttvrsis-AORUS-15-9MF kernel: NVRM: nvCheckOkFailedNoLog: Check failed: Out of memory [NV_ERR_NO_MEMORY] (0x00000051) returned from rmStatus @ system_mem.c:356
oct 26 19:05:52 kvttvrsis-AORUS-15-9MF kernel: NVRM: nvAssertOkFailedNoLog: Assertion failed: Out of memory [NV_ERR_NO_MEMORY] (0x00000051) returned from pRmApi->Alloc(pRmApi, device->session->handle, isSystemMemory ? device->handle : device->subhandle, &physHandle, isSystemMemory ? NV01_MEMORY_SYSTEM : NV01_MEMORY_LOCAL_USER, &memAllocParams, sizeof(memAllocParams)) @ nv_gpu_ops.c:4969

== exit codes (0 = success) ==
sysctl=0 meminfo=0 swapon=0 free=0 awk=0 oom=0
```

Key readings from that snapshot:

| Metric | Value | Meaning |
|---|---|---|
| `Committed_AS` | 37,907,532 kB (≈ 37.9 GB) | total virtual address space the kernel has promised to processes |
| `CommitLimit` | 28,464,068 kB (≈ 28.5 GB) | the hard ceiling if overcommit mode 2 were enforced |
| `MemTotal` | 31,762,328 kB (≈ 31.7 GB) | physical RAM |
| `MemAvailable` | 18,087,340 kB (≈ 18.1 GB) | memory available to start new apps without swapping |
| `vm.overcommit_memory` | 0 | heuristic overcommit (stock default) |
| `vm.swappiness` | 120 | non-default; aggressive anonymous-page swap bias |
| swap tier | /swap.img 8G (prio −1) + zram0 4G (prio 100) | mixed disk + compressed-RAM swap |

### Manual diagnostics (same information, no script)

```bash
# 1. commit accounting
grep -E '^(MemTotal|MemFree|MemAvailable|Committed_AS|CommitLimit):' /proc/meminfo

# 2. overcommit policy knobs
sysctl vm.overcommit_memory vm.overcommit_ratio vm.swappiness

# 3. swap tier
swapon --show

# 4. human-readable totals
free -h

# 5. real OOM-killer events this boot (kernel OOM killer, not "Out of memory" strings)
journalctl -k -b --no-pager | grep -i 'oom-kill'
```

> **Which numbers trigger concern?**
> - `MemAvailable` small (single-digit GB or less) while `Committed_AS` is huge → real pressure; investigate actual consumers.
> - `oom-kill` lines in the journal → the kernel actually had to kill; that is the real OOM signal, not a big committed number.
> - Committed_AS ≫ CommitLimit under mode 0 → expected under heuristic overcommit; only a problem if resident demand follows.
> - Committed_AS approaching CommitLimit under mode 2 → you are near the configured ceiling; allocations will start failing with `ENOMEM`.

---

## Interpretation

### What `Committed_AS` is

`Committed_AS` (in `/proc/meminfo`) is the sum of all **virtual address space** the kernel has agreed to provide — every mapping a process currently holds, resident or not. It counts reservations: anonymous mappings, heap/stack areas, sparse `mmap`s, shared libraries mapped into each process, thread stacks, and copy-on-write regions. It is a **promise**, not a measure of physical consumption. The kernel documentation describes it as bounded by the commit limit under strict accounting; under the default heuristic policy (mode 0) it routinely exceeds `CommitLimit` — exactly what we observe here (1.33×).

### Why commit so far exceeds physical RAM

Under `vm.overcommit_memory=0` (heuristic, the Ubuntu default), the kernel deliberately overcommits: it refuses only allocations that are obviously impossible for the current system (e.g. a single allocation larger than RAM+swap), and otherwise says "yes" to reservations. Browsers, Electron apps, JVMs, and container runtimes routinely reserve gigabytes of address space they never touch. Because these reservations are virtual, `Committed_AS` can be several times physical RAM without any harm — as long as the pages, when actually faulted in, fit within RAM+swap (or are reclaimed before that).

### The three overcommit modes

| `vm.overcommit_memory` | Name | Behavior |
|---|---|---|
| `0` | heuristic (default) | refuse obviously-wild single allocations; otherwise overcommit freely. Committed_AS may exceed CommitLimit. |
| `1` | always overcommit | never refuse; commit is effectively unbounded; no safety net. |
| `2` | never overcommit | hard cap: total commit is refused beyond `CommitLimit`. OOM killer acts when real demand hits the cap. |

`CommitLimit` is *not* a fixed number. The kernel computes it (see `mm/util.c` → `vm_commit_limit()`) approximately as:

```
CommitLimit ≈ swap
            + (RAM − hugetlb) × overcommit_ratio / 100
            + (SLAB_reclaimable + SLAB_unreclaimable + shmem + file-mapped + anon-mapped)
```

With `overcommit_ratio=50` and the current swap tier, this host's CommitLimit ≈ 28.5 GB — read it live from `/proc/meminfo` rather than trusting a static figure.

### Where `swappiness` fits

`vm.swappiness` (0–200 since kernel 5.8; default 60) biases **when the kernel swaps anonymous pages out** once real memory pressure exists. It does **not** bound `Committed_AS`. The two knobs are orthogonal:

- `overcommit_memory` decides how much **address space** the kernel will promise;
- `swappiness` decides how aggressively it **pages out cold anonymous pages** to the swap tier when resident pressure climbs.

This machine sits at `swappiness=120` with a **mixed swap tier**: 4 GB zram (compressed RAM, prio 100) and 8 GB `/swap.img` (disk, prio −1). High swappiness is coherent here because the **primary** swap is zram — fast, no seek cost — so aggressively demoting cold pages into compressed RAM is sensible (see the sibling zram runbook). It would be a poor fit if `/swap.img` (disk) were the only swap. The sibling `rtkit` runbook documents this value deliberately being reduced from `150 → 120` after a scheduling-collapse incident; 120 is the current intended end state.

---

## Remediation (decision-driven — no change is mandatory)

The honest headline: **a large Committed_AS is not a fault.** Remediate only when you have a *real* symptom (OOM kills, stalls, ENOMEM failures), or when you want a hard, predictable ceiling for capacity planning.

### Case A — healthy (the common case): change nothing

If `MemAvailable` stays ample and there are no `oom-kill` events, the big committed figure is benign reservation. Action: keep `vm.overcommit_memory=0`, keep the current swappiness, and use this runbook as the reference for why the numbers look alarming but are not.

### Case B — you want a hard cap (mode 2)

For servers or predictable capacity planning, bound commits to `CommitLimit`:

```bash
# inspect first
sysctl vm.overcommit_memory vm.overcommit_ratio vm.swappiness

# experimental (runtime only, lost on reboot)
sudo sysctl -w vm.overcommit_memory=2 vm.overcommit_ratio=80

# persist across reboots
printf 'vm.overcommit_memory=2\nvm.overcommit_ratio=80\n' | sudo tee /etc/sysctl.d/99-overcommit.conf
sudo sysctl --system
```

Consequences to accept: reservation-heavy workloads (some JVMs, Electron, large sparse mmaps) may now fail early with `ENOMEM` even when real usage is modest, because the *promised* total is capped. Lower `overcommit_ratio` = tighter ceiling; raise it to loosen. Test with your real workload before leaving it enabled.

### Case C — reduce the reservation appetite

The biggest commit contributors are processes reserving vast virtual spaces. Practical levers:

- close idle Electron/browser profile instances (each maps shared libraries + reserves heaps);
- place container limits (`--memory`, cgroup `memory.max`) so one tenant cannot reserve unbounded space;
- for JVM-style runtimes, cap heap reservations explicitly.

This lowers both `Committed_AS` and worst-case resident risk, regardless of the overcommit mode.

### Case D — tune swappiness to the swap backend

- Swap tier is **primarily zram/zswap** (fast): high values (100–180) are appropriate; 120 is fine.
- Swap tier is **disk only**: lower swappiness (e.g. 10–60) to avoid thrash; high values here cause disk swap storms.

```bash
# example: reduce to 60 for a disk-only swap tier
sudo sysctl -w vm.swappiness=60
printf 'vm.swappiness=60\n' | sudo tee /etc/sysctl.d/99-swappiness.conf
sudo sysctl --system
```

Do not change swappiness purely because Committed_AS looks big — they are unrelated; swappiness only matters once real pressure exists.

---

## Verification

```bash
# policy + tuning
sysctl vm.overcommit_memory vm.overcommit_ratio vm.swappiness

# commit accounting now bounded (mode 2) or floating (mode 0)
grep -E '^(MemTotal|MemFree|MemAvailable|Committed_AS|CommitLimit):' /proc/meminfo

# quick view
free -h

# confirm no kernel OOM-killer events
journalctl -k -b --no-pager | grep -i 'oom-kill' || true
```

Expected outcomes:

- **Mode 2:** `Committed_AS` stops growing past `CommitLimit`; allocation-heavy apps either run within the cap or fail fast (`ENOMEM`) instead of the machine freezing later.
- **Mode 0 (unchanged):** committed continues to float above CommitLimit; that is the expected, documented behavior.
- **Swappiness change:** only observable under real pressure (swap usage rate shifts); the numbers themselves won't "improve".

---

## Tradeoffs — honest version

| Change | Buys you | Costs you |
|---|---|---|
| **overcommit mode 2** | a hard, predictable ceiling; no surprise OOM from runaway reservation | early `ENOMEM` failures in reservation-heavy apps even when real usage is low; requires workload testing |
| **overcommit mode 1** | never refuse an allocation | no safety net at all; a runaway process can drive the machine into an OOM freeze |
| **swappiness high (120+)** | cold anonymous pages evict cheaply into zram; keeps RAM for hot data | if the swap tier is disk, high values cause thrash (and this box already had an rtkit scheduling-collapse incident at 150) |
| **swappiness low** | less swap churn on disk | more reliance on reclaim; may kill page cache under pressure if zram is unused |
| **doing nothing (mode 0)** | stock behavior; reservation-heavy apps just work | committed can balloon; you must read the *right* numbers (MemAvailable, oom-kill) to avoid false alarms |

---

## Rollback

All changes are reversible:

```bash
# remove overcommit policy drop-in (back to heuristic mode 0, ratio 50)
sudo rm -f /etc/sysctl.d/99-overcommit.conf
sudo sysctl --system

# remove swappiness drop-in (back to prior value)
sudo rm -f /etc/sysctl.d/99-swappiness.conf
sudo sysctl --system

# verify
sysctl vm.overcommit_memory vm.overcommit_ratio vm.swappiness
```

Expected after rollback: `vm.overcommit_memory=0`, `vm.overcommit_ratio=50`, `vm.swappiness` back to the prior persisted value.

---

## Evidence / test log

| Date | Event | Outcome |
|---|---|---|
| 2026-10-31 | evidence capture for this runbook (sysctl, meminfo, `free -h`, `swapon`) | `overcommit_memory=0`, `overcommit_ratio=50`, `swappiness=120`; Committed_AS 37,908,652 kB vs MemTotal 31,762,328 kB; CommitLimit 28,464,068 kB; MemAvailable ≈ 18.1 GB; swap = zram0 4G (prio 100) + /swap.img 8G (prio −1) |
| 2026-10-31 | `diagnose-overcommit.sh` run | exit codes all 0; bash -n syntax check exit 0; the only "Out of memory" strings in the boot journal are NVIDIA NVRM `NV_ERR_NO_MEMORY` allocation failures (GPU driver), not kernel OOM-killer events |
| 2026-10-31 | motivating incident (referenced) | Committed_AS observed ≈ 134 GB vs MemTotal ≈ 31.7 GB (≈ 4.2× RAM) under mode 0 |
| _pending_ | if mode 2 is enabled | watch for early ENOMEM in reservation-heavy apps; confirm Committed_AS ≤ CommitLimit |

---

## References

- Kernel sysctl documentation — `vm.overcommit_memory`, `vm.overcommit_ratio`, `vm.swappiness`: Documentation/admin-guide/sysctl/vm.rst (Linux 6.8)
- `/proc/meminfo` field meanings (`Committed_AS`, `CommitLimit`): Documentation/filesystems/proc.rst
- Commit-limit implementation: `mm/util.c` → `vm_commit_limit()` (kernel source)
- Sibling memory/swap runbooks on this machine: [`Ubuntu_zram_oomd_Memory_Pressure_Tuning`](../Ubuntu_zram_oomd_Memory_Pressure_Tuning) (zram + swappiness 150 + oomd), [`Ubuntu_GNOME_rtkit_KMS_Scheduling_Collapse_Session_Respawn`](../Ubuntu_GNOME_rtkit_KMS_Scheduling_Collapse_Session_Respawn) (swappiness 150 → 120)
