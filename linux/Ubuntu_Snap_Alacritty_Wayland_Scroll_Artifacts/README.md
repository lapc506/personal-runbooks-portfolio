# Ubuntu Snap Alacritty — Wayland Scroll Artifacts & Scrollback Hygiene

Kill the **visual scroll glitch** in a snap-confined Alacritty — the ghost text,
stale lines that don't clear on scroll, half-redrawn rows you've been fixing by
**nudging the zoom in/out** — and, separately, put an **explicit scrollback cap**
in the config so the default stops being a silent mystery.

Two unrelated things get conflated here, so this runbook keeps them apart:

1. **The scroll artifact** (rendering bug — what actually annoys you daily).
2. **The scrollback cap** (memory hygiene — *not* what blew RAM to 6.9 GB; see
   the "What scrollback is NOT" section).

- **Machine:** Ubuntu, **Wayland** session (`XDG_SESSION_TYPE=wayland`,
  `WAYLAND_DISPLAY=wayland-0`), GNOME/mutter.
- **GPU:** hybrid **Intel Iris Xe** (Alder Lake-P, the one Alacritty actually
  renders on) + **NVIDIA RTX 4050 Mobile** (idle for this workload).
- **Alacritty:** **0.17.0 from snap** (`/snap/alacritty/160/`, `classic`),
  rendering through the snap's **own bundled Mesa**, not the host's.

---

## TL;DR (the working end state)

1. **Confirm the render path** — Alacritty here renders with OpenGL via the
   snap's *bundled* Mesa on the Intel iGPU under native Wayland. That stack is
   the source of the damage/redraw artifact.
2. **Fix the glitch:** force Alacritty onto **XWayland** with
   `WINIT_UNIX_BACKEND=x11`. XWayland repaints the whole surface instead of
   relying on Wayland partial-damage, so the stale-line artifact disappears.
3. **Why your zoom trick worked:** changing font size triggers a **full grid
   reflow + full repaint**, which overwrites the stale damage region. You were
   manually doing what XWayland does automatically every frame.
4. **Scrollback hygiene** (separate concern): add an explicit `[scrollback]`
   block so the cap is visible and intentional. It does **not** fix RAM spikes.

---

## What scrollback is NOT (the 6.9 GB was not this)

The transient **6.9 GB** you saw on the `alacritty` process tree was **the child
process** (Claude Code / the shell) dumping output, buffered in *that* process's
memory and in the PTY pipe — **not** Alacritty's scrollback ring.

Alacritty's scrollback default is **10,000 lines**. A line is a small fixed-size
cell array; 10k lines is on the order of **tens of MB at most**, never GB. So:

- There was **no explicit cap** because Alacritty ships an **implicit default of
  10,000 lines** and the config never overrode it. Nothing was misconfigured —
  the default was simply never written down.
- Capping scrollback to, say, 1,000 lines is **good hygiene** (smaller ring,
  cleaner config intent) but will **not** meaningfully move RAM, and would **not**
  have prevented the 6.9 GB spike. That spike is a *child-process output* problem
  (rein in what's being printed, or pipe to a pager/`tee`), not a terminal
  scrollback problem.

Keep these mentally separate:

| Thing | Lives in | Size | Caused the 6.9 GB? |
|---|---|---|---|
| Alacritty scrollback | Alacritty's grid ring | ~tens of MB at 10k lines | **No** |
| Child output buffer | shell / Claude Code / PTY | up to GB if it floods | **Yes** |

---

## The scroll artifact — root cause

### What you observe
The reproducible case: an already-rendered **markdown table** drawn with Unicode
box-drawing borders. **Scroll up** and the table gets **sliced** — the header and
the first couple of rows survive, but the rest of the rows and the **bottom
border never repaint**. The content below is truncated / ghosted, as if the lower
part of the grid was marked "already drawn" and skipped. A **zoom in/out** (or a
window resize) makes it snap clean again.

More generally: ghost text, lines that aren't cleared after scrolling,
partially-redrawn rows. Always cured by anything that forces a full repaint.

### Why it happens
This Alacritty is rendering under **native Wayland** through the **Mesa bundled
inside the snap**, on the Intel iGPU. Confirmed from the live process, not
assumed:

```bash
PID=$(pgrep -x alacritty | head -1)

# Native Wayland (NOT XWayland): the socket is present, no DISPLAY-only fallback
tr '\0' '\n' < /proc/$PID/environ | grep -iE 'WAYLAND_DISPLAY|WINIT|LIBGL'
#  WAYLAND_DISPLAY=wayland-0
#  LIBGL_DRIVERS_PATH=/snap/alacritty/160/usr/lib/x86_64-linux-gnu/dri   <- snap's own Mesa

# Which GL driver is actually mapped into the process:
grep -iE 'iris_dri|libEGL_mesa|nvidia' /proc/$PID/maps | awk '{print $6}' | sort -u
#  /snap/alacritty/160/usr/lib/x86_64-linux-gnu/dri/iris_dri.so
#  /snap/alacritty/160/usr/lib/x86_64-linux-gnu/libEGL_mesa.so.0.0.0
```

So the stack is: **Alacritty (winit GL) → snap-bundled `libEGL_mesa` +
`iris_dri` → Wayland compositor**. The artifact is a **damage-tracking /
partial-redraw bug**, and upstream's own design notes explain exactly why a
*scroll* triggers it:

- **Partial redraw via buffer-age is the whole point of the Wayland path.**
  Since 0.11, Alacritty no longer re-renders the full grid every frame: it uses
  the `EGL_EXT_buffer_age` extension to repaint **only the damaged cells** and
  reports that damage region to the compositor (alacritty PRs
  [#5773](https://github.com/alacritty/alacritty/pull/5773) and
  [#5863](https://github.com/alacritty/alacritty/pull/5863)). This is great for
  CPU/GPU, but it means the renderer now has to compute *exactly which rows
  changed* — and trust that everything else is still valid in the back buffer.
- **Scrolling is the documented hard case.** When the damage calculation gets
  complicated — **scrolling being the named example** — Alacritty is supposed to
  fall back to damaging the *entire* surface. The upstream tracking issue
  ([#5843](https://github.com/alacritty/alacritty/issues/5843)) explicitly notes
  **glitches in clearing on edge cases** during this work, and
  [#8217](https://github.com/alacritty/alacritty/issues/8217) ("rendering
  desynced artifact") is the same class of scroll-time desync. When that
  full-surface fallback doesn't fire (or fires against a stale buffer), the rows
  that scrolled in are drawn but the region below — your table's lower rows and
  bottom border — is left as whatever was there before. **That is the sliced
  table.**
- **The snap's stale, bundled Mesa makes the buffer-age path fragile.** The snap
  carries its **own** Mesa (`LIBGL_DRIVERS_PATH` points *inside* the snap), frozen
  at build time; host Mesa updates never reach it. Buffer-age / damage behavior
  on the Intel iris driver depends on Mesa, so a frozen Mesa keeps any
  damage/buffer-age bug present that newer host Mesa would have fixed.

**Why XWayland fixes it:** under X11, Alacritty doesn't drive the compositor's
fine-grained Wayland surface-damage protocol with buffer-age partial redraw the
same way; the present goes through XWayland's full-surface path, so the
"only-some-rows-are-damaged" miscalculation that slices the table never happens.

### Why the zoom workaround works
Changing the font size forces Alacritty to **recompute the entire cell grid and
repaint every cell** — a full-surface damage. That full repaint overwrites the
stale region, so the ghosting clears. You've been hand-cranking a full redraw.
Same reason a window resize fixes it.

---

## The fix — force XWayland

Run Alacritty with the winit backend pinned to X11 so it goes through XWayland's
full-surface present path instead of native-Wayland partial damage:

```bash
WINIT_UNIX_BACKEND=x11 alacritty
```

Verify it took (the process should now have `DISPLAY` driving it and **no**
`WAYLAND_DISPLAY` in winit's chosen backend):

```bash
PID=$(pgrep -x alacritty | head -1)
tr '\0' '\n' < /proc/$PID/environ | grep -iE 'WINIT_UNIX_BACKEND|^DISPLAY'
```

Make it the default for your launcher. If you start Alacritty from a `.desktop`
file or a keybinding, set the env there. A drop-in wrapper is provided:
`alacritty-x11` (see `alacritty-x11.sh`), which just `exec`s the snap binary with
the backend forced.

### If you'd rather stay on native Wayland
The artifact is a damage/redraw bug, so the alternatives all amount to "force a
fuller repaint or a fresher GL stack":

- **Get off the snap's stale Mesa.** Install Alacritty from the upstream binary,
  Cargo (`cargo install alacritty`), or a PPA so it links the **host** Mesa,
  which is updated and carries newer damage/buffer-age fixes. The snap's frozen
  Mesa is the single biggest aggravating factor.
- **Disable partial damage** if a newer Alacritty exposes it, or keep
  `WINIT_UNIX_BACKEND=x11` — the simplest reliable knob today.

XWayland (`WINIT_UNIX_BACKEND=x11`) is the recommended fix: zero rebuild, works
with the snap you already have, and directly removes the partial-damage path
that causes the artifact.

---

## Scrollback hygiene (separate from the glitch)

Make the cap explicit so it stops being an invisible default. This is housekeeping,
**not** a RAM fix (see "What scrollback is NOT").

Add to `~/.config/alacritty/alacritty.toml`:

```toml
[scrollback]
history = 10000   # explicit = the old implicit default; lower to e.g. 1000 to trim the ring
multiplier = 3    # lines scrolled per wheel notch (default)
```

Alacritty **live-reloads on save** (default since 0.13), so this applies with no
restart. Pick `history` deliberately:

- Keep **10000** if you actually scroll back through long output.
- Drop to **1000–2000** for a leaner ring and a config that states intent.

Either way, if a child process floods 6.9 GB of output again, that's the child —
pipe it through `less`, `tee`, or rein in the verbosity. Scrollback won't save you.

---

## Why there was never an explicit cap

Nothing removed it; it was **never written**. Alacritty applies a built-in
**10,000-line** default when `[scrollback].history` is absent, so the running cap
existed the whole time — just implicitly. The recent config edits only touched
`[font]` and a `Shift+Return` keybinding, so `[scrollback]` simply never came up.
This runbook makes the default explicit so the next reader doesn't have to wonder.

---

## Files

- `alacritty-x11.sh` — wrapper that launches the snap Alacritty forced onto
  XWayland (`WINIT_UNIX_BACKEND=x11`). Install as `~/.local/bin/alacritty-x11`.
- `set-scrollback.sh` — idempotently adds/updates an explicit `[scrollback]`
  block in `~/.config/alacritty/alacritty.toml` (preserves the rest verbatim).

---

## References

- Damage tracking / report to compositors —
  [alacritty PR #5773](https://github.com/alacritty/alacritty/pull/5773),
  [PR #2724](https://github.com/alacritty/alacritty/pull/2724)
- Buffer-age partial rendering —
  [alacritty PR #5863](https://github.com/alacritty/alacritty/pull/5863),
  tracking issue [#5843](https://github.com/alacritty/alacritty/issues/5843)
  (notes the clearing glitches in edge cases, **scroll** being the named one)
- Scroll-time rendering desync artifact —
  [alacritty issue #8217](https://github.com/alacritty/alacritty/issues/8217)
- `WINIT_UNIX_BACKEND=x11` as the Wayland-issue escape hatch (winit/snap) —
  e.g. [alacritty issue #3066](https://github.com/alacritty/alacritty/issues/3066)
- 0.11.0 release (damage tracking landed) —
  [alacritty.org/changelog_0_11_0](https://alacritty.org/changelog_0_11_0.html)
