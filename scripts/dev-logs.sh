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
ODOO_ARGS=("$@")

# ── Pick compose context + container ──────────────────────
if [ -n "$NAME" ]; then
    name=$(printf '%s' "$NAME" | tr -c 'a-zA-Z0-9_-' '_')
    service="odoo_$name"
    container="ephem-$name"
    db_default="ephem_$name"

    if [ ! -f "$MULTI_FILE" ]; then
        echo "✗ No multi-instance stack found ($MULTI_FILE missing)."
        echo "  Start it first:  bash scripts/dev-instances.sh up $name"
        exit 1
    fi
    COMPOSE=(docker compose -f docker-compose.yml -f "$MULTI_FILE")
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
    "${COMPOSE[@]}" stop "$service" >/dev/null

    echo "▶ One-shot:  odoo ${ODOO_ARGS[*]}"
    # --no-deps: don't restart db; it should already be running.
    # --rm: don't leave a leftover container behind.
    "${COMPOSE[@]}" run --rm --no-deps "$service" odoo "${ODOO_ARGS[@]}"

    echo "▶ Starting $service back up…"
    "${COMPOSE[@]}" start "$service" >/dev/null 2>&1 || "${COMPOSE[@]}" up -d "$service"
else
    echo "↻ Restarting $service…"
    "${COMPOSE[@]}" restart "$service"
fi

echo "─── following logs ($container) — stop the run to detach; container keeps running ───"
exec docker logs -f --tail=50 "$container"
