#!/bin/bash
# ──────────────────────────────────────────────
# One-time migration: rebuild the PostgreSQL cluster so the app's 'odoo'
# role is no longer the cluster superuser.
#
# Why: installs made before August 2026 initialized PostgreSQL with the
# app's role as the BOOTSTRAP superuser, and PostgreSQL refuses to demote
# the bootstrap user in place. The only clean fix is: dump every database,
# re-initialize the cluster (the new setup creates an unprivileged app
# role automatically), and restore the dumps.
#
# Safety:
#   • every database is dumped first, and each dump is checked
#   • the old data directory is copied to a rollback volume before
#     anything is wiped — nothing is destroyed until you delete it
#   • the site is DOWN during the migration (typically a few minutes,
#     longer for large databases) — plan a maintenance window
#   • asks for explicit confirmation; refuses to run non-interactively
#
# Run:      bash scripts/migrate-db-cluster.sh
# Rollback: printed at the end, and shown here:
#   docker compose stop db
#   docker run --rm -v VOLUME:/d alpine sh -c 'find /d -mindepth 1 -delete'
#   docker run --rm -v VOLUME-premigration:/from -v VOLUME:/to alpine \
#       sh -c 'cd /from && cp -a . /to'
#   docker compose up -d
# ──────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

compose() { docker compose -f "$SCRIPT_DIR/docker-compose.yml" "$@"; }
# `|| true`: a key absent from .env must yield "", not kill the script
# (grep exits 1 on no match, which set -e would treat as fatal).
env_get() { grep "^$1=" .env 2>/dev/null | cut -d'=' -f2- | xargs || true; }

APP_ROLE="$(env_get POSTGRES_USER)"; APP_ROLE="${APP_ROLE:-odoo}"
APP_PASS="$(env_get POSTGRES_PASSWORD)"
TS=$(date +%Y%m%d_%H%M%S)
MIGDIR="$SCRIPT_DIR/backups/migration_$TS"
LOG="$MIGDIR/migration.log"

if [ ! -t 0 ]; then
    echo "This migration must be run interactively (it needs your confirmation)." >&2
    exit 1
fi
if [ -z "$APP_PASS" ]; then
    echo "POSTGRES_PASSWORD is not set in .env — fix that first." >&2
    exit 1
fi

echo "═══════════════════════════════════════════"
echo "  ePHEM database cluster migration"
echo "═══════════════════════════════════════════"

# ── 1. Start db and confirm this migration is actually needed ────────
compose up -d db >/dev/null
for i in $(seq 1 30); do
    compose exec -T db pg_isready -q </dev/null 2>/dev/null && break
    [ "$i" -eq 30 ] && { echo "Database did not come up." >&2; exit 1; }
    sleep 2
done

psql_q() { compose exec -T db psql -U "$APP_ROLE" -d postgres -t -A -c "$1" </dev/null; }

BOOTSTRAP=$(psql_q "SELECT rolname FROM pg_roles WHERE oid = 10;" | tr -d '[:space:]')
IS_SUPER=$(psql_q "SELECT rolsuper FROM pg_roles WHERE rolname = '$APP_ROLE';" | tr -d '[:space:]')
if [ "$IS_SUPER" != "t" ] || [ "$BOOTSTRAP" != "$APP_ROLE" ]; then
    echo "Nothing to migrate: '$APP_ROLE' is not the bootstrap superuser."
    echo "(bash scripts/harden-db-role.sh reports the current state.)"
    exit 0
fi

DATABASES=$(psql_q "SELECT datname FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres');" | tr -d '\r')
DB_CID=$(compose ps -q db)
VOL=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Name}}{{end}}{{end}}' "$DB_CID")
DATA_SIZE=$(docker run --rm -v "$VOL":/d:ro alpine du -sh /d 2>/dev/null | cut -f1)

echo ""
echo "Cluster:    bootstrap superuser is '$APP_ROLE' — migration needed"
echo "Databases:  $(echo "$DATABASES" | tr '\n' ' ')"
echo "Volume:     $VOL ($DATA_SIZE)"
echo ""
echo "This will:"
echo "  1. dump every database to backups/migration_$TS/"
echo "  2. stop the other containers (site goes DOWN)"
echo "  3. copy the old data to rollback volume '${VOL}-premigration'"
echo "  4. wipe and re-initialize the cluster ('$APP_ROLE' becomes unprivileged)"
echo "  5. restore every database and start everything again"
echo ""
echo "Free disk needed: roughly the data size again for the rollback copy,"
echo "plus the dumps. Rollback instructions are printed at the end."
echo ""
read -r -p "Type MIGRATE to continue: " CONFIRM
if [ "$CONFIRM" != "MIGRATE" ]; then
    echo "Aborted — nothing was changed."
    exit 1
fi

mkdir -p "$MIGDIR"
touch "$LOG"

# ── 2. Dump every database, and record a table count to verify against ─
declare -A TABLE_COUNT
for db in $DATABASES; do
    echo "→ Dumping $db ..."
    compose exec -T db pg_dump -U "$APP_ROLE" -Fc "$db" > "$MIGDIR/$db.dump"
    [ -s "$MIGDIR/$db.dump" ] || { echo "Dump of $db is EMPTY — aborting before anything is touched." >&2; exit 1; }
    TABLE_COUNT[$db]=$(compose exec -T db psql -U "$APP_ROLE" -d "$db" -t -A -c \
        "SELECT count(*) FROM pg_class WHERE relkind = 'r' AND relnamespace = 'public'::regnamespace;" </dev/null | tr -d '[:space:]')
    echo "   $(du -h "$MIGDIR/$db.dump" | cut -f1), ${TABLE_COUNT[$db]} tables"
done

# ── 3. Stop everything else that talks to this database ───────────────
DB_NAME=$(docker inspect -f '{{.Name}}' "$DB_CID" | sed 's|^/||')
NET=$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' "$DB_CID")
PEERS=$(docker network inspect "$NET" -f '{{range .Containers}}{{.Name}}{{"\n"}}{{end}}' | grep -v "^${DB_NAME}$" | grep -v '^$' || true)
if [ -n "$PEERS" ]; then
    echo "→ Stopping: $(echo "$PEERS" | tr '\n' ' ')"
    # shellcheck disable=SC2086
    docker stop $PEERS >/dev/null
fi

# ── 4. Rollback copy, then wipe and re-initialize ─────────────────────
echo "→ Stopping the database..."
compose stop db >/dev/null
echo "→ Copying old data to rollback volume '${VOL}-premigration' ..."
docker run --rm -v "$VOL":/from:ro -v "${VOL}-premigration":/to alpine \
    sh -c 'cd /from && cp -a . /to' >>"$LOG" 2>&1
echo "→ Wiping the data volume and re-initializing..."
docker run --rm -v "$VOL":/d alpine sh -c 'find /d -mindepth 1 -delete' >>"$LOG" 2>&1
compose up -d db >/dev/null

# Wait for the NEW cluster: TCP login as the (new, unprivileged) app role
# proves initdb finished, db-init ran, and password auth works.
echo "→ Waiting for the new cluster..."
for i in $(seq 1 60); do
    if compose exec -T -e PGPASSWORD="$APP_PASS" db \
         psql -h 127.0.0.1 -U "$APP_ROLE" -d postgres -c "SELECT 1;" </dev/null >/dev/null 2>&1; then
        break
    fi
    [ "$i" -eq 60 ] && { echo "New cluster did not come up — see rollback instructions below; old data is intact in '${VOL}-premigration'." >&2; exit 1; }
    sleep 2
done

# ── 5. Restore ────────────────────────────────────────────────────────
RESTORE_WARNINGS=0
for db in $DATABASES; do
    echo "→ Restoring $db ..."
    compose exec -T db createdb -U "$APP_ROLE" "$db" </dev/null
    rc=0
    compose exec -T db pg_restore -U "$APP_ROLE" --no-owner --role="$APP_ROLE" -d "$db" \
        < "$MIGDIR/$db.dump" >>"$LOG" 2>&1 || rc=$?
    if [ "$rc" -gt 1 ]; then
        echo "   RESTORE FAILED (exit $rc) — see $LOG. Old data is intact in '${VOL}-premigration'." >&2
        exit "$rc"
    fi
    [ "$rc" -eq 1 ] && { echo "   restored with warnings (usually harmless COMMENT/extension notices — check $LOG)"; RESTORE_WARNINGS=1; }
    GOT=$(compose exec -T db psql -U "$APP_ROLE" -d "$db" -t -A -c \
        "SELECT count(*) FROM pg_class WHERE relkind = 'r' AND relnamespace = 'public'::regnamespace;" </dev/null | tr -d '[:space:]')
    if [ "$GOT" != "${TABLE_COUNT[$db]}" ]; then
        echo "   TABLE COUNT MISMATCH for $db: expected ${TABLE_COUNT[$db]}, got $GOT — investigate before deleting the rollback volume." >&2
        RESTORE_WARNINGS=1
    else
        echo "   OK: $GOT tables"
    fi
done

# ── 6. Start everything again and report ──────────────────────────────
if [ -n "$PEERS" ]; then
    # shellcheck disable=SC2086
    docker start $PEERS >/dev/null 2>&1 || true
fi
compose up -d >/dev/null 2>&1 || true

echo ""
echo "═══════════════════════════════════════════"
echo "✓ Migration complete. Roles now:"
psql_q "SELECT '  ' || rolname || ': superuser=' || rolsuper || ', createdb=' || rolcreatedb
        FROM pg_roles WHERE rolname IN ('postgres', '$APP_ROLE') ORDER BY rolname;"
echo ""
echo "Dumps kept in:      $MIGDIR"
echo "Rollback copy:      docker volume '${VOL}-premigration'"
echo ""
if [ "$RESTORE_WARNINGS" -eq 1 ]; then
    echo "⚠  There were warnings — review $LOG and test the site before cleanup."
fi
echo "After a few days of normal operation, reclaim the space with:"
echo "    docker volume rm ${VOL}-premigration"
echo "    rm -rf $MIGDIR"
echo ""
echo "To roll back instead:"
echo "    docker compose stop db"
echo "    docker run --rm -v $VOL:/d alpine sh -c 'find /d -mindepth 1 -delete'"
echo "    docker run --rm -v ${VOL}-premigration:/from -v $VOL:/to alpine sh -c 'cd /from && cp -a . /to'"
echo "    docker compose up -d"
