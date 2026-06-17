#!/usr/bin/env bash
# supabase-stack-control.sh <status|stop|disable-autostart|enable-autostart|start>
#
# Controls a self-hosted Supabase stack running as Docker containers, so it can
# be stopped cleanly when idle and kept from reviving at every boot.
#
# Why this script exists
# ----------------------
# `supabase start` brings up ~13 containers (postgres + kong + auth + realtime +
# storage + studio + supavisor pooler + logflare analytics + vector + …). The
# Erlang/Elixir services (realtime, analytics, supavisor) each run a `beam.smp`
# VM and, together with postgres, hold a multi-GB resident baseline. Those
# containers are created with `RestartPolicy=unless-stopped`, so once Docker's
# own systemd unit (`docker.service`, enabled) starts dockerd at boot, the whole
# stack comes back automatically — even if nobody asked for it. On a
# memory-constrained host that baseline contributes to the memory pressure that
# can collapse the GNOME session.
#
# What it does NOT do
# -------------------
#   * Never runs `sudo`. Everything here works through the `docker` group.
#   * Never deletes volumes or data — no `docker rm`, no `down -v`, no prune.
#   * Never touches `docker.service`. Stopping Docker wholesale would kill every
#     OTHER container on the host too; that is the wrong lever. We scope strictly
#     to the `supabase_*` containers.
#   * `disable-autostart` is reversible at any time with `enable-autostart`.
#
# Idempotent. Safe to re-run. Asks for confirmation before stopping.
#
# Exit codes:
#   0 — command completed (or nothing was needed)
#   1 — invalid arguments / usage
#   2 — Docker not reachable (daemon down or user not in `docker` group)
#   3 — user declined a confirmation prompt

set -euo pipefail

# ---- container selection ---------------------------------------------------
# The stack's containers are named `supabase_<service>_<project_id>`. We match
# the family by the `supabase_` name prefix, which is stable across the project
# id and across CLI versions.
NAME_FILTER='supabase_'

# Where to find the Supabase project (so we can prefer the real CLI lifecycle
# commands over raw `docker stop`). Auto-discovered if not set.
PROJECT_DIR="${SUPABASE_PROJECT_DIR:-}"

RED=$'\033[31m'; YEL=$'\033[33m'; GRN=$'\033[32m'; CYA=$'\033[36m'; RST=$'\033[0m'; BOLD=$'\033[1m'
ok()    { printf '%s✔%s %s\n' "$GRN" "$RST" "$*"; }
warn()  { printf '%s⚠%s %s\n' "$YEL" "$RST" "$*" >&2; }
fail()  { printf '%s✘%s %s\n' "$RED" "$RST" "$*" >&2; }
info()  { printf '%s•%s %s\n' "$CYA" "$RST" "$*"; }

usage() {
    cat <<EOF
usage: $(basename "$0") <command>

Commands:
  status              List supabase containers: state, RAM, restart policy.
  stop                Stop the stack cleanly (asks first). Keeps all data.
  disable-autostart   Set restart=no on supabase containers so they do NOT
                      revive at boot. Reversible with enable-autostart.
  enable-autostart    Restore restart=unless-stopped on supabase containers.
  start               Bring the stack back up (supabase start).

Environment:
  SUPABASE_PROJECT_DIR   Path to the dir containing supabase/config.toml.
                         Auto-discovered under ~/Documentos/GitHub if unset.

Notes:
  * Never uses sudo. Never deletes volumes/data. Never touches docker.service.
  * To take the stack down for good (no boot revival) without losing data:
        $(basename "$0") stop
        $(basename "$0") disable-autostart
EOF
}

# ---- preflight: docker reachable -------------------------------------------
require_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        fail "docker CLI not found in PATH."
        exit 2
    fi
    if ! docker info >/dev/null 2>&1; then
        fail "Cannot talk to the Docker daemon."
        fail "Is dockerd running, and is your user in the 'docker' group?"
        exit 2
    fi
}

# ---- discover the supabase CLI ---------------------------------------------
# Prefer a real `supabase` binary; fall back to `npx supabase` (which fetches
# the CLI on demand). Echoes the invocation to stdout, or nothing if neither
# is available.
supabase_cli() {
    if command -v supabase >/dev/null 2>&1; then
        printf 'supabase'
    elif command -v npx >/dev/null 2>&1; then
        printf 'npx --yes supabase'
    fi
}

# ---- discover the project dir ----------------------------------------------
# Returns the directory that CONTAINS the `supabase/` folder (i.e. where you run
# `supabase start`), not the `supabase/` folder itself.
discover_project_dir() {
    [ -n "$PROJECT_DIR" ] && { printf '%s' "$PROJECT_DIR"; return 0; }
    local hit
    hit="$(find "$HOME/Documentos/GitHub" -maxdepth 4 -name config.toml \
              -path '*supabase*' 2>/dev/null | head -n1 || true)"
    [ -n "$hit" ] || return 1
    # config.toml lives at <root>/supabase/config.toml → strip two path levels.
    printf '%s' "$(dirname "$(dirname "$hit")")"
}

# ---- list matching container ids -------------------------------------------
stack_ids() {        # running only
    docker ps        --filter "name=${NAME_FILTER}" -q
}
stack_ids_all() {    # including stopped/created
    docker ps -a     --filter "name=${NAME_FILTER}" -q
}

# ---- commands --------------------------------------------------------------
cmd_status() {
    require_docker
    local ids
    ids="$(stack_ids_all)"
    if [ -z "$ids" ]; then
        warn "No supabase containers found (stack was never created on this host)."
        return 0
    fi

    printf '%s%-28s %-22s %-18s %s%s\n' "$BOLD" "NAME" "STATE" "RESTART-POLICY" "MEM" "$RST"
    local running_mem=""
    # Snapshot live memory once; map name→mem for running containers.
    running_mem="$(docker stats --no-stream --format '{{.Name}}={{.MemUsage}}' 2>/dev/null || true)"

    local id name state policy mem
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        name="$(docker inspect -f '{{.Name}}' "$id" | sed 's#^/##')"
        state="$(docker inspect -f '{{.State.Status}}' "$id")"
        policy="$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$id")"
        [ -n "$policy" ] || policy='(none)'
        mem="$(printf '%s\n' "$running_mem" | sed -n "s#^${name}=##p" | head -n1)"
        [ -n "$mem" ] || mem='-'
        printf '%-28s %-22s %-18s %s\n' "$name" "$state" "$policy" "$mem"
    done <<<"$ids"

    local n_all n_run
    n_all="$(printf '%s\n' "$ids" | grep -c . || true)"
    n_run="$(stack_ids | grep -c . || true)"
    printf '\n'
    info "${n_all} supabase container(s); ${n_run} running."
    if [ "$n_run" -gt 0 ]; then
        info "Stop them with:  $(basename "$0") stop"
    fi
    # Surface boot-revival risk.
    local revivers
    revivers="$(while IFS= read -r id; do
        [ -n "$id" ] || continue
        p="$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$id")"
        case "$p" in always|unless-stopped|on-failure) printf '.';; esac
    done <<<"$ids")"
    if [ -n "$revivers" ]; then
        warn "${#revivers} container(s) will revive at boot (restart policy set)."
        warn "Prevent that with:  $(basename "$0") disable-autostart"
    else
        ok "No container is set to revive at boot."
    fi
}

confirm() {          # confirm "<question>"
    local ans
    printf '%s%s%s [y/N] ' "$BOLD" "$1" "$RST"
    read -r ans || true
    case "$ans" in [yY]|[yY][eE][sS]) return 0;; *) return 1;; esac
}

cmd_stop() {
    require_docker
    local running
    running="$(stack_ids)"
    if [ -z "$running" ]; then
        ok "No supabase containers are running. Nothing to stop."
        return 0
    fi

    local n
    n="$(printf '%s\n' "$running" | grep -c . || true)"
    info "${n} supabase container(s) currently running."
    if ! confirm "Stop the Supabase stack now? (data is preserved)"; then
        warn "Aborted. Nothing was stopped."
        exit 3
    fi

    # Prefer the CLI lifecycle (`supabase stop`) from the project dir; it stops
    # the stack the way it was started. `--no-backup` keeps it fast and is the
    # default behaviour for a plain stop — data in the named volumes stays put.
    local proj cli
    proj="$(discover_project_dir || true)"
    cli="$(supabase_cli)"
    if [ -n "$proj" ] && [ -n "$cli" ]; then
        info "Using project at: $proj"
        info "Running: ( cd \"$proj\" && $cli stop )"
        if ( cd "$proj" && $cli stop ); then
            ok "Stack stopped via supabase CLI."
            return 0
        fi
        warn "supabase stop failed; falling back to 'docker stop' on the containers."
    else
        [ -n "$proj" ] || warn "Could not locate the Supabase project dir."
        [ -n "$cli" ]  || warn "supabase CLI not available (no 'supabase', no 'npx')."
        warn "Falling back to 'docker stop' on the supabase_* containers."
    fi

    # Fallback: stop the containers directly. This does not remove anything.
    docker stop $running >/dev/null
    ok "Stopped ${n} supabase container(s) with docker stop."
}

cmd_set_restart() {  # cmd_set_restart <no|unless-stopped>
    require_docker
    local target="$1"
    local ids
    ids="$(stack_ids_all)"
    if [ -z "$ids" ]; then
        warn "No supabase containers found. Nothing to update."
        return 0
    fi

    local changed=0 skipped=0 id name cur
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        name="$(docker inspect -f '{{.Name}}' "$id" | sed 's#^/##')"
        cur="$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$id")"
        [ -n "$cur" ] || cur='no'
        if [ "$cur" = "$target" ]; then
            skipped=$((skipped+1))
            continue
        fi
        docker update --restart="$target" "$id" >/dev/null
        printf '  %s: %s → %s\n' "$name" "$cur" "$target"
        changed=$((changed+1))
    done <<<"$ids"

    ok "${changed} container(s) updated, ${skipped} already at restart=${target}."
    if [ "$target" = "no" ]; then
        info "The stack will NOT revive at boot. Re-enable with: $(basename "$0") enable-autostart"
    else
        info "The stack WILL revive at boot (when dockerd starts)."
    fi
}

cmd_start() {
    require_docker
    local proj cli
    proj="$(discover_project_dir || true)"
    cli="$(supabase_cli)"
    if [ -z "$proj" ]; then
        fail "Could not locate the Supabase project dir (no supabase/config.toml under ~/Documentos/GitHub)."
        fail "Set SUPABASE_PROJECT_DIR to the dir that contains the supabase/ folder."
        exit 1
    fi
    if [ -z "$cli" ]; then
        fail "supabase CLI not available (no 'supabase' binary and no 'npx')."
        exit 1
    fi
    info "Using project at: $proj"
    info "Running: ( cd \"$proj\" && $cli start )"
    ( cd "$proj" && $cli start )
    ok "Stack start requested. Check state with: $(basename "$0") status"
}

# ---- dispatch --------------------------------------------------------------
case "${1:-}" in
    status)             cmd_status ;;
    stop)               cmd_stop ;;
    disable-autostart)  cmd_set_restart no ;;
    enable-autostart)   cmd_set_restart unless-stopped ;;
    start)              cmd_start ;;
    -h|--help|help|"")  usage; [ -n "${1:-}" ] && exit 0 || exit 1 ;;
    *)                  fail "Unknown command: $1"; usage >&2; exit 1 ;;
esac
