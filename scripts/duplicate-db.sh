#!/bin/bash
# ──────────────────────────────────────────────
# ePHEM Duplicate Database Script
# Copies one database into multiple new databases.
#
# Usage:
#   ./scripts/duplicate-db.sh source-db new-db1 new-db2 new-db3
#
# Examples:
#   ./scripts/duplicate-db.sh training-01 training-02 training-03 training-04 training-05
#   ./scripts/duplicate-db.sh production staging
# ──────────────────────────────────────────────

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ $# -lt 2 ]; then
    echo ""
    echo "Usage: ./scripts/duplicate-db.sh SOURCE_DB TARGET_DB [TARGET_DB2] [TARGET_DB3] ..."
    echo ""
    echo "Examples:"
    echo "  ./scripts/duplicate-db.sh training-01 training-02 training-03 training-04 training-05"
    echo "  ./scripts/duplicate-db.sh production staging"
    echo ""
    exit 1
fi

SOURCE_DB="$1"
shift
TARGET_DBS=("$@")

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo ""
echo "========================================="
echo "  ePHEM — Duplicate Database"
echo "========================================="
echo ""
echo "Source:  $SOURCE_DB"
echo "Targets: ${TARGET_DBS[*]}"
echo "Count:   ${#TARGET_DBS[@]} copies"
echo ""

# ── Check source database exists ─────────────
echo "Checking source database..."

DB_EXISTS=$(docker compose -f "$SCRIPT_DIR/docker-compose.yml" exec -T db \
    psql -U odoo -d postgres -t -A -c \
    "SELECT 1 FROM pg_database WHERE datname = '$SOURCE_DB';" 2>/dev/null | tr -d '\r')

if [ "$DB_EXISTS" != "1" ]; then
    echo -e "${RED}✗${NC} Database '$SOURCE_DB' does not exist."
    echo ""
    echo "Available databases:"
    docker compose -f "$SCRIPT_DIR/docker-compose.yml" exec -T db \
        psql -U odoo -d postgres -t -A -c \
        "SELECT datname FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres');" 2>/dev/null | tr -d '\r'
    echo ""
    exit 1
fi

echo -e "${GREEN}✓${NC} Source database '$SOURCE_DB' found"

# ── Check for conflicts ──────────────────────
CONFLICTS=()
for TARGET_DB in "${TARGET_DBS[@]}"; do
    EXISTS=$(docker compose -f "$SCRIPT_DIR/docker-compose.yml" exec -T db \
        psql -U odoo -d postgres -t -A -c \
        "SELECT 1 FROM pg_database WHERE datname = '$TARGET_DB';" 2>/dev/null | tr -d '\r')

    if [ "$EXISTS" = "1" ]; then
        CONFLICTS+=("$TARGET_DB")
    fi
done

if [ ${#CONFLICTS[@]} -gt 0 ]; then
    echo ""
    echo -e "${YELLOW}! The following databases already exist:${NC}"
    for c in "${CONFLICTS[@]}"; do
        echo "  - $c"
    done
    echo ""
    read -p "Overwrite them? This will DELETE their data. (y/n) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi

    # Drop conflicting databases
    for c in "${CONFLICTS[@]}"; do
        echo "Dropping '$c'..."
        docker compose -f "$SCRIPT_DIR/docker-compose.yml" exec -T db \
            psql -U odoo -d postgres -c \
            "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$c' AND pid <> pg_backend_pid();" > /dev/null 2>&1
        docker compose -f "$SCRIPT_DIR/docker-compose.yml" exec -T db \
            psql -U odoo -d postgres -c "DROP DATABASE \"$c\";" > /dev/null 2>&1
    done
fi

# ── Disconnect users from source ─────────────
echo ""
echo "Preparing source database..."
docker compose -f "$SCRIPT_DIR/docker-compose.yml" exec -T db \
    psql -U odoo -d postgres -c \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$SOURCE_DB' AND pid <> pg_backend_pid();" > /dev/null 2>&1

# ── Duplicate databases ──────────────────────
echo ""
SUCCEEDED=0
FAILED=0

for TARGET_DB in "${TARGET_DBS[@]}"; do
    echo -n "Creating '$TARGET_DB' from '$SOURCE_DB'... "

    if docker compose -f "$SCRIPT_DIR/docker-compose.yml" exec -T db \
        psql -U odoo -d postgres -c \
        "CREATE DATABASE \"$TARGET_DB\" WITH TEMPLATE \"$SOURCE_DB\" OWNER odoo;" > /dev/null 2>&1; then
        echo -e "${GREEN}✓${NC}"
        SUCCEEDED=$((SUCCEEDED + 1))
    else
        echo -e "${RED}✗ failed${NC}"
        FAILED=$((FAILED + 1))
    fi
done

# ── Copy filestore ───────────────────────────
echo ""
echo "Copying filestore for each database..."

for TARGET_DB in "${TARGET_DBS[@]}"; do
    echo -n "Copying filestore for '$TARGET_DB'... "

    docker compose -f "$SCRIPT_DIR/docker-compose.yml" exec -T odoo \
        sh -c "
            if [ -d /var/lib/odoo/filestore/$SOURCE_DB ]; then
                rm -rf /var/lib/odoo/filestore/$TARGET_DB
                cp -a /var/lib/odoo/filestore/$SOURCE_DB /var/lib/odoo/filestore/$TARGET_DB
                echo 'done'
            else
                echo 'no filestore to copy'
            fi
        " 2>/dev/null || echo "skipped"
done

# ── Summary ──────────────────────────────────
echo ""
echo "========================================="
echo -e "${GREEN}✓ Duplication complete!${NC}"
echo ""
echo "  Succeeded: $SUCCEEDED"
if [ $FAILED -gt 0 ]; then
    echo -e "  ${RED}Failed:    $FAILED${NC}"
fi
echo ""
echo "Databases on this server:"
docker compose -f "$SCRIPT_DIR/docker-compose.yml" exec -T db \
    psql -U odoo -d postgres -t -A -c \
    "SELECT datname FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres') ORDER BY datname;" 2>/dev/null | tr -d '\r' | sed 's/^/  /'
echo ""

if [ $SUCCEEDED -gt 0 ]; then
    echo "Make sure each database has a matching domain."
    echo "Add domains with: ./scripts/add-domain.sh domain1 domain2 ..."
fi
echo "========================================="
echo ""