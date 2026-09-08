#!/bin/bash
# ──────────────────────────────────────────────
# ePHEM stack helpers (sourced by setup.sh, manage.sh and scripts/, never run)
#
# One checkout of this repo runs in exactly ONE of four modes, recorded in
# .env so every tool agrees on what it is managing:
#
#   EPHEM_MODE=server     production or staging: nginx + certbot + one Odoo
#   EPHEM_MODE=demo       local evaluation: one Odoo on :8069, no nginx
#   EPHEM_MODE=dev        one Odoo on :8069, custom-addons/ mounted read-write
#   EPHEM_MODE=dev-multi  several Odoos (odca1/, odca2/, ...) on one Postgres
#
# setup.sh writes the key at the end of every successful run, and
# scripts/dev-instances.sh writes dev-multi whenever it brings a stack up.
# Installs made before the key existed are recognised from the files they
# left behind (ephem_mode_detect), so nothing has to be re-run.
#
# What the mode changes:
#
#   compose        which compose files are loaded. dev-multi adds the
#                  generated docker-compose.dev-multi.yml; the other modes add
#                  docker-compose.override.yml when it exists, which is what
#                  a plain `docker compose` picks up on its own.
#   ODOO_SVC etc.  the Odoo service, container, addons folder, config file,
#                  database, data volume and URL a tool acts on. In dev-multi
#                  these describe ONE instance (stack_use_instance); in every
#                  other mode they are the single 'odoo' service.
#
# Usage, from a script in the repo root or in scripts/:
#
#     source "$(dirname "$0")/scripts/stack-lib.sh"      # or ../scripts/stack-lib.sh
#     stack_init [instance] || echo "$STACK_ERROR"
#
# Every function here is safe under `set -euo pipefail`: the ones that can
# legitimately fail (inst_index, stack_init, retire_single_override,
# filestore_archive) are meant to be called inside `if` or with `|| ...`.
# ──────────────────────────────────────────────

EPHEM_ROOT="${EPHEM_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Only define colours the sourcing script has not defined already.
RED="${RED:-\033[0;31m}"
GREEN="${GREEN:-\033[0;32m}"
YELLOW="${YELLOW:-\033[1;33m}"
CYAN="${CYAN:-\033[0;36m}"
BOLD="${BOLD:-\033[1m}"
NC="${NC:-\033[0m}"

# ── .env ──────────────────────────────────────
# `|| true`: a key absent from .env must yield "", not kill a set -e script
# (grep exits 1 on no match).
env_get() { grep "^$1=" "$EPHEM_ROOT/.env" 2>/dev/null | cut -d'=' -f2- | xargs || true; }

set_env_key() {  # set_env_key KEY VALUE: update or append KEY=VALUE in .env
    local f="$EPHEM_ROOT/.env"
    [ -f "$f" ] || touch "$f"
    if grep -q "^$1=" "$f"; then
        sed -i "s|^$1=.*|$1=$2|" "$f"
    else
        # A .env whose last line has no newline would otherwise swallow the key.
        [ -s "$f" ] && [ -n "$(tail -c1 "$f")" ] && echo >> "$f"
        printf '%s=%s\n' "$1" "$2" >> "$f"
    fi
}

DB_USER="$(env_get POSTGRES_USER)"; DB_USER="${DB_USER:-odoo}"

# ── Mode ──────────────────────────────────────
EPHEM_MODE="${EPHEM_MODE:-}"
EPHEM_MODE_SOURCE=""          # env | detected

ephem_mode_valid() { case "${1:-}" in server|demo|dev|dev-multi) return 0 ;; esac; return 1; }

# Accept the words people type or older scripts wrote.
ephem_mode_normalise() {
    case "${1:-}" in
        production|prod)                   echo server ;;
        developer|development|single)      echo dev ;;
        multi|multi-instance|dev-multi-instance|developer-multi) echo dev-multi ;;
        *)                                 echo "${1:-}" ;;
    esac
}

ephem_mode_label() {
    case "${1:-$EPHEM_MODE}" in
        server)    echo "server (production or staging)" ;;
        demo)      echo "demo (local evaluation)" ;;
        dev)       echo "developer, single instance" ;;
        dev-multi) echo "developer, multi-instance" ;;
        *)         echo "unknown" ;;
    esac
}

# Recognise an install that predates EPHEM_MODE from the files setup.sh and
# dev-instances.sh leave behind. dev-multi wins when both kinds are present:
# the multi stack is what actually runs, the single-instance override is a
# leftover (see stack_leftovers).
ephem_mode_detect() {
    local ov="$EPHEM_ROOT/docker-compose.override.yml"
    if [ -s "$EPHEM_ROOT/.dev-instances" ] && [ -f "$EPHEM_ROOT/docker-compose.dev-multi.yml" ]; then
        echo dev-multi
    elif [ -f "$ov" ] && grep -q 'Developer override' "$ov"; then
        echo dev
    elif [ -f "$ov" ] && grep -q 'Demo override' "$ov"; then
        echo demo
    else
        echo server
    fi
}

# Sets EPHEM_MODE from .env, else from the files on disk (EPHEM_MODE_SOURCE
# says which). Always succeeds.
ephem_mode() {
    local m; m=$(ephem_mode_normalise "$(env_get EPHEM_MODE)")
    if ephem_mode_valid "$m"; then
        EPHEM_MODE="$m"; EPHEM_MODE_SOURCE=env
    else
        EPHEM_MODE=$(ephem_mode_detect); EPHEM_MODE_SOURCE=detected
    fi
    return 0
}

ephem_mode_save() {  # ephem_mode_save MODE
    local m; m=$(ephem_mode_normalise "$1")
    ephem_mode_valid "$m" || { echo "ephem_mode_save: '$1' is not a mode" >&2; return 1; }
    set_env_key EPHEM_MODE "$m"
    EPHEM_MODE="$m"; EPHEM_MODE_SOURCE=env
}

# ── Compose ───────────────────────────────────
COMPOSE_FILES=()

compose_files_init() {
    COMPOSE_FILES=(-f "$EPHEM_ROOT/docker-compose.yml")
    if [ "$EPHEM_MODE" = dev-multi ]; then
        COMPOSE_FILES+=(-f "$EPHEM_ROOT/docker-compose.dev-multi.yml")
    elif [ -f "$EPHEM_ROOT/docker-compose.override.yml" ]; then
        COMPOSE_FILES+=(-f "$EPHEM_ROOT/docker-compose.override.yml")
    fi
}

# The compose call for this mode. Absolute -f paths make the repo root the
# project directory, so this works from cron and from any cwd.
compose() { docker compose "${COMPOSE_FILES[@]}" "$@"; }

# How to type the same thing by hand (for the commands the menus print).
compose_cmd_text() {
    if [ "$EPHEM_MODE" = dev-multi ]; then
        echo "docker compose -f docker-compose.yml -f docker-compose.dev-multi.yml"
    else
        echo "docker compose"
    fi
}

# Project name compose derived for this checkout: volumes are named
# <project>_<volume>. Read off the db container (present in every mode once
# the stack has run), falling back to compose's own default.
compose_project() {
    docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' ephem-db 2>/dev/null | grep . \
        || basename "$EPHEM_ROOT" | tr '[:upper:]' '[:lower:]'
}

# Container state for one compose service, without parsing `docker compose
# ps` output (its columns move between compose versions).
svc_state() {  # svc_state SERVICE → running | stopped | absent
    local cid; cid=$(compose ps -aq "$1" 2>/dev/null | head -1)
    [ -z "$cid" ] && { echo "absent"; return 0; }
    case "$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null)" in
        running) echo "running" ;;
        "")      echo "absent" ;;
        *)       echo "stopped" ;;
    esac
}

# Same, with the exit code when it is not running: "exited (127)".
svc_detail() {  # svc_detail SERVICE
    local cid st; cid=$(compose ps -aq "$1" 2>/dev/null | head -1)
    [ -z "$cid" ] && { echo "not created"; return 0; }
    st=$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' "$cid" 2>/dev/null)
    case "${st%% *}" in
        running) echo "running" ;;
        "")      echo "not created" ;;
        exited)  echo "exited (${st#* })" ;;
        *)       echo "${st%% *}" ;;
    esac
}

# Docker's own reason a container cannot start ("" when there is none). The
# usual one here: a single-file bind mount (odoo.conf, odoo-N.conf) whose file
# was replaced, so the recorded mount no longer resolves and start fails with
# "not a directory". Recreating the container re-resolves the mount.
svc_start_error() {  # svc_start_error SERVICE
    local cid; cid=$(compose ps -aq "$1" 2>/dev/null | head -1)
    [ -z "$cid" ] && return 0
    docker inspect -f '{{.State.Error}}' "$cid" 2>/dev/null || true
}

# Start one service the way that actually works: create it when it has never
# run, recreate it when docker refuses the old container, plain start else.
svc_start() {  # svc_start SERVICE
    local err
    if [ "$(svc_state "$1")" = absent ]; then
        echo -e "  ${CYAN}→${NC} $(compose_cmd_text) up -d $1"
        compose up -d "$1"
        return
    fi
    err=$(svc_start_error "$1")
    if [ -n "$err" ]; then
        echo -e "  ${YELLOW}!${NC} The existing container cannot start: ${err:0:140}"
        echo -e "  ${CYAN}→${NC} $(compose_cmd_text) up -d --force-recreate $1   (data volumes are kept)"
        compose up -d --force-recreate "$1"
        return
    fi
    echo -e "  ${CYAN}→${NC} $(compose_cmd_text) start $1"
    compose start "$1"
}

# Restart, and when the old container cannot come back, recreate it.
svc_restart() {  # svc_restart SERVICE
    echo -e "  ${CYAN}→${NC} $(compose_cmd_text) restart $1"
    compose restart "$1" && return 0
    echo -e "  ${YELLOW}!${NC} Restart failed, trying to recreate the container."
    svc_start "$1"
}

# The app image this mode runs. The generated multi file always tracks latest.
stack_image() {
    local t; t=$(env_get EPHEM_IMAGE_TAG)
    [ "$EPHEM_MODE" = dev-multi ] && t=""
    echo "borrs/ephem:${t:-latest}"
}

# ── Instances (dev-multi) ─────────────────────
# The roster is .dev-instances, one name per line, written by
# scripts/dev-instances.sh. A name's position gives its ports: the first
# instance listens on 8010/8012, the next on 8020/8022, and so on.
INSTANCES_FILE="$EPHEM_ROOT/.dev-instances"
INSTANCES=()
INST_WEB_BASE=8010
INST_LONG_BASE=8012
INST_STEP=10

instances_load() {
    local n
    INSTANCES=()
    [ -f "$INSTANCES_FILE" ] || return 0
    while IFS= read -r n; do
        [ -n "$n" ] && INSTANCES+=("$n")
    done < "$INSTANCES_FILE"
    return 0
}

inst_index() {  # inst_index NAME → position, or 1 when unknown
    local i=0 n
    for n in "${INSTANCES[@]}"; do
        [ "$n" = "${1:-}" ] && { echo "$i"; return 0; }
        i=$((i + 1))
    done
    return 1
}

inst_port()      { local i; i=$(inst_index "$1") || return 1; echo $(( INST_WEB_BASE + INST_STEP * i )); }
inst_long_port() { local i; i=$(inst_index "$1") || return 1; echo $(( INST_LONG_BASE + INST_STEP * i )); }
inst_service()   { echo "odoo_$1"; }
inst_container() { echo "ephem-$1"; }
inst_addons()    { echo "odca$1"; }
inst_conf()      { echo "odoo-$1.conf"; }
inst_db()        { echo "ephem_$1"; }
inst_volume()    { echo "odoo-data-$1"; }

inst_branch() {  # current branch of odcaN, or why there is none
    local b
    [ -d "$EPHEM_ROOT/odca$1/.git" ] || { echo "not a git clone"; return 0; }
    b=$(git -C "$EPHEM_ROOT/odca$1" branch --show-current 2>/dev/null) || b=""
    echo "${b:-(detached)}"
}

inst_last_commit() {
    git -C "$EPHEM_ROOT/odca$1" log -1 --format='%h %ad' --date=short 2>/dev/null || echo "-"
}

# Number of tracked files with uncommitted changes in odcaN (0 when clean or
# not a clone). grep -c reads to the end, so this is safe under pipefail.
inst_dirty_count() {
    local n
    n=$(git -C "$EPHEM_ROOT/odca$1" status --porcelain --untracked-files=no 2>/dev/null | grep -c .) || n=0
    echo "${n:-0}"
}

# ── The Odoo a tool acts on ───────────────────
EPHEM_INSTANCE=""
ODOO_SVC=odoo
ODOO_CTN=ephem-app
ADDONS_DIR=""
ADDONS_NAME=custom-addons
ODOO_CONF=""
ODOO_DB=""
ODOO_VOL=odoo-data
ODOO_PORT=8069
ODOO_URL=""

stack_use_single() {
    EPHEM_INSTANCE=""
    ODOO_SVC=odoo; ODOO_CTN=ephem-app
    ADDONS_DIR="$EPHEM_ROOT/custom-addons"; ADDONS_NAME=custom-addons
    ODOO_CONF="$EPHEM_ROOT/odoo.conf"
    ODOO_DB=""; ODOO_VOL=odoo-data; ODOO_PORT=8069
    case "$EPHEM_MODE" in
        server) ODOO_URL="" ;;
        *)      ODOO_URL="http://localhost:8069" ;;
    esac
}

stack_use_instance() {  # stack_use_instance NAME (must be in the roster)
    inst_index "$1" >/dev/null || return 1
    EPHEM_INSTANCE="$1"
    ODOO_SVC="odoo_$1"; ODOO_CTN="ephem-$1"
    ADDONS_DIR="$EPHEM_ROOT/odca$1"; ADDONS_NAME="odca$1"
    ODOO_CONF="$EPHEM_ROOT/odoo-$1.conf"
    ODOO_DB="ephem_$1"; ODOO_VOL="odoo-data-$1"
    ODOO_PORT=$(inst_port "$1"); ODOO_URL="http://localhost:$ODOO_PORT"
}

# Remember the instance for the next run (EPHEM_INSTANCE in .env).
stack_pin_instance() { set_env_key EPHEM_INSTANCE "$1"; }

# Mode, compose files, roster, and the Odoo to act on. In dev-multi the
# instance is the argument, else EPHEM_INSTANCE from .env, else the first in
# the roster. Returns 1 with STACK_ERROR set when the request cannot be met;
# the variables are still filled with the best available choice so a caller
# can print the error and carry on.
STACK_ERROR=""
stack_init() {  # stack_init [INSTANCE]
    local want="${1:-}"
    STACK_ERROR=""
    ephem_mode
    compose_files_init
    instances_load
    if [ "$EPHEM_MODE" != dev-multi ]; then
        stack_use_single
        [ -n "$want" ] && STACK_ERROR="This checkout is in $(ephem_mode_label) mode: there are no instances to choose from."
        [ -z "$STACK_ERROR" ]
        return
    fi
    if [ "${#INSTANCES[@]}" -eq 0 ]; then
        stack_use_single
        STACK_ERROR=".dev-instances is empty. Bring the stack up first:  bash scripts/dev-instances.sh up 1 2 3"
        return 1
    fi
    if [ ! -f "$EPHEM_ROOT/docker-compose.dev-multi.yml" ]; then
        STACK_ERROR="docker-compose.dev-multi.yml is missing. Regenerate it:  bash scripts/dev-instances.sh up ${INSTANCES[*]}"
    fi
    if [ -n "$want" ]; then
        if ! inst_index "$want" >/dev/null; then
            STACK_ERROR="No instance named '$want'. Configured: ${INSTANCES[*]}"
            want="${INSTANCES[0]}"
        fi
    else
        want=$(env_get EPHEM_INSTANCE)
        inst_index "$want" >/dev/null 2>&1 || want="${INSTANCES[0]}"
    fi
    stack_use_instance "$want"
    [ -z "$STACK_ERROR" ]
}

# ── Reaching a filestore ──────────────────────
FILESTORE="/var/lib/odoo/.local/share/Odoo/filestore"
FS_PARENT="/var/lib/odoo/.local/share/Odoo"

# Run a shell command against one Odoo service's data volume. Prefers the
# running container; falls back to a throwaway one (same volumes, no
# dependencies started) so the filestore stays reachable while Odoo is
# stopped. stdin is closed: a stray exec must never swallow a menu's own
# keyboard input.
odoo_sh_on() {  # odoo_sh_on SERVICE 'shell command'
    if [ "$(svc_state "$1")" = "running" ]; then
        compose exec -T "$1" sh -c "$2" </dev/null
    else
        compose run --rm -T --no-deps --entrypoint sh "$1" -c "$2" </dev/null
    fi
}

# Same, but stdin IS passed through (a restore streams an archive in). Kept
# separate so no ordinary call can eat menu input by accident.
odoo_pipe_on() {  # odoo_pipe_on SERVICE 'shell command' < file
    if [ "$(svc_state "$1")" = "running" ]; then
        compose exec -T "$1" sh -c "$2"
    else
        compose run --rm -T --no-deps --entrypoint sh "$1" -c "$2"
    fi
}

# The service a filestore operation should go to. A caller sets ODOO_SH_SVC
# (fs_svc_for gives the right one per database); otherwise the pinned Odoo.
odoo_sh()   { odoo_sh_on   "${ODOO_SH_SVC:-$ODOO_SVC}" "$1"; }
odoo_pipe() { odoo_pipe_on "${ODOO_SH_SVC:-$ODOO_SVC}" "$1"; }

# Which instance's volume holds (or should hold) the filestore of a database.
# Postgres is shared in dev-multi, filestores are not: ephem_2's attachments
# live in odoo-data-2 whichever instance the menu is pinned to. Order:
#   1. the instance the name points at (ephem_2, ephem_2_copy → instance 2)
#      when that instance's volume has the folder. A stale copy left in
#      another volume (instance 1 once ran ephem_2) must not win.
#   2. the pinned instance, then any other instance, that has the folder.
#   3. for a folder that does not exist yet: the instance the name points
#      at, else the pinned instance.
declare -A FS_SVC_CACHE=()
fs_svc_for() {  # fs_svc_for DBNAME → service
    [ "$EPHEM_MODE" = dev-multi ] || { echo "$ODOO_SVC"; return 0; }
    local hit="${FS_SVC_CACHE[$1]:-}"
    [ -n "$hit" ] && { echo "$hit"; return 0; }
    local n svc="" named=""
    for n in "${INSTANCES[@]}"; do
        case "$1" in "ephem_$n"|"ephem_${n}_"*) named="odoo_$n"; break ;; esac
    done
    if [ -n "$named" ] && odoo_sh_on "$named" "test -d $FILESTORE/$1" >/dev/null 2>&1; then
        svc="$named"
    elif odoo_sh_on "$ODOO_SVC" "test -d $FILESTORE/$1" >/dev/null 2>&1; then
        svc="$ODOO_SVC"
    else
        for n in "${INSTANCES[@]}"; do
            [ "odoo_$n" = "$ODOO_SVC" ] || [ "odoo_$n" = "$named" ] && continue
            if odoo_sh_on "odoo_$n" "test -d $FILESTORE/$1" >/dev/null 2>&1; then
                svc="odoo_$n"; break
            fi
        done
    fi
    [ -z "$svc" ] && svc="${named:-$ODOO_SVC}"
    FS_SVC_CACHE[$1]="$svc"
    echo "$svc"
}

# The instance name behind a service ("odoo_2" → "2"), "" for the single odoo.
svc_instance() { case "$1" in odoo_*) echo "${1#odoo_}" ;; *) echo "" ;; esac; }

# One tar.gz of every filestore this checkout owns, to stdout: one directory
# per database at the top level, the layout scripts/backup.sh has always
# written and the restore menu reads. Mounts the data volumes directly, so it
# works while Odoo is stopped and, in dev-multi, gathers every instance's
# volume into a single archive. Exit 3 = no filestore exists yet.
filestore_archive() {
    local proj n vol tag
    local -a mounts=()
    proj=$(compose_project)
    if [ "$EPHEM_MODE" = dev-multi ]; then
        for n in "${INSTANCES[@]}"; do
            vol="${proj}_odoo-data-$n"
            if docker volume inspect "$vol" >/dev/null 2>&1; then
                mounts+=(-v "$vol:/fs/$n:ro")
            else
                echo "  note: instance $n has no data volume yet ($vol), nothing to archive" >&2
            fi
        done
    else
        vol="${proj}_odoo-data"
        docker volume inspect "$vol" >/dev/null 2>&1 && mounts+=(-v "$vol:/fs/single:ro")
    fi
    [ "${#mounts[@]}" -eq 0 ] && return 3
    # The sh inside collects only the filestore folders that exist, so an
    # instance that has never created a database cannot fail the whole run.
    docker run --rm "${mounts[@]}" --entrypoint sh "$(stack_image)" -c '
        set --
        for d in /fs/*/.local/share/Odoo/filestore; do
            [ -d "$d" ] && set -- "$@" -C "$d" .
        done
        [ $# -eq 0 ] && exit 3
        exec tar -czf - "$@"'
}

# ── Databases (shared Postgres) ───────────────
list_dbs() {
    compose exec -T db psql -U "$DB_USER" -d postgres -t -A -c \
        "SELECT datname FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres') ORDER BY datname;" \
        </dev/null 2>/dev/null | tr -d '\r'
}

# ── Leftovers from another mode ───────────────
# Files and containers a previous mode left behind. One line each on stdout;
# returns 1 when something was found, 0 when clean.
stack_leftovers() {
    local found=0 ov="$EPHEM_ROOT/docker-compose.override.yml" c st
    if [ "$EPHEM_MODE" = dev-multi ]; then
        if [ -f "$ov" ]; then
            echo "docker-compose.override.yml: the single-instance override. The multi stack ignores it, but a plain 'docker compose' command still loads it and would start ephem-app."
            found=1
        fi
        st=$(docker inspect -f '{{.State.Status}}' ephem-app 2>/dev/null) || st=""
        if [ -n "$st" ]; then
            echo "container ephem-app ($st): the single-instance Odoo, not part of the multi stack."
            found=1
        fi
    else
        while IFS= read -r c; do
            case "$c" in
                ""|ephem-app|ephem-db|ephem-nginx|ephem-certbot) continue ;;
            esac
            st=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null) || st="?"
            echo "container $c ($st): from multi-instance mode (scripts/dev-instances.sh)."
            found=1
        done < <(docker ps -a --filter "name=^ephem-" --format '{{.Names}}' 2>/dev/null)
        if [ -f "$EPHEM_ROOT/docker-compose.dev-multi.yml" ]; then
            echo "docker-compose.dev-multi.yml: the multi-instance stack file (unused in $EPHEM_MODE mode)."
            found=1
        fi
    fi
    [ "$found" -eq 0 ]
}

# Remove the single-instance override setup.sh generated. A file without
# that header was written by hand and is left alone (returns 1).
retire_single_override() {
    local ov="$EPHEM_ROOT/docker-compose.override.yml"
    [ -f "$ov" ] || return 0
    if grep -q 'generated by setup.sh' "$ov"; then
        rm -f "$ov"
        echo -e "  ${GREEN}✓${NC} removed docker-compose.override.yml (single-instance override generated by setup.sh)"
        return 0
    fi
    echo -e "  ${YELLOW}!${NC} docker-compose.override.yml was not generated by setup.sh, left in place."
    echo "     A plain 'docker compose up' would use it; move it away if you no longer need it."
    return 1
}

# ── Doctor ────────────────────────────────────
# Scan one Odoo service's recent log for the failures people hit most, and
# print the fix. Reads a stopped container's log too: that is where the
# reason it stopped is.
stack_doctor() {  # stack_doctor SERVICE
    local svc="$1" LOGS found=0 MISSING n
    echo -e "${CYAN}${BOLD}Doctor: scanning the last 300 log lines of $svc${NC}"
    echo ""
    if [ "$(svc_state "$svc")" != running ]; then
        echo -e "${YELLOW}!${NC} $svc is $(svc_detail "$svc")."
        echo ""
    fi
    # Docker refusing to start the container is not in Odoo's log.
    local err; err=$(svc_start_error "$svc")
    if [ -n "$err" ]; then
        found=1
        echo -e "${RED}✗${NC} Docker could not start the container:"
        echo "$err" | fold -s -w 90 | sed 's/^/     /'
        echo "   Usually a stale single-file mount (its config file was replaced)."
        echo "   Recreate it:  $(compose_cmd_text) up -d --force-recreate $svc"
        echo "   (the Stack menu's start does that for you; data volumes are kept)"
        echo ""
    fi
    LOGS=$(compose logs --tail=300 --no-log-prefix "$svc" 2>&1) || LOGS=""
    if [ -z "$LOGS" ]; then
        echo -e "${YELLOW}!${NC} No log output for $svc (never started?)."
        return 0
    fi
    # Here-strings, not `echo | grep -q`: grep quitting early must not
    # SIGPIPE a producer under pipefail.
    if grep -q "ModuleNotFoundError" <<< "$LOGS"; then
        found=1
        MISSING=$(sed -n "s/.*ModuleNotFoundError: No module named '\([^']*\)'.*/\1/p" <<< "$LOGS" | sort -u | tr '\n' ' ')
        echo -e "${RED}✗${NC} Missing Python module(s): ${BOLD}${MISSING}${NC}"
        echo "   A custom addon imports a package that is not in the app image."
        echo "   Permanent fix: add it to the image (rebuild and push), then pull."
        echo "   Quick local patch:"
        echo "     $(compose_cmd_text) exec -u root $svc pip install --break-system-packages ${MISSING}"
        echo "     $(compose_cmd_text) restart $svc"
        echo ""
    fi
    if grep -q "Failed to load registry" <<< "$LOGS"; then
        found=1
        echo -e "${RED}✗${NC} Registry failed to load: every page returns 500."
        echo "   Usually a module raising on import (see above) or a bad XML/data file."
        echo ""
    fi
    if grep -qE "ParseError|XMLSyntaxError|ValidationError.*view" <<< "$LOGS"; then
        found=1
        echo -e "${RED}✗${NC} A view or data file did not load. Last mention:"
        grep -E "ParseError|XMLSyntaxError|ValidationError.*view" <<< "$LOGS" | tail -1 | cut -c1-200 | sed 's/^/     /'
        echo ""
    fi
    if grep -q "password authentication failed" <<< "$LOGS"; then
        found=1
        echo -e "${RED}✗${NC} Postgres rejects the app password: .env and the database disagree."
        echo "   Re-run  bash setup.sh  (it syncs the 'odoo' password to .env)."
        echo ""
    fi
    if grep -qiE "could not translate host name|connection refused.*5432|database .* does not exist" <<< "$LOGS"; then
        found=1
        echo -e "${RED}✗${NC} Database connectivity or availability issue."
        echo "   Check:  $(compose_cmd_text) ps   and   $(compose_cmd_text) logs db"
        echo ""
    fi
    if grep -q "Address already in use" <<< "$LOGS"; then
        found=1
        echo -e "${RED}✗${NC} A port inside the container is already taken: two Odoo processes in one container."
        echo "   Restart it:  $(compose_cmd_text) restart $svc"
        echo ""
    fi
    n=$(grep -c " ERROR " <<< "$LOGS") || n=0
    if [ "$found" -eq 0 ]; then
        if [ "${n:-0}" -gt 0 ]; then
            echo -e "${YELLOW}!${NC} No known signature, but $n ERROR line(s) in the last 300. Newest:"
            grep " ERROR " <<< "$LOGS" | tail -3 | cut -c1-200 | sed 's/^/     /'
        else
            echo -e "${GREEN}✓${NC} No known error signatures in the last 300 log lines."
        fi
    fi
    return 0
}

# ── GitHub SSH access ─────────────────────────
# Every git operation on borse/ePHEM goes over SSH. A key with a passphrase
# and no agent makes ssh ask for it on EVERY git command; one menu action runs
# several, and a command under `timeout` cannot even show the prompt (it sits
# in a background process group), so it just fails. Before the first git
# command: test access without prompting and, when the only thing missing is
# the passphrase, load the key into an agent once. An agent the shell already
# has (SSH_AUTH_SOCK) is reused, so the key stays loaded after this script
# ends; otherwise one is started for this process and stopped with it.
GITHUB_SSH_STATE=""     # "" (not checked yet) | ok | declined | no-access

github_ssh_ok() {  # never prompts; GitHub answers "successfully authenticated" and exits 1
    local out
    out=$(ssh -o BatchMode=yes -o ConnectTimeout=10 -T git@github.com 2>&1) || true
    grep -q "successfully authenticated" <<< "$out"
}

ssh_key_file() {  # the private key ssh offers by default
    local k
    for k in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_ecdsa" "$HOME/.ssh/id_rsa"; do
        [ -f "$k" ] && { echo "$k"; return 0; }
    done
    return 1
}

ssh_key_encrypted() { ! ssh-keygen -y -P "" -f "$1" >/dev/null 2>&1; }

# Returns 0 when git can reach GitHub without prompting from now on. Asked
# once per run: a declined offer is remembered, so a later action does not
# ask again (git then prompts on its own, as it always did).
ensure_github_ssh() {
    case "$GITHUB_SSH_STATE" in ok) return 0 ;; declined|no-access) return 1 ;; esac
    if github_ssh_ok; then GITHUB_SSH_STATE=ok; return 0; fi
    local key rc=0 A
    key=$(ssh_key_file) || key=""
    if [ -n "$key" ] && ssh_key_encrypted "$key"; then
        echo -e "  ${YELLOW}!${NC} Your SSH key has a passphrase and no agent holds it, so ssh would"
        echo "     ask for it on every git command (and silently fail the quick checks)."
        echo "     Key: $key"
        # EOF (no terminal) counts as no: ssh-add could not ask for the passphrase anyway.
        read -r -p "  Load it into an agent once for this session? [Y/n]: " A || A=n
        if [[ "${A:-Y}" =~ ^[Nn]$ ]]; then
            GITHUB_SSH_STATE=declined
            echo "     Left as is: expect a passphrase prompt per git command."
            return 1
        fi
        # ssh-add -l: 0 = agent with keys, 1 = agent without keys, 2 = no agent
        ssh-add -l >/dev/null 2>&1 || rc=$?
        if [ "$rc" -eq 2 ]; then
            eval "$(ssh-agent -s)" >/dev/null 2>&1
            # Stopped with this process. To keep a key loaded across terminals
            # see README → Developer Mode → Troubleshooting.
            trap 'ssh-agent -k >/dev/null 2>&1' EXIT
            echo "     (started an ssh-agent for this run; it stops when the script exits)"
        fi
        if ! ssh-add "$key"; then
            GITHUB_SSH_STATE=declined
            return 1
        fi
        if github_ssh_ok; then GITHUB_SSH_STATE=ok; return 0; fi
        echo -e "  ${RED}✗${NC} The key is loaded but GitHub refuses it. Is its public key on your"
        echo "     GitHub account, and are you a collaborator on borse/ePHEM?  ssh -T git@github.com"
        GITHUB_SSH_STATE=no-access
        return 1
    fi
    echo -e "  ${RED}✗${NC} No SSH access to GitHub (ssh -o BatchMode=yes -T git@github.com fails)."
    echo "     README → Developer Mode → SSH key setup."
    GITHUB_SSH_STATE=no-access
    return 1
}

# ── Interactive helpers ───────────────────────
# Run a foreground command the operator ends with Ctrl-C (a log tail) and
# come back to the menu instead of dying with it.
run_interruptible() {
    local rc=0
    trap ':' INT
    "$@" || rc=$?
    trap - INT
    return "$rc"
}
