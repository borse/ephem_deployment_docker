#!/bin/bash
# ──────────────────────────────────────────────
# Ensure the Odoo database role is NOT a superuser.
#
# Servers installed before the August 2026 hardening bootstrapped
# PostgreSQL with the app's own role ('odoo') as the cluster superuser,
# so a compromised addon could read or drop every database, or run OS
# commands inside the db container via COPY ... FROM PROGRAM.
#
# What this script does, depending on what it finds:
#   • role already unprivileged (all new installs) → nothing, reports OK
#   • role is a superuser but NOT the cluster's bootstrap user →
#     demotes it in place to LOGIN + CREATEDB (all Odoo needs)
#   • role IS the bootstrap user (installs made before August 2026) →
#     PostgreSQL 16 forbids demoting the bootstrap user, so it prints
#     instructions for the one-time migration:  scripts/migrate-db-cluster.sh
#
# Idempotent — safe to run any number of times. setup.sh runs it
# automatically.
# ──────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

# `|| true`: a key absent from .env must yield "", not kill the script
# (grep exits 1 on no match, which set -e would treat as fatal).
env_get() { grep "^$1=" .env 2>/dev/null | cut -d'=' -f2- | xargs || true; }

APP_ROLE="$(env_get POSTGRES_USER)"
APP_ROLE="${APP_ROLE:-odoo}"
ADMIN_PASS="$(env_get POSTGRES_ADMIN_PASSWORD)"
ADMIN_PASS="${ADMIN_PASS:-$(env_get POSTGRES_PASSWORD)}"

if [ "$APP_ROLE" = "postgres" ]; then
    echo "POSTGRES_USER is 'postgres' — refusing to touch the superuser."
    echo "Set POSTGRES_USER=odoo in .env so the app uses a separate role."
    exit 1
fi

# All queries run inside the db container over its unix socket, which the
# postgres image trusts — so this works regardless of stored passwords.
psql_q() { docker compose exec -T db psql -U "$APP_ROLE" -d postgres -t -A -c "$1" </dev/null; }

IS_SUPER=$(psql_q "SELECT rolsuper FROM pg_roles WHERE rolname = '$APP_ROLE';" 2>/dev/null | tr -d '[:space:]') || {
    echo "Could not reach the database — is it running? (docker compose up -d db)" >&2
    exit 1
}

if [ -z "$IS_SUPER" ]; then
    echo "Role '$APP_ROLE' does not exist yet — nothing to do (db-init creates it on first start)."
    exit 0
fi

if [ "$IS_SUPER" != "t" ]; then
    echo "✓ Database role '$APP_ROLE' has no superuser rights."
    exit 0
fi

# The bootstrap user (the one initdb created, OID 10) must stay a superuser
# on PostgreSQL 16 — it cannot be demoted in place.
BOOTSTRAP=$(psql_q "SELECT rolname FROM pg_roles WHERE oid = 10;" | tr -d '[:space:]')

if [ "$BOOTSTRAP" = "$APP_ROLE" ]; then
    echo ""
    echo "⚠  SECURITY: the app's database role '$APP_ROLE' is this cluster's"
    echo "   bootstrap SUPERUSER (installs made before August 2026 were set up"
    echo "   this way). PostgreSQL cannot demote the bootstrap user in place,"
    echo "   so this needs a one-time migration — dump, re-initialize, restore:"
    echo ""
    echo "       bash scripts/migrate-db-cluster.sh"
    echo ""
    echo "   Plan a short maintenance window (the site is down during the"
    echo "   migration; a rollback copy of the old data is kept). Everything"
    echo "   else keeps working in the meantime — but until it is done, a"
    echo "   compromised addon could read or drop every database."
    echo ""
    exit 0
fi

echo "Role '$APP_ROLE' is a superuser (not bootstrap) — demoting in place..."

# 1) Keep a maintenance superuser so the cluster never ends up without one.
#    SQL goes via stdin: psql only interpolates :'pw' variables there, not in -c.
psql_q "DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'postgres')
        THEN CREATE ROLE postgres SUPERUSER LOGIN; END IF; END \$\$;" >/dev/null
if [ -n "$ADMIN_PASS" ]; then
    docker compose exec -T db psql -U "$APP_ROLE" -d postgres -v pw="$ADMIN_PASS" >/dev/null <<'SQL'
ALTER ROLE postgres WITH SUPERUSER LOGIN PASSWORD :'pw';
SQL
fi

# 2) Strip superuser from the app role; keep CREATEDB.
psql_q "ALTER ROLE \"$APP_ROLE\" NOSUPERUSER NOCREATEROLE NOREPLICATION CREATEDB;" >/dev/null

echo "✓ Done. Current roles:"
psql_q "SELECT rolname || ': superuser=' || rolsuper || ', createdb=' || rolcreatedb
        FROM pg_roles WHERE rolname IN ('postgres', '$APP_ROLE') ORDER BY rolname;"
echo "  Maintenance superuser: 'postgres' (docker compose exec db psql -U postgres)"
