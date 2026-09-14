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

# Names end up inside SQL identifiers and filestore paths, and a new name
# must be one Odoo itself accepts. Checked before anything is touched: a
# comma-separated list typed by mistake would otherwise become ONE database
# called "a,b,c" (an existing one with a comma is still accepted as SOURCE).
valid_db_name()    { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$'; }
existing_db_name() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._,-]*$'; }
if ! existing_db_name "$SOURCE_DB"; then
    echo -e "${RED}✗${NC} '$SOURCE_DB' is not a valid database name."
    exit 1
fi
for TARGET_DB in "${TARGET_DBS[@]}"; do
    if ! valid_db_name "$TARGET_DB"; then
        echo -e "${RED}✗${NC} '$TARGET_DB' is not a valid database name (letters, digits, . _ -)."
        case "$TARGET_DB" in *,*) echo "  Separate several names with spaces, not commas:  eg2 eg3 eg4 eg5" ;; esac
        exit 1
    fi
done

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Mode, compose files and filestore routing: scripts/stack-lib.sh
EPHEM_ROOT="$SCRIPT_DIR"
# shellcheck source=stack-lib.sh
source "$SCRIPT_DIR/scripts/stack-lib.sh"
stack_init || { echo -e "${RED}✗${NC} $STACK_ERROR"; exit 1; }

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

DB_EXISTS=$(compose exec -T db \
    psql -U "$DB_USER" -d postgres -t -A -c \
    "SELECT 1 FROM pg_database WHERE datname = '$SOURCE_DB';" 2>/dev/null | tr -d '\r')

if [ "$DB_EXISTS" != "1" ]; then
    echo -e "${RED}✗${NC} Database '$SOURCE_DB' does not exist."
    echo ""
    echo "Available databases:"
    compose exec -T db \
        psql -U "$DB_USER" -d postgres -t -A -c \
        "SELECT datname FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres');" 2>/dev/null | tr -d '\r'
    echo ""
    exit 1
fi

echo -e "${GREEN}✓${NC} Source database '$SOURCE_DB' found"

# ── Check for conflicts ──────────────────────
CONFLICTS=()
for TARGET_DB in "${TARGET_DBS[@]}"; do
    EXISTS=$(compose exec -T db \
        psql -U "$DB_USER" -d postgres -t -A -c \
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
        compose exec -T db \
            psql -U "$DB_USER" -d postgres -c \
            "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$c' AND pid <> pg_backend_pid();" > /dev/null 2>&1
        compose exec -T db \
            psql -U "$DB_USER" -d postgres -c "DROP DATABASE \"$c\";" > /dev/null 2>&1
    done
fi

# ── Disconnect users from source ─────────────
echo ""
echo "Preparing source database..."
compose exec -T db \
    psql -U "$DB_USER" -d postgres -c \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$SOURCE_DB' AND pid <> pg_backend_pid();" > /dev/null 2>&1

# ── Duplicate databases ──────────────────────
echo ""
SUCCEEDED=0
FAILED=0

for TARGET_DB in "${TARGET_DBS[@]}"; do
    echo -n "Creating '$TARGET_DB' from '$SOURCE_DB'... "

    if compose exec -T db \
        psql -U "$DB_USER" -d postgres -c \
        "CREATE DATABASE \"$TARGET_DB\" WITH TEMPLATE \"$SOURCE_DB\" OWNER \"$DB_USER\";" > /dev/null 2>&1; then
        echo -e "${GREEN}✓${NC}"
        SUCCEEDED=$((SUCCEEDED + 1))
    else
        echo -e "${RED}✗ failed${NC}"
        FAILED=$((FAILED + 1))
    fi
done

# ── Copy filestore ───────────────────────────
# The copy lands next to the source, on the volume that holds the source's
# filestore (in multi-instance developer mode: that instance's volume).
echo ""
echo "Copying filestore for each database..."

FS_SVC=$(fs_svc_for "$SOURCE_DB")
[ "$EPHEM_MODE" = dev-multi ] && echo "  (volume of instance $(svc_instance "$FS_SVC"))"

for TARGET_DB in "${TARGET_DBS[@]}"; do
    echo -n "Copying filestore for '$TARGET_DB'... "

    odoo_sh_on "$FS_SVC" "
            if [ -d $FILESTORE/$SOURCE_DB ]; then
                rm -rf $FILESTORE/$TARGET_DB
                cp -a $FILESTORE/$SOURCE_DB $FILESTORE/$TARGET_DB
                echo 'done'
            else
                echo 'no filestore to copy'
            fi
        " 2>/dev/null | tr -d '\r' || echo "skipped"
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
compose exec -T db \
    psql -U "$DB_USER" -d postgres -t -A -c \
    "SELECT datname FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres') ORDER BY datname;" 2>/dev/null | tr -d '\r' | sed 's/^/  /'
echo ""

if [ $SUCCEEDED -gt 0 ] && [ "$EPHEM_MODE" = server ]; then
    echo "Make sure each database has a matching domain."
    echo "Add domains with: ./scripts/add-domain.sh domain1 domain2 ..."
elif [ $SUCCEEDED -gt 0 ] && [ "$EPHEM_MODE" = dev-multi ]; then
    echo "Open a copy on instance $(svc_instance "$FS_SVC"):  bash scripts/dev-logs.sh $(svc_instance "$FS_SVC") -d ${TARGET_DBS[0]}"
    echo "(its dbfilter pins the web UI to ephem_$(svc_instance "$FS_SVC"); one-shot runs take any -d)"
fi
echo "========================================="
echo ""