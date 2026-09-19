#!/bin/bash
# ──────────────────────────────────────────────
# Restart an Odoo container and follow its (colored) logs.
# Optionally run a one-shot odoo command (e.g. -u module1,module2) inside
# the container before the restart + tail — useful as a PyCharm run config.
# Colors come from ODOO_PY_COLORS=1 (set in the compose override).
#
# Usage:
#   bash scripts/dev-logs.sh                                # single-instance: restart + tail
#   bash scripts/dev-logs.sh <name>                         # multi-instance: instance <name>
#   bash scripts/dev-logs.sh <name> -u mod1,mod2 …          # update modules, then restart + tail
#   bash scripts/dev-logs.sh <name> -i new_module           # install module, then restart + tail
#   bash scripts/dev-logs.sh <name> -u mod1 --dev=xml …     # any extra odoo args forwarded
#   bash scripts/dev-logs.sh <name> -u mod1 --no-follow     # exit once Odoo answers again
#
# --no-follow (ours, not forwarded to odoo): instead of tailing forever, check
# every 3 s that the server answers /web/login, print progress, and exit 0 as
# soon as it does. Exits 1 if the container stops or keeps answering 500, 2 on
# timeout (DEV_LOGS_WAIT_TIMEOUT seconds, default 300), printing the last log
# lines either way. Meant for scripts and agents; the tail stays the default.
#
# The service is always started again after a one-shot, even when the
# one-shot fails (a failing test) or the run is interrupted. The script
# refuses to run while another one-shot is already using the same instance.
#
# Any args after the (optional) instance name are forwarded to a one-shot
#   `odoo …`
# run inside the container, with these auto-defaults:
#   • -d ephem_<name>        (only added if you didn't pass -d / --database)
#   • --stop-after-init      (only added if you didn't pass it)
# The main odoo server is stopped during the one-shot run to free the DB
# locks, and restarted afterwards.
#
# Tip: make one PyCharm Shell Script run config per scenario, e.g.
#   • "Odoo 1 (restart + tail)":   scripts/dev-logs.sh 1
#   • "Odoo 1 (update + tail)":    scripts/dev-logs.sh 1 -u eoc_signals,eoc_incident_management
#   • "Odoo a (install + tail)":   scripts/dev-logs.sh a -i my_new_module
# ──────────────────────────────────────────────
set -euo pipefail

# Run from the repo root regardless of where it's invoked from.
cd "$(dirname "$0")/.."

MULTI_FILE="docker-compose.dev-multi.yml"

# ── Parse args ─────────────────────────────────────────────
# First positional arg that doesn't start with '-' is the multi-instance name.
# Everything else is forwarded to the one-shot odoo invocation (if any).
NAME=""
if [ $# -gt 0 ] && [[ "$1" != -* ]]; then
    NAME="$1"
    shift
fi
FOLLOW=1
WAIT_TIMEOUT="${DEV_LOGS_WAIT_TIMEOUT:-300}"
HTTP_PORT="${DEV_LOGS_HTTP_PORT:-8069}"   # inside the container
ODOO_ARGS=()
for a in "$@"; do
    case "$a" in
        --no-follow) FOLLOW=0 ;;
        *)           ODOO_ARGS+=("$a") ;;
    esac
done

# ── Pick compose context + container ──────────────────────
if [ -n "$NAME" ]; then
    name=$(printf '%s' "$NAME" | tr -c 'a-zA-Z0-9_-' '_')
    service="odoo_$name"
    container="ephem-$name"
    db_default="ephem_$name"

    COMPOSE=(docker compose -f docker-compose.yml -f "$MULTI_FILE")

    # Self-heal: if the multi-instance override is missing, or this instance's
    # service isn't defined in it (manual deletion, or the file was regenerated
    # without it), rebuild the stack via dev-instances.sh. Existing instances
    # keep their position in .dev-instances (= their ports); the requested one
    # is appended if new.
    if [ ! -f "$MULTI_FILE" ] || \
       ! "${COMPOSE[@]}" config --services 2>/dev/null | grep -qx "$service"; then
        echo "! $service is not part of the current multi-instance stack — (re)creating it…"
        instances=()
        if [ -f .dev-instances ]; then
            while IFS= read -r n; do
                [ -n "$n" ] && instances+=("$n")
            done < .dev-instances
        fi
        present=0
        for n in "${instances[@]:-}"; do
            [ "$n" = "$name" ] && present=1
        done
        [ "$present" -eq 1 ] || instances+=("$name")
        bash scripts/dev-instances.sh up "${instances[@]}"
    fi
else
    service="odoo"
    container="ephem-app"
    db_default=""  # single-instance odoo.conf has no built-in dbfilter; let odoo pick
    COMPOSE=(docker compose)
fi

# ── Did the user pass a -u/-i (one-shot run requested)? ───
needs_oneshot=0
if [ ${#ODOO_ARGS[@]} -gt 0 ]; then
    for a in "${ODOO_ARGS[@]}"; do
        case "$a" in
            -u|-i|--update|--init|--update=*|--init=*)
                needs_oneshot=1 ;;
        esac
    done
fi

# ── Another one-shot on this instance? Don't fight it ─────
# `compose run` names its container <project>-<service>-run-<id>. Two runs
# against one database wait on each other's locks, and restarting the service
# under someone else's update defeats the point of stopping it.
busy=$(docker ps -q --filter "name=${service}-run-")
if [ -n "$busy" ]; then
    echo "✗ Another one-shot run is using $service right now:"
    docker ps --filter "name=${service}-run-" --format '    {{.Names}}  (running {{.RunningFor}})'
    echo "  Wait for it to finish, then run this again."
    exit 3
fi

# ── Never leave the service stopped behind us ─────────────
# Set while the one-shot runs; the EXIT trap starts the service again if the
# script dies or is interrupted (INT/TERM become a normal exit so it fires).
STOPPED_BY_US=0
restore_service() {
    if [ "$STOPPED_BY_US" -eq 1 ]; then
        STOPPED_BY_US=0
        echo "▶ Starting $service back up…"
        "${COMPOSE[@]}" start "$service" >/dev/null 2>&1 || "${COMPOSE[@]}" up -d "$service"
    fi
}
trap restore_service EXIT
trap 'exit 130' INT TERM

# ── --no-follow: wait until Odoo answers, then return ─────
# /web/login is the check because it goes through the database registry, so a
# 200 means people can log in, not just that the port is open. 303 is the
# database selector of a stack without a dbfilter.
wait_ready() {
    local start=$SECONDS elapsed=0 last=-10 state code="" not_running=0 errors=0
    echo "⏳ Waiting for $container to answer /web/login (every 3s, up to ${WAIT_TIMEOUT}s)…"
    while :; do
        elapsed=$((SECONDS - start))
        state=$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || echo missing)
        if [ "$state" != running ]; then
            not_running=$((not_running + 1))
            if [ "$not_running" -ge 3 ]; then
                echo "✗ $container is '$state' after ${elapsed}s. Last log lines:"
                docker logs --tail=60 "$container" 2>&1 || true
                return 1
            fi
        else
            not_running=0
            code=$(docker exec "$container" curl -s -o /dev/null -w '%{http_code}' \
                     --max-time 20 "http://localhost:${HTTP_PORT}/web/login" 2>/dev/null || true)
            case "$code" in
                200|303)
                    echo "✓ $container is up: /web/login answered $code after ${elapsed}s."
                    return 0 ;;
                500)
                    errors=$((errors + 1))
                    if [ "$errors" -ge 3 ]; then
                        echo "✗ $container answers 500 on /web/login. Last log lines:"
                        docker logs --tail=60 "$container" 2>&1 || true
                        return 1
                    fi ;;
                *)  errors=0 ;;
            esac
        fi
        if [ "$elapsed" -ge "$WAIT_TIMEOUT" ]; then
            echo "✗ $container not ready after ${elapsed}s (last HTTP ${code:-none}). Last log lines:"
            docker logs --tail=60 "$container" 2>&1 || true
            return 2
        fi
        if [ $((elapsed - last)) -ge 6 ]; then
            echo "   … ${elapsed}s: container $state, HTTP ${code:-000}"
            last=$elapsed
        fi
        sleep 3
    done
}

# ── Make sure the service is up so stop/start works ───────
if ! "${COMPOSE[@]}" ps --status=running --services 2>/dev/null | grep -qx "$service"; then
    echo "▶ Starting $service…"
    "${COMPOSE[@]}" up -d "$service"
fi

if [ "$needs_oneshot" -eq 1 ]; then
    # Auto-inject -d <db> and --stop-after-init unless the user already provided them.
    has_d=0; has_stop=0
    for a in "${ODOO_ARGS[@]}"; do
        case "$a" in
            -d|--database)     has_d=1 ;;
            --database=*)      has_d=1 ;;
            --stop-after-init) has_stop=1 ;;
        esac
    done
    if [ "$has_d" -eq 0 ] && [ -n "$db_default" ]; then
        ODOO_ARGS+=("-d" "$db_default")
    fi
    if [ "$has_stop" -eq 0 ]; then
        ODOO_ARGS+=("--stop-after-init")
    fi

    echo "⏸  Stopping $service so the one-shot run can take DB locks…"
    STOPPED_BY_US=1
    "${COMPOSE[@]}" stop "$service" >/dev/null

    echo "▶ One-shot:  odoo ${ODOO_ARGS[*]}"
    # --no-deps: don't restart db; it should already be running.
    # --rm: don't leave a leftover container behind.
    # A failing one-shot (a failing test, a broken module) must not leave the
    # service stopped, so its exit code is kept and the service comes back first.
    set +e
    "${COMPOSE[@]}" run --rm --no-deps "$service" odoo "${ODOO_ARGS[@]}"
    rc=$?
    set -e

    restore_service
    if [ "$rc" -ne 0 ]; then
        echo "✗ One-shot exited with code $rc (see above). $service was started again; not following logs."
        exit "$rc"
    fi
else
    echo "↻ Restarting $service…"
    "${COMPOSE[@]}" restart "$service"
fi

if [ "$FOLLOW" -eq 0 ]; then
    rc=0
    wait_ready || rc=$?
    exit "$rc"
fi

echo "─── following logs ($container) — stop the run to detach; container keeps running ───"
exec docker logs -f --tail=50 "$container"
