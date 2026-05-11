#!/usr/bin/env bash
# detect-hybrid-regressions.sh
#
# Capture the current hybrid-graphics state and compare against the most
# recent baseline at ~/.local/share/hybrid-graphics-baseline/latest.json.
# Report a semantic diff: which fields changed, grouped by category, with
# each change prefixed by its concern area.
#
# Categories reported:
#   [kernel]   kernel cmdline, version, module params
#   [driver]   NVIDIA driver version, vbios, i915 version
#   [power]    runtime PM state per device, nvidia-persistenced status
#   [display]  connected monitors, active resolutions
#   [session]  session type, GNOME Shell version, extensions
#   [env]      GPU-relevant env vars (MUTTER_*, __NV_*, LIBGL_*, etc.)
#   [pipewire] audio sinks, PipeWire version
#   [modprobe] modprobe.d file contents
#   [grub]     /etc/default/grub cmdline line
#
# No sudo. Read-only.

set -uo pipefail

ok()   { printf '\e[1;32m[ok]\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m[warn]\e[0m %s\n' "$*"; }
fail() { printf '\e[1;31m[fail]\e[0m %s\n' "$*"; exit 1; }
info() { printf '\e[1;34m[..]\e[0m %s\n' "$*"; }

BASEDIR="${XDG_DATA_HOME:-$HOME/.local/share}/hybrid-graphics-baseline"
LATEST="$BASEDIR/latest.json"

if [[ ! -f "$LATEST" ]]; then
    fail "No baseline found at $LATEST. Run baseline-hybrid-state.sh first."
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMP_CURRENT=$(mktemp --suffix=.json)
trap 'rm -f "$TMP_CURRENT"' EXIT

info "Capturing current state (ephemeral — not saved to baseline dir)"

# Re-run the capture script but redirect its stdout JSON to a tempfile.
# We achieve this by sourcing the capture portion directly, to avoid having
# two sources of truth for what fields to capture. Simplest approach:
# just run baseline-hybrid-state.sh, then use the newest file in BASEDIR.
# But that pollutes the baseline dir. So we do it with an env-var override:

# Run capture via a subshell that redirects the baseline file
# away from BASEDIR. Uses XDG_DATA_HOME override.
TMP_XDG=$(mktemp -d)
trap 'rm -rf "$TMP_XDG"; rm -f "$TMP_CURRENT"' EXIT
XDG_DATA_HOME="$TMP_XDG" bash "$SCRIPT_DIR/baseline-hybrid-state.sh" >/dev/null 2>&1
CURRENT_FILE=$(ls -t "$TMP_XDG"/hybrid-graphics-baseline/baseline-*.json 2>/dev/null | head -1)

if [[ -z "$CURRENT_FILE" || ! -s "$CURRENT_FILE" ]]; then
    fail "Failed to capture current state. Run baseline-hybrid-state.sh manually to debug."
fi

cp "$CURRENT_FILE" "$TMP_CURRENT"

ok "Captured current state for comparison"
echo

# ------- Diff via python for structured comparison -------------------------

python3 - "$LATEST" "$TMP_CURRENT" <<'PYEOF'
import json, sys
from datetime import datetime

with open(sys.argv[1]) as f:
    baseline = json.load(f)
with open(sys.argv[2]) as f:
    current = json.load(f)

# Color codes
RED = "\033[1;31m"
GREEN = "\033[1;32m"
YELLOW = "\033[1;33m"
BLUE = "\033[1;34m"
DIM = "\033[2m"
RESET = "\033[0m"

def tag(category):
    return f"{BLUE}[{category}]{RESET}"

changes = []

def add(category, severity, message):
    prefix = {"warn": YELLOW, "change": "", "info": DIM}.get(severity, "")
    changes.append(f"{tag(category)} {prefix}{message}{RESET}")

def diff_scalar(category, path, old, new, severity="change"):
    if old != new:
        add(category, severity, f"{path}: {truncate(old)!r} → {truncate(new)!r}")

def diff_dict(category, path, old, new, severity="change"):
    old = old or {}
    new = new or {}
    keys = sorted(set(old.keys()) | set(new.keys()))
    for k in keys:
        if old.get(k) != new.get(k):
            if k not in old:
                add(category, severity, f"{path}.{k} ADDED: {truncate(new[k])!r}")
            elif k not in new:
                add(category, severity, f"{path}.{k} REMOVED (was {truncate(old[k])!r})")
            else:
                add(category, severity, f"{path}.{k}: {truncate(old[k])!r} → {truncate(new[k])!r}")

def truncate(s, n=200):
    if s is None:
        return None
    s = str(s)
    if len(s) > n:
        return s[:n] + "..."
    return s

# -- kernel ----------------------------------------------------------------
diff_scalar("kernel", "cmdline",
            baseline.get("kernel_cmdline"), current.get("kernel_cmdline"))
diff_scalar("kernel", "uname",
            baseline["meta"].get("kernel_release"), current["meta"].get("kernel_release"))

# -- driver ----------------------------------------------------------------
diff_scalar("driver", "nvidia-smi summary",
            baseline["nvidia_driver"].get("nvidia_smi"),
            current["nvidia_driver"].get("nvidia_smi"))
diff_scalar("driver", "/proc/driver/nvidia/version",
            baseline["nvidia_driver"].get("proc_driver_version"),
            current["nvidia_driver"].get("proc_driver_version"))
diff_dict("driver", "kernel_modules",
          baseline.get("kernel_modules"), current.get("kernel_modules"))
diff_scalar("driver", "nvidia_drm.modeset",
            baseline["nvidia_driver"].get("nvidia_drm_modeset"),
            current["nvidia_driver"].get("nvidia_drm_modeset"),
            severity="warn")
diff_scalar("driver", "nvidia_drm.fbdev",
            baseline["nvidia_driver"].get("nvidia_drm_fbdev"),
            current["nvidia_driver"].get("nvidia_drm_fbdev"),
            severity="warn")

# -- power -----------------------------------------------------------------
diff_dict("power", "", baseline.get("power_management"), current.get("power_management"))

# -- display ---------------------------------------------------------------
bc = baseline.get("display_topology", {}).get("connectors", {})
cc = current.get("display_topology", {}).get("connectors", {})
all_connectors = sorted(set(bc.keys()) | set(cc.keys()))
for name in all_connectors:
    bi = bc.get(name, {"status": "__ABSENT__"})
    ci = cc.get(name, {"status": "__ABSENT__"})
    if bi.get("status") != ci.get("status"):
        add("display", "change",
            f"{name} status: {bi.get('status')!r} → {ci.get('status')!r}")

# -- session ---------------------------------------------------------------
bsess = baseline.get("session", {})
csess = current.get("session", {})
for key in ["XDG_SESSION_TYPE", "GDMSESSION", "XDG_CURRENT_DESKTOP", "gnome_shell_version", "mutter_version"]:
    diff_scalar("session", key, bsess.get(key), csess.get(key))

# Extensions — handle as sets because order doesn't matter
be = set((bsess.get("enabled_extensions") or "").split())
ce = set((csess.get("enabled_extensions") or "").split())
for added in sorted(ce - be):
    add("session", "change", f"extension ENABLED: {added}")
for removed in sorted(be - ce):
    add("session", "change", f"extension DISABLED: {removed}")

# -- env -------------------------------------------------------------------
diff_dict("env", "hybrid_env_vars",
          baseline.get("hybrid_env_vars"), current.get("hybrid_env_vars"))
diff_dict("env", "environment_d",
          baseline.get("environment_d"), current.get("environment_d"))

# -- pipewire --------------------------------------------------------------
bpw = baseline.get("pipewire", {})
cpw = current.get("pipewire", {})
for key in ["pipewire_version", "default_sink", "wireplumber_active"]:
    diff_scalar("pipewire", key, bpw.get(key), cpw.get(key))
# Cards/sinks — just note if they changed (full diff would be noisy)
if bpw.get("pactl_cards") != cpw.get("pactl_cards"):
    add("pipewire", "change", "audio card list changed (inspect manually: pactl list cards)")
if bpw.get("pactl_sinks") != cpw.get("pactl_sinks"):
    add("pipewire", "change", "audio sink list changed (inspect manually: pactl list sinks)")

# -- modprobe --------------------------------------------------------------
for field in ["modprobe_d", "modprobe_d_i915", "modprobe_d_blacklist"]:
    diff_dict("modprobe", field, baseline.get(field), current.get(field))

# -- grub ------------------------------------------------------------------
bg = baseline.get("grub", {})
cg = current.get("grub", {})
for key in ["default_cmdline_line", "cmdline_linux_line"]:
    diff_scalar("grub", key, bg.get(key), cg.get(key))

# -- AccountsService -------------------------------------------------------
diff_scalar("accounts_service", "user_file",
            baseline.get("accounts_service", {}).get("user_file"),
            current.get("accounts_service", {}).get("user_file"))

# -- GDM custom.conf -------------------------------------------------------
diff_scalar("gdm", "custom.conf",
            baseline.get("gdm", {}).get("custom_conf"),
            current.get("gdm", {}).get("custom_conf"))

# ----- Output ------------------------------------------------------------
baseline_age = datetime.fromisoformat(baseline["meta"]["captured_at"].replace("Z","+00:00"))
now = datetime.fromisoformat(current["meta"]["captured_at"].replace("Z","+00:00"))
age = now - baseline_age

print("="*62)
print(f"  Hybrid graphics regression detector")
print(f"  Baseline age: {age} (captured {baseline['meta']['captured_at']})")
print("="*62)
print()

if not changes:
    print(f"{GREEN}✓ No regressions detected. Current state matches baseline.{RESET}")
    sys.exit(0)

print(f"{YELLOW}▲ {len(changes)} change(s) detected since baseline:{RESET}")
print()
for c in changes:
    print(f"  {c}")
print()
print(f"{DIM}Each change is a candidate explanation for a current symptom.{RESET}")
print(f"{DIM}Cross-reference with hypotheses.md for the failure categories.{RESET}")
sys.exit(1)
PYEOF
