# inotify exhaustion → `ENOSPC` freezes and crashes (not disk full)

Unrelated apps die at the same time with "no space left on device" while the
disk has tens of GB free: a Tauri/WebKitGTK app (Linear) freezes the moment you
type in the login field, and the OpenCode TUI crash-screens with `ENOSPC` on a
`watch()` call. Both are the same bug: the per-user **inotify limits are
exhausted**, and `ENOSPC` from `inotify_add_watch()` / `inotify_init()` means
"out of inotify resources", not "out of disk".

## Symptom

Three faces, one cause (all observed 2026-09-09 on Ubuntu 24.04, GNOME Wayland):

1. **Linear desktop (Tauri/WebKitGTK) freezes while typing the login e-mail.**
   Process alive, `WebKitNetworkProcess` alive, but **no `WebKitWebProcess`** —
   the web process died at startup so the window is dead. Journal at launch:
   ```
   app-gnome-Linear-*.scope: Failed to add control inotify watch descriptor
   for control group ...: No space left on device
   ```
2. **OpenCode TUI crash screen**: `Error: ENOSPC: no space left on device,
   watch '/home/kvttvrsis/.local/state/opencode/next/tui'` from
   `tui/src/context/storage.tsx` via `node:fs` `watch()`.
3. Disk healthy (`df` showed 78G free, inodes 80% free) — ruling out real ENOSPC.

## Root cause

Ubuntu defaults are low for a heavy desktop session:

```
fs.inotify.max_user_instances = 1024   # open inotify fds per user
fs.inotify.max_user_watches   = 65536  # watched paths per user
```

Steady state here sat at a few hundred instances against the 1024 cap, but the
binding constraint was the **watch budget**: a post-fix measurement showed
~118k watches in use (a single Chrome watcher fd can hold tens of thousands),
i.e. nearly **2x the old 65536 cap**. Either budget trips the same misleading
`ENOSPC`. AI-agent workflows are the multiplier: OpenCode / Cursor / Claude
Code with **subagents + worktree isolation** means every worktree is a full
monorepo under watch, each agent adds its own watchers, each worktree gets its
own LSP server, and un-excluded `node_modules` / `target/` / `dist/` / `.git`
multiply everything.

## Diagnose

```bash
./inotify-diagnose.sh
```

Read-only. Prints current limits, inotify instances in use, top consumer
processes, recent `ENOSPC`/inotify journal hits, and disk space (to rule out a
real full disk).

## Fix

```bash
./inotify-raise-limits.sh   # asks for sudo once
```

Writes `/etc/sysctl.d/60-inotify.conf` (persistent across reboots) and applies
it live:

```
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=4096
```

Then **fully quit and reopen** the affected apps (a frozen instance stays dead).

### Agent-workflow hygiene (so the ceiling isn't hit again)

- Exclude heavy dirs from every watcher: Cursor/VS Code `files.watcherExclude`
  (`**/node_modules/**`, `**/target/**`, `**/dist/**`, `**/.git/**`,
  `**/.next/**`), and equivalents in OpenCode/Claude Code.
- Kill stale agents/dev servers holding watchers (orphaned `node`/LSP
  processes from old sessions are the usual suspects — see diagnose output).
- Limit concurrent worktrees over the same monorepo, or stagger agents.

### Cost note

Each watch costs ~1KB of non-swappable kernel memory, so don't set millions
blindly — 524288 is sane on a 16GB+ machine and ~8x this session's load.

## Verify

- `./inotify-diagnose.sh` shows usage comfortably below the new caps and no
  fresh journal hits.
- Linear launches with a live `WebKitWebProcess` (`ps -eo comm | grep WebKit`)
  and typing in the login field works.
- OpenCode TUI starts without the crash screen.
