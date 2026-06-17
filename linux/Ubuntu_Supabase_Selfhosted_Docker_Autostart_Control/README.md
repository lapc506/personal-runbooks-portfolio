# Ubuntu — stop a self-hosted Supabase (Docker) stack cleanly and keep it from reviving at boot

_Applies to: Ubuntu 24.04 LTS, Docker Engine (with the user in the `docker` group), a Supabase project started locally via `supabase start`. Written on a Gigabyte AORUS 15 9MF (32 GB RAM) where the Supabase stack's resident baseline was a contributor to a host-starvation crash of the GNOME session._

> **⚠ Reader's summary:** `supabase start` brings up **~13 Docker containers** (postgres + kong + auth + realtime + storage + studio + supavisor pooler + logflare analytics + vector + edge-runtime + …). Three of them — `realtime`, `analytics`, `pooler` — are Erlang/Elixir services, each running a `beam.smp` VM; together with postgres they hold a multi-GB resident baseline. The containers are created with **`RestartPolicy=unless-stopped`**, and `docker.service` is **enabled**, so at every boot dockerd starts and the whole stack **comes back automatically** — whether or not you're using it. The script in this folder, `supabase-stack-control.sh`, lets you (a) **see** the stack's state/RAM/restart-policy, (b) **stop** it cleanly without losing data, and (c) **disable boot-revival** (`docker update --restart=no`, reversible). It never uses `sudo`, never deletes volumes, and never touches `docker.service`.

## Context

This machine suffers **host-starvation crashes** — see the sibling runbooks [`Ubuntu_GNOME_Shell_Xwayland_BadWindow_Crash_Under_Load`](../Ubuntu_GNOME_Shell_Xwayland_BadWindow_Crash_Under_Load) and [`Ubuntu_GNOME_Mutter_Internal_Panel_Drop_False_Freeze`](../Ubuntu_GNOME_Mutter_Internal_Panel_Drop_False_Freeze): under sustained RAM/CPU pressure the GNOME session degrades or collapses. These are **not** GPU faults (the `Xid56` family is already neutralized by `prime-select on-demand`) — they are pure resource starvation, so every multi-GB resident baseline that is *running but unused* matters.

A self-hosted Supabase stack is exactly such a baseline. It is not anchored to any terminal: `supabase start` shells out to `docker compose up -d`, the containers attach to `containerd-shim` under `systemd`, and they outlive the shell that launched them. Combined with `unless-stopped` + an enabled `docker.service`, the stack is effectively a **boot-persistent background service** you didn't explicitly install as one.

## Problem statement

You want to be able to:

1. **Park** the stack when you're not developing against it, reclaiming its RAM.
2. Make sure it **does not silently come back** on the next reboot.
3. Do both **without losing data** and **without affecting other Docker containers** on the host.

Two naive approaches are wrong:

- **Stopping Docker itself** (`systemctl stop docker` / disabling `docker.service`) takes down **every** container on the machine, not just Supabase. Wrong lever — too broad.
- **`docker compose down -v` / `docker rm`** destroys the named volumes — i.e. your local Postgres data. Never do this just to free RAM.

The right scope is: the `supabase_*` containers only, stopped (not removed), with their restart policy flipped to `no`.

## Why the stack auto-starts (the mechanism)

| Layer | State on this host | Effect |
|---|---|---|
| `docker.service` (systemd) | `enabled` + `active` | dockerd starts at every boot |
| Container `RestartPolicy` | `unless-stopped` on 12 of 13 supabase containers | dockerd re-launches them at boot unless they were explicitly `docker stop`-ped *and* the policy still permits it |
| `supabase start` | ran on a recent boot | created the containers with the above policy |

The subtlety of `unless-stopped`: it means "restart on boot **unless** the container was in a stopped state when the daemon last went down." That is fragile to rely on for keeping the stack down — a single `docker start` (or the CLI bringing it up once) re-arms it. The robust way to keep it parked is to change the **policy itself** to `no`, which is what `disable-autostart` does (reversibly).

## The script — `supabase-stack-control.sh`

Subcommands:

| Command | What it does | Mutates? |
|---|---|---|
| `status` | Lists every `supabase_*` container with state, live RAM, and restart policy; warns which ones will revive at boot. | No (read-only) |
| `stop` | Stops the stack cleanly — prefers `supabase stop` from the project dir, falls back to `docker stop` on the containers. **Asks for confirmation.** Keeps all data. | Yes |
| `disable-autostart` | `docker update --restart=no` on the supabase containers, so they do **not** revive at boot. | Yes |
| `enable-autostart` | Restores `restart=unless-stopped`. The reverse of the above. | Yes |
| `start` | `supabase start` from the project dir. | Yes |

Guarantees baked in: `set -euo pipefail`, idempotent (re-running a command that's already in the target state is a no-op), **no `sudo`**, **no volume/data deletion**, **no touching `docker.service`**, and a `[y/N]` confirmation before `stop`.

It matches the stack by the **`supabase_` name prefix**, which is stable across the project id and CLI versions. The `supabase` CLI is discovered automatically: a real `supabase` binary if present, otherwise `npx --yes supabase` (this host has no global install — only `npx` works). The project dir is auto-discovered by finding `supabase/config.toml` under `~/Documentos/GitHub`; override with `SUPABASE_PROJECT_DIR` if needed.

### Usage

```bash
# See what's there, what it's eating, and what will revive at boot:
./supabase-stack-control.sh status

# Park it for good (the two-step that actually keeps it down):
./supabase-stack-control.sh stop              # asks first; data preserved
./supabase-stack-control.sh disable-autostart # won't come back next boot

# Later, when you want it back:
./supabase-stack-control.sh enable-autostart  # re-arm boot revival (optional)
./supabase-stack-control.sh start             # bring the stack up now
```

To take the stack down **for this session only** (it will still revive next boot), run just `stop`. To keep it down **across reboots**, you need `stop` *and* `disable-autostart` — `disable-autostart` alone doesn't stop a currently-running stack, and `stop` alone doesn't survive a reboot.

## Relation to the crash of today

On the day this runbook was written, the GNOME session was lost to memory pressure. The Supabase stack — running since a boot several days earlier, untouched — was holding a multi-GB resident baseline (postgres + three `beam.smp` Erlang VMs) the whole time, purely because of `unless-stopped` + an enabled `docker.service`. Parking it with `stop` + `disable-autostart` removes that standing baseline from the host's memory budget when you're not actively developing against it, buying headroom that keeps the compositor alive under load — the same motivation as the sibling Chrome Memory Saver runbook ([`Ubuntu_Chrome_Memory_Saver_All_Profiles`](../Ubuntu_Chrome_Memory_Saver_All_Profiles)).

## Verification

After `stop` + `disable-autostart`, re-run `status` and confirm:

- every `supabase_*` container shows **STATE = exited** (or none running),
- **RESTART-POLICY = no** on all of them,
- the final line reads `✔ No container is set to revive at boot.`

Reboot to confirm the stack stays down; `status` should still show them exited.
