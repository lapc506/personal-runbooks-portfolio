# Ubuntu — enforce Chrome "Memory Saver: Maximum" across all profiles via managed policy

_Applies to: Ubuntu 24.04 LTS, Google Chrome (stable, Linux), GNOME Shell on Wayland, any machine running multiple Chrome profiles. Written on a Gigabyte AORUS 15 9MF (32 GB RAM) where Chrome was the second-largest memory consumer behind a Gradle build._

> **⚠ Reader's summary:** Chrome's **Memory Saver** ("Ahorro de memoria") discards inactive tabs to free RAM, with three levels — Moderate / Balanced / **Maximum**. The control lives in `chrome://settings/performance` and is **per-profile**: turning it on in one profile does nothing for the others, and a heavy user typically runs several profiles (personal, work, per-client) plus app-mode (`chrome-<name>.desktop`) launchers — each its own profile. To enforce **Maximum** everywhere at once, including profiles created later, drop a **managed policy** JSON in `/etc/opt/chrome/policies/managed/`. Two keys do it: `HighEfficiencyModeEnabled: true` (turns Memory Saver on) and `MemorySaverModeSavings: 2` (sets the level to Maximum). The "full" variant adds `NetworkPredictionOptions: 2` to disable speculative page preloading, squeezing a bit more RAM/CPU at a small navigation-speed cost.

## Context

This machine suffers **host-starvation crashes** — see the sibling runbook [`Ubuntu_GNOME_Shell_Xwayland_BadWindow_Crash_Under_Load`](../Ubuntu_GNOME_Shell_Xwayland_BadWindow_Crash_Under_Load): under sustained CPU/RAM pressure Xwayland dies (`gnome-shell: Connection to xwayland lost` → `Xwayland terminated, exiting since it was mandatory`) and the GNOME session collapses; GDM restarts it without a reboot. This is **not** the GPU-fault family ([`Ubuntu_NVIDIA_Xid56_Display_Freeze_Under_Load`](../Ubuntu_NVIDIA_Xid56_Display_Freeze_Under_Load)); `prime-select on-demand` already neutralized that — the crashes that remain carry **no `Xid`**, they are pure resource starvation.

A PSS (proportional-set-size — no double-counting of shared memory) breakdown during one such episode:

| App / group | Real RAM (PSS) | Processes |
|---|---|---|
| Java / Gradle / Kotlin (Android build) | 6.61 G | 3 |
| **Chrome (all windows / profiles)** | **5.01 G** | **94** |
| Claude Code sessions | 1.44 G | 10 |
| QtWebEngine | 1.30 G | 2 |
| Slack (Electron) | 0.58 G | 8 |
| ZapZap / WhatsApp (Electron) | 0.48 G | 8 |

With `free` showing **424 MB free / 21 GB used / swap in use**, Chrome's ~5 GB across **94 processes** is the largest *controllable, persistent* baseline (the Gradle build is transient). Shrinking Chrome's resident footprint buys the headroom that keeps the compositor alive under load.

## Problem statement

Memory Saver is a **per-profile preference**, stored in each profile's `Preferences` JSON:

- `~/.config/google-chrome/Default/Preferences`
- `~/.config/google-chrome/Profile 1/Preferences`
- `~/.config/google-chrome/Profile 3/Preferences`
- … and any profile created later.

Setting it by hand means visiting `chrome://settings/performance` in **every** profile; it is not enforced (a profile reset reverts it); and it does **not** apply to profiles created afterward. For a user juggling several work/client profiles, that is fragile and easy to forget.

## Solution — a system-wide managed policy

On Linux, Chrome reads enterprise policies from `/etc/opt/chrome/policies/managed/*.json` and applies them to **every profile on the machine**, present and future. The relevant keys:

| Policy | Type | Value | Effect |
|---|---|---|---|
| `HighEfficiencyModeEnabled` | bool | `true` | Turns Memory Saver **on** (the enabler). |
| `MemorySaverModeSavings` | int | `2` | Level: `0`=Moderate, `1`=Balanced, **`2`=Maximum**. Only takes effect while Memory Saver is on. |
| `NetworkPredictionOptions` | int | `2` | _(optional — the "full" variant)_ Disables page **preloading**: `0`=predict on any network, `2`=never. Saves RAM/CPU spent on speculative loads, at a small first-navigation-speed cost. |

### The policy file

`/etc/opt/chrome/policies/managed/memory-saver.json`:

```json
{
  "HighEfficiencyModeEnabled": true,
  "MemorySaverModeSavings": 2,
  "NetworkPredictionOptions": 2
}
```

## Apply

Run the helper (validates the JSON, writes the file with `sudo`, prints next steps):

```bash
./apply-chrome-memory-policy.sh
```

Or by hand:

```bash
sudo mkdir -p /etc/opt/chrome/policies/managed
sudo tee /etc/opt/chrome/policies/managed/memory-saver.json >/dev/null <<'JSON'
{
  "HighEfficiencyModeEnabled": true,
  "MemorySaverModeSavings": 2,
  "NetworkPredictionOptions": 2
}
JSON
```

Then **quit Chrome completely** — every window *and* every `chrome-<name>.desktop` app instance (`pkill -i chrome` if unsure) — and reopen it. Policies load at startup.

## Verify

1. `chrome://policy` → **Reload policies** → `HighEfficiencyModeEnabled`, `MemorySaverModeSavings`, `NetworkPredictionOptions` all show **Status: OK** (applied across profiles).
2. `chrome://settings/performance` in any profile → Memory Saver shows **Maximum**, greyed out / "Managed by your organization".
3. Watch the footprint settle after inactive tabs discard:
   ```bash
   ps -eo rss,comm | awk '/chrome/{s+=$1} END{printf "Chrome RSS: %.2f GB\n", s/1048576}'
   ```

## Rollback

```bash
sudo rm /etc/opt/chrome/policies/managed/memory-saver.json
```

Restart Chrome; the setting becomes user-editable again, per profile.

## Tradeoffs

- **Enforced / locked**: the policy *greys out* the control in all profiles ("Managed by your organization"). On a single-user machine that is the point; remove the file to hand control back.
- **Maximum** discards inactive tabs sooner → they **reload when refocused** (a brief delay + refetch). Whitelist always-on sites via `chrome://settings/performance` → "Always keep these sites active".
- **`NetworkPredictionOptions: 2`** trades a little first-navigation speed for less speculative RAM/CPU. Drop that one key if you would rather keep preloading.

## Notes

- **Other Chromium browsers**: Chromium reads `/etc/chromium/policies/managed/`, Brave reads `/etc/brave/policies/managed/`, Edge reads `/etc/opt/edge/policies/managed/`. Same JSON keys.
- `HighEfficiencyModeEnabled` is the legacy name of the Memory-Saver enabler; it is still honored. `chrome://policy` flags it if a future Chrome renames it.
- This is a **host-starvation mitigation, not a GPU fix** — it lowers the odds Xwayland gets starved; it does not change which GPU the compositor renders on (that is the `prime-select on-demand` lever in the Xid 56 runbook).

## References

- [MemorySaverModeSavings — Chrome Enterprise policy](https://chromeenterprise.google/policies/memory-saver-mode-savings/)
- [Personalize Chrome performance — Google Chrome Help](https://support.google.com/chrome/answer/12929150)
- Sibling runbooks: [`Ubuntu_GNOME_Shell_Xwayland_BadWindow_Crash_Under_Load`](../Ubuntu_GNOME_Shell_Xwayland_BadWindow_Crash_Under_Load) · [`Ubuntu_NVIDIA_Xid56_Display_Freeze_Under_Load`](../Ubuntu_NVIDIA_Xid56_Display_Freeze_Under_Load)
