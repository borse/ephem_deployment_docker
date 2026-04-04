#!/bin/bash
# ──────────────────────────────────────────────
# ePHEM Module Update Script
# Updates Odoo modules across one or all databases.
#
# Usage:
#   ./scripts/update-modules.sh              (interactive — pick modules & databases)
#   ./scripts/update-modules.sh --auto       (update all modules on all databases)
#   ./scripts/update-modules.sh --auto --db training-server
# ──────────────────────────────────────────────

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/update_${TIMESTAMP}.log"

# ── Read database credentials from .env ──────
DB_USER=$(grep "^POSTGRES_USER=" "$SCRIPT_DIR/.env" 2>/dev/null | cut -d'=' -f2- || echo "odoo")
DB_PASS=$(grep "^POSTGRES_PASSWORD=" "$SCRIPT_DIR/.env" 2>/dev/null | cut -d'=' -f2-)
DB_USER="${DB_USER:-odoo}"

if [ -z "$DB_PASS" ]; then
    echo -e "${RED}✗${NC} Cannot read POSTGRES_PASSWORD from .env"
    exit 1
fi

# ── Module list (in update order) ────────────
MODULES=(
  "eoc_base"
  "eoc_signals"
  "eoc_actors"
  "eoc_incident_management"
  "eoc_mass_mailing_tailoring"
  "eoc_whin_connector"
  "eoc_regional_level"
  "eoc_regional_level_who"
  "eoc_project"
  "eoc_project_management"
  "eoc_dashboard"
  "eoc_eios_connector"
  "eoc_dhis2_connector"
  "ks_dashboard_ninja"
  "ks_website_dashboard_ninja"
  "ks_dn_advance"
  "mail_composer_on_send_message"
  "mail_debrand"
  "mass_mailing_partner"
  "odoo-debrand-11"
  "rowno_in_tree"
  "spiffy_theme_backend"
  "web_timeline"
  "wk_debrand_odoo"
  "base_user_role"
  "document_knowledge"
  "document_management_system"
  "enhanced_document_management"
  "auditlog"
  "eoc_onehealth"
  "eoc_ims"
  "eoc_phsm"
  "eoc_ethiopia"
  "eoc_cabo_verde"
  "web_replace_url"
  "remove_odoo_enterprise"
  "mail"
  "web_hierarchy"
)

# ── Parse arguments ──────────────────────────
AUTO_MODE=false
SPECIFIC_DB=""
SPECIFIC_ACTION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --auto)     AUTO_MODE=true; shift ;;
        --db)       SPECIFIC_DB="$2"; shift 2 ;;
        --install)  SPECIFIC_ACTION="install"; shift ;;
        *)          echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ── Get all databases ────────────────────────
get_databases() {
    docker compose -f "$SCRIPT_DIR/docker-compose.yml" exec -T db \
        psql -U odoo -d postgres -t -A -c \
        "SELECT datname FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres') ORDER BY datname;" \
        2>/dev/null | tr -d '\r'
}

# ── Update modules on a database (batch) ─────
# Runs all selected modules in ONE Odoo command.
# Much faster than running one command per module.
run_batch_update() {
    local DB="$1"
    shift
    local MODULE_LIST="$*"
    local ACTION="${SPECIFIC_ACTION:-update}"
    local FLAG="-u"

    if [ "$ACTION" = "install" ]; then
        FLAG="-i"
    fi

    # Join modules with comma for Odoo CLI
    local MODULES_CSV=$(echo "$MODULE_LIST" | tr ' ' ',')

    echo -e "  ${BOLD}Modules:${NC} $MODULES_CSV"
    echo -e "  ${BOLD}Action:${NC}  $ACTION"
    echo ""

    # Run with live output — user can see progress
    # Pass database credentials explicitly since odoo.conf doesn't have them
    docker compose -f "$SCRIPT_DIR/docker-compose.yml" exec -T odoo \
        odoo $FLAG "$MODULES_CSV" \
        -d "$DB" \
        --db_host db \
        --db_port 5432 \
        --db_user "$DB_USER" \
        --db_password "$DB_PASS" \
        --stop-after-init --no-http 2>&1 | \
        tee -a "$LOG_FILE" | \
        grep --line-buffered -E "INFO|WARNING|ERROR|CRITICAL|Loading|loading|Updat|updat|instal" | \
        sed 's/^/    /'

    # Check exit code from the pipe
    local EXIT_CODE=${PIPESTATUS[0]}
    return $EXIT_CODE
}

# ── Print header ─────────────────────────────
echo ""
echo "========================================="
echo "  ePHEM — Module Update"
echo "========================================="
echo ""
echo -e "Log file: ${CYAN}$LOG_FILE${NC}"
echo ""

# ── Get database list ────────────────────────
if [ -n "$SPECIFIC_DB" ]; then
    DATABASES=("$SPECIFIC_DB")
else
    mapfile -t DATABASES < <(get_databases)
fi

if [ ${#DATABASES[@]} -eq 0 ]; then
    echo -e "${RED}✗${NC} No databases found."
    exit 1
fi

ACTION="${SPECIFIC_ACTION:-update}"

# ── AUTO MODE ────────────────────────────────
if [ "$AUTO_MODE" = true ]; then
    echo -e "${BOLD}Mode:${NC}      Auto"
    echo -e "${BOLD}Action:${NC}    ${ACTION}"
    echo -e "${BOLD}Databases:${NC} ${DATABASES[*]}"
    echo -e "${BOLD}Modules:${NC}   ${#MODULES[@]} modules (batch)"
    echo ""

    FAILED_DBS=()

    for DB in "${DATABASES[@]}"; do
        echo ""
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${CYAN}  Database: $DB${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""

        echo "--- $DB ---" >> "$LOG_FILE"

        if run_batch_update "$DB" "${MODULES[@]}"; then
            echo ""
            echo -e "  ${GREEN}✓ $DB completed${NC}"
        else
            echo ""
            echo -e "  ${RED}✗ $DB had errors (check log)${NC}"
            FAILED_DBS+=("$DB")
        fi
    done

    echo ""
    echo "========================================="
    echo -e "${GREEN}✓ Update complete${NC}"

    if [ ${#FAILED_DBS[@]} -gt 0 ]; then
        echo -e "${RED}  Databases with errors: ${FAILED_DBS[*]}${NC}"
    fi

    echo ""
    echo -e "Full log: ${CYAN}$LOG_FILE${NC}"
    echo "========================================="
    echo ""
    echo "Restarting Odoo..."
    docker compose -f "$SCRIPT_DIR/docker-compose.yml" restart odoo
    echo -e "${GREEN}✓${NC} Done."
    echo ""
    exit 0
fi

# ── MANUAL MODE ──────────────────────────────
echo -e "${BOLD}Mode:${NC} Manual (interactive)"
echo ""

# Step 1: Choose action
echo "What do you want to do?"
echo "  1) Update modules"
echo "  2) Install modules"
echo ""
read -p "Choose [1-2] (default: 1): " ACTION_CHOICE
case "$ACTION_CHOICE" in
    2) ACTION="install" ;;
    *) ACTION="update" ;;
esac

# Step 2: Choose databases
echo ""
echo "Available databases:"
echo "  0) All databases"
for i in "${!DATABASES[@]}"; do
    printf "  %d) %s\n" $((i+1)) "${DATABASES[i]}"
done
echo ""
read -p "Select databases (comma-separated, e.g. 1,3 or 0 for all): " DB_SELECTION

SELECTED_DBS=()
if [ "$DB_SELECTION" = "0" ]; then
    SELECTED_DBS=("${DATABASES[@]}")
else
    IFS=',' read -ra DB_INDICES <<< "$DB_SELECTION"
    for idx in "${DB_INDICES[@]}"; do
        idx=$(echo "$idx" | xargs)
        if [ "$idx" -ge 1 ] && [ "$idx" -le ${#DATABASES[@]} ] 2>/dev/null; then
            SELECTED_DBS+=("${DATABASES[$((idx-1))]}")
        fi
    done
fi

if [ ${#SELECTED_DBS[@]} -eq 0 ]; then
    echo -e "${RED}✗${NC} No databases selected."
    exit 1
fi

# Step 3: Choose modules
echo ""
echo "Available modules:"
echo "  0) All modules (in sequence)"
for i in "${!MODULES[@]}"; do
    printf "  %2d) %s\n" $((i+1)) "${MODULES[i]}"
done
echo ""
read -p "Select modules (comma-separated, e.g. 1,5,6,8 or 0 for all): " MOD_SELECTION

SELECTED_MODULES=()
if [ "$MOD_SELECTION" = "0" ]; then
    SELECTED_MODULES=("${MODULES[@]}")
else
    IFS=',' read -ra MOD_INDICES <<< "$MOD_SELECTION"
    for idx in "${MOD_INDICES[@]}"; do
        idx=$(echo "$idx" | xargs)
        if [ "$idx" -ge 1 ] && [ "$idx" -le ${#MODULES[@]} ] 2>/dev/null; then
            SELECTED_MODULES+=("${MODULES[$((idx-1))]}")
        fi
    done
fi

if [ ${#SELECTED_MODULES[@]} -eq 0 ]; then
    echo -e "${RED}✗${NC} No modules selected."
    exit 1
fi

# Step 4: Confirm
MODULES_CSV=$(echo "${SELECTED_MODULES[*]}" | tr ' ' ',')
echo ""
echo "─────────────────────────────────────────"
echo -e "${BOLD}Action:${NC}    ${ACTION}"
echo -e "${BOLD}Databases:${NC} ${SELECTED_DBS[*]}"
echo -e "${BOLD}Modules:${NC}   $MODULES_CSV"
echo "─────────────────────────────────────────"
echo ""
read -p "Proceed? (y/n) " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

# Step 5: Execute (batch per database)
echo ""

FAILED_DBS=()

for DB in "${SELECTED_DBS[@]}"; do
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Database: $DB${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    SPECIFIC_ACTION="$ACTION"
    echo "--- $DB ---" >> "$LOG_FILE"

    if run_batch_update "$DB" "${SELECTED_MODULES[@]}"; then
        echo ""
        echo -e "  ${GREEN}✓ $DB completed${NC}"
    else
        echo ""
        echo -e "  ${RED}✗ $DB had errors (check log)${NC}"
        FAILED_DBS+=("$DB")
    fi
done

# Summary
echo ""
echo "========================================="
echo -e "${GREEN}✓ Update complete${NC}"

if [ ${#FAILED_DBS[@]} -gt 0 ]; then
    echo -e "${RED}  Databases with errors: ${FAILED_DBS[*]}${NC}"
fi

echo ""
echo -e "Full log: ${CYAN}$LOG_FILE${NC}"
echo "========================================="
echo ""
echo "Restarting Odoo..."
docker compose -f "$SCRIPT_DIR/docker-compose.yml" restart odoo
echo -e "${GREEN}✓${NC} Done."
echo ""