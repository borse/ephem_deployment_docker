#!/bin/bash
# ──────────────────────────────────────────────
# ePHEM Backup Script
# Dumps every database + the filestore, optionally encrypts the whole
# snapshot, and pings a monitoring URL on success.
#
# Configure in .env (all optional, but the first is STRONGLY recommended):
#
#   BACKUP_AGE_RECIPIENT=age1...
#       Encrypt each snapshot with age (sudo apt install -y age).
#       Generate a key pair on your ADMIN machine, not the server:
#           age-keygen -o ephem-backup-key.txt
#       Put the printed public "age1..." key here. Keep the private key
#       file in a vault, OFF the server — without it nobody can read the
#       backups, including whoever stores the off-site copies.
#
#   BACKUP_PING_URL=https://hc-ping.com/<uuid>
#       Pinged only after a fully successful backup (healthchecks.io,
#       Uptime Kuma, ...). The monitor alerts you when backups STOP
#       arriving — quiet failure is how backups are usually lost.
#
#   BACKUP_KEEP_DAYS=14
#       Local retention.
#
# Restore an ENCRYPTED snapshot (needs the private key from your vault):
#   age -d -i ephem-backup-key.txt backups/TIMESTAMP.tar.age | tar -x
#   → yields the same DBNAME_TIMESTAMP.sql.gz / filestore_*.tar.gz files;
#   restore them as described in README → Backups.
# ──────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BACKUP_DIR="$SCRIPT_DIR/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# `|| true`: a key absent from .env must yield "", not kill the script
# (grep exits 1 on no match, which set -e would treat as fatal).
env_get() { grep "^$1=" "$SCRIPT_DIR/.env" 2>/dev/null | cut -d'=' -f2- | xargs || true; }
AGE_RECIPIENT="$(env_get BACKUP_AGE_RECIPIENT)"
PING_URL="$(env_get BACKUP_PING_URL)"
RETENTION_DAYS="$(env_get BACKUP_KEEP_DAYS)"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
DB_USER="$(env_get POSTGRES_USER)"
DB_USER="${DB_USER:-odoo}"

compose() { docker compose -f "$SCRIPT_DIR/docker-compose.yml" "$@"; }

mkdir -p "$BACKUP_DIR"
echo "[$TIMESTAMP] Starting backup..."

if [ -n "$AGE_RECIPIENT" ]; then
    if ! command -v age >/dev/null 2>&1; then
        echo "[$TIMESTAMP] FATAL: BACKUP_AGE_RECIPIENT is set but 'age' is not installed." >&2
        echo "[$TIMESTAMP]        Install it with: sudo apt install -y age" >&2
        exit 1
    fi
    # Stage plaintext in a hidden dir and remove it on EVERY exit path, so
    # a failed run can never strand unencrypted dumps on disk.
    DEST="$BACKUP_DIR/.staging_$TIMESTAMP"
    mkdir -p "$DEST"
    trap 'rm -rf "$DEST"' EXIT INT TERM
else
    echo "[$TIMESTAMP] WARNING: backups are NOT encrypted — set BACKUP_AGE_RECIPIENT in .env" >&2
    echo "[$TIMESTAMP]          (see the header of this script for how)." >&2
    DEST="$BACKUP_DIR"
fi

# Get list of all Odoo databases
DATABASES=$(compose exec -T db psql -U "$DB_USER" -d postgres -t -A -c \
    "SELECT datname FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres');" \
    | tr -d '\r')

if [ -z "$DATABASES" ]; then
    echo "[$TIMESTAMP] No databases found to back up."
    exit 1
fi

# Backup each database (pipefail makes a failed pg_dump abort the run)
for DB in $DATABASES; do
    echo "[$TIMESTAMP] Backing up database: $DB"
    compose exec -T db pg_dump -U "$DB_USER" "$DB" | gzip > "$DEST/${DB}_${TIMESTAMP}.sql.gz"
    echo "[$TIMESTAMP] Done: $DB"
done

# Backup filestore (attachments / uploaded documents). tar exit 1 means
# "file changed while reading" — routine on a live system, not a failure.
# Exit 2+ is a real error and must abort instead of being swallowed.
echo "[$TIMESTAMP] Backing up filestore..."
if compose exec -T odoo test -d /var/lib/odoo/.local/share/Odoo/filestore </dev/null 2>/dev/null; then
    rc=0
    compose exec -T odoo tar -czf - -C /var/lib/odoo/.local/share/Odoo/filestore . \
        > "$DEST/filestore_${TIMESTAMP}.tar.gz" || rc=$?
    if [ "$rc" -gt 1 ]; then
        echo "[$TIMESTAMP] FATAL: filestore backup failed (tar exit $rc)" >&2
        exit "$rc"
    fi
    [ "$rc" -eq 1 ] && echo "[$TIMESTAMP] Note: files changed while archiving (normal on a live system)"
    echo "[$TIMESTAMP] Done: filestore"
else
    echo "[$TIMESTAMP] Note: no filestore directory yet — skipping"
fi

# Config needed to rebuild this server. Bundled only into ENCRYPTED
# snapshots, because .env and odoo.conf contain passwords.
if [ -n "$AGE_RECIPIENT" ]; then
    CONF_FILES=()
    for f in .env odoo.conf docker-compose.yml nginx/active.conf nginx/default.conf; do
        [ -f "$SCRIPT_DIR/$f" ] && CONF_FILES+=("$f")
    done
    tar -czf "$DEST/config_${TIMESTAMP}.tar.gz" -C "$SCRIPT_DIR" "${CONF_FILES[@]}"
    echo "[$TIMESTAMP] Done: config"

    # Encrypt the snapshot. Written to a .partial name first so an
    # interrupted run never leaves a truncated file that looks valid.
    OUT="$BACKUP_DIR/${TIMESTAMP}.tar.age"
    tar -C "$DEST" -cf - . | age -r "$AGE_RECIPIENT" -o "${OUT}.partial"
    mv "${OUT}.partial" "$OUT"
    chmod 600 "$OUT"
    rm -rf "$DEST"
    trap - EXIT INT TERM
    echo "[$TIMESTAMP] Encrypted snapshot: $OUT ($(du -h "$OUT" | cut -f1))"

    # ── Copy OFF-SITE (strongly recommended — a backup on the same disk
    # ── dies with the server). Example, with rclone configured:
    # rclone copy "$OUT" remote:ephem-backups/$(hostname)/
fi

# Clean old backups (encrypted snapshots, legacy plain files, stray
# staging dirs and .partial files from killed runs)
echo "[$TIMESTAMP] Removing backups older than $RETENTION_DAYS days..."
find "$BACKUP_DIR" -maxdepth 1 -type f \
    \( -name '*.gz' -o -name '*.age' -o -name '*.age.partial' \) \
    -mtime +"$RETENTION_DAYS" -delete
find "$BACKUP_DIR" -maxdepth 1 -type d -name '.staging_*' -mtime +1 -exec rm -rf {} +

echo "[$TIMESTAMP] Backup complete."
ls -lh "$BACKUP_DIR"/*"${TIMESTAMP}"* 2>/dev/null || true

# Tell the monitor we succeeded (only reached if everything above passed)
if [ -n "$PING_URL" ]; then
    curl -fsS -m 10 --retry 3 "$PING_URL" >/dev/null \
        || echo "[$TIMESTAMP] WARN: could not reach BACKUP_PING_URL" >&2
fi
