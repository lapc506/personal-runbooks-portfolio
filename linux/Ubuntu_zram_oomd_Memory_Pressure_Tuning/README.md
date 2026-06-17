# Ubuntu — stop systemd-oomd from killing apps on memory-pressure spikes (add zram + relax the oomd thresholds)

_Applies to: Ubuntu 24.04 LTS, GNOME 46 on Wayland, systemd 255, 32 GB RAM, swap = 8 GB file `/swap.img` (prio −2), `vm.swappiness=60`, **no zram** (module not loaded), Gigabyte AORUS 15 9MF._

> **⚠ Reader's summary:** `systemd-oomd` killed `chrome-lapc506` (4.2 GB) when the per-user slice `user@1000` crossed **85.61% memory pressure for >20s** — exactly the two stock Ubuntu thresholds (`ManagedOOMMemoryPressureLimit=50%` on `user@.service`, `DefaultMemoryPressureDurationSec=20s`). The machine was **not** out of memory: 32 GB RAM, only an 8 GB disk swapfile, no zram. The fix is two-part and they are **coupled**: (1) add a **16 GB zram** device so a transient spike lands in compressed RAM instead of triggering a kill, and (2) **relax oomd** (limit 50%→80%, duration 20s→30s) so it stops firing on brief, recoverable spikes. Doing (2) alone would be reckless; zram is the safety net that makes the looser thresholds safe.

## Why was zram never configured?

Because **Ubuntu desktop does not ship zram by default.** It is opt-in here. zram-by-default is a thing on Fedora (`zram-generator` since F33), SteamOS, and some Ubuntu *flavors*/spins — but **not** stock Ubuntu desktop. On this box there was also no pressure to add it: 32 GB RAM plus a disk swapfile looked like "plenty", so nobody ever loaded the module. The result is the state below — zram module absent, package absent, no config file:

```
zramctl                      -> (empty, no devices)
lsmod | grep zram            -> (nothing)
swapon --show                -> /swap.img  file  8G  prio -2     # disk swap only
cat /proc/sys/vm/swappiness  -> 60
dpkg -l | grep zram          -> (nothing installed)
```

## Diagnosis — confirm this is the failure you hit

```bash
./diagnose-memory-pressure.sh        # read-only; mutates nothing
```

The smoking gun in the journal (the oomd kill):

```bash
journalctl -b 0 -u systemd-oomd --no-pager | grep -i 'killed\|pressure'
# systemd-oomd: Killed /user.slice/user-1000.slice/.../chrome-lapc506...
#   due to memory pressure for /user.slice/user-1000.slice being 85.61% > 50.00%
#   for > 20s with reclaim activity
```

The two stock thresholds it tripped:

```bash
systemctl cat user@.service | grep ManagedOOMMemoryPressureLimit
# ManagedOOMMemoryPressureLimit=50%        <- per-user slice limit
systemd-analyze cat-config systemd/oomd.conf | grep Duration
# DefaultMemoryPressureDurationSec=20s     <- how long pressure must hold
```

> **Note on a confusing display:** `systemctl show user@1000.service -p ManagedOOMMemoryPressureLimit` prints `2147483648` (an absolute byte figure), which looks unrelated to "50%". The knob oomd actually evaluates is the **`50%` on the template `user@.service`** (shown by `systemctl cat user@.service`). That is the value this runbook raises.

## Root cause

`systemd-oomd` is a **pressure**-based killer, not a true OOM killer — it acts on PSI (Pressure Stall Information), well before the kernel OOM killer would. Ubuntu wires it to monitor the per-user slice and kill its heaviest cgroup once pressure exceeds `ManagedOOMMemoryPressureLimit` for `DefaultMemoryPressureDurationSec`. With **only a slow 8 GB disk swapfile**, a memory spike produces high reclaim pressure quickly (the kernel thrashes against disk), PSI climbs past 50%, holds for 20s, and oomd kills Chrome — even though 22 GB was still "available". There was no fast swap tier to absorb the spike, and the thresholds were tight enough to fire on a recoverable burst.

## The fix — three changes (all approved)

Files in this runbook mirror their target paths under `etc/`. Install each with `sudo install` (preserves your originals; nothing is edited in place).

### 1. Add a 16 GB zram device (modern `systemd-zram-generator` method)

```bash
sudo apt install systemd-zram-generator
sudo install -m 0644 etc/systemd/zram-generator.conf /etc/systemd/zram-generator.conf
sudo systemctl daemon-reload
sudo systemctl start systemd-zram-setup@zram0.service
```

Config (`/etc/systemd/zram-generator.conf`): `zram-size = min(ram, 16384)` MiB, `compression-algorithm = zstd`, **`swap-priority = 100`** (must outrank `/swap.img` at −2 so zram fills **first**).

**Verify:**

```bash
zramctl                # DISKSIZE 16G, ALGORITHM zstd
swapon --show          # /dev/zram0 prio 100  ABOVE  /swap.img prio -2
```

### 2. Raise swappiness for zram (counter-intuitive — read this)

```bash
sudo install -m 0644 etc/sysctl.d/99-zram-swappiness.conf /etc/sysctl.d/99-zram-swappiness.conf
sudo sysctl --system
```

This sets `vm.swappiness=150` and `vm.page-cluster=0`. **People get this backwards.** The classic advice "keep swappiness low" exists to avoid slow *disk* swap. With zram, "swap" is **compressed RAM** — fast, no seek cost — so you *want* the kernel to prefer pushing cold pages into zram over evicting useful file cache. High swappiness (100–180) is correct **for zram**; the value 60 here is the disk-era default. `page-cluster=0` disables swap readahead, which is pure waste when each "read" is a cheap in-RAM decompression.

**Verify:** `cat /proc/sys/vm/swappiness` → `150`.

### 3. Relax systemd-oomd (drop-ins only — never edit base files)

```bash
# per-user pressure limit: 50% -> 80%
sudo install -D -m 0644 etc/systemd/system/user@.service.d/50-oomd-pressure-limit.conf \
  /etc/systemd/system/user@.service.d/50-oomd-pressure-limit.conf

# global pressure duration: 20s -> 30s
sudo install -D -m 0644 etc/systemd/oomd.conf.d/50-pressure-duration.conf \
  /etc/systemd/oomd.conf.d/50-pressure-duration.conf

sudo systemctl daemon-reload
sudo systemctl restart systemd-oomd
```

**Verify:**

```bash
systemctl cat user@.service | grep ManagedOOMMemoryPressureLimit   # -> 80%
oomctl | grep Duration                                            # -> 30s
```

> The limit lives on the **template** `user@.service`, so the drop-in goes in `user@.service.d/`, not `user@1000.service.d/`. It applies to every user instance on next `daemon-reload`.

## Tradeoffs — honest version

| Change | Buys you | Costs you |
|---|---|---|
| **zram 16 GB** | a fast, compressed RAM swap tier that absorbs spikes before pressure ever spikes; ~2–4 GB of typical data compresses into ~1 GB | a little CPU for (de)compression; zram's backing store **is RAM**, so 16 GB zram can hold up to 16 GB of compressed pages — sized at `min(ram,16384)` so it can never claim more than physical RAM |
| **limit 50% → 80%** | oomd tolerates deeper pressure before killing → far fewer surprise app kills | if RAM *genuinely* runs out, oomd waits longer → higher risk of a real stall/freeze before it acts |
| **duration 20s → 30s** | a brief spike (tab load, linker, image export) rides through without a kill | 10 extra seconds of a real runaway leak chewing memory before oomd steps in |

**Why the combo is coherent, not just "two risky loosenings":** raising the oomd thresholds alone *would* be reckless — you would simply be telling the safety system to wait longer while the machine drowns. But zram changes the physics: a spike now lands in compressed RAM first, so pressure climbs **slower** and recovers **faster**, which means the 80%/30s window is mostly absorbing *recoverable* spikes, not masking a true OOM. zram is the airbag that makes driving with the looser thresholds safe. If you ever remove zram, **revert the oomd changes too.**

## Rollback

Each change is independent and fully reversible.

```bash
# 3. oomd back to stock
sudo rm /etc/systemd/system/user@.service.d/50-oomd-pressure-limit.conf
sudo rm /etc/systemd/oomd.conf.d/50-pressure-duration.conf
sudo systemctl daemon-reload && sudo systemctl restart systemd-oomd
#   verify: systemctl cat user@.service | grep ManagedOOM  -> 50% ; oomctl | grep Duration -> 20s

# 2. swappiness back to 60
sudo rm /etc/sysctl.d/99-zram-swappiness.conf
sudo sysctl --system
#   verify: cat /proc/sys/vm/swappiness -> 60

# 1. remove zram
sudo swapoff /dev/zram0
sudo systemctl stop systemd-zram-setup@zram0.service
sudo rm /etc/systemd/zram-generator.conf
sudo systemctl daemon-reload
# (optional) sudo apt remove systemd-zram-generator
#   verify: zramctl -> empty ; swapon --show -> only /swap.img
```

Both swappiness and the zram device are also wiped by a plain reboot if the files are gone; the configs above make them survive reboots.

## Verification checklist (after all three)

```bash
swapon --show     # /dev/zram0 prio 100 (16G)  +  /swap.img prio -2 (8G)
zramctl           # zstd, DISKSIZE ~16G
sysctl vm.swappiness vm.page-cluster          # 150, 0
systemctl cat user@.service | grep ManagedOOMMemoryPressureLimit   # 80%
oomctl | grep Duration                                            # 30s
```

## Test log

| Date | Event | Outcome |
|---|---|---|
| 2026-06-17 | baseline incident | `systemd-oomd` killed `chrome-lapc506` (4.2 GB) at 85.61% > 50% for >20s; 22 GB RAM still available; no zram present |
| _pending_ | apply zram + oomd drop-ins | _watch `journalctl -u systemd-oomd` over a heavy Chrome/build session; expect zram to fill first and no kill_ |

## References

- `systemd-zram-generator` (the modern zram-on-systemd method): <https://github.com/systemd/zram-generator>
- `oomd.conf(5)` / `systemd-oomd` PSI-based killing: <https://www.freedesktop.org/software/systemd/man/latest/systemd-oomd.service.html>
- Pressure Stall Information (PSI), what oomd reads: <https://docs.kernel.org/accounting/psi.html>
- zram swappiness guidance (why high, not low): Fedora's `zram-generator` defaults + kernel `zram` docs <https://docs.kernel.org/admin-guide/blockdev/zram.html>
- Sibling memory/host-health runbooks on this machine: [`Ubuntu_Chrome_Memory_Saver_All_Profiles`](../Ubuntu_Chrome_Memory_Saver_All_Profiles), [`Ubuntu_GNOME_Mutter_Internal_Panel_Drop_False_Freeze`](../Ubuntu_GNOME_Mutter_Internal_Panel_Drop_False_Freeze)
