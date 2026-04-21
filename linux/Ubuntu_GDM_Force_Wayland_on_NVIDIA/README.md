# Ubuntu — Force Wayland session on GDM with NVIDIA proprietary driver

_Applies to: Ubuntu 24.04 LTS, GDM 46.x, NVIDIA driver 580-open (or any version ≥ 470), hybrid graphics (Intel iGPU + discrete NVIDIA)._

> **⚠ Reader's summary:** what looked like "tweak one config file" turned into a 3-attempt escalation. Each attempt uncovered a new layer of the problem. The final reliable fix is **Attempt 3** below. The earlier attempts are kept in the doc because they capture the failure modes you should expect to hit and why each intermediate fix alone is insufficient.

## Context

Standard user flow to switch GDM from X11 to Wayland is:

1. Uncomment `# WaylandEnable=false` in `/etc/gdm3/custom.conf` so Wayland is allowed
2. Logout → login screen → gear icon ⚙ → pick **"Ubuntu on Wayland"** → login

On Ubuntu 24.04 with NVIDIA hardware, three separate obstacles stack on top of each other:

1. **Canonical udev rule forces xorg preference.** `/usr/lib/udev/rules.d/61-gdm.rules` at boot writes `PreferredDisplayServer=xorg` in runtime-config for every NVIDIA machine not on a Dell SKU whitelist.
2. **Autologin hides the gear ⚙.** If `AutomaticLoginEnable=True`, GDM bypasses the login screen entirely, so the interactive session picker never appears.
3. **GDM session-list cache.** GDM enumerates `/usr/share/xsessions/` and `/usr/share/wayland-sessions/` exactly once at daemon startup. File changes after that don't propagate until gdm3 is restarted. Additionally, GDM deduplicates session entries by `Name=`, so multiple `.desktop` files with `Name=Ubuntu` collapse into a single picker entry — the winning one determined by `PreferredDisplayServer`.

Any single fix addresses only one of the three obstacles. All three need to be removed for the end-to-end flow to work.

## Problem Statement

Hardware: Gigabyte AORUS 15 9MF, RTX 4050 Laptop (NVIDIA driver 580.126.09-open), kernel 6.17.0-22-generic, Ubuntu 24.04.

Symptom: `echo $XDG_SESSION_TYPE` always returns `x11`. `loginctl show-session $XDG_SESSION_ID -p Type` confirms `Type=x11`, `GDMSESSION=ubuntu`.

## Root Cause

Read the Ubuntu GDM udev rule:

```bash
cat /usr/lib/udev/rules.d/61-gdm.rules
```

The critical branch for modern NVIDIA (driver ≥ 470):

```udev
# NVIDIA prefer Wayland on specific hardware platforms
SUBSYSTEM!="pci", GOTO="nvidia_pci_device_end"
ACTION!="add", ACTION!="bind", GOTO="nvidia_pci_device_end"
ATTR{vendor}!="0x10de", GOTO="nvidia_pci_device_end"
DRIVER!="nvidia", GOTO="nvidia_pci_device_end"

# Only a few Dell SKUs get GDM_PREFER_WAYLAND=1 whitelisted
ACTION!="remove", ATTR{[dmi/id]sys_vendor}=="Dell Inc.", ATTR{[dmi/id]product_sku}=="0D8[0-3]", ENV{GDM_PREFER_WAYLAND}="1"
ACTION!="remove", ATTR{[dmi/id]sys_vendor}=="Dell Inc.", ATTR{[dmi/id]product_sku}=="0DD4", ENV{GDM_PREFER_WAYLAND}="1"

# Anything else falls through to gdm_prefer_xorg
ACTION=="bind", ENV{GDM_PREFER_WAYLAND}!="1", GOTO="gdm_prefer_xorg"

LABEL="gdm_prefer_xorg"
RUN+="/usr/libexec/gdm-runtime-config set daemon PreferredDisplayServer xorg"
```

**Canonical hard-codes a runtime preference of X11 for every NVIDIA machine not on a Dell SKU whitelist.** This is a deliberate decision that prioritizes stability over features — sensible when NVIDIA + Wayland was unstable (pre-2022), but obsolete in 2026 with 580-open + kernel 6.17+.

## Solution attempts (in order of escalation)

### Attempt 1 — Three-layer udev override (did NOT work standalone)

See [`force-wayland-nvidia.sh`](./force-wayland-nvidia.sh).

The hypothesis was to apply three override layers:

1. **`/etc/udev/rules.d/62-gdm-prefer-wayland.rules`** — higher number than 61-gdm.rules, its `RUN+=` command should override the xorg preference on every boot.
2. **`PreferredDisplayServer=wayland` in `/etc/gdm3/custom.conf`** — persistent across apt upgrades.
3. **Immediate runtime override** via `gdm-runtime-config set daemon PreferredDisplayServer wayland` for the current boot.

**What actually happened on the test machine after running the script + logout + login:**

```bash
echo $XDG_SESSION_TYPE
# → x11

sudo /usr/libexec/gdm-runtime-config get daemon PreferredDisplayServer
# → error: the tool has no 'get' subcommand, only 'set'

sudo cat /run/gdm/runtime-config
# → No such file or directory

sudo journalctl -b 0 -u gdm | grep -iE "wayland|xorg|displayserver"
# → empty, GDM didn't log any display-server decision
```

**Interpretation:**

* `/run/gdm/runtime-config` does not even exist after boot. Either the file gets wiped, never gets created, or is irrelevant to GDM's actual session decision on 24.04+GDM 46.
* The runtime-config tool only supports `set` (no `get`), so the config mechanism cannot be introspected by admins. Signal that the interface may be partially deprecated upstream.
* GDM's autologin session decision in this version likely depends on an entirely different code path — hardcoded NVIDIA-detection inside the GDM binary, or a dconf key.

The three-layer script is still applied in the repo. It does not break anything, may help in future GDM versions, but **is not the primary fix.**

### Attempt 2 — Disable autologin + manual session pick (partially worked)

See [`wayland-plan-b.sh`](./wayland-plan-b.sh).

Strategy: temporarily disable autologin so GDM shows the login screen and the gear ⚙ icon becomes accessible. User picks "Ubuntu on Wayland" manually, logs in, then re-enables autologin. GDM remembers the manual choice in AccountsService.

**Steps:**

```bash
# 1. Disable autologin (script flips AutomaticLoginEnable → False)
bash ./wayland-plan-b.sh

# 2. CRITICAL: restart gdm3 so the daemon re-reads custom.conf.
#    Without this, gdm3 keeps the cached AutomaticLoginEnable=True
#    value from its own startup, so logout triggers autologin again.
sudo systemctl restart gdm3   # kills current session
# (or: reboot)

# 3. Login screen appears. Click your username. Before typing password,
#    click the gear ⚙ (bottom-right of the password field).
# 4. See the session picker.
# 5. Pick "Ubuntu on Wayland". Login.
```

**What actually happened:** the gear ⚙ appeared (so step 1 + 2 worked), **but the picker showed only two options**:

1. Ubuntu (radio selected)
2. Ubuntu on Xorg

No explicit "Ubuntu on Wayland" entry, despite `/usr/share/wayland-sessions/ubuntu-wayland.desktop` existing on disk with `Name=Ubuntu on Wayland`:

```bash
cat /usr/share/wayland-sessions/ubuntu-wayland.desktop
# [Desktop Entry]
# Name=Ubuntu on Wayland
# Exec=env GNOME_SHELL_SESSION_MODE=ubuntu /usr/bin/gnome-session --session=ubuntu
# ...
```

The user can click "Ubuntu" but it resolves to X11 (because `PreferredDisplayServer=xorg` is still in effect on runtime-config, undisturbed by the Attempt 1 overrides). Picking "Ubuntu on Xorg" is explicitly X11. Either choice lands in X11.

**Why "Ubuntu on Wayland" is missing from the picker** — GDM enumerates sessions exactly once at daemon startup. On a machine where GDM was already running when the Attempt 1 script added `PreferredDisplayServer=wayland` to `custom.conf`, GDM has the stale enumeration cached. Until GDM is restarted (which Attempt 2 didn't do on its own), the picker shows whatever GDM enumerated at its own startup time — in this case, a deduplicated list where the Wayland ubuntu.desktop merged with the X11 ubuntu.desktop under the single "Ubuntu" entry.

### Attempt 3 — Remove the xsessions/ubuntu.desktop alias + restart gdm3 (reliable)

See [`wayland-restart-gdm.sh`](./wayland-restart-gdm.sh).

Strategy:

1. Move `/usr/share/xsessions/ubuntu.desktop` out of the scan path. With only `/usr/share/wayland-sessions/ubuntu.desktop` remaining under `Name=Ubuntu`, there is no X11 alternative to dedupe with. "Ubuntu" in the picker becomes Wayland unambiguously.
2. `sudo systemctl restart gdm3` forces GDM to re-enumerate sessions from disk and re-read `custom.conf`. The restart kills the user's current X11 session, so all work must be saved first.

After restart, the picker shows three distinct entries:

- **Ubuntu** → Wayland (only version of `Name=Ubuntu` remaining)
- **Ubuntu on Wayland** → Wayland (explicit, from `ubuntu-wayland.desktop`)
- **Ubuntu on Xorg** → X11 (`xorg` escape hatch from `ubuntu-xorg.desktop`)

User picks any of the first two → Wayland session.

**Note:** the previous attempts (1 and 2) remain applied. The three-layer udev override + custom.conf + AccountsService `Session=ubuntu-wayland` work together with Attempt 3. Attempt 3 alone without those may also work, but the cumulative configuration is more resilient to future regressions (e.g., apt upgrades that re-introduce `xsessions/ubuntu.desktop`).

## Verification

After Attempt 3 + picking "Ubuntu on Wayland":

```bash
echo $XDG_SESSION_TYPE                          # → wayland
loginctl show-session $XDG_SESSION_ID -p Type   # → Type=wayland
xdpyinfo >/dev/null 2>&1 && echo "X11 direct" || echo "Wayland (no pure X11)"
```

Once confirmed, re-enable autologin so future logins skip the picker but stay in Wayland:

```bash
sudo sed -i 's|^AutomaticLoginEnable=False|AutomaticLoginEnable=True|' /etc/gdm3/custom.conf
# Logout. Next autologin uses the last-picked session (Wayland).
```

## Rollback

### Undo Attempt 3 (restore xsessions/ubuntu.desktop)

```bash
# From TTY (Ctrl+Alt+F3) if the GUI is broken:
sudo mv /usr/share/xsessions/ubuntu.desktop.claude-bak.<timestamp> /usr/share/xsessions/ubuntu.desktop
sudo systemctl restart gdm3
```

### Undo Attempt 1 (remove the three-layer overrides)

```bash
sudo rm /etc/udev/rules.d/62-gdm-prefer-wayland.rules
sudo sed -i '/^PreferredDisplayServer=/d' /etc/gdm3/custom.conf
sudo udevadm control --reload-rules
```

### Undo Attempt 2 (restore autologin)

```bash
sudo sed -i 's|^AutomaticLoginEnable=False|AutomaticLoginEnable=True|' /etc/gdm3/custom.conf
```

## Known Constraints

* **Driver version ≥ 470 required.** The same `61-gdm.rules` contains a branch that hard-disables Wayland for NVIDIA drivers below 470:
  ```udev
  ACTION=="bind", ENV{NV_MODULE_VERSION}=="4[0-6][0-9].*|[0-3][0-9][0-9].*|[0-9][0-9].*|[0-9].*", GOTO="gdm_disable_wayland"
  ```
  On 460 or older, Wayland is disabled entirely. This runbook cannot rescue that case.

* **`nvidia_drm.modeset=1` required.** If `/sys/module/nvidia_drm/parameters/modeset` is `N`, Wayland is hard-disabled by the same udev rule.

* **`gdm-runtime-config` appears legacy in GDM 46.** The binary has only `set`, no `get`. The file `/run/gdm/runtime-config` may not exist at all. Don't rely on that mechanism as the single fix.

* **AccountsService `XSession=` vs `Session=`.** Older AccountsService files may have both fields set. Removing or correcting both is necessary. Verify with `sudo cat /var/lib/AccountsService/users/<username>`. The GDM picker writes both correctly when the user manually picks a session via the gear ⚙.

* **`systemctl restart gdm3` kills the current session.** All running apps in the X11 session die. Chrome auto-restores tabs on next launch, but other apps with unsaved state lose it. `Ctrl+Alt+F3` gives you a TTY escape hatch during the restart window.

* **`dash-to-dock` / Ubuntu Dock may not respond immediately after `systemctl restart gdm3`.** The extension loses state when its host GNOME Shell dies and re-initializes on the new session. Clicks on pinned launchers may not register for a few seconds as the extension rehydrates. A second logout/login (after Wayland is confirmed) is a reliable way to reset the dock extension cleanly.

## References

* [GDM upstream (GNOME GitLab)](https://gitlab.gnome.org/GNOME/gdm)
* [Ubuntu 61-gdm.rules source (packaged in gdm3)](https://git.launchpad.net/~ubuntu-core-dev/ubuntu/+source/gdm3/) — see `debian/61-gdm.rules.in`
* [freedesktop.org — udev rule file ordering](https://www.freedesktop.org/software/systemd/man/latest/udev.html)
* [AccountsService spec — user session persistence](https://www.freedesktop.org/wiki/Software/AccountsService/)

## Debugging lessons

1. **Upstream-published mechanisms are not always wired to the consumer code path.** The udev-based runtime-config hook documented in GDM's own rules file turned out to not influence session selection in GDM 46 on Ubuntu 24.04 during the test. Always verify the full input-to-output chain before trusting an override.
2. **If a tool has `set` but no `get`, be suspicious of the mechanism.** You cannot audit what configuration a service has pulled from that file, so you cannot prove the override took effect.
3. **Display managers cache their session enumeration at daemon startup.** Editing `/usr/share/xsessions/` or `/usr/share/wayland-sessions/` after GDM has started requires a `systemctl restart gdm3` for GDM to notice. This also applies to dconf/gsettings schemas that GDM reads at its own startup.
4. **Session pickers dedupe by `Name=`.** If `/usr/share/xsessions/foo.desktop` and `/usr/share/wayland-sessions/foo.desktop` both have `Name=Foo`, the picker shows one entry, and which one executes depends on the display-server preference. Removing the X11 alias is a blunt but reliable way to force the Wayland version.
5. **When config-file hacking fails, let the app persist the choice itself.** GDM's gear ⚙ writes to AccountsService with the EXACT internal schema the autologin flow later consumes. Emulating that schema from outside is fragile; letting GDM's own UI save it is reliable — but only after the picker is functional, which requires everything else in this runbook.
