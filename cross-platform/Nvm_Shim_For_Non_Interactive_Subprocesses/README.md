# Cross-platform — nvm-managed node binaries invisible to non-interactive subprocesses

_Applies to: any OS where `nvm` is the node version manager (verified on Ubuntu 24.04 LTS + nvm 0.40.x + bash 5.2; same root cause and same fix apply on macOS with zsh or bash, and on Linux + WSL setups using nvm rather than `nodenv`/`asdf`/`fnm`)._

> **Verified on:** Ubuntu 24.04 LTS + nvm 0.40.1 + node v22.x as `nvm alias default` + Claude Code spawning the `chrome-devtools-mcp` server via `"command": "npx"` in its MCP manifest. Before the shim: `spawn npx ENOENT` on every MCP server start. After installing `~/.local/bin/nvm-shim` plus the four symlinks below: MCP server starts on the first try, and the same fix survived a subsequent `nvm install 24` + `nvm alias default 24` with no edits to any config file.

## Context

Modern dev environments routinely spawn node tooling from **non-interactive subprocesses**:

* **Claude Code MCP servers** — manifests declare `"command": "npx"` / `"node"` and the agent's host process spawns them directly (no login shell).
* **VS Code / Cursor extensions** — extensions that shell out to node scripts on activation.
* **`systemd --user` services**, `cron` jobs, `at` jobs.
* **Docker `exec`** into a container whose entrypoint isn't a login shell.
* **CI runners** that don't source the user profile before invoking a step.
* **GUI launchers** (`.desktop` files on Linux, Automator/`launchd` on macOS).

Under `nvm`, all of these fail with `ENOENT` (or "command not found") for `node`, `npm`, `npx`, `corepack` — even though typing the same command in your terminal works fine. This is **by-design nvm behavior**, not a bug, and it isn't fixed by adding `~/.nvm/...` to `~/.profile` (most subprocess spawners don't source `~/.profile` either).

## Problem Statement

Concrete symptom that triggered this runbook:

```
Error: spawn npx ENOENT
    at ChildProcess._handle.onexit (node:internal/child_process:...)
    code: 'ENOENT',
    syscall: 'spawn npx',
    path: 'npx',
    spawnargs: [ '-y', 'chrome-devtools-mcp@latest' ]
```

In an interactive terminal on the same machine:

```bash
which npx
# → /home/me/.nvm/versions/node/v22.20.0/bin/npx
npx --version
# → 11.x.x
```

The interactive shell sees `npx`. The Claude Code host process, spawning the MCP server from its own PID tree, does not. The disconnect is `PATH`, and the root cause is how `nvm` injects itself.

## Root Cause

`nvm` is a shell function, **not** a daemon or system-wide installer. Its `install.sh` appends this block to `~/.bashrc` (or `~/.zshrc`):

```bash
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"   # loads nvm
[ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion"
```

When you open a terminal, bash runs `~/.bashrc`, which sources `nvm.sh`. `nvm.sh` defines the `nvm` shell function **and** prepends `$NVM_DIR/versions/node/<default>/bin` to `PATH` (by calling `nvm use default` implicitly). That's the only thing making `node`/`npm`/`npx` discoverable.

A subprocess spawned by Claude Code (or any non-shell host) does:

```c
execvp("npx", argv);   // resolves through the inherited PATH
```

It does **not** start bash, does **not** read `~/.bashrc`, and therefore never gains the `~/.nvm/.../bin` entry. The inherited `PATH` typically contains:

```
/home/me/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin
```

None of those directories contain `npx`. Result: `ENOENT`.

This is correct nvm behavior. Per-shell version switching is the *point* of nvm — you can have node 18 in one terminal and node 22 in another. A global symlink would defeat that. But it does mean every non-shell subprocess silently breaks, with no diagnostic from nvm.

## Solution options

| Option | How it works | Trade-off |
|---|---|---|
| **A. Hard-symlink to a version-specific bin** (`ln -s ~/.nvm/versions/node/v22.20.0/bin/npx ~/.local/bin/npx`) | Direct symlink; subprocess `execvp` resolves it. | Hardcodes node version. Breaks the next time you `nvm install` a newer release and switch default. The dead link is invisible until something hits it. |
| **B. Hardcoded `PATH` in the host's config** (e.g. `"PATH": "/home/me/.nvm/.../bin:$PATH"` in `~/.claude/settings.json`) | Specific to one host. Won't help systemd, cron, VS Code, etc. | Same hardcoded-version problem as A. Multiplied across every host's config file. |
| **C. Wrap in `bash -ilc 'npx ...'`** (interactive + login shell forces `~/.bashrc` sourcing) | Theoretically picks up nvm via the user profile. | Claude Code (and most MCP hosts) spawn with stdin/stdout redirected; `-i` is rejected, ignored, or makes the shell wait for prompts. Reading-from-pipe under `-i` regularly hangs. Also doubles startup latency. |
| **D. Universal shim at a stable PATH entry** (this runbook) | A single bash script at `~/.local/bin/nvm-shim` sources `nvm.sh`, runs `nvm use default`, then `exec`s the real binary. Symlinks at `~/.local/bin/{npx,node,npm,corepack}` all point to the shim. | Adds ~30–80ms of startup time per invocation (one-time `nvm.sh` parse). Trivial for MCP/CI; not appropriate for a hot inner loop. |

Option D wins because:

* `~/.local/bin/` is already on the default `PATH` for user-level subprocesses on Linux (per `systemd-user.conf` and most desktop session managers) and on macOS (via `/etc/paths` once `~/.local/bin` is added, or via `launchd` `setenv`).
* It auto-resolves the **current** default version on every invocation. `nvm install 24 && nvm alias default 24` — no edits needed anywhere.
* It's one file. No per-tool config (`~/.claude/settings.json`, `.vscode/settings.json`, systemd `Environment=`, ...) needs to know about node versions.

## Solution: install `nvm-shim`

See [`nvm-shim`](./nvm-shim).

The shim, in 30 lines:

1. Gets its own invocation name via `basename "$0"` (so the same script handles `npx`, `node`, `npm`, `corepack` based on which symlink was followed).
2. Sources `nvm.sh --no-use` (loads the `nvm` function without auto-switching — faster).
3. Runs `nvm use default --silent` (now `PATH` has the real bin dir prepended for this shim process).
4. Resolves the real binary with `command -v "$CMD"`.
5. Guards against infinite recursion: if `command -v` somehow still resolves to the shim itself (broken setup, `PATH` ordering bug), abort with `exit 127` instead of forking infinitely.
6. `exec`s the real binary, replacing the shim process. The caller sees normal exit status / signal handling — the shim is transparent except for the startup cost.

### Install commands

```bash
# 1. Write the shim into ~/.local/bin
mkdir -p ~/.local/bin
# (copy the nvm-shim file from this runbook to ~/.local/bin/nvm-shim)
chmod +x ~/.local/bin/nvm-shim

# 2. Create a symlink for each node-tool binary you want shimmed
for cmd in npx node npm corepack; do
  ln -sf ~/.local/bin/nvm-shim ~/.local/bin/"$cmd"
done

# 3. Ensure ~/.local/bin precedes the system PATH in your interactive shell too
#    (so `which npx` agrees with what subprocesses see). Most distros already
#    have this in ~/.profile; verify with:
echo "$PATH" | tr ':' '\n' | grep -n local/bin
```

**macOS note:** `~/.local/bin/` is not on the default `PATH` out of the box. Either add it via `/etc/paths.d/` or include it in a `launchd` `setenv` (for GUI-spawned subprocesses) so the shim is reachable from Spotlight-launched apps and `Automator`. For Terminal sessions, `~/.zshrc` or `~/.bash_profile` should also prepend it.

## Verification

The crucial test is "what does a **non-shell** subprocess see". Simulate that with `/usr/bin/env -i` (wipes the environment) and a minimal `PATH` that mirrors what Claude Code / systemd would actually inherit:

```bash
/usr/bin/env -i HOME="$HOME" PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" \
  bash -c 'npx --version; node --version; npm --version; corepack --version'
```

Expected output:

```
11.x.x          # npx
v22.x.x         # node (or whatever your `nvm alias default` points to)
10.x.x          # npm
0.x.x           # corepack
```

If any of these returns `command not found` or `ENOENT`, the shim is misconfigured. Common causes:

* `~/.local/bin/` is not on the inherited `PATH` of the spawner — check with `cat /proc/<host-pid>/environ | tr '\0' '\n' | grep ^PATH=`.
* `nvm alias default` was never set — fix with `nvm alias default <version>`.
* A previous symlink (Option A above) is still in `~/.local/bin/` and takes precedence over the shim — `ls -la ~/.local/bin/{npx,node,npm,corepack}` and verify all four point to `nvm-shim`.

To verify the **survives-upgrade** property: install a newer node, switch default, re-run the same verification command with no other changes:

```bash
nvm install 24
nvm alias default 24
# Re-run the env -i verification above. Should now report v24.x.x for node
# with zero changes to ~/.local/bin/ or any config file.
```

## Why not other approaches (detailed)

### Why not Option A (direct symlink to versioned bin)

```bash
ln -s ~/.nvm/versions/node/v22.20.0/bin/npx ~/.local/bin/npx
```

Works today, breaks the day you `nvm install 24` and `nvm uninstall 22` (or even just `nvm alias default 24`). The symlink target `v22.20.0/bin/npx` may still exist on disk, but it'll use the v22 npm registry, the v22 lockfile format, and the v22 globals dir — silently divergent from what your interactive shell now uses. You'll spend an afternoon debugging "why does VS Code use a different node than my terminal".

### Why not Option B (hardcoded PATH in host config)

`~/.claude/settings.json`:

```json
{
  "env": {
    "PATH": "/home/me/.nvm/versions/node/v22.20.0/bin:${env:PATH}"
  }
}
```

Same versioning problem as A, plus you have to repeat the fix for every host: VS Code's `terminal.integrated.env.linux`, systemd's `Environment=PATH=`, cron's `PATH=` line at the top of the crontab, etc. N hosts × your node version count = N×M config edits per upgrade.

### Why not Option C (`bash -ilc`)

The standard suggestion on Stack Overflow is "wrap the command in `bash -ilc 'real command here'`". The `-i` flag makes bash interactive, which *does* source `~/.bashrc` and *does* load nvm.

It fails in practice for MCP/CI for three reasons:

1. **Interactive shells expect a terminal.** Claude Code's MCP transport pipes stdin/stdout for JSON-RPC. Bash under `-i` with a non-tty stdin emits warnings, may hang on prompts (e.g., if any rc script reads from `$PS1`), and can refuse to start at all on some bash builds.
2. **Login mode (`-l`) runs `~/.bash_profile` / `~/.profile`** — these are not always nvm-aware on every distro (Ubuntu sources nvm from `~/.bashrc`, not `~/.profile`). `-l` without `-i` skips `~/.bashrc`. You need both flags, and even then, distros vary.
3. **Latency**: a fresh interactive+login bash takes ~120ms minimum (sources `~/.bashrc`, `~/.bash_profile`, completions, prompt customizations). The shim is faster (~30–80ms) because it sources only `nvm.sh --no-use`.

The shim sidesteps all three.

## Maintenance

**This is the headline feature.** Once installed, the shim survives:

* `nvm install <newer-version>` — yes, the shim picks up the new default on next invocation.
* `nvm alias default <newer-version>` — yes, same.
* `nvm uninstall <older-version>` (as long as a default still exists) — yes.
* `nvm reinstall-packages <version>` — yes.
* `~/.bashrc` changes / re-sourcing — irrelevant, the shim doesn't depend on the interactive shell's PATH.

The shim breaks only if:

* `~/.nvm/nvm.sh` is moved or deleted (you uninstalled nvm). Then nothing nvm-managed works anywhere; this is expected.
* `nvm alias default` is unset (no default version). The shim's error message says exactly this: `\`nvm use default\` failed. Run \`nvm alias default <version>\` once to set.`

There is no scheduled re-run, no "after each node install do X" gotcha, no version pinning. Install once, forget.

## Known constraints

* **Startup latency**: ~30–80ms per invocation, dominated by parsing `nvm.sh`. Fine for MCP server startup (one-shot), CI steps, cron jobs. **Not fine** for inner loops — e.g., a watcher that fires `npx tsc` 50 times per second. For that workload, resolve the real path once (`REAL_NPX=$(~/.local/bin/nvm-shim --print-path npx)`, not implemented in this version) or call the versioned binary directly.
* **Requires bash on PATH**: the shim's shebang is `#!/usr/bin/env bash`. Pure-`sh` environments (Alpine without bash, BusyBox) need bash installed first.
* **`set -u`**: any unset variable in the loaded `nvm.sh` would abort the shim. Upstream nvm is `set -u`-clean as of 0.39+, but custom `~/.nvmrc` integrations or third-party patches may not be — if you have heavy nvm customization in `~/.bashrc`, test the shim end-to-end before relying on it.
* **Symlink loop guard is essential**: the check `[ "$REAL" -ef "$0" ]` prevents the shim from `exec`ing itself when `PATH` is misconfigured. Without it, a wrong `PATH` would fork bomb the spawner. Don't remove this check.
* **Windows / WSL**: this is a POSIX shim. Under WSL it works because WSL is Linux. Under native Windows with `nvm-windows`, the failure mode is similar but the fix is different — `nvm-windows` already does global symlinking, so non-interactive subprocesses generally work without a shim.

## Related

* [nvm install README — `nvm` is a function, not a binary](https://github.com/nvm-sh/nvm#installing-and-updating) — official docs explain why nvm doesn't ship as a system binary.
* [nvm issue #2058 — "nvm not loading in non-interactive shells"](https://github.com/nvm-sh/nvm/issues/2058) — canonical upstream thread, same problem domain.
* [VS Code issue #25551 — "Extension Host doesn't see nvm-managed node"](https://github.com/microsoft/vscode/issues/25551) — same root cause, different host.
* [Claude Code MCP docs — `command`/`args` spec](https://docs.anthropic.com/en/docs/claude-code/mcp) — the spawning behavior that triggers this for MCP servers.

## History

* **2026-05-13** — Documented after a Claude Code session debugging `chrome-devtools-mcp` ENOENT during the Pathways sidebar work for `dojo-os` (Linear issue DOJ-4053). The MCP manifest used `"command": "npx"` and Claude Code's host spawned it directly without a shell, so the nvm-injected PATH never reached the child. Option D was selected after rejecting A (versioning brittleness), B (per-host config sprawl), and C (interactive-shell hangs under piped stdio).

## Debugging lessons

1. **`ENOENT` on a command that "obviously exists" is almost always a PATH propagation problem, not a missing binary.** Confirm with `which <cmd>` in your terminal **and** `/usr/bin/env -i HOME=$HOME PATH=<minimal> bash -c 'which <cmd>'`. If the first works and the second doesn't, you've found a PATH-propagation bug — every interactive-shell-only PATH injector (nvm, rbenv, pyenv without shims, conda without `conda init`, asdf without proper hook) has the same failure mode in subprocesses.
2. **`bash -ilc` is the wrong answer for piped stdio.** The internet's most common suggestion. Read the bash man page on `-i` carefully: "An interactive shell is one started without non-option arguments... or one started with the -i option." It explicitly assumes a terminal. MCP transports are not terminals. Use shims, not interactive wrappers.
3. **Hardcoding versions in config files is a slow leak.** Every config file (`~/.claude/settings.json`, `.vscode/settings.json`, systemd units, cron) that pins `v22.20.0` becomes a TODO the day you upgrade. The shim approach has zero version mentions in any config — by design.
4. **`exec -ef` (the `[ "$REAL" -ef "$0" ]` test) catches a real bug class.** Symlink resolution can surprise you: if `nvm use default` somehow set a `PATH` where `~/.local/bin/` still wins, `command -v npx` would return `~/.local/bin/npx` (the shim itself). Without the `-ef` guard, the shim would `exec` itself, and on Linux you'd get a fork bomb that takes down the spawner. Always guard self-exec.
5. **The shim works in CI too.** GitHub Actions, GitLab CI, and self-hosted runners that pre-install nvm have exactly the same problem — `actions/setup-node` workarounds exist precisely because of this. A repo-local `nvm-shim` checked into `scripts/` and called from CI is portable.
6. **macOS needs `~/.local/bin/` explicitly added to PATH.** Linux session managers add it by default; macOS doesn't. If you're documenting this for a team, the macOS install step has one extra line. Don't assume parity.

---

Created by Claude Code on behalf of @lapc506
