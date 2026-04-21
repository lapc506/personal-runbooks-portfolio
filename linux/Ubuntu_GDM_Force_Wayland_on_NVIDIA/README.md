# Ubuntu — Force Wayland session on GDM with NVIDIA proprietary driver

_Applies to: Ubuntu 24.04 LTS, GDM 46.x, NVIDIA driver 580-open (or any version ≥ 470), hybrid graphics (Intel iGPU + discrete NVIDIA). Works without reboot._

## Context

Standard user flow to switch GDM from X11 to Wayland is:

1. Uncomment `# WaylandEnable=false` in `/etc/gdm3/custom.conf` so Wayland is allowed
2. Logout → login screen → gear icon ⚙ → pick **"Ubuntu on Wayland"** → login

This does **not work** on Ubuntu 24.04 machines with NVIDIA hardware because:

* Ubuntu ships a udev rule (`/usr/lib/udev/rules.d/61-gdm.rules`) that detects NVIDIA PCI devices at boot and **forces** `PreferredDisplayServer=xorg` at runtime, regardless of user config.
* If `AutomaticLoginEnable=True`, the gear ⚙ on the login screen is **never shown** — GDM jumps straight into the session without giving the user a chance to pick.

Combined, the user ends up stuck in an X11 session even after:

* Setting `Session=ubuntu-wayland` in AccountsService
* Removing `XSession=ubuntu` from the same file
* Restarting `accounts-daemon`
* Running `Alt+F2 → r` to reload GNOME Shell
* Any number of logout/login cycles

## Problem Statement

Hardware: Gigabyte AORUS 15 9MF, RTX 4050 Laptop (NVIDIA driver 580.126.09-open), kernel 6.17.0-22-generic, Ubuntu 24.04.

Symptom: `echo $XDG_SESSION_TYPE` always returns `x11`. `loginctl show-session $XDG_SESSION_ID -p Type` confirms `Type=x11`, `GDMSESSION=ubuntu` (the X11 default).

Even with all of the following set correctly, GDM autologin lands in X11:

```bash
# /etc/gdm3/custom.conf
# WaylandEnable=false                 # commented → Wayland not blocked
AutomaticLoginEnable=True
AutomaticLogin=kvttvrsis

# /var/lib/AccountsService/users/kvttvrsis
[User]
Session=ubuntu-wayland                 # correct
# XSession=ubuntu                      # removed for safety
```

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

**The rule hard-codes a runtime preference of X11 for every NVIDIA machine that isn't on a specific Dell SKU whitelist.** This is a deliberate Canonical decision that prioritizes stability over features — the restriction was sensible when NVIDIA + Wayland was unstable (pre-2022), but is obsolete in 2026 with driver 580-open + kernel 6.17+.

GDM's config precedence at session start (most-specific to least):

1. **`/run/gdm/runtime-config`** (populated by udev via `gdm-runtime-config set`) — wins
2. `/etc/gdm3/custom.conf` (admin-managed static config)
3. AccountsService `Session=` (per-user preference in `/var/lib/AccountsService/users/<username>`)
4. GDM compiled-in defaults

Because the udev rule writes to layer 1, it **overrides** AccountsService and custom.conf unless explicitly countered.

Confirm the markers that indicate the rule fired for your hardware:

```bash
ls /run/udev/gdm-*
# Expected on NVIDIA hybrid laptops:
#   /run/udev/gdm-machine-has-hardware-gpu
#   /run/udev/gdm-machine-has-hybrid-graphics
#   /run/udev/gdm-machine-has-vendor-nvidia-driver
```

## Solution

Three layers of defense to override `gdm_prefer_xorg`:

1. **A newer udev rule** (`/etc/udev/rules.d/62-gdm-prefer-wayland.rules`). Udev processes rules in numerical order; file `62` runs after file `61`, so its `RUN+=` command overrides the xorg preference on every boot.
2. **`PreferredDisplayServer=wayland` in `/etc/gdm3/custom.conf`**. Survives `apt upgrade` of gdm3 that might later remove the udev override.
3. **Immediate runtime override** via `gdm-runtime-config set` so the next logout/login uses Wayland without requiring a reboot.

### Script

See [`force-wayland-nvidia.sh`](./force-wayland-nvidia.sh) in this directory. Summary of its operations:

```bash
# Layer 1: persistent udev rule
sudo tee /etc/udev/rules.d/62-gdm-prefer-wayland.rules > /dev/null <<'EOF'
ACTION=="add", SUBSYSTEM=="drm", RUN+="/usr/libexec/gdm-runtime-config set daemon PreferredDisplayServer wayland"
EOF
sudo udevadm control --reload-rules

# Layer 2: persistent custom.conf (belt-and-suspenders)
sudo cp -a /etc/gdm3/custom.conf /tmp/gdm-custom.conf.bak.$(date +%Y%m%d-%H%M%S)
if grep -qE '^PreferredDisplayServer=' /etc/gdm3/custom.conf; then
    sudo sed -i 's|^PreferredDisplayServer=.*|PreferredDisplayServer=wayland|' /etc/gdm3/custom.conf
else
    sudo sed -i '/^\[daemon\]/a PreferredDisplayServer=wayland' /etc/gdm3/custom.conf
fi

# Layer 3: immediate runtime override for current boot
sudo /usr/libexec/gdm-runtime-config set daemon PreferredDisplayServer wayland
```

Run the script:

```bash
bash /path/to/force-wayland-nvidia.sh
```

### Why the naming `62-gdm-prefer-wayland.rules`

Files in `/etc/udev/rules.d/` with the **same** filename as one in `/usr/lib/udev/rules.d/` completely mask it — udev skips the lib version entirely. That would require reimplementing all the virtual-GPU / hybrid-graphics / nomodeset detection logic that the original `61-gdm.rules` does, which is fragile and high-maintenance.

Instead, use a **different** filename with a **higher number** (`62-*`). Udev processes both files in lexicographic order: `61-gdm.rules` first (which sets `PreferredDisplayServer=xorg`), then `62-gdm-prefer-wayland.rules` (which overrides to `wayland`). Last write wins. This is the [canonical](https://www.freedesktop.org/software/systemd/man/latest/udev.html) way to extend without reimplementing.

### Why AccountsService alone was not enough

Initial attempts set `Session=ubuntu-wayland` and removed `XSession=ubuntu` in `/var/lib/AccountsService/users/<username>`. That works for **interactive logins** (manual session pick via gear icon) but not for **autologin**, because `PreferredDisplayServer=xorg` in runtime-config takes precedence over AccountsService `Session`. The `gdm-prefer-xorg` decision is made before AccountsService is even consulted.

## Verification

After running the script:

```bash
# Logout (GUI: top-right menu → user → Log out)
# Autologin resumes — should now land in Wayland

# In a fresh terminal after login:
echo $XDG_SESSION_TYPE                          # → wayland
loginctl show-session $XDG_SESSION_ID -p Type   # → Type=wayland
xdpyinfo >/dev/null 2>&1 && echo "X11 direct" || echo "Wayland (no pure X11)"
```

If any of those still says `x11`, the override didn't apply. Inspect:

```bash
# Runtime state GDM sees
sudo /usr/libexec/gdm-runtime-config get daemon PreferredDisplayServer
# → should be "wayland"

# udev rule parsed?
sudo udevadm test /sys/class/drm/card0 2>&1 | grep -i wayland

# Marker files — confirm hybrid-graphics / NVIDIA detection works
ls /run/udev/gdm-*
```

## Rollback

Restore the pre-override state:

```bash
sudo rm /etc/udev/rules.d/62-gdm-prefer-wayland.rules
sudo cp /tmp/gdm-custom.conf.bak.<timestamp> /etc/gdm3/custom.conf
sudo /usr/libexec/gdm-runtime-config set daemon PreferredDisplayServer xorg
sudo udevadm control --reload-rules
# Logout — next login is X11 again
```

## Known Constraints

* **Driver version ≥ 470 required.** The same `61-gdm.rules` file contains an earlier branch that hard-disables Wayland for NVIDIA drivers below 470:
  ```udev
  ACTION=="bind", ENV{NV_MODULE_VERSION}=="4[0-6][0-9].*|[0-3][0-9][0-9].*|[0-9][0-9].*|[0-9].*", GOTO="gdm_disable_wayland"
  ```
  On 460 or older, Wayland is disabled entirely (not just "preferred against") — the override in this runbook cannot rescue that case because there is no Wayland session to switch to.

* **`nvidia_drm.modeset=1` is required.** Another branch in the same file:
  ```udev
  KERNEL!="nvidia_drm", GOTO="gdm_nvidia_drm_end"
  ATTR{parameters/modeset}!="Y", GOTO="gdm_disable_wayland"
  ```
  If `/sys/module/nvidia_drm/parameters/modeset` is `N`, Wayland is hard-disabled. Confirm yours with `sudo cat /sys/module/nvidia_drm/parameters/modeset` before applying this runbook. Most recent Ubuntu installs set modeset via `/etc/modprobe.d/nvidia-drm-modeset.conf`.

* **Autologin hides the gear ⚙ icon.** If you need interactive session selection (to temporarily pick Xorg for debugging), disable autologin first:
  ```bash
  sudo sed -i 's|^AutomaticLoginEnable=True|AutomaticLoginEnable=False|' /etc/gdm3/custom.conf
  # Logout → login screen shows gear ⚙ → pick session → login
  # Re-enable autologin afterwards
  sudo sed -i 's|^AutomaticLoginEnable=False|AutomaticLoginEnable=True|' /etc/gdm3/custom.conf
  ```

## References

* [GDM upstream — runtime-config behavior](https://gitlab.gnome.org/GNOME/gdm)
* [Ubuntu 61-gdm.rules source (packaged in gdm3)](https://git.launchpad.net/~ubuntu-core-dev/ubuntu/+source/gdm3/) — see `debian/61-gdm.rules.in`
* [freedesktop.org — udev rule file ordering](https://www.freedesktop.org/software/systemd/man/latest/udev.html)
* [AccountsService spec — user session persistence](https://www.freedesktop.org/wiki/Software/AccountsService/)
