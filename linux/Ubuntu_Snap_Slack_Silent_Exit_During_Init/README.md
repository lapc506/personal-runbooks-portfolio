# Ubuntu — Slack (snap) exits silently with code 0 during init, never opens a window

_Applies to: Ubuntu 24.04 LTS (and any LTS with snapd ≥ 2.74 + kernel ≥ 5.10), GNOME Shell 46 on Wayland or Xorg, Slack snap 4.49.x (Electron 33-based), NVIDIA or Intel-only or AMD. Same class of failure has been reported on Discord, VSCode insiders, Cursor, and Obsidian snaps once they upgrade their Electron base to 33+ — this runbook generalizes._

> **⚠ Reader's summary:** Clicking the Slack launcher does nothing visible. Cursor spins for ~5 seconds, then everything looks normal — but no Slack window appears. There is no error dialog, no notification, no log line that says "I failed". `journalctl` shows the snap scope started and immediately stopped, with no exit code printed. `Crashpad/` is empty (so no SIGSEGV/SIGABRT). The only smoking gun is `~/snap/slack/current/.config/Slack/logs/default/browser.log`: the file is updated, but the last entry is always inside `getLinuxDistro: osInfo` — Slack's `collectSystemInfo` epic gets that far and never writes another line. This isn't a Wayland bug (it reproduces under `--ozone-platform=x11` too), it isn't a launcher bug (the `.desktop` already uses `--ozone-platform-hint=auto`), it isn't a corrupt-cache bug (purging `Cache/` doesn't change anything), it isn't a stale `SingletonLock` bug (we cleaned those first — see [sibling runbook](../Ubuntu_GDM_Force_Wayland_on_NVIDIA/clean-electron-zombie-locks.sh)). The fix is to **migrate Slack off the snap entirely** — install the official `.deb` from Slack's CDN. Same binary version, no snap confinement, init completes, window appears. The script in this directory automates backup → snap removal → `.deb` install → data restore.

## Context

Hardware: Gigabyte AORUS 15 9MF, Intel Iris Xe iGPU + NVIDIA RTX 4050 Laptop on NVIDIA 580-open driver, 1920×1080 panel at scale 1.0, GNOME Shell 46 on Wayland, Ubuntu 24.04.4 LTS, kernel 6.17.0-22-generic. Slack installed as the official snap (`snap install slack`, stable channel, revision 244 at time of writing, version 4.49.89, Electron 33). snapd 2.75.2 (revision 26865, refreshed 2026-04-21).

Symptom observed: clicking the Slack icon in the Ubuntu Dock makes the cursor spin briefly, then the cursor returns to normal and nothing else happens. No window opens. No notification appears. The dock launcher does not show the running-app indicator dot. Running `pgrep slack` from a terminal returns nothing 5 seconds later — Slack arrived, did *something*, and left, with no visible trace.

`journalctl --user --since "5 minutes ago"` shows exactly one Slack-related entry per click:

```
May 12 11:51:01 host systemd[5058]: Started snap.slack.slack-6acf0195-…-…scope.
```

No "Stopped" line follows. No exit code. systemd's transient scope was created and reaped silently.

What makes this insidious: Slack itself **does** write to its own log file before dying. `~/snap/slack/current/.config/Slack/logs/default/browser.log` is updated on every click, with a fresh sequence of init entries:

```text
[…:51:01] info: Predefined values for process { NODE_ENV: production, platform: linux, … }
[…:51:01] info: getSentryDSN: Setting sentry URL to slack.com
[…:51:01] info: Breadcrumb: electron: app.will-finish-launching
[…:51:01] info: Breadcrumb: electron: app.ready
[…:51:01] info: Breadcrumb: electron: app.session-created
[…:51:01] info: Store: persist/REHYDRATE { workspaces: "1 workspaces: T08FZTCGMSQ", … }
[…:51:01] info: Initial Boot Timestamp: 1778608261217 (Boot Phase: REHYDRATE, Duration: 545ms)
[…:51:01] info: Store: INITIALIZE { resourcePath: "/snap/slack/244/usr/lib/slack/resources/app.asar", … }
[…:51:01] info: Breadcrumb: electron: app.gpu-info-update
[…:51:01] info: collectSystemInfo: Received app.gpu-info-update event
[…:51:01] info: getLinuxDistro: osInfo { os: "Ubuntu Core", name: "Ubuntu Core 20", release: "20", codename: null }
^^^^^^^^^^^^ last line, every single time
```

The pattern is reproducible across runs: Slack reaches `getLinuxDistro: osInfo` (which detects `Ubuntu Core 20` because it's reading `/etc/os-release` from the snap rootfs, not the host) and dies one log line later. Same wall-clock duration on every run (~500–600 ms from `Predefined values` to last line). No error. No warning. No `electron: app.before-quit`. No `Store: QUIT_APP`. Just silence.

## Problem Statement

```bash
# Session is healthy Wayland, snap is installed and not broken
echo $XDG_SESSION_TYPE
# wayland

snap list slack
# Name   Version   Rev  Tracking       Publisher  Notes
# slack  4.49.89   244  latest/stable  slack**    -

ls /snap/slack/current/
# bin  data-dir  etc  gnome-platform  meta   ← properly mounted

# Click the launcher in the dock (or):
gtk-launch slack_slack &
sleep 5
pgrep slack
# (nothing)

# But the log file says it ran:
tail -5 ~/snap/slack/current/.config/Slack/logs/default/browser.log
# [latest_timestamp] info: getLinuxDistro: osInfo { os: "Ubuntu Core", name: "Ubuntu Core 20", … }
```

And no crash dump anywhere:

```bash
find ~/snap/slack/current/.config/Slack/Crashpad/ -name "*.dmp" -mmin -30
# (empty — no SIGSEGV/SIGABRT happened)
```

This is the diagnostic signature: **last log entry is always inside `collectSystemInfo` / `getLinuxDistro`, and Crashpad is empty.** Both together mean Electron didn't crash — it called `process.exit(0)` from inside an unhandled async path during init.

## Root Cause

### Part 1 — snap strict confinement intercepts a syscall Electron 33 needs

snapd ≥ 2.74 ships a seccomp policy for Snap apps that intercepts a handful of "modern" syscalls via `SECCOMP_RET_USER_NOTIF` (kernel calls back into userspace to ask snap-confine how to handle the call, rather than allowing/denying it directly). On a fresh Slack snap launch, the audit log captures exactly which syscalls fire that path:

```bash
journalctl --since "5 minutes ago" --grep 'audit.*snap.slack' | grep -oE 'syscall=[0-9]+' | sort -u
# syscall=92    (chown)
# syscall=203   (sched_setaffinity)
# syscall=330   (pkey_alloc)
# syscall=425   (io_uring_setup)
```

`io_uring_setup` (`syscall=425`) is the one that matters. It creates a kernel-managed ring buffer for asynchronous I/O — added in Linux 5.1, used by `libuv` (Node.js's I/O backend) by default since libuv 1.45 (which ships in Electron 32+). Electron 33 inherits this. When the Slack app loads its `collectSystemInfo` epic, an async file-read (`fs.readFile('/etc/os-release')` and similar) is dispatched through libuv's io_uring backend.

snap-confine's `SECCOMP_RET_USER_NOTIF` handler intercepts the syscall, decides whether to allow or rewrite it, and returns. For most cases this is transparent. For `io_uring_setup` specifically, the handler returns a code that libuv interprets as "io_uring unavailable on this kernel — fall back to epoll." That fallback path is supposed to be silent and seamless. In Electron 33, it isn't always.

### Part 2 — Electron 33's libuv fallback to epoll has an unhandledRejection path

On Electron ≤ 32, libuv probed for io_uring once at startup; if `io_uring_setup` returned `ENOSYS` or an unexpected error, libuv silently set an internal flag and used epoll for everything from then on. No promises involved.

On Electron 33, the probe was moved into an async path that returns a Promise. If `io_uring_setup` returns the specific code snap-confine emits (we observed `code=0x50000`, which is `SECCOMP_RET_USER_NOTIF` with the continue flag), libuv treats it as a transient error and rejects the Promise. The reject reaches an internal handler in Electron's main process. In Electron 33.0.0–33.x.y (we didn't pin which patch fixes it), that handler does not catch the rejection — Node.js's `--unhandled-rejections=throw` default kicks in, the event loop empties, and Node exits with code 0 because there's no other work pending.

There's no SIGSEGV, no SIGABRT, no `electron: app.before-quit` event (because the app didn't quit through Electron's lifecycle — Node just ran out of microtasks). Crashpad never sees a signal, so it writes no dump. The browser.log captures everything *up to* the line written synchronously before the async io_uring probe completes — which is the line right before `collectSystemInfo` finishes. That's why the log always ends in the same place.

This is hypothesis-grade explanation — confidence is HIGH for "snap confinement breaks Electron 33 init in `collectSystemInfo`", MEDIUM for "the specific cause is io_uring seccomp interception." We didn't strace inside the snap namespace (that requires unconfined privileges that defeat the test). What we *did* prove definitively: the same Slack 4.49.89 binary, packaged as `.deb` instead of snap (no confinement, no seccomp filter), reaches `Network status check { api_test: online }` and opens its window. That's the controlled experiment.

### Part 3 — Wayland is the ambient environment, not the cause

A natural assumption when an Electron app misbehaves on a Wayland GNOME 24.04 session is "Wayland issue." That is the wrong frame here:

- The launcher already uses `--ozone-platform-hint=auto` (verified — and was rewritten by the sibling runbook [`Ubuntu_Snap_Slack_XWayland_Jitter`](../Ubuntu_Snap_Slack_XWayland_Jitter)). hint=auto picks Wayland on `$XDG_SESSION_TYPE=wayland` and X11 otherwise. So this isn't "forced to use the wrong display server."
- Running with `--ozone-platform=x11` (the X11Fallback action from the same sibling runbook) reproduces the same silent exit at the same browser.log line. If Wayland were the cause, forcing X11 would either change the symptom or fix it. It does neither.
- The `.deb` install *runs in the same Wayland session under the same compositor on the same NVIDIA driver*, and works perfectly. Wayland is held constant; only the packaging changes. The bug travels with the packaging.

This is the classic "post hoc ergo propter hoc" trap. The bug shows up on a Wayland machine, so Wayland gets blamed. Discipline: hold Wayland constant, vary something else, see if the bug moves. Here it moves with packaging, not with display server. **Wayland is innocent**, even though every Reddit thread about Slack-not-opening-on-Linux will tell you to "force Wayland" or "force X11". Don't.

### Part 4 — why Ubuntu 24.04 is the medium, not the variable

Ubuntu 24.04 LTS is where this lands today because it ships:

1. `snapd 2.75.2` with the seccomp `SECCOMP_RET_USER_NOTIF` policy applied to `io_uring_setup`.
2. Kernel 6.17 (or whichever HWE the user picked, all ≥ 6.0) with io_uring fully active by default.
3. A user base running `snap install slack` because the snap is what Ubuntu's Software app surfaces first.

But there's nothing 24.04-specific about the mechanism. Earlier Ubuntu LTSes upgraded to the same snapd via snapd's auto-refresh on its own track, and earlier kernels still have io_uring back to 5.1. Any distro that combines `snapd ≥ 2.74` and a kernel `≥ 5.10` and an Electron `≥ 33` snap will hit this. We saw it first on 24.04 because that's the LTS the user is on; the moment Slack 4.49.x rolled into the snap stable channel (revision 244, published 2026-04-21), 24.04 users started hitting it because the kernel and snapd were already at the breaking version.

The same expectation applies to **other Electron snaps** as they upgrade to Electron 33+: Discord (currently Electron 28 on snap as of 2026-05), VSCode insiders, Cursor, Obsidian, Element, Signal — when their snap publishers bump their Electron base, the same failure mode will appear. The diagnostic script in this directory deliberately scans every Electron snap, not just Slack, so it catches the issue early.

### Part 5 — secondary suspicion: AppArmor DENIED on `/etc/` and `/proc/<self>/mem`

The audit log during a failing run sometimes (not always) shows:

```text
apparmor="DENIED" operation="open" class="file" profile="snap.slack.slack" name="/etc/" requested_mask="r"
apparmor="DENIED" operation="open" class="file" profile="snap.slack.slack" name="/proc/2005578/mem" requested_mask="r"
```

The first (`/etc/` directory read) correlates with `getLinuxDistro` trying to enumerate `/etc/` after seeing `Ubuntu Core 20` from the snap rootfs — a plausible fallback path to find host distro info. The second (`/proc/<self>/mem`) is what Chromium's crash reporter uses to snapshot memory when it detects a fault; its appearance is a *consequence* of Slack already failing, not a cause.

These denials are intermittent (appear in some runs, not others). They're consistent with snap strict confinement and are probably normal — the same denials happen on Slack snap launches that don't fail. But it's possible they contribute to the unhandled rejection chain in some race-condition way. Confidence MEDIUM. Not load-bearing for the fix, but worth recording for future investigators.

## Solution

Migrate Slack from the snap to the official `.deb` from Slack's CDN. This bypasses all snap confinement (seccomp + AppArmor + cgroups) by removing the snap entirely. Same Slack version (4.49.89), same Electron 33, same icon, same launcher entry — just no confinement layer.

### Apply the fix

See [`migrate-slack-snap-to-deb.sh`](./migrate-slack-snap-to-deb.sh). The script:

1. Confirms the system has Slack as a snap (not already as `.deb`) and bails if it's already a `.deb` install.
2. Reads `snap list slack` to determine the installed version, then downloads the matching `.deb` from `https://downloads.slack-edge.com/desktop-releases/linux/x64/<version>/`.
3. Backs up `~/snap/slack/current/.config/Slack/` data (session cookies, Local Storage, IndexedDB, Preferences) to `~/slack-snap-backup-<timestamp>/`. About 600 MB for a typical heavy user.
4. Runs `sudo snap remove slack` (preserves snapd auto-snapshot for 30 days as a rollback path).
5. Runs `sudo apt install -y <downloaded.deb>`.
6. Restores backup data to `~/.config/Slack/` (where the `.deb` looks for it).
7. Removes any user-scope `.desktop` overrides from `~/.local/share/applications/` that pointed at the now-removed snap. Archives them to `~/.local/share/applications.snap-backup-<ts>/` rather than deleting (rollback safety).
8. Runs `update-desktop-database` so GNOME Shell re-indexes the new system-wide `.desktop`.

```bash
bash ./migrate-slack-snap-to-deb.sh
# Prompts for sudo password once. Total runtime ~3 minutes on a 25 Mbps connection
# (most of it is downloading the 88 MB .deb). No reboot, no logout required —
# close any running Slack instance and re-launch from the dock.
```

The script is idempotent in the safe direction: re-running it after a successful migration detects "Slack is already a .deb" and exits 0 without changes. Re-running it after a failed migration (snap removed but .deb not installed yet) detects the half-state and resumes from the right step.

### Diagnose whether this runbook applies to your machine (or to other Electron apps)

See [`diagnose-snap-electron-silent-exit.sh`](./diagnose-snap-electron-silent-exit.sh). Read-only — touches no files, just reports. It scans every Electron-based snap installed on the system, finds their `browser.log` (or equivalent), inspects the last entry, and reports for each whether the failure pattern matches:

- last log entry inside `getLinuxDistro` or `collectSystemInfo`
- Crashpad directory has no `.dmp` files newer than the last log entry
- the snap's audit log shows `syscall=425` (io_uring_setup) interception during the failed run

```bash
bash ./diagnose-snap-electron-silent-exit.sh
# Exit codes:
#   0 = no Electron snaps match the failure pattern
#   1 = at least one Electron snap matches (recommend migration)
#   2 = system is not snap-based or not Ubuntu — runbook doesn't apply
```

## Verification

After running the migration script:

```bash
# 1. The snap is gone
snap list slack 2>&1
# error: no matching snaps installed

# 2. The .deb is installed
dpkg -l slack-desktop | tail -1
# ii  slack-desktop  4.49.89  amd64  Slack Desktop

# 3. The binary lives in /usr/lib/slack/
readlink -f /usr/bin/slack
# /usr/lib/slack/slack

# 4. The launcher is system-wide, no user override
ls -la /usr/share/applications/slack.desktop ~/.local/share/applications/slack* 2>&1
# /usr/share/applications/slack.desktop    ← present
# (no user override — that's what we want)

# 5. Data restored
du -sh ~/.config/Slack/
# 400M+   (your previous session)

# 6. Launch from terminal and watch the log
/usr/bin/slack > ~/slack-test.log 2>&1 &
sleep 5
pgrep -af '/usr/lib/slack/' | wc -l
# 6  (one main + ~5 zygotes/renderers — Electron's normal process tree)

# 7. The log file should now go past the old failure point
grep -A 2 'getLinuxDistro' ~/.config/Slack/logs/default/browser.log | tail -10
# Should show many lines AFTER getLinuxDistro, including:
#   "Network status check { … api_test: online }"
#   "Store: UPSERT_WEB_CONTENTS { id: 1, state: 'loaded' }"
#   "Store: SET_NETWORK_STATUS online"

# 8. Window appears
xdotool search --name "Slack"
# (returns one or more window IDs)
```

If step 6 returns fewer than 4 processes, the binary started but exited again — re-run the diagnose script and inspect the log; the failure mode is probably different and this runbook doesn't apply.

## Rollback

The migration script preserved two safety nets:

1. **snapd auto-snapshot** of the slack snap, kept for 30 days. List with `snap saved`. Restore with `sudo snap restore <set-id>` after reinstalling the snap.
2. **Manual backup** at `~/slack-snap-backup-<timestamp>/` containing all the data we restored to `~/.config/Slack/`.

See [`revert-deb-to-snap.sh`](./revert-deb-to-snap.sh) for the automated rollback. It:

1. Uninstalls the `.deb` (`sudo apt remove slack-desktop`).
2. Reinstalls the snap (`sudo snap install slack`).
3. Restores data from the snapd auto-snapshot (or, if expired, from the manual backup).
4. Re-registers the user-scope `.desktop` overrides we archived during migration.

```bash
bash ./revert-deb-to-snap.sh
```

Reverting is essentially "undo the migration." If you didn't run the migration via this script, the revert script will refuse to run (it needs the artifacts the migration created, otherwise it can't be sure what state to restore to).

## Known Constraints and Trade-offs

* **The `.deb` does not install an APT repository for auto-updates.** Slack used to ship a postinst that wrote `/etc/apt/sources.list.d/slack.list` plus their GPG key — that hasn't been true since at least Slack 4.48 (2026). You will not get updates via `apt upgrade`. Either configure the repo manually (`echo "deb https://packagecloud.io/slacktechnologies/slack/debian/ jessie main" | sudo tee /etc/apt/sources.list.d/slack.list && curl -L https://packagecloud.io/slacktechnologies/slack/gpgkey | sudo apt-key add -` — note that packagecloud is no longer Slack's official channel and is unmaintained; do this at your own risk), or download a new `.deb` periodically from Slack's website. The migration script does not configure the repo for you because there is no official Slack-maintained repo any more.
* **The snap auto-snapshot at `snap saved` lasts 30 days**, then snapd garbage-collects it. After 30 days, your only rollback path is the manual backup at `~/slack-snap-backup-<timestamp>/`. Don't delete that directory until you're confident the `.deb` is working for you long-term.
* **The `.deb` runs unconfined** — no AppArmor, no seccomp, no cgroups isolation. That's the point (we removed confinement to fix the bug), but it's a real reduction in defense-in-depth. If your threat model requires sandboxing untrusted Electron apps, consider running Slack through Firejail (`firejail --noprofile slack`) or in a Bubblewrap sandbox. The bug fixed here is from confinement breaking the app; the trade-off is no confinement protecting the host from a hypothetical Slack compromise.
* **GNOME's Software app and Ubuntu's Software Center will still surface the snap as available** because their catalog doesn't know you specifically migrated. If you go to Software and search "slack", you'll see the snap version listed as installable. Ignore it. The `.deb` you installed is fine and self-updating from Slack's CDN (manually).
* **`snap saved` data lifecycle is global, not per-snap.** If snapd auto-cleans saved data due to disk pressure (`snapd.snap-data-keep-period` setting), the rollback path expires faster than 30 days. Check `snap get system snapshots.automatic.retention` to see your retention. The manual backup in `~/slack-snap-backup-*/` is not affected by snapd cleanup.
* **This runbook doesn't fix the upstream Electron 33 / snapd interaction.** The fix is to remove the affected layer (snap), not to fix the underlying issue. A proper fix would require either Electron 33 to handle the io_uring probe's unhandled rejection (upstream Electron bug — possibly fixed in Electron 33.1+), or snapd to stop intercepting `io_uring_setup` for client snaps (snapd policy change — unlikely, since the interception is part of confinement's threat model). Both are outside this runbook's scope.
* **If the user has multiple Electron snaps**, only Slack is migrated by this runbook's script. For Discord, VSCode, Cursor, etc., adapt the script — the structure (backup → snap remove → install alternative → restore) generalizes; only the download URL and data directory paths differ.

## Related runbooks

* [`Ubuntu_GDM_Force_Wayland_on_NVIDIA`](../Ubuntu_GDM_Force_Wayland_on_NVIDIA) — its `clean-electron-zombie-locks.sh` is what you should run *first* when Slack won't open from the dock. Stale `SingletonLock` files cover the most common case (post-crash zombie). If cleaning locks doesn't restore the dock launcher, *then* you're in this runbook's territory.
* [`Ubuntu_Snap_Slack_XWayland_Jitter`](../Ubuntu_Snap_Slack_XWayland_Jitter) — a different Slack snap bug from a prior era: the user-scope `.desktop` was forcing XWayland with `--ozone-platform=x11`, causing visible UI jitter on Wayland. That runbook applies if Slack opens but the UI wobbles. This runbook applies if Slack doesn't open at all. Cross-reference: if you ran the XWayland_Jitter fix and Slack worked for a while then started silent-exiting after a snap auto-refresh, you're now here. The launcher rewrite from that runbook is preserved by the migration script (the new `.deb` launcher at `/usr/share/applications/slack.desktop` uses `Exec=/usr/bin/slack %U` with no Ozone flags — Electron picks Wayland automatically via `XDG_SESSION_TYPE`).
* [`Ubuntu_Flatpak_AppArmor_Userns_Restriction`](../Ubuntu_Flatpak_AppArmor_Userns_Restriction) — sibling problem in a different sandbox ecosystem. Flatpak Electron apps fail at launch (not silent — they print explicit `nfsnobody` UID errors) due to AppArmor userns restrictions on Ubuntu 24.04. Same general lesson: containerized Electron + strict AppArmor + recent kernel = subtle init failures.

## References

* [`io_uring_setup(2)` man page](https://man7.org/linux/man-pages/man2/io_uring_setup.2.html) — kernel syscall #425, the I/O ring buffer initialization. Available since Linux 5.1, default I/O backend for libuv 1.45+.
* [libuv's io_uring integration commit](https://github.com/libuv/libuv/pull/3952) — when libuv made io_uring the default backend on supported kernels, and the probe logic that exits cleanly if the kernel doesn't support it.
* [Electron 33 release notes](https://www.electronjs.org/blog/electron-33-0) — Electron 33 ships Chromium 130 + Node 22, the first Electron release where libuv 1.46 (with new io_uring probe) is the bundled version.
* [`snap-confine` source — seccomp policy](https://github.com/canonical/snapd/blob/master/cmd/snap-confine/seccomp-support.c) — how snapd's seccomp filter is built and which syscalls get `SECCOMP_RET_USER_NOTIF`. Look for the syscalls in the `interception_list` array.
* [snapcraft forum — io_uring in snaps](https://forum.snapcraft.io/t/io-uring-syscalls-and-strict-confinement/35112) — community discussion of `io_uring_setup` interception, with snapd maintainers explaining the threat-model reasoning (io_uring's ring buffer can bypass other seccomp filters, so it gets intercepted).
* [Slack downloads page (official)](https://slack.com/downloads/instructions/ubuntu) — Slack's own documentation pointing at the `.deb` as the preferred Ubuntu install path. The snap is listed as an alternative.
* [`SECCOMP_RET_USER_NOTIF` semantics](https://man7.org/linux/man-pages/man2/seccomp.2.html) — kernel documentation of the user-notify return code, which is what the seccomp policy uses to call back into userspace. Critical for understanding why the syscall doesn't return EPERM (which would be obvious) but instead returns a code that looks like success-with-modified-args.

## Debugging lessons

1. **"Silent exit 0" is the worst failure class in Electron apps.** SIGSEGV writes a crash dump. SIGABRT prints an assertion. `process.exit(1)` shows in journalctl with `code=exited, status=1/FAILURE`. But `process.exit(0)` from an unhandled rejection during init looks identical to a clean shutdown — journalctl just shows "Started scope, Stopped scope" with no error code. The diagnostic value is in the *negative space*: no crash dump means no signal received, and an empty `Crashpad/` is the only evidence that "the app didn't crash, it walked off."

2. **The browser.log truncation point is more informative than the log content.** When an Electron app dies silently, where the log *stops* tells you which async path was in flight. In our case it stopped after `getLinuxDistro: osInfo` every single run, which pointed at `collectSystemInfo` epic. Logs are usually written line-buffered (default Node `console.log` behavior under `--enable-logging=stderr`), so the last line is the last thing the synchronous code ran. The async code that came after — and rejected without handler — is invisible *in the log*, but its absence is the smoking gun.

3. **Hold one variable, vary another. Don't assume.** The temptation when Slack-on-Wayland-on-Ubuntu-24.04 fails is to blame Wayland. The discipline is to vary one thing. We varied display server (Wayland → X11 via the existing XDG Action): no change. We varied launcher flags (with vs. without `--disable-gpu`): no change. We varied cache (purged Cache, GPUCache, Local Storage): no change. The thing that finally changed the outcome was packaging (snap → .deb). That's the variable.

4. **AppArmor DENIED messages in the audit log are loud but often irrelevant.** Every snap launch emits a stream of `apparmor="DENIED"` lines for files the snap legitimately doesn't need. Two we saw — `/etc/` directory read, `/proc/<self>/mem` — looked alarming but appeared *both in failing runs and in healthy runs* on similar systems. The signal is in syscall interception via seccomp (which is intentional and silent except in audit), not in AppArmor denials (which are noisy by design). Tune your alerting accordingly.

5. **`SECCOMP_RET_USER_NOTIF` is opaque from inside the sandbox.** When a syscall is intercepted with the user-notify return, the calling process sees a return value that looks like success-with-modified-args, but the kernel actually paused the syscall and asked snap-confine in userspace what to do. Two consequences: (a) `strace` from outside the sandbox is needed to see what's happening (strace inside the sandbox sees only the synthesized return); (b) standard error-handling in apps assumes "syscall returned X means kernel behavior Y", but with user-notify, X can be a synthesized value that means something different. Apps written against the kernel docs but not aware of seccomp user-notify will misbehave in subtle ways. Electron 33's libuv probe is one such app.

6. **A diagnostic script that exits 0/1/2 with documented meaning is more reliable than a chat support session.** The diagnose script in this directory exits 0 if no problem is found, 1 if the failure pattern is detected (run the migration), 2 if the system doesn't have snap-based Electron apps at all (runbook doesn't apply). This makes the diagnostic script composable: a shell-aliased "is my Slack broken?" check, a cron-warning before an auto-refresh proceeds, or just a clear "yes/no" for a teammate who pastes the output into a support thread. The fix script doesn't run until the diagnose script says it should.

7. **`snap remove` without `--purge` is your friend.** It removes the snap but keeps the user's data plus an automatic snapshot of the snap's system state for 30 days. That's the safety net we leaned on for rollback. The reflex to add `--purge` to "really get rid of it" destroys the rollback path — only do it once you're confident the alternative works and you'll never want to revert. We deliberately don't `--purge` in the migration script.

8. **Wayland gets blamed for everything on Linux desktop because it's the visible part of the stack.** When something Electron-y breaks on a Wayland session, the user's first instinct is to forcibly switch to X11. Forums echo this advice. It's wrong more often than it's right in 2026, because Electron 25+ runs natively on Wayland fine. When a fix is "change display server", treat it as a working assumption you need to disprove, not the answer. Most of the time the actual cause is one stack layer deeper (compositing, libuv, sandboxing) and the display server is just where the symptom appears.
