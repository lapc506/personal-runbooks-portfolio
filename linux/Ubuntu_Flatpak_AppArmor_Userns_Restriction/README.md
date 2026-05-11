# Ubuntu 24.04 — Flatpak Chromium/QtWebEngine apps blocked by AppArmor userns restriction

_Applies to: Ubuntu 24.04 LTS (kernel 6.8+ but easiest to reproduce on 6.17.x), Flatpak 1.14.x, bwrap 0.8.x, and any flatpak that ships QtWebEngine (ZapZap, KaOS Signal, Element Desktop) or Chromium/Electron (Slack flatpak, Discord flatpak, Obsidian flatpak, Joplin flatpak, Chromium itself as a flatpak)._

> **⚠ Reader's summary:** a freshly-installed flatpak app exits immediately after launch with a cascade of EGL / ANGLE / QRhi errors. The errors look like GPU driver mismatches and pull you toward installing `org.freedesktop.Platform.GL.default` and `org.freedesktop.Platform.GL.nvidia-*` extensions. Installing them changes nothing — because the root cause is not GPU-related at all. Ubuntu 24.04 ships with `kernel.apparmor_restrict_unprivileged_userns=1` by default, which blocks `bwrap` (the sandbox flatpak uses) from setting up the user-namespace UID mapping its runtime depends on. Inside a broken sandbox, `/dev/dri/*` appears owned by `nfsnobody`, fontconfig can't find its config, dbus can't reach the system bus, and the display stack collapses end-to-end. The fix is a single sysctl toggle that disables Ubuntu's mitigation for CVE-2023-2640 / CVE-2023-32629. That's the trade-off the operator must accept: functional flatpak apps in exchange for returning to pre-23.10 user-namespace behavior.

## Context

A freshly upgraded Ubuntu 24.04.4 laptop (Gigabyte AORUS 15 9MF, kernel 6.17.0-22-generic, Intel Iris Xe + NVIDIA RTX 4050 on Wayland). The workflow was:

1. Uninstall the unmaintained WhatsDesk snap (Electron 5-era, publisher `zerkc`, frozen since 2022) because it was segfaulting on the recent kernel.
2. Install [ZapZap](https://github.com/zapzap-linux/zapzap) as a replacement — a Qt6-based WhatsApp-on-Linux client packaged as a flatpak on Flathub (`com.rtosta.zapzap`).
3. Launch it. Nothing opens. The terminal prints ~40 lines of GPU/EGL errors and exits.

The same class of failure shows up with other flatpak apps that embed a web engine: Slack, Discord, Element, Obsidian — anything wrapping Chromium or QtWebEngine.

## Problem Statement

```bash
flatpak run com.rtosta.zapzap
```

produces, in order:

```
Fontconfig error: Cannot load default config file: No such file: (null)
qt.qpa.wayland: EGL not available
QRhiGles2: Failed to create temporary context
QRhiGles2: Failed to create context
[...] Failed to connect to the bus: Failed to connect to socket /run/dbus/system_bus_socket: No such file or directory
[...] ANGLE Display::initialize error 12289: Failed to get system egl display
[...] eglInitialize OpenGL failed with error EGL_NOT_INITIALIZED, trying next display type
[...] eglInitialize OpenGLES failed with error EGL_NOT_INITIALIZED
[...] Initialization of all EGL display types failed.
[...] GLDisplayEGL::Initialize failed.
QQuickWidget: Attempted to render scene with no rhi
GLOzone not found for unknown
```

And the app exits without drawing a window.

Symptom reads like "GPU driver missing inside sandbox". It's not.

## Root Cause

### The misleading surface symptom

The EGL / ANGLE errors come from three separate Qt subsystems all failing in the same way:

1. **QtQuick (`QRhiGles2`)** — Qt's Rendering Hardware Interface tries to open a GL context via Mesa's libEGL; gets `EGL_NOT_INITIALIZED`.
2. **QtWebEngine (`ANGLE`)** — embedded Chromium tries ANGLE → OpenGL → OpenGLES → SwiftShader; every backend returns the same `Failed to get system egl display`.
3. **QPA Wayland plugin** — Qt's Wayland integration reports `EGL not available` before even attempting EGL initialization.

All three reach the host's `libEGL_mesa.so.0` through the flatpak runtime, and all three fail at the same call (`eglGetDisplay(EGL_DEFAULT_DISPLAY)`). Classic GPU-extension-missing stacktrace.

Natural first hypothesis: install the matching GL extensions at the runtime branch ZapZap uses.

```bash
flatpak info com.rtosta.zapzap | grep Runtime
# → Runtime: org.kde.Platform/x86_64/6.10     (based on freedesktop 25.08)

flatpak install --user --assumeyes flathub \
    org.freedesktop.Platform.GL.default//25.08 \
    org.freedesktop.Platform.GL.nvidia-580-126-09
# (the exact nvidia version matches `nvidia-smi` driver output, 580.126.09)
```

**Both extensions install cleanly. Re-run zapzap. Identical errors. Zero change.**

### The real symptom: `nfsnobody` inside the sandbox

Inspect the sandbox's view of `/dev/dri/`:

```bash
flatpak run --command=sh com.rtosta.zapzap -c 'ls -la /dev/dri/'
```

```
drwxr-xr-x   3 nfsnobody nfsnobody      140 Apr 21 04:59 .
drwxr-xr-x  21 nfsnobody nfsnobody     8780 Apr 21 14:28 ..
drwxr-xr-x   2 nfsnobody nfsnobody      120 Apr 21 04:59 by-path
crw-rw----+  1 nfsnobody nfsnobody 226,   1 Apr 21 14:35 card1
crw-rw----+  1 nfsnobody nfsnobody 226,   2 Apr 21 14:35 card2
crw-rw----+  1 nfsnobody nfsnobody 226, 128 Apr 21 14:35 renderD128
crw-rw----+  1 nfsnobody nfsnobody 226, 129 Apr 21 14:35 renderD129
```

Every device and directory under `/dev/dri/` inside the sandbox is owned by `nfsnobody:nfsnobody`. On a healthy flatpak sandbox these are owned by `root:video` or `root:render` — the same as on the host, because bwrap bind-mounts them and preserves ownership via user namespace mapping.

`nfsnobody` ownership is the signal that **UID mapping into the user namespace did not take effect**. When a user namespace is requested but its uid_map / gid_map setup fails, the kernel degrades gracefully by showing every UID/GID as the overflow UID, conventionally displayed as `nfsnobody` (UID 65534). The sandbox is up, files are bind-mounted, but the per-process UID translation that lets the sandboxed processes interact with the bind-mounts as if they were root of their own namespace has been silently denied.

The consequence: `open("/dev/dri/renderD128")` fails with EACCES (the render group membership doesn't translate, so the bind-mounted device is inaccessible despite being present), fontconfig can't resolve `/etc/fonts/fonts.conf` (same mapping failure), dbus can't reach the system bus socket (same), and Chromium's sandbox layer on top of all of this falls over.

### Why the mapping fails: Ubuntu's AppArmor userns restriction

Ubuntu 23.10 added two kernel hardening controls aimed at containing the class of local-privilege-escalation exploits that use unprivileged user namespaces as a stepping stone (CVE-2023-2640, CVE-2023-32629, and the OverlayFS family of userns-assisted attacks). By 24.04 they are the default:

```bash
cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns
# → 1
```

This sysctl tells AppArmor to **deny `CAP_SYS_ADMIN` equivalents to every unprivileged user-namespace creator unless it's covered by a named AppArmor profile that opts in**. Out of the box, Ubuntu 24.04 ships a handful of such profiles (`chrome`, `firefox`, a generic one for the system `bwrap`), but they don't cover the `bwrap` binary that flatpak ships inside its own runtime or that lives at `/usr/bin/bwrap` in certain install paths.

For the affected flatpaks, the sequence is:

1. `flatpak run` → spawns `bwrap`.
2. `bwrap` → calls `unshare(CLONE_NEWUSER)`. Kernel allows it (userns is not globally disabled).
3. `bwrap` → writes to `/proc/self/uid_map` to map UID 1000 → 0 inside the namespace. **AppArmor LSM hook refuses the write silently** because the process is not covered by a userns-allowing AppArmor profile and `apparmor_restrict_unprivileged_userns=1`.
4. The sandbox starts anyway. Every file inside it shows UID 65534 (overflow) because no mapping entry exists.
5. Access to bind-mounted devices fails with EACCES. libEGL, fontconfig, dbus all wedge.
6. The app exits in a storm of unrelated-looking errors.

The silent denial in step 3 is what makes this hard to diagnose. There's no log entry in `dmesg`, no line in `/var/log/audit/audit.log` (unless audit is explicitly configured to log AppArmor denials, which Ubuntu 24.04 does not do by default). The app's stderr contains only the downstream symptoms.

## Solution

One sysctl toggle. It can be applied temporarily (survives until reboot) or persistently via a drop-in file under `/etc/sysctl.d/`.

### Temporary fix (survives until reboot)

```bash
sudo sysctl kernel.apparmor_restrict_unprivileged_userns=0
```

Then relaunch the flatpak app. No logout needed. No flatpak re-install needed.

### Persistent fix

See [`fix-apparmor-userns-persistent.sh`](./fix-apparmor-userns-persistent.sh). The script writes a drop-in at `/etc/sysctl.d/60-apparmor-userns.conf` and re-runs `sysctl --system` so the change takes effect without a reboot. The filename uses `60-` so it orders after `/usr/lib/sysctl.d/50-bubblewrap.conf` (which defaults to the restrictive value) — later files win on sysctl precedence.

```bash
sudo bash ./fix-apparmor-userns-persistent.sh
```

### Diagnostic helper (run before the fix, to confirm this runbook applies to your machine)

See [`diagnose-flatpak-userns.sh`](./diagnose-flatpak-userns.sh). The script:

1. Prints distro + kernel version.
2. Prints the two relevant sysctls (`apparmor_restrict_unprivileged_userns`, `unprivileged_userns_clone`).
3. Optionally runs a trivial flatpak command inside the sandbox and reports whether `/dev/dri/*` is owned by `nfsnobody` (the smoking gun).
4. Exits 0 if the symptoms match this runbook, exits 1 otherwise (so the reader doesn't apply a sysctl change for an unrelated issue).

```bash
bash ./diagnose-flatpak-userns.sh
```

## Verification

After applying either fix:

```bash
# 1. The sysctl is now 0
cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns   # → 0

# 2. Inside the sandbox, /dev/dri is owned by root, not nfsnobody
flatpak run --command=sh com.rtosta.zapzap -c 'ls -la /dev/dri/ | head -3'
# drwxr-xr-x   3 root root   140 Apr 21 04:59 .
# drwxr-xr-x  21 root root  8780 Apr 21 14:28 ..
# drwxr-xr-x   2 root root   120 Apr 21 04:59 by-path

# 3. The app launches and renders a window
flatpak run com.rtosta.zapzap
# Window appears. QR code visible. No EGL errors.
```

Also verify that other Chromium/Electron flatpaks that were affected (Slack, Discord, Element) now launch — this fix is global across every flatpak on the machine, not just the one you tested.

## Rollback

### Undo the temporary fix

Reboot. The sysctl returns to its default (1) automatically, because the drop-in file does not exist.

### Undo the persistent fix

```bash
sudo rm /etc/sysctl.d/60-apparmor-userns.conf
sudo sysctl kernel.apparmor_restrict_unprivileged_userns=1
# Verify:
cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns   # → 1
```

Note: reverting reactivates the mitigation for CVE-2023-2640 / CVE-2023-32629 but will also re-break every flatpak that relies on bwrap userns. Only revert if you have moved those apps off flatpak (to native packages, snaps, or web-based equivalents).

## Known Constraints and Security Trade-offs

* **This sysctl controls a real mitigation.** `kernel.apparmor_restrict_unprivileged_userns=1` was added to Ubuntu 23.10 to contain the LPE vectors that abuse user namespaces to gain `CAP_SYS_ADMIN`-equivalent inside the namespace, then pivot to host-level via OverlayFS or similar. Setting it to 0 returns to pre-23.10 behavior: unprivileged user namespaces can be created and their uid_map populated without AppArmor mediation. For a developer workstation with no untrusted local users this is an acceptable trade. **For a shared machine, a server, or any host where a local attacker would already be halfway-in, it is not.** Think about your threat model before deploying this fix in a fleet.

* **The proper long-term fix is a per-app AppArmor profile.** Ubuntu intends distro-shipped profiles to opt apps into userns access on a case-by-case basis. Writing a `/etc/apparmor.d/flatpak-bwrap` profile that allows userns capability transitions for `/var/lib/flatpak/exports/bin/*` and `/home/*/.local/share/flatpak/exports/bin/*` is the "blessed" path. At the time of this runbook (April 2026) no upstream profile ships for the user-scope flatpak bwrap path, which is why the sysctl toggle is still the pragmatic workaround.

* **Snap apps are unaffected.** snapd uses its own AppArmor confinement that predates the userns restriction and is separately carved out. If the goal is "run WhatsApp-style apps without disabling the mitigation", snap is a genuine alternative (e.g. `whatsapp-for-linux` snap, which is a different publisher from the dead WhatsDesk snap and is actively maintained).

* **`flatpak run` failures inside a VM are often confused with this issue.** Inside a guest with `kernel.unprivileged_userns_clone=0` or with a host-enforced seccomp profile blocking `unshare(CLONE_NEWUSER)`, the symptoms overlap with this runbook but the fix is different. Check `cat /proc/sys/kernel/unprivileged_userns_clone` — if it's 0, the issue is userns being globally disabled, not AppArmor restriction. `diagnose-flatpak-userns.sh` distinguishes between the two.

* **The NVIDIA + Wayland angle is a red herring here.** The failure reproduces identically on an Intel-only laptop with the iGPU as the only display adapter. NVIDIA is not the cause and not part of the fix. The reason it *felt* like a GPU problem is that Qt / Chromium's first interaction with the sandbox happens through the graphics stack — but anything else that the sandbox touches (fontconfig, dbus, pulseaudio) would fail at the same point; it's just less visible because those failures are not fatal and print less prominent errors.

## Related runbooks

* [`Ubuntu_GDM_Force_Wayland_on_NVIDIA`](../Ubuntu_GDM_Force_Wayland_on_NVIDIA) — adjacent territory: Wayland session wiring on NVIDIA hardware. If this runbook's fix enables a flatpak app that then fails to render because *the host's* GL stack (not the sandbox's) is mis-configured, cross-reference that runbook for the display-server layer.

## References

* [Ubuntu Blueprint — unprivileged user namespace restrictions](https://ubuntu.com/blog/ubuntu-23-10-restricted-unprivileged-user-namespaces) — the official write-up of the policy change in 23.10/24.04, with the threat model Canonical is trying to mitigate.
* [AppArmor upstream — `userns_restrict` profile flag](https://gitlab.com/apparmor/apparmor/-/blob/master/profiles/apparmor.d/abstractions/userns-accessible) — the abstraction Canonical ships that flatpak bwrap is *supposed* to inherit from but often doesn't at user scope.
* [Flathub issue tracker — bwrap + AppArmor userns on Ubuntu 24.04](https://github.com/flathub/flathub/issues/5200) — long-running thread with many repros, mostly resolved with the same sysctl workaround.
* [CVE-2023-2640 / CVE-2023-32629 — OverlayFS local root via userns](https://ubuntu.com/security/CVE-2023-2640) — the CVEs whose mitigation you're disabling. Read before deciding.
* [bubblewrap upstream — uid_map semantics](https://github.com/containers/bubblewrap/blob/main/README.md#user-namespaces) — the `bwrap` docs on exactly which syscalls it makes and which permissions they require.

## Debugging lessons

1. **Errors from three independent subsystems in the same stacktrace rarely mean three independent bugs.** QtQuick-Rhi, QtWebEngine-ANGLE, and QPA-Wayland all failing at `eglGetDisplay` within milliseconds of each other is a strong signal that they're not the cause — they're the first three things in the process that tried to touch the display stack. The real fault is upstream of all of them (in this case, the sandbox's view of the filesystem). When symptoms repeat across subsystems, look for a common dependency those subsystems share and inspect *that*.

2. **An installer that completes cleanly does not prove the component is wired in.** `flatpak install org.freedesktop.Platform.GL.default//25.08` finished with "Installation complete." but changed nothing because the sandbox couldn't reach those files regardless of whether they were on disk. Completion of an install step is evidence that the artifacts landed, not that they reached the consumer code path. Always verify by observing the runtime actually using the new artifact (e.g., via `strace -f`, `ltrace`, or a sandbox-inspection escape hatch like `flatpak run --command=sh`).

3. **UID 65534 / `nfsnobody` / `overflowuid` inside a container or sandbox is a diagnosis, not a display artifact.** It's the kernel's way of saying "I had to show you something for a UID that doesn't map to anything in this namespace". When you see it for files the sandbox is supposed to own, the user-namespace mapping is broken. When you see it for files that are legitimately unmapped (e.g., truly root-owned host files exposed read-only), it's benign. The difference is whether the sandbox's *own* processes also appear as `nfsnobody` in `ps` — if yes, the whole namespace is broken; if no, it's just the one file and the namespace is fine.

4. **Silent denials from an LSM (AppArmor, SELinux) are the hardest class of failure to attribute.** The kernel returns EACCES or EPERM but the denied call itself produces no log entry unless the operator has explicitly turned audit logging on for that subsystem. AppArmor's `restrict_unprivileged_userns` sysctl is particularly silent: the `unshare` succeeds, the `write` to `uid_map` returns -1 EPERM, and every downstream failure looks like an unrelated application bug. Rule of thumb: whenever a sandboxed process appears to lose capabilities it should have, check `dmesg -T | grep -i 'apparmor\|audit\|denied'` first, even if it's empty — and if the sysctls under `/proc/sys/kernel/apparmor_*` have non-default values, suspect them.

5. **When a distro ships a security mitigation that breaks a class of user-visible apps, the distro's own position on the trade-off is rarely neutral.** Canonical shipped `apparmor_restrict_unprivileged_userns=1` knowing it would break flatpak for many users, because they judged the CVE class as higher priority. Reverting the sysctl is an informed operator decision to disagree with that trade-off on your specific machine — it is not "fixing a bug". Frame it that way when documenting it, so future operators (including yourself) don't forget what they consented to.

6. **A sysctl named after an LSM is an instruction to that LSM, not a description of its behavior.** `kernel.apparmor_restrict_unprivileged_userns=1` reads as "AppArmor restricts unprivileged userns" (true), but the actual mechanism is "AppArmor's LSM hook on `uid_map` writes consults this flag and denies the write if the calling process is not in a userns-allowing profile". The flag name hides the profile-coverage detail, which is where the real complexity lives. If you ever need to fix this "properly" without disabling the mitigation globally, the work is in writing or installing an AppArmor profile that covers your specific bwrap invocation — not in toggling the flag.
