#!/bin/bash
# ──────────────────────────────────────────────
# ePHEM Module Update Script
# Updates Odoo modules across one or all databases.
#
# Usage:
#   ./scripts/update-modules.sh              (interactive — pick modules & databases)
#   ./scripts/update-modules.sh --auto       (update all modules on all databases)
#   ./scripts/update-modules.sh --auto --db training-server
#
# The modules come from every source folder of the Odoo acted on (the
# addons/ parent: ePHEM-core plus whatever manage.sh → Addons added).
#
# Multi-instance developer mode (EPHEM_MODE=dev-multi in .env): acts on ONE
# instance, its odcaN/ code and, by default, its own database ephem_N. The
# instance is --instance N, else the one manage.sh pinned last (EPHEM_INSTANCE
# in .env), else the first in .dev-instances:
#   ./scripts/update-modules.sh --instance 2            (pick modules, ephem_2)
#   ./scripts/update-modules.sh --instance 2 --auto     (every module, ephem_2)
# The instance is stopped for the run (a dev server holds the registry) and
# started again afterwards, the same way scripts/dev-logs.sh does it.
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

# Mode, compose files and the Odoo to act on: scripts/stack-lib.sh
EPHEM_ROOT="$SCRIPT_DIR"
# shellcheck source=stack-lib.sh
source "$SCRIPT_DIR/scripts/stack-lib.sh"

DB_PASS=$(env_get POSTGRES_PASSWORD)
if [ -z "$DB_PASS" ]; then
    echo -e "${RED}✗${NC} Cannot read POSTGRES_PASSWORD from .env"
    exit 1
fi

# ── Parse arguments ──────────────────────────
AUTO_MODE=false
SPECIFIC_DB=""
SPECIFIC_ACTION=""
INSTANCE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --auto)     AUTO_MODE=true; shift ;;
        --db)       SPECIFIC_DB="$2"; shift 2 ;;
        --install)  SPECIFIC_ACTION="install"; shift ;;
        --instance) INSTANCE="$2"; shift 2 ;;
        *)          echo "Unknown option: $1"; exit 1 ;;
    esac
done

stack_init "$INSTANCE" || { echo -e "${RED}✗${NC} $STACK_ERROR"; exit 1; }

# ── Module list (in update order) ────────────
# Where a new entry goes: a new eoc_ module after the last eoc_ entry, any
# other module at the bottom of the list. The three below are the one
# exception, and only because eoc_base depends on the theme: Odoo refuses to
# update a module whose new dependency is not yet installed.
MODULES=(
  "disable_odoo_online"
  "remove_odoo_enterprise"
  "ephem_theme_backend"
  "eoc_base"
  "eoc_actors"
  "eoc_signals"
  "eoc_incident_management"
  # OCA's Document Management System, and the PHEOC Repository layer built on
  # it. `eoc_documents` depends on dms, eoc_signals and eoc_incident_management,
  # so it follows all three; `dms` leads because the layer is built on it.
  #
  # Their absence from this list would not be cosmetic. `--auto` upgrades what
  # the list names and nothing else, so a Repository release would be written,
  # committed, deployed — and silently not applied, because the modules were
  # never told to reload. That is precisely what happened to eoc_ear_academy,
  # whose course data sat undeployed through several revisions for the same
  # reason, and the note against it further down this list records it.
  "dms"
  "eoc_documents"
  "eoc_mass_mailing_tailoring"
  "eoc_meetings"
  "eoc_linelist"
  "eoc_regional_level"
  "eoc_regional_level_who"
  "eoc_regional_level_acdc"
  "eoc_ai"
  "eoc_theme_backend"
  "eoc_sso_only"
  "eoc_organogram"
  "eoc_whin_connector"
  "eoc_mail_acdc"
  "eoc_api_migration"
  "eoc_project"
  "eoc_project_management"
  "eoc_dashboard"
  "eoc_eios_connector"
  "eoc_dhis2_connector"
  "eoc_incident_task_flexible"
  "eoc_district_auto_state"
  "eoc_platform_ext"
  "eoc_call_center"
  "eoc_emt"
  "eoc_supply_chain"
  "eoc_inventory"
  "eoc_star_api"
  "eoc_herams"
  "eoc_lims"
  "eoc_surveillance"
  "eoc_casualty_surveillance"
  "eoc_rapid_signals"
  "eoc_training_mode"
  "eoc_demo_mode"
  "eoc_signals_academy"
  "eoc_incident_academy"
  "eoc_ear_academy"
  "eoc_rrt"
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
  "eoc_contingency_plan_demo_data"
  "eoc_ethiopia"
  "eoc_bangladesh"
  "eoc_cabo_verde"
  "eoc_austria"
  "eoc_brazil"
  "eoc_czech"
  "eoc_iraq"
  "eoc_italy"
  "eoc_liberia"
  "eoc_sudan"
  "eoc_togo"
  "eoc_uganda"
  "eoc_yemen"
  "ephem_api_base"
  "ephem_theme_push"
  "ephem_survey"
  "ephem_analytics"
  "ephem_connect"
  "ephem_bridge"
  "cmp_core"
  "cmp_entity"
  "cmp_consent"
  "cmp_credential"
  "cmp_resources"
  "cmp_deployment"
  "cmp_import"
  "cmp_question_bank"
  "cmp_global_view"
  "cmp_comms"
  "cmp_training"
  "cmp_event_assessment"
  "cmp_mail_templates"
  "cmp_members"
  "cmp_social"
  "cmp_ticket"
  "cmp_working_plan"
  "ephem_analytics_cmp"
  "web_replace_url"
  "mail"
  "web_hierarchy"
)

# ── Auto-include every eoc_* / ephem_* module in the addons folders ─────
# The curated list above fixes the update order for the core chain; any
# module matching these prefixes that is not already listed is appended,
# from every source folder (ePHEM-core and whatever was added next to it).
# New modules added to a repo are picked up automatically — no need to
# edit this script. Safe against every database: Odoo's -u simply skips
# module names that are not installed on that database.
while IFS= read -r _src; do
    [ -n "$_src" ] || continue
    for _dir in "$_src"/eoc_*/ "$_src"/ephem_*/ "$_src"/cmp_*/; do
        [ -f "$_dir/__manifest__.py" ] || continue
        _mod=$(basename "$_dir")
        _known=false
        for _m in "${MODULES[@]}"; do [ "$_m" = "$_mod" ] && { _known=true; break; }; done
        [ "$_known" = false ] && MODULES+=("$_mod")
    done
done < <(addons_module_dirs "$ADDONS_DIR")
unset _src _dir _mod _known _m

# ── Get all databases ────────────────────────
get_databases() { list_dbs; }

# ── Stop / start the Odoo around the run ─────
# A developer server (workers=0, dev_mode) holds the registry and reloads on
# file changes, so the one-shot runs against a stopped instance, as
# scripts/dev-logs.sh does. A production server keeps serving: the update
# runs inside the live container, and Odoo is restarted at the end.
ODOO_WAS_RUNNING=false
[ "$(svc_state "$ODOO_SVC")" = "running" ] && ODOO_WAS_RUNNING=true

odoo_pause() {
    if [ "$EPHEM_MODE" != server ] && [ "$ODOO_WAS_RUNNING" = true ]; then
        echo "Stopping $ODOO_SVC for the run..."
        compose stop "$ODOO_SVC" >/dev/null
    fi
}

odoo_resume() {
    echo ""
    if [ "$EPHEM_MODE" != server ]; then
        if [ "$ODOO_WAS_RUNNING" = true ]; then
            svc_start "$ODOO_SVC" >/dev/null 2>&1 || svc_start "$ODOO_SVC"
        else
            echo "$ODOO_SVC was not running before; leaving it stopped."
            echo "  Start it:  bash scripts/dev-logs.sh ${EPHEM_INSTANCE:-}"
        fi
    else
        echo "Restarting Odoo..."
        svc_restart "$ODOO_SVC"
    fi
    echo -e "${GREEN}✓${NC} Done."
    echo ""
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

    # Run with live output. sh -c so the command inherits the container's
    # environment (HOST, PORT, USER, PASSWORD). Inside the live container
    # when it is running, else in a throwaway one on the same volumes.
    local -a RUNNER
    if [ "$(svc_state "$ODOO_SVC")" = "running" ]; then
        RUNNER=(compose exec -T "$ODOO_SVC")
    else
        RUNNER=(compose run --rm -T --no-deps "$ODOO_SVC")
    fi
    "${RUNNER[@]}" \
        sh -c "odoo $FLAG $MODULES_CSV -d $DB --db_host \$HOST --db_port \$PORT --db_user \$USER --db_password \$PASSWORD --stop-after-init --no-http" \
        </dev/null 2>&1 | \
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
echo -e "Mode:     $(ephem_mode_label)"
if [ "$EPHEM_MODE" = dev-multi ]; then
    echo -e "Instance: ${BOLD}$EPHEM_INSTANCE${NC}  (code: $ADDONS_NAME/, service: $ODOO_SVC)"
fi
echo -e "Sources:  $(addons_sources "$ADDONS_DIR" | tr '\n' ' ' | sed 's/ *$//' | grep . || echo "(none: $ADDONS_NAME/ is empty)")"
addons_warn_duplicates "$ADDONS_DIR" || true
echo ""

# ── Get database list ────────────────────────
# dev-multi: the instance's own database only. The other instances run other
# branches of the code; updating their databases through this container
# would load the wrong modules into them.
if [ -n "$SPECIFIC_DB" ]; then
    DATABASES=("$SPECIFIC_DB")
elif [ "$EPHEM_MODE" = dev-multi ]; then
    DATABASES=("$ODOO_DB")
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
    odoo_pause

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
    odoo_resume
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
odoo_pause

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
odoo_resume