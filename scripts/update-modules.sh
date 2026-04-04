#!/bin/bash
# ──────────────────────────────────────────────
# ePHEM Module Update Script
# Updates Odoo modules across one or all databases.
#
# Usage:
#   ./scripts/update-modules.sh              (interactive)
#   ./scripts/update-modules.sh --auto       (update all modules on all databases)
#   ./scripts/update-modules.sh --auto --db training-server   (one database only)
# ──────────────────────────────────────────────

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# ── Module list (in update order) ────────────
# Modules are updated in this sequence.
# Edit this list to add/remove/reorder modules.
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

# ── Update a single module on a single database ─
run_module_action() {
    local DB="$1"
    local MODULE="$2"
    local ACTION="${3:-update}"
    local FLAG="-u"

    if [ "$ACTION" = "install" ]; then
        FLAG="-i"
    fi

    docker compose -f "$SCRIPT_DIR/docker-compose.yml" exec -T odoo \
        odoo $FLAG "$MODULE" -d "$DB" --stop-after-init --no-http 2>&1
}

# ── Print header ─────────────────────────────
echo ""
echo "========================================="
echo "  ePHEM — Module Update"
echo "========================================="
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

# ── Determine action ────────────────────────
ACTION="update"
if [ -n "$SPECIFIC_ACTION" ]; then
    ACTION="$SPECIFIC_ACTION"
fi

# ── AUTO MODE ────────────────────────────────
if [ "$AUTO_MODE" = true ]; then
    echo -e "${BOLD}Mode:${NC}      Auto (all modules, all databases)"
    echo -e "${BOLD}Action:${NC}    ${ACTION}"
    echo -e "${BOLD}Databases:${NC} ${DATABASES[*]}"
    echo -e "${BOLD}Modules:${NC}   ${#MODULES[@]} modules"
    echo ""

    TOTAL=$((${#DATABASES[@]} * ${#MODULES[@]}))
    CURRENT=0
    FAILED=0
    FAILED_LIST=()

    for DB in "${DATABASES[@]}"; do
        echo ""
        echo -e "${CYAN}━━━ Database: $DB ━━━${NC}"

        for MODULE in "${MODULES[@]}"; do
            CURRENT=$((CURRENT + 1))
            PROGRESS="[$CURRENT/$TOTAL]"
            echo -n -e "  $PROGRESS ${ACTION^}ing ${BOLD}$MODULE${NC}... "

            OUTPUT=$(run_module_action "$DB" "$MODULE" "$ACTION" 2>&1)

            if echo "$OUTPUT" | grep -q "ERROR\|Traceback\|CRITICAL"; then
                echo -e "${RED}✗${NC}"
                FAILED=$((FAILED + 1))
                FAILED_LIST+=("$DB:$MODULE")
            else
                echo -e "${GREEN}✓${NC}"
            fi
        done
    done

    # Summary
    echo ""
    echo "========================================="
    SUCCEEDED=$((TOTAL - FAILED))
    echo -e "${GREEN}✓ Completed: $SUCCEEDED succeeded${NC}"

    if [ $FAILED -gt 0 ]; then
        echo -e "${RED}✗ Failed: $FAILED${NC}"
        echo ""
        echo "Failed modules:"
        for f in "${FAILED_LIST[@]}"; do
            echo "  - $f"
        done
    fi

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
echo ""
echo "─────────────────────────────────────────"
echo -e "${BOLD}Action:${NC}    ${ACTION}"
echo -e "${BOLD}Databases:${NC} ${SELECTED_DBS[*]}"
echo -e "${BOLD}Modules:${NC}   ${SELECTED_MODULES[*]}"
echo "─────────────────────────────────────────"
echo ""
read -p "Proceed? (y/n) " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

# Step 5: Execute
echo ""

TOTAL=$((${#SELECTED_DBS[@]} * ${#SELECTED_MODULES[@]}))
CURRENT=0
FAILED=0
FAILED_LIST=()

for DB in "${SELECTED_DBS[@]}"; do
    echo ""
    echo -e "${CYAN}━━━ Database: $DB ━━━${NC}"

    for MODULE in "${SELECTED_MODULES[@]}"; do
        CURRENT=$((CURRENT + 1))
        PROGRESS="[$CURRENT/$TOTAL]"
        echo -n -e "  $PROGRESS ${ACTION^}ing ${BOLD}$MODULE${NC}... "

        OUTPUT=$(run_module_action "$DB" "$MODULE" "$ACTION" 2>&1)

        if echo "$OUTPUT" | grep -q "ERROR\|Traceback\|CRITICAL"; then
            echo -e "${RED}✗${NC}"
            FAILED=$((FAILED + 1))
            FAILED_LIST+=("$DB:$MODULE")

            # Show error details
            echo "$OUTPUT" | grep -E "ERROR|Traceback|CRITICAL" | head -3 | sed 's/^/    /'
        else
            echo -e "${GREEN}✓${NC}"
        fi
    done
done

# Summary
echo ""
echo "========================================="
SUCCEEDED=$((TOTAL - FAILED))
echo -e "${GREEN}✓ Completed: $SUCCEEDED succeeded${NC}"

if [ $FAILED -gt 0 ]; then
    echo -e "${RED}✗ Failed: $FAILED${NC}"
    echo ""
    echo "Failed modules:"
    for f in "${FAILED_LIST[@]}"; do
        echo "  - $f"
    done
fi

echo "========================================="
echo ""
echo "Restarting Odoo..."
docker compose -f "$SCRIPT_DIR/docker-compose.yml" restart odoo
echo -e "${GREEN}✓${NC} Done."
echo ""