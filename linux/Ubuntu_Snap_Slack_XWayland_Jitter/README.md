# Ubuntu — Slack (snap) UI "brinca" / parpadea because the Snap launcher forces XWayland on a Wayland session

_Applies to: Ubuntu 24.04 LTS, GNOME Shell 46 on Wayland, Slack snap 4.47.x (Electron 33-based), any display scale (1.0 or fractional), NVIDIA or Intel-only or AMD. Extends naturally to Discord, VSCode, Cursor, Obsidian and other Electron snaps that ship the same launcher pattern._

> **⚠ Reader's summary:** Slack's UI visibly "jumps" (the content shifts 1–2 px between frames, scroll feels rubber-band-y, the sidebar flickers when hovering) on a Wayland GNOME session. The canonical Reddit advice points at fractional scaling + XWayland as the cause, and tells you to force Slack into native Wayland with `--enable-features=UseOzonePlatform --ozone-platform=wayland`. That advice is correct in spirit but understates the actual mechanism: the Snap package ships two `.desktop` files that coexist in the XDG search path, and the user-scope one (`~/.local/share/applications/slack_slack.desktop`) explicitly blanks `WAYLAND_DISPLAY=` and passes `--ozone-platform=x11` — forcing XWayland **unconditionally**, regardless of the session. On Wayland, XWayland presents frames through a separate path that doesn't align with mutter's triple-buffering vblank schedule (new in GNOME 46) and Electron 33's compositor; frames land a refresh late, the compositor re-aligns them, and the UI jitters. The fix is to rewrite the user-scope `.desktop` with modern Ozone flags (`--ozone-platform-hint=auto` + `--enable-features=WaylandWindowDecorations`) and register a right-click Action that keeps the old forced-X11 invocation one click away — so when a future Slack release breaks the Wayland path, fallback is UI-level instead of requiring a terminal.

## Context

Hardware: Gigabyte AORUS 15 9MF, Intel Iris Xe iGPU + NVIDIA RTX 4050 Laptop on NVIDIA 580-open driver, 1920x1080 panel at scale 1.0, GNOME Shell 46 on Wayland, Ubuntu 24.04. Slack installed as the official snap (`snap install slack`, stable channel, revision 224 at time of writing, version 4.47.69, based on Electron 33).

Symptom observed: after logging into the GNOME Wayland session, launching Slack from the dock produces a window whose content is subtly unstable — text glyphs shimmer during scroll, the left sidebar fades in/out 1–2 px at channel-list boundary, DM pop-outs open with a visible 1-frame offset, and the whole window's position within mutter's workspace appears to "breathe" by a pixel each time the CPU-side frame rate drops below 60. The behavior is worst when the Slack app has focus and you're actively scrolling; it's invisible in screenshots because each individual frame is correct — only the transitions between frames are wrong.

Reading the clipboard pile of Reddit threads ([thread 1](https://www.reddit.com/r/Slack/comments/1r9sl40/linux_version_still_not_working_on_wayland/?tl=es-419), [thread 2](https://www.reddit.com/r/Slack/comments/1cw036v/slack_client_still_not_working_properly_on_linux/?tl=es-419), [thread 3](https://www.reddit.com/r/Slack/comments/1qcocqa/linux_issue_slack_not_launching_correctly_or/?tl=es-419)) produces the same advice in three places: "force native Wayland with `--enable-features=UseOzonePlatform --ozone-platform=wayland`". The advice resolves the jitter but doesn't explain *why* the default is broken, and doesn't tell you *where to put* the flags so they survive updates. This runbook fills those gaps.

## Problem Statement

```bash
env | grep -iE '(wayland|display|xdg_session)'
# XDG_SESSION_TYPE=wayland
# WAYLAND_DISPLAY=wayland-0
# DISPLAY=:0         ← XWayland socket (expected, it's always there)
```

A pure-Wayland session. Launch Slack the way the user normally does — click the Slack icon in the Ubuntu Dock — and inspect which launcher fired:

```bash
ls -la ~/.local/share/applications/slack*.desktop /var/lib/snapd/desktop/applications/slack*.desktop
# -rw-r--r-- 1 kvttvrsis kvttvrsis 465 ... /home/.../slack_slack.desktop
# -rw-r--r-- 1 root      root      344 ... /var/lib/snapd/desktop/applications/slack_slack.desktop
```

Two `.desktop` files with the same filename, one system-wide and one user-scope. The XDG Desktop Entry Specification resolves this by giving the user-scope directory precedence — `~/.local/share/applications/` wins.

Inspect the user-scope one:

```bash
cat ~/.local/share/applications/slack_slack.desktop
# [Desktop Entry]
# ...
# Exec=env BAMF_DESKTOP_FILE_HINT=/var/lib/snapd/desktop/applications/slack_slack.desktop WAYLAND_DISPLAY= /snap/bin/slack --ozone-platform=x11 %U
```

Two disabling instructions on the Exec line:

1. `WAYLAND_DISPLAY=` — assigning the empty string removes the variable from the child's environment (bash idiom for *unset for this invocation*). Once the variable is gone, Slack's Electron runtime has no way to connect to the Wayland compositor even if it wanted to.
2. `--ozone-platform=x11` — explicitly instructs Chromium's Ozone abstraction layer to use the X11 backend. Ozone is Chromium's windowing-system abstraction; the `x11` backend routes all windowing through XWayland on a Wayland host.

Check the system-wide launcher:

```bash
cat /var/lib/snapd/desktop/applications/slack_slack.desktop
# Exec=/snap/bin/slack %U       ← plain, no flags, would let Slack auto-detect
```

So the disabling is not something the Snap package does at the system level — it's in the user-scope override that was created at some point (likely by an older version of snap userd, or by a manual edit that got forgotten). The user-scope override has silently been forcing XWayland since it was written, and because Chromium's XWayland path *works* (just badly on Wayland), the symptoms look like generic Electron flakiness rather than a misconfiguration.

## Root Cause

### Part 1 — the two-launcher XDG lookup

`~/.local/share/applications/` ranks above `/var/lib/snapd/desktop/applications/` in the desktop-entry search path. The GNOME Shell Activities overview, the dock, notifications, and `gio launch` / `gtk-launch` all resolve `slack_slack.desktop` by walking `$XDG_DATA_DIRS` in order and returning the first hit. If both exist, the user one wins every time.

A side effect is that the system version is essentially hidden — reinstalling or refreshing the snap updates the system file but doesn't touch the user-scope file, so the forced-X11 flags persist across `snap refresh slack`. The user ends up carrying forever a config that was correct in 2021 (when Electron's Wayland support was unstable and forcing X11 was the pragmatic default) and is wrong in 2026 (when Electron 33 ships solid native Wayland).

### Part 2 — XWayland presents frames through a different path than native Wayland

The visual "jumping" is not a fractional-scaling artifact on this machine (this system runs at scale 1.0 with no fractional experimental flag enabled). The actual mechanism is frame-pacing desync between three layers:

1. **mutter 46 triple-buffering.** GNOME 46 shipped a mutter that holds up to three frames in flight per output and opportunistically upgrades single-buffered clients to double- or triple-buffered when vblank pressure permits. This improves perceived smoothness for well-behaved Wayland clients but requires the client to present frames in alignment with mutter's vblank scheduler.
2. **XWayland's presentation path.** An X11 client (including Chromium-on-X11) submits frames through Xorg's composite/damage extensions, which mutter's XWayland component then forwards into the Wayland pipeline. This adds one dispatch hop per frame. XWayland does implement the Present extension for vsync alignment, but Chromium's X11 backend defaults to a BlockingSwapBuffers path that interacts poorly with mutter's triple-buffering — Chromium targets a frame cadence that assumes double-buffered flip semantics, and mutter re-times the frame one refresh later to fit its triple-buffer ring.
3. **Electron 33's Ozone-X11 compositor assumes 60 Hz fixed.** When the system is actually running at 60 Hz but mutter introduces a half-frame delay on occasional frames (to absorb CPU-side variance), Electron's compositor sees the delay as a frame drop and shifts its layout by 1 px to "re-baseline" — which is the 1–2 px breathing the user perceives as the jitter.

The result: Slack on XWayland is *not* slow — it renders every frame correctly — but its frames land on a cadence that's one refresh period offset from mutter's preferred cadence, and mutter's re-alignment produces a visible temporal pattern that the human eye interprets as "the UI is wobbling."

Switching Slack to native Wayland removes all three failure modes at once: there's no XWayland hop, Chromium submits directly to mutter through `wl_surface.commit` with correct vblank semantics, and mutter's triple-buffer ring sees a single well-behaved producer.

### Part 3 — why `--ozone-platform-hint=auto` is the right flag, not `--ozone-platform=wayland`

The three Reddit threads recommend `--enable-features=UseOzonePlatform --ozone-platform=wayland`. That flag combination works on Electron 22+, but:

- `--enable-features=UseOzonePlatform` has been a no-op since Electron 22 because Ozone is now the only windowing backend Chromium ships; there's no non-Ozone path to enable. Keeping the flag is harmless but makes the Exec line longer than it needs to be.
- `--ozone-platform=wayland` hard-wires Wayland. If a future reboot happens from a TTY into a non-Wayland session (GNOME Xorg fallback, remote X session via `ssh -X`, rescue mode with XFCE on X11), Slack will launch, try to connect to a Wayland socket that isn't there, and exit with `Ozone: failed to initialize Wayland display`.
- `--ozone-platform-hint=auto` (added in Chromium 98, Electron 18+) reads `$XDG_SESSION_TYPE` and `$WAYLAND_DISPLAY` at startup and picks Wayland if both indicate it, X11 otherwise. It's the canonical modern flag; Fedora's official Electron packaging guidelines and Chromium's own `ozone_platform.md` both recommend it.

`--enable-features=WaylandWindowDecorations` tells Chromium to request server-side decorations from the compositor rather than drawing its own client-side decorations. On GNOME with Adwaita, server-side decorations match the system theme and honor the system's window-control layout; without the flag, Slack draws its own Chromium-native decorations that look visibly out of place. Cheap ergonomic win.

### Part 4 — a named right-click Action is the right fallback surface

Slack on Wayland works today. Slack on Wayland in six months might break if Electron 34 or Slack 4.50 regress the Wayland path. The user needs a fallback that (a) doesn't require editing files, (b) doesn't require opening a terminal, and (c) is discoverable. The XDG Desktop Entry spec's `Actions=` field creates right-click menu entries on the launcher — the Ubuntu Dock renders them as the submenu that appears on right-click on a dock icon. Putting the forced-X11 invocation into a named action means: when Slack starts jumping again after an update, right-click → "Open in X11 fallback mode" → Slack opens with the old forced-XWayland config immediately, no file editing required.

## Solution

Rewrite `~/.local/share/applications/slack_slack.desktop` with the modern Ozone flags on the primary `Exec=` line, preserve the BAMF hint for dock grouping, and add two named Actions: one for X11 fallback, one for GPU-disabled debugging.

### Apply the fix

See [`repair-slack-launcher.sh`](./repair-slack-launcher.sh). The script:

1. Confirms the session is Wayland (`$XDG_SESSION_TYPE=wayland`). Bails otherwise with an explanation — on an X11 session this runbook's fix is not needed (there's no XWayland hop to avoid because the whole session is X11).
2. Confirms Slack is installed as a snap (`/snap/bin/slack` exists and `snap list slack` succeeds). Bails otherwise — the flag set is correct for non-snap installs too, but the launcher file-path layout differs and this script doesn't handle `.deb` / Flathub Slack.
3. Reads the system launcher at `/var/lib/snapd/desktop/applications/slack_slack.desktop` to extract the current `Icon=`, `StartupWMClass=`, and `MimeType=` lines — so the generated file picks up any Slack-packaged icon path updates automatically.
4. Backs up `~/.local/share/applications/slack_slack.desktop` to `slack_slack.desktop.bak.<timestamp>` if it exists.
5. Writes the new launcher with the main `Exec=` on Wayland-native Ozone and two named Actions for fallback. Also writes a brief header comment so the next operator (or future you) understands what this file is and when it was regenerated.
6. Validates the result with `desktop-file-validate` if available (purely advisory — the spec is lenient and some "warnings" are cosmetic; script does not abort on warnings).
7. Runs `update-desktop-database ~/.local/share/applications/` so GNOME Shell re-indexes the MIME types (relevant for `slack://` URL handling from browsers).

```bash
bash ./repair-slack-launcher.sh
# No reboot, no logout needed. Close any running Slack window and relaunch from the dock.
```

Completely in userspace, no `sudo`. The snap itself is not modified, the system-wide launcher is not modified; only `~/.local/share/applications/slack_slack.desktop` is rewritten.

### Diagnose whether this runbook applies to your machine (or to other Electron apps)

See [`diagnose-electron-wayland-launchers.sh`](./diagnose-electron-wayland-launchers.sh). This is a broader diagnostic — it scans every `.desktop` file in the usual XDG locations, finds the ones that invoke an Electron-based binary (Slack, Discord, VSCode, Cursor, Obsidian, Element, Teams, Zoom, Signal, Mattermost, Rocket.Chat, Joplin), and reports for each whether it's forcing X11 via `--ozone-platform=x11` or `WAYLAND_DISPLAY=` blanking, and whether a user-scope override is hiding the system version.

```bash
bash ./diagnose-electron-wayland-launchers.sh
```

The script exits 0 if no problems are found, 1 if at least one Electron launcher forces XWayland on a Wayland session, and 2 if the session isn't Wayland at all (runbook doesn't apply).

## Verification

After running the repair script:

```bash
# 1. The Exec line now uses Ozone hint=auto
grep '^Exec=' ~/.local/share/applications/slack_slack.desktop
# Exec=env BAMF_DESKTOP_FILE_HINT=/var/lib/snapd/desktop/applications/slack_slack.desktop /snap/bin/slack --ozone-platform-hint=auto --enable-features=WaylandWindowDecorations %U

# 2. WAYLAND_DISPLAY is NOT being blanked anywhere in the file
grep -c 'WAYLAND_DISPLAY=' ~/.local/share/applications/slack_slack.desktop
# 0

# 3. The two Actions are registered
grep '^\[Desktop Action' ~/.local/share/applications/slack_slack.desktop
# [Desktop Action X11Fallback]
# [Desktop Action DebugGPU]

# 4. Launch Slack fresh and confirm it runs native Wayland
pkill -f '^/snap/slack/current' 2>/dev/null; sleep 2
gtk-launch slack_slack &
sleep 5

# 5. Look at the Slack process and confirm it connected to the Wayland socket, not :0
pidof slack | xargs -I {} ls -la /proc/{}/fd/ 2>/dev/null | grep -E 'wayland|X11-unix' | head
#    wayland-0 socket should appear; /tmp/.X11-unix/X0 should NOT.

# 6. Confirm no --ozone-platform=x11 in the running process's cmdline
tr '\0' ' ' < /proc/$(pidof slack | awk '{print $1}')/cmdline
# Should include --ozone-platform-hint=auto and NOT --ozone-platform=x11.

# 7. Observe the UI. Scroll a long channel (say #announcements with 1000+ messages).
#    The jitter should be gone: text glyphs stable, sidebar edges crisp, DM popouts
#    aligned with the first frame of their opening animation.
```

If step 6 shows `--ozone-platform=x11` in the cmdline, the new `.desktop` didn't take effect. Most likely causes: the dock cached the old launcher (log out and back in, or run `busctl --user call org.gnome.Shell /org/gnome/Shell org.gnome.Shell Eval s 'Main.shellDBusService.unregister()'` to force a shell reload — cheaper is to just log out), or there's a third `.desktop` file somewhere (`/usr/share/applications/slack_slack.desktop` written by a manual dpkg install, or `~/.local/share/flatpak/exports/share/applications/` from a flatpak install). Run the diagnostic script — it lists all copies.

## Rollback

The repair script wrote a backup at `~/.local/share/applications/slack_slack.desktop.bak.<timestamp>`. Restore it:

```bash
# Find the most recent backup
ls -t ~/.local/share/applications/slack_slack.desktop.bak.* | head -1
# /home/.../slack_slack.desktop.bak.20260424-164500

# Restore
mv ~/.local/share/applications/slack_slack.desktop.bak.20260424-164500 \
   ~/.local/share/applications/slack_slack.desktop
update-desktop-database ~/.local/share/applications/
```

Alternatively, delete the user-scope launcher entirely — GNOME Shell will fall back to the system one (`/var/lib/snapd/desktop/applications/slack_slack.desktop`), which runs `/snap/bin/slack %U` with no flags. Electron will then auto-pick its backend on its own, which in modern Electron defaults to X11 on Snap because Snap's AppArmor profile for Slack has the `x11` plug connected; on an unconfined install it would pick Wayland via hint=auto. This is a slightly different state from either the pre-fix or post-fix configuration, but is safe.

```bash
rm ~/.local/share/applications/slack_slack.desktop
update-desktop-database ~/.local/share/applications/
```

If you prefer to keep the pre-fix forced-XWayland launcher as your baseline and only want to try native Wayland experimentally: right-click Slack in the dock on the *post-fix* install and use the "Open in X11 fallback mode" action. That's precisely why the Action is there — it's the non-destructive way to compare the two paths side-by-side.

## Known Constraints and Trade-offs

* **Screen sharing stability.** Native Wayland screen sharing goes through PipeWire + xdg-desktop-portal. On GNOME this is mature, but Slack's own "share a window" dialog sometimes requires the user to pick the shared window twice in a row before the stream starts — an upstream issue tracked by PipeWire's portal backend. On XWayland, screen sharing used the older X11 capture path which Slack handled reliably on first pick, but produced worse-quality streams. Trade-off: pick-twice quirk for a meaningful quality improvement. The trade is worth it for most users.
* **Slack Huddles have intermittently crashed on Wayland-native Electron across multiple Slack releases.** Reported on the Slack Linux forum and on the Reddit threads cited above. The crash manifests as the Huddle window closing mid-call, the Slack main window remaining responsive, and the next Huddle attempt hanging for ~30 s before working. No reliable repro; when it happens, the X11 fallback action is the immediate workaround — launch Slack through "Open in X11 fallback mode", join the Huddle on XWayland, re-launch native Wayland after the Huddle ends for the rest of the session. This is specifically why the Action exists.
* **The snap's AppArmor profile emits `apparmor="DENIED"` entries in journalctl for StatusNotifierItem and DBus.ListActivatableNames.** These are unrelated to the XWayland vs. Wayland path and happen on both. They do not cause crashes or visible bugs; they're noise from Snap's legacy-unity confinement. Silence them by deactivating the system-tray indicator in Slack preferences (Preferences → Advanced → uncheck "Show a tray indicator"), or ignore — they do not affect functionality.
* **If Chrome/Chromium on the system is forced through XWayland by an `/etc/chromium/policies/` managed policy or a `--ozone-platform=x11` in `~/.config/chrome-flags.conf`, investigate whether the same override accidentally applies to Electron's Chromium.** Electron does not read `chrome-flags.conf` by default, but some corporate-managed laptops ship a `CHROMIUM_FLAGS` env var in `/etc/profile.d/` that Electron does honor. Check `cat /etc/profile.d/*.sh | grep -i chromium` before blaming Slack's `.desktop` alone.
* **`--ozone-platform-hint=auto` is a runtime detection.** If the same `.desktop` is launched from an X11 session (e.g., by switching to the GNOME-on-Xorg session at the login screen), the launcher still works — Slack will detect X11, pick the X11 backend, and run through regular Xorg. There's no need for a session-type branch in the launcher itself.
* **This fix does not remove the system launcher or the snap's shipped launcher generation.** If the snap refreshes to a version that ships a different `/var/lib/snapd/desktop/applications/slack_slack.desktop` schema, the user-scope file keeps winning the XDG lookup. That's desirable (reapply doesn't needed) but means if the snap's new schema has important changes (e.g., new `MimeType=` entries for slack-protocol URLs), the user-scope file won't pick them up automatically. Re-run the repair script periodically (say, after major Slack version bumps) to re-sync from the system template.

## Related runbooks

* [`Ubuntu_Flatpak_AppArmor_Userns_Restriction`](../Ubuntu_Flatpak_AppArmor_Userns_Restriction) — also about Electron/Chromium apps misbehaving on Ubuntu 24.04, but a different failure mode: **that** runbook's apps fail to launch at all (EGL errors, `nfsnobody` UIDs inside the sandbox), because of an AppArmor userns restriction unrelated to display. If you see Slack/Discord/Element fail at launch rather than just jitter, apply that runbook first — the XWayland jitter fix assumes the app at least starts. Cross-reference: the Slack snap discussed here is *not* affected by that runbook because Snap's AppArmor confinement predates the userns restriction and is separately carved out.
* [`Ubuntu_NVIDIA_Wayland_Flip_Event_Timeout`](../Ubuntu_NVIDIA_Wayland_Flip_Event_Timeout) — if the XWayland-to-native-Wayland switch makes the whole compositor crash under Slack load (SIGTRAP in gnome-shell, `nv_drm_atomic_commit *ERROR* Flip event timeout`), that's an NVIDIA-driver layer issue, not a Slack-layer issue; apply that runbook's GRUB `nvidia-drm.modeset=1` fix first.
* [`Ubuntu_GDM_Force_Wayland_on_NVIDIA`](../Ubuntu_GDM_Force_Wayland_on_NVIDIA) — **prerequisite-ish**. If `echo $XDG_SESSION_TYPE` returns `x11`, the entire premise of this runbook is moot — XWayland doesn't exist inside an X11 session. First flip the session to Wayland via that runbook, then come back here.

## References

* [Reddit r/Slack — Linux version still not working on Wayland](https://www.reddit.com/r/Slack/comments/1r9sl40/linux_version_still_not_working_on_wayland/?tl=es-419) — canonical thread with the `--enable-features=UseOzonePlatform --ozone-platform=wayland` advice and several user reports of the jitter.
* [Reddit r/Slack — Slack client still not working properly on Linux](https://www.reddit.com/r/Slack/comments/1cw036v/slack_client_still_not_working_properly_on_linux/?tl=es-419) — older thread, same class of issue, covers Huddles crash on Wayland.
* [Reddit r/Slack — Slack not launching correctly or hanging](https://www.reddit.com/r/Slack/comments/1qcocqa/linux_issue_slack_not_launching_correctly_or/?tl=es-419) — covers the specific case of the snap launcher shipping flags that force X11.
* [Chromium source — `ozone_platform.md`](https://source.chromium.org/chromium/chromium/src/+/main:docs/ozone_overview.md) — upstream doc explaining `--ozone-platform-hint=auto` vs. `--ozone-platform=wayland`, including the guidance that `hint=auto` is the right flag for desktop packaging.
* [Electron `command-line-switches.md`](https://www.electronjs.org/docs/latest/api/command-line-switches) — the flags Electron inherits from Chromium's command line, including the Ozone set.
* [Freedesktop.org — Desktop Entry Specification, v1.5 — `Actions=` field](https://specifications.freedesktop.org/desktop-entry-spec/latest/extra-actions.html) — canonical spec for right-click actions in launchers, including the `[Desktop Action <name>]` group syntax.
* [GNOME mutter — triple buffering in 46](https://blogs.gnome.org/shell-dev/2023/12/13/triple-buffering-is-coming-to-gnome-46/) — the mutter change that made XWayland frame-pacing visibly worse for some Electron apps.
* [Snapcraft forum — Wayland support for snaps](https://forum.snapcraft.io/t/wayland-support/) — background on Snap's `wayland` plug and the long history of Slack's desktop launcher being ahead/behind of actual Electron Wayland readiness.

## Debugging lessons

1. **Two `.desktop` files with the same name and different `Exec` lines is a silent-precedence bug waiting to happen.** XDG `$XDG_DATA_DIRS` precedence resolves them deterministically, but the determinism is invisible — there is no warning, no log line, no UI indicator that "the user-scope override is shadowing the system version". When a symptom looks like "this runs with different flags than I remember setting", the first diagnostic is `find ~/.local/share/applications/ /usr/share/applications/ /var/lib/snapd/desktop/applications/ /var/lib/flatpak/exports/share/applications/ -name '<app>*.desktop'` and diff the Exec lines. The winning one is the first in XDG_DATA_DIRS order.

2. **"Force X11" was correct advice at a specific point in time and becomes wrong advice silently.** Forcing `--ozone-platform=x11` was the right pragmatic choice in Electron 14–17 when Wayland support was genuinely broken (no clipboard, no IME, no drag-and-drop). Electron 22 stabilized Wayland. Electron 25+ made it the default-recommended path. The `.desktop` file written in the Electron-17 era never updates itself; the advice in old Stack Overflow and Reddit answers never updates itself. This is a general pattern — any "force X" flag in a config file is a time-stamped artifact of when the user last touched it, not a current best practice. Every 1–2 years, audit the flag sets in your `~/.local/share/applications/` launchers against the current upstream recommendations.

3. **Subtle visual bugs (1–2 px wobble, sub-frame flicker) are frame-pacing bugs until proven otherwise.** When the UI "looks slightly off" but every individual frame is correct, the fault is in the temporal dimension: the compositor schedule, the client's presentation cadence, or the interaction between them. Grabbing a video (`obs --startrecording &` for 10 seconds, then inspect frame-by-frame) is the quickest way to confirm — if each frame is pixel-perfect but the video plays weirdly, you have frame-pacing desync, not a rendering bug. Forcing a single compositor path (native Wayland everywhere, or X11 everywhere) usually fixes it; mixing creates re-timing overhead that the eye catches.

4. **`env | grep` inside a terminal is not representative of what a launched-from-dock app sees.** The dock-launched `.desktop` starts with the session systemd-user's environment, plus any `env FOO=...` prefixes in the Exec line. In particular, `WAYLAND_DISPLAY=` on the Exec line empties the variable *for the child*, but the terminal's own `env` still shows `WAYLAND_DISPLAY=wayland-0`. To check what a launched app actually sees, read `/proc/<pid>/environ` (null-separated) after launching it. This caught the `WAYLAND_DISPLAY=` trap in this runbook — the terminal said Wayland was up, but Slack's own process environment had it blanked.

5. **XDG Actions are the right escape hatch for "I want a non-default invocation one click away."** Every launcher with non-trivial flag set should have a named Action for at least one fallback invocation. It costs 4 lines of `.desktop` file, adds a right-click option the user discovers naturally, and prevents the next "why doesn't Slack work" episode from requiring a terminal. The Actions field is widely supported (GNOME, KDE, XFCE, Budgie, Cinnamon) and free of gotchas — it's one of the few XDG features that Just Works.

6. **A good diagnostic script answers "does this apply to me" before the fix script answers "how do I fix it".** The pattern in this repo — paired `diagnose-*.sh` (read-only, exits 0/1/2 with matching conditions) and `repair-*.sh` or `fix-*.sh` (idempotent, --noninteractive supported) — is load-bearing. It means the reader can cp-paste the scripts into a support chat, say "run the first one, paste the output, then I'll tell you whether to run the second", and the reader doesn't have to understand the whole runbook to know whether they're about to fix a real problem or apply a placebo.
