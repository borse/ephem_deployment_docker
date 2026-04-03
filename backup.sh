#!/bin/bash
# ──────────────────────────────────────────────
# ePHEM Backup Script
# Backs up all databases and the filestore
# ──────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BACKUP_DIR="$SCRIPT_DIR/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RETENTION_DAYS=14

mkdir -p "$BACKUP_DIR"

echo "[$TIMESTAMP] Starting backup..."

# Get list of all Odoo databases
DATABASES=$(docker compose -f "$SCRIPT_DIR/docker-compose.yml" exec -T db \
    psql -U odoo -d postgres -t -A -c \
    "SELECT datname FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres');" \
    2>/dev/null | tr -d '\r')

if [ -z "$DATABASES" ]; then
    echo "[$TIMESTAMP] No databases found to back up."
    exit 1
fi

# Backup each database
for DB in $DATABASES; do
    echo "[$TIMESTAMP] Backing up database: $DB"
    docker compose -f "$SCRIPT_DIR/docker-compose.yml" exec -T db \
        pg_dump -U odoo "$DB" | gzip > "$BACKUP_DIR/${DB}_${TIMESTAMP}.sql.gz"
    echo "[$TIMESTAMP] Done: $DB"
done

# Backup filestore
echo "[$TIMESTAMP] Backing up filestore..."
docker compose -f "$SCRIPT_DIR/docker-compose.yml" exec -T odoo \
    tar -czf - -C /var/lib/odoo/filestore . 2>/dev/null > "$BACKUP_DIR/filestore_${TIMESTAMP}.tar.gz" || true
echo "[$TIMESTAMP] Done: filestore"

# Clean old backups
echo "[$TIMESTAMP] Removing backups older than $RETENTION_DAYS days..."
find "$BACKUP_DIR" -type f -name "*.gz" -mtime +$RETENTION_DAYS -delete

echo "[$TIMESTAMP] Backup complete."
ls -lh "$BACKUP_DIR"/*_${TIMESTAMP}* 2>/dev/null
