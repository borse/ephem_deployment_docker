#!/bin/bash
# ──────────────────────────────────────────────
# Restart Odoo and follow its (colored) logs.
# Handy as a PyCharm Shell Script run config — one green ▶ to restart + tail.
# Colors come from ODOO_PY_COLORS=1 in docker-compose.override.yml.
# ──────────────────────────────────────────────
set -euo pipefail

# Run from the repo root regardless of where it's invoked from.
cd "$(dirname "$0")/.."

# Restart if already running; otherwise start it.
if docker compose ps --status=running --services 2>/dev/null | grep -qx odoo; then
    echo "↻ Restarting odoo…"
    docker compose restart odoo
else
    echo "▶ Starting odoo…"
    docker compose up -d odoo
fi

echo "─── following logs (stop the run to detach; container keeps running) ───"
exec docker logs -f --tail=50 ephem-app
