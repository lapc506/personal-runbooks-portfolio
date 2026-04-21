# Ubuntu — Force Wayland session on GDM with NVIDIA proprietary driver

_Applies to: Ubuntu 24.04 LTS, GDM 46.x, NVIDIA driver 580-open (or any version ≥ 470), hybrid graphics (Intel iGPU + discrete NVIDIA)._

> **⚠ Important:** during the original debugging, a three-layer "udev override + custom.conf + runtime-config" approach was proposed. **It turned out to be insufficient** on the test machine (GDM 46.2 + NVIDIA 580-open). The reliable fix is **Plan B** below: temporarily disable autologin, pick the Wayland session manually through the gear ⚙ icon, then re-enable autologin. The three-layer script is kept as a supplementary defense-in-depth.

## Context

Standard user flow to switch GDM from X11 to Wayland is:

1. Uncomment `# WaylandEnable=false` in `/etc/gdm3/custom.conf` so Wayland is allowed
2. Logout → login screen → gear icon ⚙ → pick **"Ubuntu on Wayland"** → login

On Ubuntu 24.04 with NVIDIA hardware, two obstacles block this:

* A udev rule (`/usr/lib/udev/rules.d/61-gdm.rules`) that at boot time tries to set `PreferredDisplayServer=xorg` in GDM runtime-config for every NVIDIA machine not on a specific Dell SKU whitelist.
* If `AutomaticLoginEnable=True`, the gear ⚙ on the login screen is **never shown** — GDM jumps straight into the session without giving the user a chance to pick, so even if Wayland is technically available, there's no interactive entry point.

Combined, the user ends up stuck in an X11 session even after:

* Setting `Session=ubuntu-wayland` in AccountsService
* Removing `XSession=ubuntu` from the same file
* Restarting `accounts-daemon`
* Running `Alt+F2 → r` to reload GNOME Shell
* Any number of logout/login cycles

## Problem Statement

Hardware: Gigabyte AORUS 15 9MF, RTX 4050 Laptop (NVIDIA driver 580.126.09-open), kernel 6.17.0-22-generic, Ubuntu 24.04.

Symptom: `echo $XDG_SESSION_TYPE` always returns `x11`. `loginctl show-session $XDG_SESSION_ID -p Type` confirms `Type=x11`, `GDMSESSION=ubuntu` (the X11 default).

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

Compounded by autologin hiding the gear icon, the user has no interactive path to override GDM's choice.

## The three-layer udev override attempt (did not work as designed)

The initial hypothesis was to apply three override layers:

1. **`/etc/udev/rules.d/62-gdm-prefer-wayland.rules`** — higher number than 61-gdm.rules, its `RUN+=` command should override the xorg preference on every boot.
2. **`PreferredDisplayServer=wayland` in `/etc/gdm3/custom.conf`** — persistent across apt upgrades.
3. **Immediate runtime override** via `gdm-runtime-config set daemon PreferredDisplayServer wayland` for the current boot.

See [`force-wayland-nvidia.sh`](./force-wayland-nvidia.sh) for the implementation.

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

* `/run/gdm/runtime-config` does not even exist after boot, suggesting the file either gets wiped, never gets created, or is irrelevant to GDM's actual session decision on 24.04+GDM 46.
* The runtime-config tool only supports `set` (no `get`), so the config mechanism it writes to cannot be introspected by admins. This is a signal that the interface may be legacy / partially deprecated upstream.
* GDM's autologin session decision in this version likely depends on an entirely different code path (possibly hardcoded NVIDIA-detection inside the GDM binary, or a dconf key we haven't identified).

The three-layer script is still applied in the repo because it does not break anything, and it is plausible that in a future GDM version the mechanism reactivates. But **it should not be relied on as the single fix.**

## Plan B — the reliable fix

The guaranteed path: disable autologin, force the user to pass through the login screen, pick the Wayland session manually via the gear ⚙ icon, then re-enable autologin. GDM persists the manual choice in AccountsService with the correct internal flags, and every subsequent autologin uses Wayland.

See [`wayland-plan-b.sh`](./wayland-plan-b.sh). The script only automates the autologin toggle; the session pick itself is an interactive step that GDM must observe directly.

### Steps

```bash
# 1. Run the script (flips AutomaticLoginEnable → False)
bash ./wayland-plan-b.sh

# 2. Logout (GUI: top-right menu → user → Log out)

# 3. On the login screen:
#    - Click your username
#    - Before typing password, click the gear ⚙ icon (bottom-right of the password field)
#    - Select "Ubuntu on Wayland"
#    - Type password, login

# 4. Verify in a terminal:
echo $XDG_SESSION_TYPE
# → wayland

# 5. Re-enable autologin:
sudo sed -i 's|^AutomaticLoginEnable=False|AutomaticLoginEnable=True|' /etc/gdm3/custom.conf
```

GDM stores the last selected session in `/var/lib/AccountsService/users/<username>` with `Session=ubuntu-wayland` and, importantly, updates any other internal flags (like the wrong `XSession=ubuntu` that was overriding user preference before). Future autologins use this stored choice.

## Verification

After Plan B + re-enabling autologin:

```bash
echo $XDG_SESSION_TYPE                          # → wayland
loginctl show-session $XDG_SESSION_ID -p Type   # → Type=wayland
xdpyinfo >/dev/null 2>&1 && echo "X11 direct" || echo "Wayland (no pure X11)"
```

## Rollback

To return to X11:

```bash
# Disable autologin again, pick "Ubuntu on Xorg" in the gear ⚙
sudo sed -i 's|^AutomaticLoginEnable=True|AutomaticLoginEnable=False|' /etc/gdm3/custom.conf
# Logout, pick Xorg, login, re-enable autologin

# To remove the three-layer override (if you applied it):
sudo rm /etc/udev/rules.d/62-gdm-prefer-wayland.rules
sudo sed -i '/^PreferredDisplayServer=/d' /etc/gdm3/custom.conf
sudo udevadm control --reload-rules
```

## Known Constraints

* **Driver version ≥ 470 required.** The same `61-gdm.rules` file contains a branch that hard-disables Wayland for NVIDIA drivers below 470:
  ```udev
  ACTION=="bind", ENV{NV_MODULE_VERSION}=="4[0-6][0-9].*|[0-3][0-9][0-9].*|[0-9][0-9].*|[0-9].*", GOTO="gdm_disable_wayland"
  ```
  On 460 or older, Wayland is disabled entirely (not just "preferred against"). This runbook cannot rescue that case — there is no Wayland session to switch to.

* **`nvidia_drm.modeset=1` is required.** Another branch:
  ```udev
  KERNEL!="nvidia_drm", GOTO="gdm_nvidia_drm_end"
  ATTR{parameters/modeset}!="Y", GOTO="gdm_disable_wayland"
  ```
  If `/sys/module/nvidia_drm/parameters/modeset` is `N`, Wayland is hard-disabled. Confirm with `sudo cat /sys/module/nvidia_drm/parameters/modeset` before starting. Most recent Ubuntu installs set modeset via `/etc/modprobe.d/nvidia-drm-modeset.conf`.

* **`gdm-runtime-config` interface appears to be legacy in GDM 46.** The binary only has a `set` subcommand, no `get`. The file it writes (`/run/gdm/runtime-config`) may not exist at all on your system. The udev override in `force-wayland-nvidia.sh` is a _best-effort_ future-proofing step, not the primary fix.

* **AccountsService `XSession=` vs `Session=` ambiguity.** Removing or correctly setting both fields is necessary. Older GDM-touched AccountsService files may have `XSession=ubuntu` that overrides `Session=ubuntu-wayland`. Verify with `sudo cat /var/lib/AccountsService/users/<username>`. Plan B's GDM-driven save writes both correctly.

## References

* [GDM upstream (GNOME GitLab)](https://gitlab.gnome.org/GNOME/gdm)
* [Ubuntu 61-gdm.rules source (packaged in gdm3)](https://git.launchpad.net/~ubuntu-core-dev/ubuntu/+source/gdm3/) — see `debian/61-gdm.rules.in`
* [freedesktop.org — udev rule file ordering](https://www.freedesktop.org/software/systemd/man/latest/udev.html)
* [AccountsService spec — user session persistence](https://www.freedesktop.org/wiki/Software/AccountsService/)

## Debugging lessons

1. **Upstream-published mechanisms are not always wired to the consumer code path.** The udev-based runtime-config hook documented in GDM's own rules file turned out to not influence session selection in GDM 46 on Ubuntu 24.04 during our tests. Always verify the full input-to-output chain before trusting an override.
2. **If a tool has `set` but no `get`, be suspicious of the mechanism.** You cannot audit what configuration any service has pulled from that file, so you cannot prove the override took effect.
3. **When config-file hacking fails, force the UI path**. GDM's gear ⚙ writes to AccountsService with the EXACT internal schema the autologin flow later consumes. Emulating that schema from outside is fragile; letting the app persist it itself is reliable.
