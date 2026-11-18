#!/bin/bash
# ──────────────────────────────────────────────
# ePHEM Module Update Script
# Updates Odoo modules across one or all databases.
#
# Usage:
#   ./scripts/update-modules.sh              (interactive — pick modules & databases)
#   ./scripts/update-modules.sh --auto       (update all modules on all databases)
#   ./scripts/update-modules.sh --auto --db training-server
#   ./scripts/update-modules.sh --auto --stop-odoo   (Odoo stopped for the run)
#   ./scripts/update-modules.sh --auto --changed     (only what changed, per database)
#   ./scripts/update-modules.sh --auto --ask-odoo    (asks whether to stop Odoo first)
#   ./scripts/update-modules.sh --auto --changed --install-too eoc_rrt
#                                     (update, and install eoc_rrt in the same run)
#   ./scripts/update-modules.sh --auto --jobs 1  (one database at a time)
#
# Update and install in one run: Odoo accepts -u and -i together, and a module
# that must arrive in the same run as another's update (as eoc_rrt once had to
# beside eoc_actors, to keep its rows) goes in --install-too, or in the
# question after the module menu. An installed one is left as it is.
#
# What changed: every database keeps a small table, ephem_update_state, with a
# fingerprint of each module's code as it was when that database last updated
# it. "Only what changed" (menu c, or --changed) compares those with the code on
# disk and updates exactly the installed modules that differ, database by
# database. Every successful run records the modules Odoo updated, whatever
# was picked. A database with no record yet updates every installed module
# once, which starts the record. The fingerprint is git's own hash of the
# module folder; a folder with uncommitted changes, or outside git, is hashed
# file by file.
#
# Server mode: by default Odoo keeps serving while the update runs inside its
# container, and is restarted at the end. --stop-odoo stops it first instead
# (every tenant offline until the run ends), --keep-running says the default
# out loud; without either, manual mode asks. Stopping avoids the update
# fighting the live server for the database (a "deadlock detected" when a
# migration drops a column of a busy table, as on pheoc on 7 Nov 2026), and
# the run is often faster for it.
#
# Several databases at once: each database is its own Odoo process and its
# own transaction, and nearly all of the minute it takes is Odoo reloading
# XML and checking tables on one CPU core. With more than one database to
# update, the run starts several side by side: half the CPUs, at most one
# per free GB of memory, at most 4. --jobs N sets the number (1 = one at a
# time, the full Odoo log on screen as before). Each database then logs to
# its own file while it runs, joined into the one log in order at the end.
#
# The modules come from every source folder of the Odoo acted on (the
# addons/ parent: ePHEM-core plus whatever was added from manage.sh).
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
STOP_ODOO=""            # server mode: yes / no; empty = ask (manual) or no (auto)
CHANGED_MODE=false      # only the modules whose code changed, per database
ALL_MODE=false          # manual "0": every listed module installed on each database
ASK_ODOO=false          # --auto, but ask whether to stop Odoo (manage.sh after a pull)
INSTALL_TOO=""          # modules installed in the same run as the update (comma separated)
JOBS=""                 # databases updated at once; empty = suited to this machine

while [[ $# -gt 0 ]]; do
    case "$1" in
        --auto)     AUTO_MODE=true; shift ;;
        --db)       SPECIFIC_DB="$2"; shift 2 ;;
        --install)  SPECIFIC_ACTION="install"; shift ;;
        --instance) INSTANCE="$2"; shift 2 ;;
        --stop-odoo)    STOP_ODOO=yes; shift ;;
        --keep-running) STOP_ODOO=no; shift ;;
        --changed)      CHANGED_MODE=true; shift ;;
        --ask-odoo)     ASK_ODOO=true; shift ;;
        --install-too)  INSTALL_TOO="$2"; shift 2 ;;
        --jobs)         JOBS="${2:-}"; shift 2 ;;
        *)          echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ -n "$JOBS" ] && ! { [[ "$JOBS" =~ ^[0-9]+$ ]] && [ "$JOBS" -ge 1 ] && [ "$JOBS" -le 16 ]; }; then
    echo -e "${RED}✗${NC} --jobs takes a number from 1 to 16: $JOBS"
    exit 1
fi

if [ -n "$INSTALL_TOO" ] && ! [[ "$INSTALL_TOO" =~ ^[A-Za-z0-9_]+(,[A-Za-z0-9_]+)*$ ]]; then
    echo -e "${RED}✗${NC} --install-too takes module names separated by commas: $INSTALL_TOO"
    exit 1
fi

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
  "eoc_training_mode"
  "eoc_demo_mode"
  "eoc_signals_academy"
  "eoc_incident_academy"
  "eoc_ear_academy"
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
  "eoc_georgia"
  "eoc_region"
  "eoc_rrt"
  "eoc_4w"
  "eoc_4w_incident"
  "ephem_api_base"
  "ephem_theme_push"
  "ephem_survey"
  "ephem_analytics"
  "ephem_connect"
  "ephem_bridge"
  "cmp_core"
  "cmp_resources"
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
  "ephem_documents"
  "ephem_custom_views"
)

# ── Auto-include the rest ───────────────────────────────────────────
# The curated list above fixes the update order for the core chain. Every
# other module a routine update covers is appended once, as stack-lib's
# addons_update_modules lists them: ePHEM-core's remaining eoc_*, ephem_*
# and cmp_* modules, and EVERY module of every other source (a country's
# own repository, an OCA repository), whatever its modules are named. New
# modules are picked up automatically, no need to edit this script. Safe
# against every database: Odoo's -u simply skips module names that are
# not installed on that database.
while IFS= read -r _mod; do
    [ -n "$_mod" ] || continue
    _known=false
    for _m in "${MODULES[@]}"; do [ "$_m" = "$_mod" ] && { _known=true; break; }; done
    [ "$_known" = false ] && MODULES+=("$_mod")
done < <(addons_update_modules "$ADDONS_DIR")
unset _mod _known _m

# ── Get all databases ────────────────────────
get_databases() { list_dbs; }

# ── Stop / start the Odoo around the run ─────
# A developer server (workers=0, dev_mode) holds the registry and reloads on
# file changes, so the one-shot runs against a stopped instance, as
# scripts/dev-logs.sh does. A production server keeps serving: the update
# runs inside the live container, and Odoo is restarted at the end.
# On a server the operator may stop it too (STOP_ODOO, asked in manual mode).
ODOO_WAS_RUNNING=false
[ "$(svc_state "$ODOO_SVC")" = "running" ] && ODOO_WAS_RUNNING=true
ODOO_STOPPED=false      # this run stopped Odoo and has not started it again

odoo_pause() {
    [ "$ODOO_WAS_RUNNING" = true ] || return 0
    if [ "$EPHEM_MODE" != server ] || [ "$STOP_ODOO" = yes ]; then
        echo "Stopping $ODOO_SVC for the run..."
        compose stop "$ODOO_SVC" >/dev/null
        ODOO_STOPPED=true
        # Whatever ends the run (an error, Ctrl+C), Odoo comes back.
        trap exit_cleanup EXIT
        trap 'exit_cleanup; exit 130' INT TERM
    fi
}

odoo_resume() {
    echo ""
    if [ "$ODOO_STOPPED" = true ]; then
        echo "Starting $ODOO_SVC again..."
        svc_start "$ODOO_SVC" >/dev/null 2>&1 || svc_start "$ODOO_SVC"
        ODOO_STOPPED=false
    elif [ "$EPHEM_MODE" != server ]; then
        echo "$ODOO_SVC was not running before; leaving it stopped."
        echo "  Start it:  bash scripts/dev-logs.sh ${EPHEM_INSTANCE:-}"
    else
        echo "Restarting Odoo..."
        svc_restart "$ODOO_SVC"
    fi
    echo -e "${GREEN}✓${NC} Done."
    echo ""
}

# The run ended before odoo_resume (an error under set -e, Ctrl+C): never
# leave a server offline because the update did not finish.
odoo_safety_start() {
    [ "$ODOO_STOPPED" = true ] || return 0
    ODOO_STOPPED=false
    echo ""
    echo -e "${YELLOW}!${NC} The run ended early: starting $ODOO_SVC again..."
    svc_start "$ODOO_SVC" >/dev/null 2>&1 || svc_start "$ODOO_SVC" || true
}

exit_cleanup() {
    par_stop_jobs
    progress_teardown
    odoo_safety_start
}

# Server mode, manual run: keep Odoo serving during the update, or stop it.
ask_stop_odoo() {
    [ "$EPHEM_MODE" = server ] && [ "$ODOO_WAS_RUNNING" = true ] && [ -z "$STOP_ODOO" ] || return 0
    echo ""
    echo "Odoo during the update:"
    echo "  1) Keep it running (default)"
    echo "     Users keep working while the update runs, and Odoo restarts at the end"
    echo "     (a few seconds offline). Fine for a routine update: views, data,"
    echo "     translations, small fixes."
    echo "  2) Stop it first"
    echo "     Every tenant on this server is offline until the update ends, usually"
    echo "     one to three minutes per database, shared out over the databases"
    echo "     updated at once ($(jobs_label)). Nothing else uses the database while"
    echo "     it runs, so the update cannot collide with users or scheduled jobs, and"
    echo "     it is often faster. Choose this when the update changes the database"
    echo "     structure (migrations, new or removed modules or fields), or after a"
    echo "     \"deadlock detected\" error."
    echo ""
    read -p "Choose [1-2] (default: 1): " STOP_CHOICE
    case "$STOP_CHOICE" in
        2) STOP_ODOO=yes ;;
        *) STOP_ODOO=no ;;
    esac
}

odoo_plan_label() {
    if [ "$EPHEM_MODE" != server ]; then echo "stopped for the run (developer mode)"
    elif [ "$ODOO_WAS_RUNNING" != true ]; then echo "not running"
    elif [ "$STOP_ODOO" = yes ]; then echo "stopped for the update, started again at the end"
    else echo "keeps running, restarted at the end"; fi
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
    local ODOO_FLAGS=""
    [ -n "$MODULES_CSV" ] && ODOO_FLAGS="$FLAG $MODULES_CSV"
    # Install too, in the same run (an update only: an install run installs anyway).
    if [ -n "$INSTALL_TOO" ] && [ "$ACTION" != install ]; then
        ODOO_FLAGS="$ODOO_FLAGS -i $INSTALL_TOO"
    fi

    echo -e "  ${BOLD}Modules:${NC} ${MODULES_CSV:-(none)}"
    echo -e "  ${BOLD}Action:${NC}  $ACTION"
    if [ -n "$INSTALL_TOO" ] && [ "$ACTION" != install ]; then
        echo -e "  ${BOLD}Install too:${NC} $INSTALL_TOO (same run)"
    fi
    echo ""

    # Run with live output. sh -c so the command inherits the container's
    # environment (HOST, PORT, USER, PASSWORD). Inside the live container
    # when it is running, else in a throwaway one on the same volumes.
    # The password is not an argument when the container carries PGPASSWORD
    # (docker-compose.yml): the database driver reads it from there, and a
    # command line can be read by every account on the server (ps). A
    # container from an older compose file has no PGPASSWORD and gets the
    # argument as before.
    local -a RUNNER
    if [ "$(svc_state "$ODOO_SVC")" = "running" ]; then
        RUNNER=(compose exec -T "$ODOO_SVC")
    else
        RUNNER=(compose run --rm -T --no-deps "$ODOO_SVC")
    fi
    "${RUNNER[@]}" \
        sh -c "if [ -n \"\${PGPASSWORD:-}\" ]; then set --; else set -- --db_password \"\$PASSWORD\"; fi; exec odoo $ODOO_FLAGS -d $DB --db_host \$HOST --db_port \$PORT --db_user \$USER \"\$@\" --stop-after-init --no-http" \
        </dev/null 2>&1 | \
        tee -a "$LOG_FILE" | \
        filter_output

    # Check exit code from the pipe
    local EXIT_CODE=${PIPESTATUS[0]}
    return $EXIT_CODE
}

# ── What changed, and what Odoo will update ──
# Odoo updates each module once per run, and with it every installed module
# that depends on it (their views and data build on it). Picking eoc_base
# therefore updates nearly all of ePHEM; picking eoc_signals beside it adds
# nothing. These helpers ask the database itself, so the answer fits each
# database's own installed modules.

declare -A FP=()          # module -> fingerprint of its code on disk
declare -A DB_MODULES=()  # database -> its own module list (changed mode)
FP_DONE=false

db_sql() {  # db_sql DB SQL → rows, one per line ('' on any error)
    compose exec -T db psql -U "$DB_USER" -d "$1" -t -A -q -c "$2" </dev/null 2>/dev/null | tr -d '\r' || true
}

dir_fingerprint() {  # every file but compiled Python, in a fixed order
    (cd "$1" && find . -type f ! -path '*/__pycache__/*' ! -name '*.pyc' -print0 \
        | LC_ALL=C sort -z | xargs -0 sha1sum 2>/dev/null) | sha1sum | cut -c1-40
}

compute_fingerprints() {
    [ "$FP_DONE" = true ] && return 0
    local src prefix name _mode type hash path dirty
    while IFS= read -r src; do
        [ -d "$src" ] || continue
        if git -C "$src" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            prefix=$(git -C "$src" rev-parse --show-prefix 2>/dev/null)
            # Committed content: git's tree hash of each folder, all in one call.
            while read -r _mode type hash name; do
                [ "$type" = tree ] && [ -f "$src/$name/__manifest__.py" ] && FP[$name]="$hash"
            done < <(git -C "$src" ls-tree "HEAD:$prefix" 2>/dev/null || true)
            # Folders with uncommitted or new files: their files, hashed.
            dirty=$(git -C "$src" status --porcelain=v1 --untracked-files=all -- . 2>/dev/null \
                | sed -E 's/^.{3}//; s/^.* -> //; s/^"//' | sed "s#^$prefix##" | cut -d/ -f1 | sort -u || true)
            for name in $dirty; do
                [ -f "$src/$name/__manifest__.py" ] && FP[$name]=$(dir_fingerprint "$src/$name")
            done
        else
            for path in "$src"/*/; do
                name=$(basename "$path")
                [ -f "$path/__manifest__.py" ] && FP[$name]=$(dir_fingerprint "$path")
            done
        fi
    done < <(addons_module_dirs "$ADDONS_DIR")
    FP_DONE=true
}

# Installed modules covered by a pick, as "module origin" rows: the pick
# itself and every installed module depending on it, directly or not.
db_coverage() {  # db_coverage DB MODULE...
    local db="$1" csv m; shift
    csv=""
    for m in "$@"; do [[ "$m" =~ ^[A-Za-z0-9_]+$ ]] && csv="$csv,$m"; done
    csv="${csv#,}"
    [ -n "$csv" ] || return 0
    db_sql "$db" "WITH RECURSIVE dep AS (
          SELECT m.name AS module, d.name AS parent
            FROM ir_module_module m JOIN ir_module_module_dependency d ON d.module_id = m.id
           WHERE m.state IN ('installed', 'to upgrade')),
        picks(name) AS (SELECT unnest(string_to_array('$csv', ','))),
        cov(name, origin) AS (
          SELECT p.name, p.name FROM picks p
            JOIN ir_module_module m ON m.name = p.name AND m.state IN ('installed', 'to upgrade')
          UNION
          SELECT dep.module, cov.origin FROM dep JOIN cov ON dep.parent = cov.name)
        SELECT name || ' ' || origin FROM cov"
}

show_scope() {  # show_scope DB MODULE...: what Odoo will update there, and why
    local db="$1"; shift
    local rows covered redundant=() missing=() m n
    rows=$(db_coverage "$db" "$@")
    covered=$(awk '{print $1}' <<< "$rows" | grep . | sort -u || true)
    n=$(grep -c . <<< "$covered" || true)
    for m in "$@"; do
        if ! grep -qx "$m $m" <<< "$rows"; then
            missing+=("$m")
        elif awk -v m="$m" '$1 == m && $2 != m {f=1} END {exit !f}' <<< "$rows"; then
            redundant+=("$m")
        fi
    done
    echo -e "  ${BOLD}$db${NC}: Odoo updates ${BOLD}$n${NC} installed module(s) for this selection."
    if [ ${#redundant[@]} -gt 5 ]; then
        echo "    ${#redundant[@]} of these picks are already covered by another one (${redundant[*]:0:5} ...): harmless, each module runs once."
    elif [ ${#redundant[@]} -gt 0 ]; then
        echo "    Already covered by another pick: $(echo "${redundant[*]}" | tr ' ' ',' | sed 's/,/, /g')"
    fi
    if [ ${#missing[@]} -gt 0 ]; then
        echo "    Not installed here, skipped: $(echo "${missing[*]}" | tr ' ' ',' | sed 's/,/, /g')"
    fi
    echo "--- scope on $db: $(echo $covered | tr ' ' ',') ---" >> "$LOG_FILE"
}

# The installed modules whose code changed since this database last recorded
# them (every installed module when it has no record yet).
changed_modules() {  # changed_modules DB → module names, one per line
    local db="$1" m
    compute_fingerprints
    local installed state
    installed=$(db_sql "$db" "SELECT name FROM ir_module_module WHERE state = 'installed' ORDER BY name")
    if [ "$(db_sql "$db" "SELECT to_regclass('ephem_update_state') IS NOT NULL")" != t ]; then
        for m in $installed; do [ -n "${FP[$m]:-}" ] && echo "$m"; done
        return 0
    fi
    declare -A known=()
    while read -r m state; do [ -n "$m" ] && known[$m]="$state"; done \
        < <(db_sql "$db" "SELECT module || ' ' || fingerprint FROM ephem_update_state")
    for m in $installed; do
        [ -n "${FP[$m]:-}" ] && [ "${known[$m]:-}" != "${FP[$m]}" ] && echo "$m"
    done
    return 0
}

# "All": every module installed on this database whose code is in our own
# folders (ePHEM-core and the repositories added from manage.sh),
# the listed ones first in list order. Odoo's official addons (base, mail...)
# are never in those folders, so they never count, even where the list names
# one; nor does an entry whose code is gone.
installed_from_list() {  # installed_from_list DB → module names, one per line
    local m
    compute_fingerprints
    declare -A here=() seen=()
    for m in $(db_sql "$1" "SELECT name FROM ir_module_module WHERE state = 'installed'"); do here[$m]=1; done
    for m in "${MODULES[@]}"; do
        [ -n "${here[$m]:-}" ] && [ -n "${FP[$m]:-}" ] && { echo "$m"; seen[$m]=1; }
    done
    for m in $(printf '%s\n' "${!FP[@]}" | sort); do
        [ -n "${here[$m]:-}" ] && [ -z "${seen[$m]:-}" ] && echo "$m"
    done
    return 0
}

plan_all() {  # plan_all DB...
    local db list
    for db in "$@"; do
        list=$(installed_from_list "$db" | tr '\n' ' ' | sed 's/ *$//')
        DB_MODULES[$db]="$list"
        echo -e "  ${BOLD}$db${NC}: $(wc -w <<< "$list") of our modules are installed there, and only those run (never Odoo's own)."
    done
}

has_update_state() { [ "$(db_sql "$1" "SELECT to_regclass('ephem_update_state') IS NOT NULL")" = t ]; }

# Changed mode: each database gets its own list, shown before the run.
plan_changed() {  # plan_changed DB...
    local db list n
    for db in "$@"; do
        list=$(changed_modules "$db" | tr '\n' ' ' | sed 's/ *$//')
        DB_MODULES[$db]="$list"
        n=$(wc -w <<< "$list")
        if [ "$n" -eq 0 ]; then
            echo -e "  ${BOLD}$db${NC}: nothing changed since its last update, skipped."
            continue
        fi
        if ! has_update_state "$db"; then
            echo -e "  ${BOLD}$db${NC}: no record of an earlier update yet: all $n installed modules this once."
        else
            echo -e "  ${BOLD}$db${NC}: $n changed: $(echo "$list" | sed 's/ /, /g')"
        fi
        show_scope "$db" $list | sed '1s/^  [^:]*: /    /' 
    done
}

# After a successful run: the database records the code it now runs, for
# every module Odoo updated (the picks and what depends on them).
record_state() {  # record_state DB MODULE...
    local db="$1"; shift
    compute_fingerprints
    local m values=""
    for m in $(db_coverage "$db" "$@" | awk '{print $1}' | sort -u); do
        [[ "$m" =~ ^[A-Za-z0-9_]+$ ]] && [[ "${FP[$m]:-}" =~ ^[0-9a-f]{40}$ ]] && values="$values,('$m','${FP[$m]}')"
    done
    [ -n "$values" ] || return 0
    db_sql "$db" "CREATE TABLE IF NOT EXISTS ephem_update_state (
            module varchar PRIMARY KEY, fingerprint varchar NOT NULL,
            updated_on timestamp NOT NULL DEFAULT (now() AT TIME ZONE 'UTC'));
        INSERT INTO ephem_update_state (module, fingerprint) VALUES ${values#,}
        ON CONFLICT (module) DO UPDATE SET fingerprint = EXCLUDED.fingerprint,
            updated_on = now() AT TIME ZONE 'UTC'" >/dev/null
}

# ── Timing and the progress bar ──────────────
# Each database is timed; the time left is the average of the databases done
# so far times the ones still to go. On a terminal a status line is pinned to
# the bottom row (a scroll region keeps the log scrolling above it), redrawn
# twice a second by a background ticker. Not a terminal (piped, cron, CI):
# no bar, the times are printed on the completion lines only.
fmt_dur() {
    local s=$1
    if [ "$s" -ge 3600 ]; then printf '%dh %02dm' $((s/3600)) $((s%3600/60))
    elif [ "$s" -ge 60 ]; then printf '%dm %02ds' $((s/60)) $((s%60))
    else printf '%ds' "$s"; fi
}

# ── Databases at once ────────────────────────
# What this machine carries: half its CPUs (Postgres and the live Odoo keep
# the other half), one per GB of free memory (an update peaks well under
# that), at most 4. --jobs overrides it. Never more than the databases.
N_DBS=1                 # databases in the run, set once they are known
machine_cpus() { nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2; }
machine_free_gb() { awk '/^MemAvailable:/ {print int($2/1048576)}' /proc/meminfo 2>/dev/null || true; }
machine_jobs() {
    local j gb
    j=$(( $(machine_cpus) / 2 ))
    gb=$(machine_free_gb)
    if [[ "$gb" =~ ^[0-9]+$ ]] && [ "$gb" -lt "$j" ]; then j=$gb; fi
    if [ "$j" -gt 4 ]; then j=4; fi
    if [ "$j" -lt 1 ]; then j=1; fi
    echo "$j"
}
effective_jobs() {
    local j=${JOBS:-$(machine_jobs)}
    if [ "$N_DBS" -lt "$j" ]; then j=$N_DBS; fi
    if [ "$j" -lt 1 ]; then j=1; fi
    echo "$j"
}
jobs_label() {
    local j; j=$(effective_jobs)
    if [ "$j" -le 1 ]; then echo "one at a time"; else echo "$j at a time"; fi
}
jobs_plan_label() {
    local why
    if [ -n "$JOBS" ]; then why="--jobs $JOBS"
    else why="$(machine_cpus) CPUs, $(machine_free_gb) GB free; --jobs N to change"; fi
    echo "$(jobs_label) ($why)"
}

PROGRESS_ON=false
PROGRESS_STATE=""
TICKER_PID=""
if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && [ -z "${NO_PROGRESS:-}" ] \
   && stty size </dev/tty >/dev/null 2>&1; then
    PROGRESS_ON=true
fi

# Odoo's log, filtered for the screen as before. "Loading module X (i/N)" is
# what Odoo prints for each module it updates: it also goes to the bar.
filter_output() {
    local line re_mod='Loading module ([^ ]+) \(([0-9]+)/([0-9]+)\)'
    local re_show='INFO|WARNING|ERROR|CRITICAL|Loading|loading|Updat|updat|instal'
    while IFS= read -r line || [ -n "$line" ]; do
        if [ -n "$PROGRESS_STATE" ]; then
            if [[ $line =~ $re_mod ]]; then
                printf 'module %s/%s %s\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[1]}" > "$PROGRESS_STATE"
            elif [[ $line == *"Modules loaded."* ]]; then
                printf 'finishing\n' > "$PROGRESS_STATE"
            fi
        fi
        [[ $line =~ $re_show ]] && printf '    %s\n' "$line"
    done
    return 0
}

# Size of the terminal: "rows cols".
term_size() { stty size </dev/tty 2>/dev/null || echo "24 80"; }

progress_setup() {
    [ "$PROGRESS_ON" = true ] || return 0
    PROGRESS_STATE=$(mktemp)
    local rows _c
    read -r rows _c < <(term_size)
    # One blank line so the cursor is never on the row the bar takes, then
    # the scroll region rows 1..rows-1 (setting it moves the cursor, hence
    # the save and restore around it).
    printf '\n\033[1A\x1b7\033[1;%dr\x1b8' $((rows-1))
    trap exit_cleanup EXIT
    trap 'exit_cleanup; exit 130' INT TERM
}

progress_teardown() {
    [ "$PROGRESS_ON" = true ] || return 0
    progress_stop_ticker
    local rows _c
    read -r rows _c < <(term_size)
    # Whole terminal scrolls again; wipe the bar row.
    printf '\x1b7\033[r\x1b8\x1b7\033[%d;1H\033[2K\x1b8' "$rows"
    rm -f "$PROGRESS_STATE"
    PROGRESS_STATE=""
    PROGRESS_ON=false
}

progress_stop_ticker() {
    if [ -n "$TICKER_PID" ]; then
        kill "$TICKER_PID" 2>/dev/null || true
        wait "$TICKER_PID" 2>/dev/null || true
        TICKER_PID=""
    fi
}

# Background redraw of the bottom row for the database being updated.
# Args: index total db db_start run_start done_seconds done_count
progress_ticker() {
    set +e
    local idx=$1 total=$2 db=$3 db_start=$4 run_start=$5 done_sum=$6 done_n=$7
    local frames='|/-\' f=0 rows cols last_rows=0 last_cols=0 status="starting Odoo" st
    while :; do
        read -r rows cols < <(term_size)
        if [ "$rows" != "$last_rows" ] || [ "$cols" != "$last_cols" ]; then
            printf '\x1b7\033[1;%dr\x1b8' $((rows-1))   # resized: move the region
            last_rows=$rows; last_cols=$cols
        fi
        st=$(cat "$PROGRESS_STATE" 2>/dev/null); [ -n "$st" ] && status=$st

        local now el_db el_run frac pct eta_txt
        now=$(date +%s); el_db=$((now-db_start)); el_run=$((now-run_start))
        # Share of the run done: finished databases, plus the current one
        # estimated from the average (capped at 95% of it).
        frac=$(( (idx-1)*1000 ))
        if [ "$done_n" -gt 0 ]; then
            local avg=$((done_sum/done_n)) cur
            cur=$(( el_db*1000/(avg>0?avg:1) )); [ $cur -gt 950 ] && cur=950
            frac=$((frac+cur))
            local left=$(( avg-el_db )); [ $left -lt 0 ] && left=0
            left=$(( left + avg*(total-idx) ))
            eta_txt="~$(fmt_dur $left) left"
        else
            eta_txt="time left after the first database"
        fi
        pct=$(( frac/total/10 ))

        local barw=20 fill bar
        fill=$(( pct*barw/100 ))
        bar=$(printf '%*s' "$fill" '' | tr ' ' '#')$(printf '%*s' $((barw-fill)) '' | tr ' ' '.')
        local plain=" ${frames:f%4:1} DB $idx/$total $db [$bar] $pct%  this db $(fmt_dur $el_db)  total $(fmt_dur $el_run)  $eta_txt  | $status"
        # Never reach the last column: a wrap on the bottom row scrolls the screen.
        plain=${plain:0:$((cols-1))}
        printf '\x1b7\033[%d;1H\033[7m%s\033[K\033[0m\x1b8' "$rows" "$plain"
        f=$((f+1))
        sleep 0.5
    done
}

# ── Several databases at once ────────────────
# One background copy of this shell per database, at most effective_jobs at
# a time. Each writes into PAR_DIR: <db>.log (its Odoo log), <db>.state (the
# module Odoo is on, for the bar), <db>.start, and, as its very last act,
# <db>.result ("ok SECONDS" or "errors SECONDS"). The main shell starts the
# next database as one ends, prints a line per database as it finishes, and
# joins the logs into LOG_FILE in database order at the end.
PAR_DIR=""
declare -A PAR_PIDS=()      # pid -> database, while it runs
PAR_DONE_SUM=0              # seconds of the databases finished so far
PAR_DONE_N=0

par_job() {  # par_job DB MODULE...  (runs in the background)
    local db="$1"; shift
    local start ok=true
    start=$(date +%s)
    echo "$start" > "$PAR_DIR/$db.start"
    LOG_FILE="$PAR_DIR/$db.log"
    PROGRESS_STATE="$PAR_DIR/$db.state"
    : > "$PROGRESS_STATE"
    {
        echo "Modules: $(IFS=,; echo "${*:-(none)}")"
        if [ -n "$INSTALL_TOO" ]; then echo "Install too: $INSTALL_TOO (same run)"; fi
    } > "$LOG_FILE"
    # The log gets everything (run_batch_update tees it); the screen nothing.
    run_batch_update "$db" "$@" >/dev/null 2>&1 || ok=false
    if [ "$ok" = true ]; then record_state "$db" "$@" ${INSTALL_TOO//,/ }; fi
    echo "$([ "$ok" = true ] && echo ok || echo errors) $(( $(date +%s) - start ))" > "$PAR_DIR/$db.result.tmp"
    mv "$PAR_DIR/$db.result.tmp" "$PAR_DIR/$db.result"
}

kill_tree() {  # kill_tree PID: its children first, so none is left behind
    local c
    for c in $(pgrep -P "$1" 2>/dev/null || true); do kill_tree "$c"; done
    kill "$1" 2>/dev/null || true
}

# Ctrl+C or an error: stop every database still running. As with one at a
# time, an Odoo already updating inside the live container finishes that
# database on its own (docker exec does not pass the signal on).
par_stop_jobs() {
    local pid
    for pid in "${!PAR_PIDS[@]}"; do kill_tree "$pid"; done
    PAR_PIDS=()
}

par_report() {  # par_report DB TOTAL JOBS: one line for a finished database
    local db=$1 total=$2 jobs=$3 res=errors dur=0 s tail=""
    if [ -f "$PAR_DIR/$db.result" ]; then read -r res dur < "$PAR_DIR/$db.result"
    elif [ -f "$PAR_DIR/$db.start" ]; then read -r s < "$PAR_DIR/$db.start"; dur=$(( $(date +%s) - s )); fi
    PAR_DONE_N=$((PAR_DONE_N+1)); PAR_DONE_SUM=$((PAR_DONE_SUM+dur))
    local left_n=$((total-PAR_DONE_N)) avg=$((PAR_DONE_SUM/PAR_DONE_N))
    tail="$PAR_DONE_N/$total done"
    if [ "$left_n" -gt 0 ]; then tail="$tail, ~$(fmt_dur $(( (avg*left_n + jobs-1) / jobs ))) left"; fi
    if [ "$res" = ok ]; then
        echo -e "  ${GREEN}✓${NC} $db completed in $(fmt_dur "$dur")  ·  $tail"
    else
        echo -e "  ${RED}✗ $db had errors after $(fmt_dur "$dur")${NC}  ·  $tail"
        # Its first errors and how it ended (the full log names the database).
        { grep -m3 -E " (ERROR|CRITICAL) " "$PAR_DIR/$db.log" 2>/dev/null || true
          tail -n 6 "$PAR_DIR/$db.log" 2>/dev/null || true; } \
            | awk '!seen[$0]++' | cut -c1-240 | sed 's/^/      /'
        FAILED_DBS+=("$db")
    fi
}

# The bottom row while several run: done so far, then each running database
# with its time and the module Odoo is on.
par_ticker() {  # par_ticker TOTAL JOBS RUN_START
    set +e
    local total=$1 jobs=$2 run_start=$3
    local frames='|/-\' f=0 rows cols last_rows=0 last_cols=0
    while :; do
        read -r rows cols < <(term_size)
        if [ "$rows" != "$last_rows" ] || [ "$cols" != "$last_cols" ]; then
            printf '\x1b7\033[1;%dr\x1b8' $((rows-1))
            last_rows=$rows; last_cols=$cols
        fi
        local now s d r el st done_n=0 done_sum=0 started=0 run_left=0 running="" eta_txt pct
        now=$(date +%s)
        for s in "$PAR_DIR"/*.start; do
            [ -e "$s" ] || continue
            started=$((started+1))
            d=${s##*/}; d=${d%.start}
            if [ -f "$PAR_DIR/$d.result" ]; then
                read -r r el < "$PAR_DIR/$d.result"
                done_n=$((done_n+1)); done_sum=$((done_sum+el))
            else
                read -r el < "$s"; el=$((now-el))
                st=$(cat "$PAR_DIR/$d.state" 2>/dev/null); st=${st#module }
                running="$running, $d $(fmt_dur $el)${st:+ $st}"
                run_left=$((run_left - el))
            fi
        done
        if [ "$done_n" -gt 0 ]; then
            local avg=$((done_sum/done_n)) rl
            # Running ones: what the average says they still need (never < 0).
            rl=$(( avg*(started-done_n) + run_left )); [ "$rl" -lt 0 ] && rl=0
            eta_txt="~$(fmt_dur $(( (rl + avg*(total-started) + jobs-1) / jobs ))) left"
        else
            eta_txt="time left after the first database"
        fi
        pct=$(( done_n*100/(total>0?total:1) ))
        local barw=20 fill bar plain
        fill=$(( pct*barw/100 ))
        bar=$(printf '%*s' "$fill" '' | tr ' ' '#')$(printf '%*s' $((barw-fill)) '' | tr ' ' '.')
        plain=" ${frames:f%4:1} $done_n/$total done [$bar] $pct%  total $(fmt_dur $((now-run_start)))  $eta_txt  | ${running#, }"
        plain=${plain:0:$((cols-1))}
        printf '\x1b7\033[%d;1H\033[7m%s\033[K\033[0m\x1b8' "$rows" "$plain"
        f=$((f+1))
        sleep 0.5
    done
}

run_databases_parallel() {  # same arguments and results as run_databases
    local jobs run_start DB pid total next=0
    local -a queue=() skipped=() mods=()
    jobs=$(effective_jobs)
    run_start=$(date +%s)
    FAILED_DBS=(); PAR_DONE_SUM=0; PAR_DONE_N=0
    PAR_DIR="$LOG_DIR/update_${TIMESTAMP}.parts"
    mkdir -p "$PAR_DIR"
    compute_fingerprints    # once, here, rather than in every copy

    for DB in "${RUN_DBS[@]}"; do
        mods=("$@")
        if [ -n "${DB_MODULES[$DB]+x}" ]; then read -ra mods <<< "${DB_MODULES[$DB]}"; fi
        if [ ${#mods[@]} -eq 0 ] && [ -z "$INSTALL_TOO" ]; then
            echo "skipped 0" > "$PAR_DIR/$DB.result"
            skipped+=("$DB")
        else
            queue+=("$DB")
        fi
    done
    total=${#queue[@]}

    echo ""
    if [ ${#skipped[@]} -gt 0 ]; then
        echo "  Nothing changed since their last update, skipped: ${skipped[*]}"
    fi
    if [ "$total" -gt 0 ]; then
        if [ "$jobs" -gt "$total" ]; then jobs=$total; fi
        echo -e "  ${BOLD}Updating $total database(s), $jobs at a time.${NC} The Odoo log of each, while it runs:"
        echo -e "  ${CYAN}$PAR_DIR/<database>.log${NC}"
        echo ""
    fi

    # Whatever ends the run, no update is left running behind it.
    trap exit_cleanup EXIT
    trap 'exit_cleanup; exit 130' INT TERM
    progress_setup
    if [ "$PROGRESS_ON" = true ] && [ "$total" -gt 0 ]; then
        par_ticker "$total" "$jobs" "$run_start" &
        TICKER_PID=$!
    fi

    while [ "$next" -lt "$total" ] || [ ${#PAR_PIDS[@]} -gt 0 ]; do
        while [ "$next" -lt "$total" ] && [ ${#PAR_PIDS[@]} -lt "$jobs" ]; do
            DB=${queue[$next]}; next=$((next+1))
            mods=("$@")
            if [ -n "${DB_MODULES[$DB]+x}" ]; then read -ra mods <<< "${DB_MODULES[$DB]}"; fi
            par_job "$DB" "${mods[@]}" </dev/null &
            PAR_PIDS[$!]=$DB
        done
        for pid in "${!PAR_PIDS[@]}"; do
            DB=${PAR_PIDS[$pid]}
            if [ ! -f "$PAR_DIR/$DB.result" ] && kill -0 "$pid" 2>/dev/null; then continue; fi
            wait "$pid" 2>/dev/null || true
            unset "PAR_PIDS[$pid]"
            par_report "$DB" "$total" "$jobs"
        done
        sleep 1
    done

    progress_teardown
    # One log, in database order, as a run one at a time writes it.
    local res dur
    for DB in "${RUN_DBS[@]}"; do
        res=errors; dur=0
        if [ -f "$PAR_DIR/$DB.result" ]; then read -r res dur < "$PAR_DIR/$DB.result"; fi
        if [ "$res" = skipped ]; then
            echo "--- $DB: nothing changed, skipped ---" >> "$LOG_FILE"
        else
            { echo "--- $DB ---"; cat "$PAR_DIR/$DB.log" 2>/dev/null || true
              echo "--- $DB: $res in $(fmt_dur "$dur") ---"; } >> "$LOG_FILE"
        fi
    done
    rm -rf "$PAR_DIR"
    PAR_DIR=""
    RUN_SECONDS=$(( $(date +%s) - run_start ))
}

# ── Run the update on every database in RUN_DBS ──
# Args: the modules. Fills FAILED_DBS; prints the time each database took
# and the time left. Several databases: run_databases_parallel.
run_databases() {
    N_DBS=${#RUN_DBS[@]}
    if [ "$(effective_jobs)" -gt 1 ]; then
        run_databases_parallel "$@"
        return 0
    fi
    local total=${#RUN_DBS[@]} idx=0 run_start db_start dur done_sum=0 done_n=0
    run_start=$(date +%s)
    FAILED_DBS=()
    progress_setup

    for DB in "${RUN_DBS[@]}"; do
        idx=$((idx+1))
        echo ""
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${CYAN}  Database: $DB  ($idx/$total)${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""

        echo "--- $DB ---" >> "$LOG_FILE"
        db_start=$(date +%s)
        if [ "$PROGRESS_ON" = true ]; then
            : > "$PROGRESS_STATE"
            progress_ticker "$idx" "$total" "$DB" "$db_start" "$run_start" "$done_sum" "$done_n" &
            TICKER_PID=$!
        fi

        local -a mods=("$@")
        if [ -n "${DB_MODULES[$DB]+x}" ]; then
            read -ra mods <<< "${DB_MODULES[$DB]}"
        fi
        if [ ${#mods[@]} -eq 0 ] && [ -z "$INSTALL_TOO" ]; then
            progress_stop_ticker
            echo "  Nothing changed since its last update: skipped."
            echo "--- $DB: nothing changed, skipped ---" >> "$LOG_FILE"
            continue
        fi

        local ok=true
        run_batch_update "$DB" "${mods[@]}" || ok=false
        progress_stop_ticker
        [ "$ok" = true ] && record_state "$DB" "${mods[@]}" ${INSTALL_TOO//,/ }

        dur=$(( $(date +%s) - db_start ))
        done_sum=$((done_sum+dur)); done_n=$((done_n+1))
        local avg=$((done_sum/done_n)) left_n=$((total-idx)) tail=""
        if [ "$left_n" -gt 0 ]; then
            tail="  ·  $idx/$total done, ~$(fmt_dur $((avg*left_n))) left (avg $(fmt_dur $avg) per database)"
        fi
        echo ""
        if [ "$ok" = true ]; then
            echo -e "  ${GREEN}✓ $DB completed in $(fmt_dur $dur)${NC}$tail"
        else
            echo -e "  ${RED}✗ $DB had errors after $(fmt_dur $dur) (check log)${NC}$tail"
            FAILED_DBS+=("$DB")
        fi
        echo "--- $DB: $([ "$ok" = true ] && echo ok || echo errors) in $(fmt_dur $dur) ---" >> "$LOG_FILE"
    done

    progress_teardown
    RUN_SECONDS=$(( $(date +%s) - run_start ))
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
    N_DBS=${#DATABASES[@]}
    [ "$ASK_ODOO" = true ] && ask_stop_odoo && echo ""
    echo -e "${BOLD}Mode:${NC}      Auto"
    echo -e "${BOLD}Action:${NC}    ${ACTION}"
    echo -e "${BOLD}Databases:${NC} ${DATABASES[*]}"
    if [ "$CHANGED_MODE" = true ]; then
        echo -e "${BOLD}Modules:${NC}   only what changed, per database:"
        plan_changed "${DATABASES[@]}"
    else
        echo -e "${BOLD}Modules:${NC}   all our modules installed on each database:"
        plan_all "${DATABASES[@]}"
    fi
    [ -n "$INSTALL_TOO" ] && echo -e "${BOLD}Install too:${NC} $INSTALL_TOO (same run)"
    echo -e "${BOLD}Odoo:${NC}      $(odoo_plan_label)"
    [ "$N_DBS" -gt 1 ] && echo -e "${BOLD}At once:${NC}   $(jobs_plan_label)"
    echo ""

    odoo_pause
    RUN_DBS=("${DATABASES[@]}")
    run_databases "${MODULES[@]}"

    echo ""
    echo "========================================="
    echo -e "${GREEN}✓ Update complete${NC} in $(fmt_dur $RUN_SECONDS)"

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
N_DBS=${#SELECTED_DBS[@]}

# Step 3: Choose modules
echo ""
echo "Available modules:"
echo "  c) Only what changed since each database's last update"
echo "  0) All our modules installed on each database (never Odoo's own)"
for i in "${!MODULES[@]}"; do
    printf "  %2d) %s\n" $((i+1)) "${MODULES[i]}"
done
echo ""
read -p "Select modules (comma-separated, e.g. 1,5,6,8, 0 for all, c for what changed): " MOD_SELECTION

SELECTED_MODULES=()
if [[ "$MOD_SELECTION" =~ ^[cC]$ ]]; then
    if [ "$ACTION" != update ]; then
        echo -e "${RED}✗${NC} \"Only what changed\" updates installed modules: choose 1) Update modules."
        exit 1
    fi
    CHANGED_MODE=true
    echo ""
    echo "What changed, database by database:"
    plan_changed "${SELECTED_DBS[@]}"
    SELECTED_MODULES=("(changed)")
elif [ "$MOD_SELECTION" = "0" ]; then
    ALL_MODE=true
    echo ""
    echo "All our modules, database by database:"
    plan_all "${SELECTED_DBS[@]}"
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

# What Odoo will really update: the picks and everything built on them.
if [ "$CHANGED_MODE" != true ] && [ "$ALL_MODE" != true ] && [ "$ACTION" = update ]; then
    echo ""
    echo "What Odoo will update (each module once, with every installed module built on it):"
    for _db in "${SELECTED_DBS[@]}"; do show_scope "$_db" "${SELECTED_MODULES[@]}"; done
fi

# Install too, in the same run (update only)
if [ "$ACTION" = update ] && [ -z "$INSTALL_TOO" ]; then
    echo ""
    echo "Also install modules in the same run? Needed only when a module must arrive"
    echo "together with an update (one module handing its records to another)."
    read -p "Numbers from the list above, comma-separated (Enter for none): " INST_SELECTION
    _inst=()
    IFS=',' read -ra _idx <<< "${INST_SELECTION:-}"
    for idx in "${_idx[@]}"; do
        idx=$(echo "$idx" | xargs)
        if [ -n "$idx" ] && [ "$idx" -ge 1 ] 2>/dev/null && [ "$idx" -le ${#MODULES[@]} ]; then
            _inst+=("${MODULES[$((idx-1))]}")
        fi
    done
    INSTALL_TOO=$(IFS=,; echo "${_inst[*]:-}")
    unset _inst _idx
fi

# Step 4: Odoo during the run (server mode)
ask_stop_odoo

# Step 5: Confirm
MODULES_CSV=$(echo "${SELECTED_MODULES[*]}" | tr ' ' ',')
echo ""
echo "─────────────────────────────────────────"
echo -e "${BOLD}Action:${NC}    ${ACTION}"
echo -e "${BOLD}Databases:${NC} ${SELECTED_DBS[*]}"
if [ "$CHANGED_MODE" = true ]; then
    echo -e "${BOLD}Modules:${NC}   only what changed, per database (listed above)"
elif [ "$ALL_MODE" = true ]; then
    echo -e "${BOLD}Modules:${NC}   all our modules installed on each database (listed above)"
else
    echo -e "${BOLD}Modules:${NC}   $MODULES_CSV"
fi
[ -n "$INSTALL_TOO" ] && echo -e "${BOLD}Install too:${NC} $INSTALL_TOO (same run)"
echo -e "${BOLD}Odoo:${NC}      $(odoo_plan_label)"
[ "$N_DBS" -gt 1 ] && echo -e "${BOLD}At once:${NC}   $(jobs_plan_label)"
echo "─────────────────────────────────────────"
echo ""
read -p "Proceed? (y/n) " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

# Step 6: Execute (batch per database)
echo ""

SPECIFIC_ACTION="$ACTION"
odoo_pause
RUN_DBS=("${SELECTED_DBS[@]}")
if [ "$CHANGED_MODE" = true ] || [ "$ALL_MODE" = true ]; then
    run_databases
else
    run_databases "${SELECTED_MODULES[@]}"
fi

# Summary
echo ""
echo "========================================="
echo -e "${GREEN}✓ Update complete${NC} in $(fmt_dur $RUN_SECONDS)"

if [ ${#FAILED_DBS[@]} -gt 0 ]; then
    echo -e "${RED}  Databases with errors: ${FAILED_DBS[*]}${NC}"
fi

echo ""
echo -e "Full log: ${CYAN}$LOG_FILE${NC}"
echo "========================================="
odoo_resume