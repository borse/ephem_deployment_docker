#!/bin/bash
# ──────────────────────────────────────────────
# Timeout check: why did the site answer "504 Gateway Time-out"? Reads only
# the logs and the settings: safe on a production server at any time, while
# it happens or after a restart. A restart (docker compose restart, a reboot)
# keeps the containers and their logs; only recreating them (down, an image
# update) loses them.
#
#   bash scripts/timeout-check.sh                     the last 24 hours
#   bash scripts/timeout-check.sh --since 6h          another window (30m, 6h, 2d,
#                                                     or a time: 2026-11-26T06:00)
#   bash scripts/timeout-check.sh --until 2026-11-26T06:45
#   bash scripts/timeout-check.sh --instance 1        a dev-multi instance
#
# A 504 is nginx giving up on Odoo: 10 s to be let in (proxy_connect_timeout),
# 12 minutes for the answer (proxy_read_timeout). What it prints:
#   1. The setup: web workers, time limits, when each container last started.
#   2. nginx: how many 504s, from when to when, and of which kind:
#      "while connecting" = Odoo let nobody in, every worker was busy;
#      "while reading"    = Odoo took a request in and did not answer.
#      The sites and the addresses that met them.
#   3. Odoo: the slowest requests that did finish. Several at about 12 minutes
#      are requests that waited for nginx to give up.
#   4. Odoo: workers killed (time or memory limit), database errors.
#   5. What it looks like: the known patterns, with what to do.
#   6. Postgres errors, then the host: memory, disk, processes the kernel
#      killed for memory.
# While it is happening, scripts/load-check.sh shows what is running now.
# ──────────────────────────────────────────────
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EPHEM_ROOT="$SCRIPT_DIR"
# shellcheck source=stack-lib.sh
source "$SCRIPT_DIR/scripts/stack-lib.sh"

SINCE=24h
UNTIL=""
INSTANCE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --since)    SINCE="${2:-}"; shift 2 ;;
        --until)    UNTIL="${2:-}"; shift 2 ;;
        --instance) INSTANCE="${2:-}"; shift 2 ;;
        -h|--help)  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)          echo "Unknown option: $1 (see --help)"; exit 2 ;;
    esac
done

stack_init "$INSTANCE" || { echo -e "${RED}✗${NC} $STACK_ERROR"; exit 1; }

heading() { echo ""; echo -e "${CYAN}${BOLD}$1${NC}"; }
ok()      { echo -e "  ${GREEN}✓${NC} $1"; }
warn()    { echo -e "  ${YELLOW}!${NC} $1"; }

WINDOW=(--since "$SINCE")
[ -n "$UNTIL" ] && WINDOW+=(--until "$UNTIL")

# Each log is read once (they can be large), without colors.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
service_log() {  # service_log SERVICE FILE
    if [ "$(svc_state "$1")" = absent ]; then : > "$2"; return; fi
    compose logs --no-log-prefix "${WINDOW[@]}" "$1" 2>&1 </dev/null | sed 's/\x1b\[[0-9;]*m//g' > "$2"
}
service_log "$ODOO_SVC" "$TMP/odoo"
service_log nginx "$TMP/nginx"
service_log db "$TMP/db"

started() {  # started SERVICE: when its container last started, and its restarts
    local id; id=$(compose ps -q "$1" 2>/dev/null </dev/null)
    [ -n "$id" ] || { echo "not created"; return; }
    docker inspect -f '{{.State.StartedAt}} (restarts: {{.RestartCount}})' "$id" 2>/dev/null \
        | sed -E 's/\.[0-9]+Z/Z/; s/T/ /'
}

# ── 1. Setup ──────────────────────────────────
heading "1. Setup (times UTC)"
W=$(odoo_conf_get_key "$ODOO_CONF" workers)
C=$(odoo_conf_get_key "$ODOO_CONF" max_cron_threads)
LTR=$(odoo_conf_get_key "$ODOO_CONF" limit_time_real)
echo "  $(basename "$ODOO_CONF"):  workers = ${W:-?}, max_cron_threads = ${C:-?}, limit_time_real = ${LTR:-?} s"
echo "  Machine:  $(nproc 2>/dev/null || echo '?') CPUs, $(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo 2>/dev/null || echo '?') MB memory; suggested workers = $(suggest_workers)"
for svc in "$ODOO_SVC" nginx db; do
    printf '  %-8s started %s\n' "$svc" "$(started "$svc")"
done
echo "  Host up since $(uptime -s 2>/dev/null || echo '?')"
echo "  Window: logs since $SINCE${UNTIL:+, until $UNTIL}"

# ── 2. nginx ──────────────────────────────────
heading "2. nginx: the 504s"
N504=$(grep -c '" 504 ' "$TMP/nginx")
CONNECT=$(grep -c 'upstream timed out.*while connecting' "$TMP/nginx")
READING=$(grep -c 'upstream timed out.*while reading' "$TMP/nginx")
REFUSED=$(grep -c 'connect() failed' "$TMP/nginx")
if [ "$(svc_state nginx)" = absent ]; then
    echo "  No nginx in this stack."
elif [ "$((N504 + CONNECT + READING + REFUSED))" = 0 ]; then
    ok "No 504 and no timeout in this window."
    echo "    A 504 page users saw anyway came from a proxy in front of this server: look at its log."
else
    echo "  504 answers: $N504.  Timed out: $CONNECT while connecting, $READING while reading.  Refused: $REFUSED."
    FIRST=$(grep -m1 -E 'upstream timed out|connect\(\) failed' "$TMP/nginx" | cut -c1-19)
    LAST=$(grep -E 'upstream timed out|connect\(\) failed' "$TMP/nginx" | tail -1 | cut -c1-19)
    [ -n "$FIRST" ] && echo "  From $FIRST to $LAST"
    echo "  Sites:"
    grep -E 'upstream timed out|connect\(\) failed' "$TMP/nginx" | sed -n 's/.*server: \([^,]*\),.*/\1/p' \
        | sort | uniq -c | sort -rn | head -10 | sed 's/^/   /'
    echo "  What was asked (address without its parameters):"
    grep -E 'upstream timed out|connect\(\) failed' "$TMP/nginx" | sed -n 's/.*request: "\([A-Z]*\) \([^ ?"]*\).*/\1 \2/p' \
        | sed -E 's#/[0-9]+(/|$)#/N\1#g' | sort | uniq -c | sort -rn | head -10 | sed 's/^/   /'
fi

# ── 3. Odoo: slow requests ────────────────────
# werkzeug's line ends with: queries, query time, other time.
heading "3. Odoo: the slowest requests that finished (over 20 s)"
awk '/werkzeug:/ && $(NF-2) ~ /^[0-9]+$/ {
        t = $(NF-1) + $NF
        if (t > 20 && match($0, /"[A-Z]+ [^ ?"]+/))
            printf "%7.1fs  %s %s  %-14s %s\n", t, $1, substr($2, 1, 8), $5, substr($0, RSTART + 1, RLENGTH - 1)
     }' "$TMP/odoo" | sort -rn > "$TMP/slow"
if [ -s "$TMP/slow" ]; then
    echo "   seconds  ended at             database       request"
    head -15 "$TMP/slow" | sed 's/^/  /'
    [ "$(wc -l < "$TMP/slow")" -gt 15 ] && echo "  … $(($(wc -l < "$TMP/slow") - 15)) more"
else
    ok "None."
fi

# ── 4. Odoo: workers and database ─────────────
heading "4. Odoo: workers killed, database errors"
grep -a -E 'virtual (real|memory) time limit|limit.*reached|Killing|Worker .* timeout|MemoryError|OperationalError|too many connections|CRITICAL' \
    "$TMP/odoo" | cut -c1-220 > "$TMP/workers"
if [ -s "$TMP/workers" ]; then
    tail -20 "$TMP/workers" | sed 's/^/  /'
else
    ok "None."
fi

# ── 5. Patterns ───────────────────────────────
heading "5. What it looks like"
FOUND=0
# Reports rendered by wkhtmltopdf inside a web worker: wkhtmltopdf asks the
# same Odoo for the report's styles and images, and waits for a free worker.
# As many reports at once as workers, and none is ever free: each ends when
# nginx gives up on those requests, about 12 minutes later.
PDF_STUCK=$(awk '$1 + 0 >= 600' "$TMP/slow" | grep -c -E 'pdf|/report/')
if [ "$PDF_STUCK" -gt 0 ]; then
    FOUND=1
    warn "$PDF_STUCK PDF report(s) took over 10 minutes: they held web workers (workers = ${W:-?})."
    echo "    wkhtmltopdf fetches the report's styles from this same Odoo and waits for a free worker;"
    echo "    with as many reports at once as workers, none is ever free until nginx gives up."
    SITREP=$(ls "$ADDONS_DIR"/*/eoc_daily_sitrep/__manifest__.py 2>/dev/null | head -1)
    if [ -n "$SITREP" ]; then
        V=$(sed -n "s/.*'version': *'\([^']*\)'.*/\1/p" "$SITREP")
        if [ "$(printf '%s\n' "18.0.1.2.0" "$V" | sort -V | head -1)" = "18.0.1.2.0" ]; then
            echo "    eoc_daily_sitrep $V prepares its PDFs in the background: /eoc_daily_sitrep/"
            echo "    requests here from after its update mean the update was not applied (Update, then m)."
        else
            echo "    eoc_daily_sitrep $V renders its PDFs in the web worker: 18.0.1.2.0 prepares"
            echo "    them in the background. Pull ePHEM-core, then update the module."
        fi
    fi
    echo "    Meanwhile, more web workers make it rarer: bash manage.sh, m, then w (suggested $(suggest_workers))."
fi
NEAR_LIMIT=$(awk '$1 + 0 >= 700 && $1 + 0 <= 760' "$TMP/slow" | wc -l | tr -d ' ')
if [ "$NEAR_LIMIT" -gt 1 ] && [ "$PDF_STUCK" = 0 ]; then
    FOUND=1
    warn "$NEAR_LIMIT requests ended after 12 to 13 minutes: they waited on something until nginx gave up."
    echo "    Often a request calling this same server, or an outside service, from a web worker."
fi
if [ "$CONNECT" -gt 0 ] && [ "$CONNECT" -ge "$READING" ]; then
    FOUND=1
    warn "Mostly \"while connecting\": every web worker was busy, so users queued and gave up."
    echo "    Section 3 shows what held them; while it happens, scripts/load-check.sh (section 4)."
fi
if [ -s "$TMP/workers" ] && grep -q -E 'memory|MemoryError' "$TMP/workers"; then
    FOUND=1
    warn "Workers reached their memory limit: see section 6 for the host's memory."
fi
if grep -q 'the database system is shutting down\|terminating connection due to administrator command' "$TMP/db" \
   && [ "$((N504 + CONNECT + READING))" = 0 ]; then
    FOUND=1
    echo "  The database was stopped or restarted in this window (a restart or a reboot)."
fi
[ "$FOUND" = 0 ] && ok "No known pattern. Sections 2 to 4 show what there is."

# ── 6. Postgres and the host ──────────────────
heading "6. Postgres: errors, most frequent first"
grep -E 'ERROR|FATAL|PANIC|deadlock' "$TMP/db" \
    | sed -E 's/^[0-9-]+ [0-9:.]+ [A-Z]+ \[[0-9]+\] //' | cut -c1-160 | sort | uniq -c | sort -rn | head -8 > "$TMP/pg"
if [ -s "$TMP/pg" ]; then sed 's/^/  /' "$TMP/pg"; else ok "None."; fi

heading "   The host"
free -h 2>/dev/null | sed 's/^/  /'
df -h / 2>/dev/null | sed 's/^/  /'
OOM=""
if command -v journalctl >/dev/null 2>&1; then
    OOM=$( { journalctl -k -b 0 --no-pager 2>/dev/null; journalctl -k -b -1 --no-pager 2>/dev/null; } \
           | grep -i -E 'out of memory|oom-kill|killed process' | tail -5)
else
    OOM=$(dmesg -T 2>/dev/null | grep -i -E 'out of memory|oom-kill|killed process' | tail -5)
fi
if [ -n "$OOM" ]; then
    warn "The kernel killed processes for memory (this boot and the one before):"
    echo "$OOM" | cut -c1-200 | sed 's/^/    /'
else
    ok "No process killed for memory (this boot and the one before)."
fi
echo ""
