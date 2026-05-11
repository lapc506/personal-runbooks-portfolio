#!/usr/bin/env bash
# baseline-hybrid-state.sh
#
# Capture a JSON snapshot of everything that could silently drift on a
# hybrid Intel+NVIDIA laptop and later correlate with a user-visible bug.
#
# Run this when the machine is healthy. Output is stored in
# ~/.local/share/hybrid-graphics-baseline/ and a 'latest.json' symlink
# is updated to point at the newest capture.
#
# See ./README.md for the rationale and ./detect-hybrid-regressions.sh
# to compare the current state against the baseline.
#
# No sudo required. Read-only.

set -uo pipefail

log()  { printf '\e[1;34m[cap]\e[0m %s\n' "$*" >&2; }
ok()   { printf '\e[1;32m[ok]\e[0m %s\n' "$*" >&2; }
warn() { printf '\e[1;33m[warn]\e[0m %s\n' "$*" >&2; }

OUTDIR="${XDG_DATA_HOME:-$HOME/.local/share}/hybrid-graphics-baseline"
STAMP=$(date -u +%Y-%m-%dT%H%M%SZ)
OUT="$OUTDIR/baseline-$STAMP.json"

mkdir -p "$OUTDIR"

log "Capturing hybrid-graphics baseline to $OUT"

# Helper: safely run a command and return stdout or an error marker.
# Never fails the script — collection is best-effort.
safe() {
    local out
    if out=$("$@" 2>&1); then
        printf '%s' "$out"
    else
        printf '__ERROR__(exit=%d): %s' "$?" "$out" | head -c 500
    fi
}

# Helper: json-escape a string (basic — handles quotes, backslashes, newlines).
json_escape() {
    python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()), end="")'
}

# Collect everything, then emit a single JSON document.
python3 - <<'PYEOF' > "$OUT"
import json, subprocess, os, glob, shutil, re, sys, pwd
from datetime import datetime, timezone

def safe_run(cmd, shell=False):
    try:
        r = subprocess.run(cmd, shell=shell, capture_output=True, text=True, timeout=10)
        if r.returncode == 0:
            return r.stdout.strip()
        return f"__ERROR__(exit={r.returncode}): {(r.stderr or r.stdout).strip()[:400]}"
    except FileNotFoundError:
        return "__NOT_INSTALLED__"
    except subprocess.TimeoutExpired:
        return "__TIMEOUT__"
    except Exception as e:
        return f"__EXCEPTION__: {e}"

def safe_read(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except FileNotFoundError:
        return None
    except PermissionError:
        return "__PERMISSION_DENIED__"
    except Exception as e:
        return f"__EXCEPTION__: {e}"

def safe_glob_read(pattern):
    out = {}
    for path in sorted(glob.glob(pattern)):
        out[path] = safe_read(path)
    return out

data = {
    "meta": {
        "captured_at": datetime.now(timezone.utc).isoformat(),
        "hostname": safe_run(["hostname"]),
        "user": pwd.getpwuid(os.getuid()).pw_name,
        "uname": safe_run(["uname", "-a"]),
        "kernel_release": safe_run(["uname", "-r"]),
        "os_release": safe_read("/etc/os-release"),
    },

    "kernel_cmdline": safe_read("/proc/cmdline"),

    "grub": {
        "default_cmdline_line": None,
    },

    "gpu_pci": {
        "lspci_nnk": safe_run(["bash", "-c",
            "lspci -nnk | awk '/VGA|3D|Display/{print; flag=1; next} flag && /Subsystem|Kernel driver|Kernel modules/{print} flag && /^[^\\t ]/{flag=0}'"]),
        "nvidia_present": "NVIDIA" in (safe_run(["bash", "-c", "lspci | grep -iE 'vga|3d|display'"]) or ""),
        "intel_present": "Intel" in (safe_run(["bash", "-c", "lspci | grep -iE 'vga|3d|display'"]) or ""),
    },

    "kernel_modules": {
        # lsmod with ref-count column stripped — ref counts change whenever any
        # process opens/closes a GL context, producing noisy regression diffs.
        # Format of awk'd output: "<module>  <size>  [<used_by>]"
        "lsmod_nvidia": safe_run(["bash", "-c",
            "lsmod | awk '/^nvidia|^i915|^nouveau/ {printf \"%s  %s\", $1, $2; if (NF>=4) printf \"  %s\", $4; print \"\"}' || true"]),
        "modinfo_nvidia_drm": safe_run(["bash", "-c", "modinfo nvidia_drm 2>/dev/null | grep -E '^(version|vermagic|filename):' | head -5 || true"]),
        "modinfo_i915": safe_run(["bash", "-c", "modinfo i915 2>/dev/null | grep -E '^(version|vermagic|filename):' | head -5 || true"]),
    },

    "nvidia_driver": {
        # NOTE: intentionally excludes pstate and power.draw — those are runtime
        # telemetry that changes every second and would generate false positives
        # in the regression detector. Config-level fields only.
        "nvidia_smi": safe_run(["nvidia-smi", "--query-gpu=name,driver_version,vbios_version,persistence_mode",
                                "--format=csv,noheader"]),
        "proc_driver_version": safe_read("/proc/driver/nvidia/version"),
        "nvidia_drm_modeset": safe_read("/sys/module/nvidia_drm/parameters/modeset"),
        "nvidia_drm_fbdev": safe_read("/sys/module/nvidia_drm/parameters/fbdev"),
    },

    "modprobe_d": safe_glob_read("/etc/modprobe.d/*nvidia*.conf"),
    "modprobe_d_i915": safe_glob_read("/etc/modprobe.d/*i915*.conf"),
    "modprobe_d_blacklist": safe_glob_read("/etc/modprobe.d/blacklist*.conf"),

    "power_management": {
        "nvidia_runtime_status": safe_read("/sys/bus/pci/devices/0000:01:00.0/power/runtime_status"),
        "nvidia_power_control": safe_read("/sys/bus/pci/devices/0000:01:00.0/power/control"),
        "intel_runtime_status": safe_read("/sys/bus/pci/devices/0000:00:02.0/power/runtime_status"),
        "intel_power_control": safe_read("/sys/bus/pci/devices/0000:00:02.0/power/control"),
        "nvidia_persistenced_active": safe_run(["systemctl", "is-active", "nvidia-persistenced.service"]),
        "nvidia_powerd_active": safe_run(["systemctl", "is-active", "nvidia-powerd.service"]),
        "nvidia_suspend_enabled": safe_run(["systemctl", "is-enabled", "nvidia-suspend.service"]),
        "nvidia_resume_enabled": safe_run(["systemctl", "is-enabled", "nvidia-resume.service"]),
    },

    "display_topology": {
        "drm_cards": sorted(glob.glob("/sys/class/drm/card*")),
        "connectors": {},
    },

    "session": {
        "XDG_SESSION_TYPE": os.environ.get("XDG_SESSION_TYPE"),
        "WAYLAND_DISPLAY": os.environ.get("WAYLAND_DISPLAY"),
        "DISPLAY": os.environ.get("DISPLAY"),
        "GDMSESSION": os.environ.get("GDMSESSION"),
        "XDG_CURRENT_DESKTOP": os.environ.get("XDG_CURRENT_DESKTOP"),
        "gnome_shell_version": safe_run(["bash", "-c", "gnome-shell --version 2>/dev/null || true"]),
        "mutter_version": safe_run(["bash", "-c", "dpkg -s mutter 2>/dev/null | awk '/^Version:/{print $2}' || true"]),
        "enabled_extensions": safe_run(["bash", "-c", "gnome-extensions list --enabled 2>/dev/null || true"]),
    },

    "environment_d": safe_glob_read(os.path.expanduser("~/.config/environment.d/*.conf")),
    "environment_d_system": safe_glob_read("/etc/environment.d/*.conf"),

    "hybrid_env_vars": {
        # These affect GPU selection and compositor behavior. Capture them
        # in the current process's inherited env.
        k: os.environ.get(k) for k in [
            "__NV_PRIME_RENDER_OFFLOAD",
            "__GLX_VENDOR_LIBRARY_NAME",
            "__VK_LAYER_NV_optimus",
            "VK_DRIVER_FILES",
            "VK_ICD_FILENAMES",
            "LIBVA_DRIVER_NAME",
            "VDPAU_DRIVER",
            "LIBGL_ALWAYS_INDIRECT",
            "LIBGL_ALWAYS_SOFTWARE",
            "MUTTER_DEBUG_FORCE_KMS_MODE",
            "MUTTER_DEBUG_DISABLE_HW_CURSORS",
            "MUTTER_DEBUG_FORCE_EGL_STREAM",
        ]
    },

    "pipewire": {
        "pactl_cards": safe_run(["pactl", "list", "cards", "short"]),
        "pactl_sinks": safe_run(["pactl", "list", "sinks", "short"]),
        "default_sink": safe_run(["pactl", "get-default-sink"]),
        "pipewire_version": safe_run(["pipewire", "--version"]),
        "wireplumber_active": safe_run(["systemctl", "--user", "is-active", "wireplumber.service"]),
    },

    "accounts_service": {
        "user_file": safe_read(f"/var/lib/AccountsService/users/{os.environ.get('USER', 'unknown')}"),
    },

    "gdm": {
        "custom_conf": safe_read("/etc/gdm3/custom.conf"),
    },
}

# GRUB file
grub_file = safe_read("/etc/default/grub")
if grub_file and grub_file != "__PERMISSION_DENIED__":
    m = re.search(r'^GRUB_CMDLINE_LINUX_DEFAULT=.*$', grub_file, re.MULTILINE)
    data["grub"]["default_cmdline_line"] = m.group(0) if m else None
    m2 = re.search(r'^GRUB_CMDLINE_LINUX=.*$', grub_file, re.MULTILINE)
    data["grub"]["cmdline_linux_line"] = m2.group(0) if m2 else None

# DRM connectors: walk /sys/class/drm/card*/card*-*/status
for path in sorted(glob.glob("/sys/class/drm/card*-*/status")):
    name = path.split("/")[-2]  # e.g. card0-HDMI-A-1
    status = safe_read(path)
    enabled = safe_read(path.replace("status", "enabled"))
    data["display_topology"]["connectors"][name] = {
        "status": status,
        "enabled": enabled,
    }

json.dump(data, sys.stdout, indent=2, sort_keys=True, default=str)
PYEOF

if [[ ! -s "$OUT" ]]; then
    warn "Output file is empty. Something went wrong in the Python capture. Leaving for inspection."
    exit 1
fi

# Update 'latest' symlink
ln -sfn "$(basename "$OUT")" "$OUTDIR/latest.json"

ok "Baseline written: $OUT"
ok "Latest symlink:   $OUTDIR/latest.json"
echo
echo "Summary:"
echo "  Size:     $(wc -c < "$OUT") bytes"
echo "  Captures: $(ls "$OUTDIR"/baseline-*.json 2>/dev/null | wc -l) total"
echo
echo "To check for regressions later, run:"
echo "  bash $(dirname "$0")/detect-hybrid-regressions.sh"
