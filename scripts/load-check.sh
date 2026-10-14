#!/bin/bash
# ──────────────────────────────────────────────
# Load check: is this server short of web workers or of scheduled job
# threads, and how much of the load is ePHEM AI? Reads only: safe on a
# production server at any time.
#
#   bash scripts/load-check.sh                 every Odoo database
#   bash scripts/load-check.sh --db NAME       one database
#   bash scripts/load-check.sh --instance 1    a dev-multi instance
#
# What it prints, and how to read it:
#   1. The setup: workers and max_cron_threads in force, CPUs, memory, the
#      suggested workers for this machine, Postgres connections.
#   2. ePHEM AI calls over the last 24 hours (eoc_ai_log), per hour and per
#      purpose. "busy" is the average number of calls running at once in
#      that hour, "peak" the most at the same moment. Code from before
#      eoc_signals 18.0.2.18.0 made each call on the signal form inside a
#      web worker: a peak near the number of workers means users queued.
#   3. Scheduled jobs more than 15 minutes late, and jobs woken but still
#      waiting: both mean the scheduled job threads are all busy.
#   4. Now: transactions open for more than 5 seconds (a request or a job
#      waiting, often on an outside service such as the AI provider). A
#      running scheduled job shows here too, for as long as it runs.
#   5. CPU and memory of the containers.
# ──────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EPHEM_ROOT="$SCRIPT_DIR"
# shellcheck source=stack-lib.sh
source "$SCRIPT_DIR/scripts/stack-lib.sh"

ONE_DB=""
INSTANCE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --db)       ONE_DB="${2:-}"; shift 2 ;;
        --instance) INSTANCE="${2:-}"; shift 2 ;;
        -h|--help)  sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)          echo "Unknown option: $1 (see --help)"; exit 2 ;;
    esac
done

stack_init "$INSTANCE" || { echo -e "${RED}✗${NC} $STACK_ERROR"; exit 1; }

# A query that fails (a table an older database lacks) reports and moves on:
# the rest of the check still runs.
psql_db() {  # psql_db DB SQL: a readable table, no pager
    compose exec -T db psql -U "$DB_USER" -d "$1" -P pager=off -P footer=off -c "$2" </dev/null \
        || echo -e "  ${YELLOW}!${NC} query failed on $1"
}
psql_val() {  # psql_val DB SQL: one bare value
    compose exec -T db psql -U "$DB_USER" -d "$1" -t -A -c "$2" </dev/null 2>/dev/null | tr -d '\r' || true
}

heading() { echo ""; echo -e "${CYAN}${BOLD}$1${NC}"; }

# ── 1. Setup ──────────────────────────────────
heading "1. Setup"
W=$(odoo_conf_get_key "$ODOO_CONF" workers)
C=$(odoo_conf_get_key "$ODOO_CONF" max_cron_threads)
echo "  $(basename "$ODOO_CONF"):  workers = ${W:-?}, max_cron_threads = ${C:-?}"
echo "  Machine:  $(nproc 2>/dev/null || echo '?') CPUs, $(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo 2>/dev/null || echo '?') MB memory; suggested workers = $(suggest_workers)"
echo "  Postgres: $(psql_val postgres "SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'client backend'") connections of $(psql_val postgres "SHOW max_connections")"
if [ "${W:-}" = 0 ]; then
    echo "  Threaded mode (workers = 0): there is no fixed number of web workers to run out of."
fi

# ── Which databases ───────────────────────────
DBS=()
if [ -n "$ONE_DB" ]; then
    DBS=("$ONE_DB")
elif [ -n "$ODOO_DB" ]; then
    DBS=("$ODOO_DB")
else
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        # Odoo databases only (they have ir_cron)
        [ "$(psql_val "$d" "SELECT to_regclass('ir_cron') IS NOT NULL")" = t ] && DBS+=("$d")
    done < <(list_dbs)
fi
[ "${#DBS[@]}" -gt 0 ] || { echo -e "  ${YELLOW}!${NC} No Odoo database found."; exit 0; }

for DB in "${DBS[@]}"; do
    echo ""
    echo -e "${BOLD}━━ Database $DB ━━${NC}"

    # ── 2. ePHEM AI ───────────────────────────
    heading "2. ePHEM AI calls, last 24 hours (times UTC)"
    if [ "$(psql_val "$DB" "SELECT to_regclass('eoc_ai_log') IS NOT NULL")" != t ]; then
        echo "  No AI usage log here (eoc_ai not installed)."
    elif [ "$(psql_val "$DB" "SELECT count(*) FROM eoc_ai_log WHERE create_date > (now() at time zone 'utc') - interval '24 hours'")" = 0 ]; then
        echo "  No calls."
    else
        PEAK=$(psql_val "$DB" "
            WITH calls AS (
                SELECT create_date - coalesce(duration_ms, 0) * interval '1 millisecond' AS s, create_date AS e
                  FROM eoc_ai_log
                 WHERE create_date > (now() at time zone 'utc') - interval '24 hours'),
            ev AS (SELECT s AS t, 1 AS d FROM calls UNION ALL SELECT e, -1 FROM calls)
            SELECT coalesce(max(n), 0) FROM (SELECT sum(d) OVER (ORDER BY t, d) AS n FROM ev) x")
        echo "  Most calls running at the same moment: ${PEAK:-0} (web workers: ${W:-?})"
        psql_db "$DB" "
            SELECT purpose, count(*) AS calls,
                   round(avg(duration_ms) / 1000.0, 1) AS avg_s,
                   round(max(duration_ms) / 1000.0) AS longest_s,
                   count(*) FILTER (WHERE status <> 'ok') AS failed
              FROM eoc_ai_log
             WHERE create_date > (now() at time zone 'utc') - interval '24 hours'
             GROUP BY 1 ORDER BY 2 DESC"
        psql_db "$DB" "
            SELECT to_char(date_trunc('hour', create_date), 'MM-DD HH24:00') AS hour,
                   count(*) AS calls,
                   round(max(duration_ms) / 1000.0) AS longest_s,
                   round(sum(duration_ms) / 3600000.0, 2) AS busy
              FROM eoc_ai_log
             WHERE create_date > (now() at time zone 'utc') - interval '24 hours'
             GROUP BY 1 ORDER BY 1 DESC"
    fi

    # ── 3. Scheduled jobs ─────────────────────
    heading "3. Scheduled jobs late by more than 15 minutes"
    LATE=$(psql_val "$DB" "SELECT count(*) FROM ir_cron WHERE active AND nextcall < (now() at time zone 'utc') - interval '15 minutes'")
    if [ "${LATE:-0}" = 0 ]; then
        echo -e "  ${GREEN}✓${NC} None."
    else
        psql_db "$DB" "
            SELECT cron_name AS job, to_char(nextcall, 'MM-DD HH24:MI') AS due,
                   round(extract(epoch FROM (now() at time zone 'utc') - nextcall) / 60) AS late_min
              FROM ir_cron
             WHERE active AND nextcall < (now() at time zone 'utc') - interval '15 minutes'
             ORDER BY nextcall"
    fi
    heading "   Jobs woken more than 2 minutes ago and still waiting"
    # an inactive job keeps the wake ups it was sent before it was switched off: not a wait
    WAITING=$(psql_val "$DB" "SELECT count(*) FROM ir_cron_trigger t JOIN ir_cron c ON c.id = t.cron_id WHERE c.active AND t.call_at < (now() at time zone 'utc') - interval '2 minutes'")
    if [ "${WAITING:-0}" = 0 ]; then
        echo -e "  ${GREEN}✓${NC} None."
    else
        psql_db "$DB" "
            SELECT c.cron_name AS job, count(*) AS wakeups,
                   round(extract(epoch FROM (now() at time zone 'utc') - min(t.call_at)) / 60) AS waiting_min
              FROM ir_cron_trigger t JOIN ir_cron c ON c.id = t.cron_id
             WHERE c.active AND t.call_at < (now() at time zone 'utc') - interval '2 minutes'
             GROUP BY 1 ORDER BY 3 DESC"
    fi

    # ── 4. Now ────────────────────────────────
    heading "4. Now: transactions open for more than 5 seconds"
    OPEN=$(psql_val "$DB" "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid() AND xact_start < now() - interval '5 seconds'")
    if [ "${OPEN:-0}" = 0 ]; then
        echo -e "  ${GREEN}✓${NC} None."
    else
        psql_db "$DB" "
            SELECT pid, state, round(extract(epoch FROM now() - xact_start)) AS secs,
                   left(regexp_replace(query, '\s+', ' ', 'g'), 70) AS last_query
              FROM pg_stat_activity
             WHERE datname = current_database() AND pid <> pg_backend_pid()
               AND xact_start < now() - interval '5 seconds'
             ORDER BY secs DESC LIMIT 15"
    fi
done

# ── 5. Containers ─────────────────────────────
heading "5. Containers (CPU, memory)"
docker stats --no-stream --format "{{.Name}} {{.CPUPerc}} {{.MemUsage}}" 2>/dev/null \
    | awk -v ctn="$ODOO_CTN" '$1 == ctn || $1 ~ /^ephem-(db|office)$/ {
          printf "  %-14s CPU %-8s memory %s %s %s\n", $1, $2, $3, $4, $5 }' || true
echo ""
