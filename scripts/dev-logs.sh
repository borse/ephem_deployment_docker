#!/bin/bash
# ──────────────────────────────────────────────
# Restart an Odoo container and follow its (colored) logs.
# Handy as a PyCharm Shell Script run config — one green ▶ to restart + tail.
# Colors come from ODOO_PY_COLORS=1 (set in the compose override).
#
# Usage:
#   bash scripts/dev-logs.sh            # single-instance stack (service: odoo)
#   bash scripts/dev-logs.sh <name>     # multi-instance: instance <name>
#                                       # (see scripts/dev-instances.sh)
#
# Tip: in multi-instance mode, make ONE PyCharm Shell Script run config per
#      instance — dev-logs.sh a, dev-logs.sh b, dev-logs.sh c — for a per-server ▶.
# ──────────────────────────────────────────────
set -euo pipefail

# Run from the repo root regardless of where it's invoked from.
cd "$(dirname "$0")/.."

MULTI_FILE="docker-compose.dev-multi.yml"

if [ -n "${1:-}" ]; then
    # ── Multi-instance mode ───────────────────────────────────
    name=$(printf '%s' "$1" | tr -c 'a-zA-Z0-9_-' '_')
    service="odoo_$name"
    container="ephem-$name"

    if [ ! -f "$MULTI_FILE" ]; then
        echo "✗ No multi-instance stack found ($MULTI_FILE missing)."
        echo "  Start it first:  bash scripts/dev-instances.sh up $name"
        exit 1
    fi
    COMPOSE=(docker compose -f docker-compose.yml -f "$MULTI_FILE")

    if "${COMPOSE[@]}" ps --status=running --services 2>/dev/null | grep -qx "$service"; then
        echo "↻ Restarting $service…"
        "${COMPOSE[@]}" restart "$service"
    else
        echo "▶ Starting $service…"
        "${COMPOSE[@]}" up -d "$service"
    fi
else
    # ── Single-instance mode (default) ────────────────────────
    service="odoo"
    container="ephem-app"

    if docker compose ps --status=running --services 2>/dev/null | grep -qx "$service"; then
        echo "↻ Restarting $service…"
        docker compose restart "$service"
    else
        echo "▶ Starting $service…"
        docker compose up -d "$service"
    fi
fi

echo "─── following logs ($container) — stop the run to detach; container keeps running ───"
exec docker logs -f --tail=50 "$container"
