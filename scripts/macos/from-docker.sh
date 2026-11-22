#!/bin/bash
# ──────────────────────────────────────────────────────────────
# from-docker.sh — move a Mac from the Docker developer stack to the native
# setup, keeping its repositories. bash manage.sh offers it when it opens on
# a Mac whose developer instances still run in Docker; it can also be run
# directly, and run again: every step looks first, so a move that stopped
# halfway carries on where it was (bash manage.sh offers that too).
#
# Docker instance odcaX/ becomes native instance N (X itself when X is 1-9,
# else the first free number; the single-instance addons/ becomes 1):
#
#   ePHEM-core     a worktree of the native ePHEM/ clone, on the same commit:
#                  every local branch comes over as odcaN/<branch>, with the
#                  commits that were never pushed, and the working files as
#                  they are (changed, new and deleted files: what was staged
#                  arrives unstaged). Stashes stay in the Docker copy.
#   other repos    copied as they are: remote, branch, changes
#
#   its database   ephem_X and its filestore become ephem_N (pg_dump from
#                  the Docker Postgres, restored with dev.sh restore). Every
#                  other database in Docker is copied out too, and kept as a
#                  backup in backups/from-docker/<name>/ (dev.sh restore N it).
#
# The stack is stopped first (docker compose stop: nothing is removed), then
# only its Postgres is started to copy the databases out. Docker Desktop is
# started when it is not running (asked first). When everything is done the
# containers, volumes and images are offered for removal; until then going
# back is bash manage.sh --docker. The Docker folders (odcaX/, addons/) are
# only read; they stay where they are until you delete them.
#
# Usage:
#   bash scripts/macos/from-docker.sh [--home DIR] [--plan] [--yes]
#     --home DIR   the native home (default: ~/Developer/ephem)
#     --plan       show what would move, and change nothing
#     --yes        take the default answer to every question
#   bash scripts/macos/from-docker.sh offer
#                  what manage.sh runs: asks first, and only on a Mac whose
#                  developer instances run in Docker. Exit 0: moved (open the
#                  native menu); 3: staying with Docker; anything else: failed.
#
# Runs on macOS's own bash 3.2.
# ──────────────────────────────────────────────────────────────
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
# shellcheck source=ui.sh
source "$MAC_DIR/ui.sh"

ME="bash scripts/macos/from-docker.sh"
V2_ME="bash manage.sh"
DEV="$MAC_DIR/dev.sh"
DENV="$EPHEM_ROOT/.env"
# Written when a move starts, removed when it is done: while it is there,
# manage.sh offers to carry on instead of opening either menu.
PENDING="$EPHEM_ROOT/.macos-from-docker"
STAY=3
DUMPS=""             # backups/from-docker/ of the native home (choose_home)
KEPT=""              # database copies not restored into an instance

OFFER=0; PLAN=0; OPT_HOME=""; ASSUME_YES="${ASSUME_YES:-0}"
if [ "${1:-}" = offer ]; then OFFER=1; shift; fi
while [ $# -gt 0 ]; do
    case "$1" in
        --home)  OPT_HOME="${2:-}"; shift ;;
        --plan)  PLAN=1 ;;
        --yes|-y) ASSUME_YES=1 ;;
        -h|--help) sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown option: $1  ($ME --help)" ;;
    esac
    shift
done
export ASSUME_YES
if [ -n "$OPT_HOME" ]; then
    case "$OPT_HOME" in "~"*) OPT_HOME="$HOME${OPT_HOME#\~}" ;; esac
    native_paths "$OPT_HOME"
fi

# ── The Docker side ───────────────────────────
# .env is read one key at a time, never sourced (as scripts/stack-lib.sh does).
denv_get() { grep "^$1=" "$DENV" 2>/dev/null | head -1 | cut -d'=' -f2- | xargs 2>/dev/null || true; }

denv_set() {  # denv_set KEY VALUE: update or append, in place
    local tmp; tmp="$(mktemp)"
    K="$1" V="$2" awk '
        index($0, ENVIRON["K"] "=") == 1 { print ENVIRON["K"] "=" ENVIRON["V"]; done = 1; next }
        { print }
        END { if (!done) print ENVIRON["K"] "=" ENVIRON["V"] }' "$DENV" > "$tmp" && cat "$tmp" > "$DENV"
    rm -f "$tmp"
}

# EPHEM_MODE from .env, else what the files on disk say: the same reading as
# ephem_mode in scripts/stack-lib.sh (which needs bash 4).
docker_mode() {
    local m ov="$EPHEM_ROOT/docker-compose.override.yml"
    m="$(denv_get EPHEM_MODE | tr '[:upper:]' '[:lower:]')"
    case "$m" in
        developer|development|single) m=dev ;;
        multi|multi-instance|dev-multi-instance|developer-multi) m=dev-multi ;;
        production|prod) m=server ;;
    esac
    case "$m" in server|demo|dev|dev-multi) echo "$m"; return 0 ;; esac
    if [ -s "$EPHEM_ROOT/.dev-instances" ] && [ -f "$EPHEM_ROOT/docker-compose.dev-multi.yml" ]; then echo dev-multi
    elif [ -f "$ov" ] && grep -q 'Developer override' "$ov"; then echo dev
    elif [ -f "$ov" ] && grep -q 'Demo override' "$ov"; then echo demo
    else echo server; fi
}

DCORE="$(denv_get EPHEM_CORE_NAME)"; DCORE="${DCORE:-ePHEM-core}"
DMODE=""

# What moves, one entry per Docker instance (bash 3.2: parallel arrays).
S_LABEL=()   # odca2/, addons/
S_DIR=()     # the mounted folder
S_CORE=()    # its ePHEM clone ("" when there is none)
S_REPOS=()   # its other repositories, space-separated
S_N=()       # the native instance it becomes

src_repos() {  # src_repos DIR: the other repositories next to the ePHEM clone
    local d name out=""
    for d in "$1"/*/; do
        [ -d "$d" ] || continue
        name="$(basename "$d")"
        [ "$name" = "$DCORE" ] && continue
        case "$name" in *[!A-Za-z0-9._-]*) continue ;; esac
        if [ -e "$d/.git" ] || dir_has_modules "$d"; then out="$out $name"; fi
    done
    echo "${out# }"
}

add_source() {  # add_source LABEL DIR
    local dir="$2" core="" repos=""
    [ -d "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ] || return 0
    if [ -e "$dir/$DCORE/.git" ]; then
        core="$dir/$DCORE"; repos="$(src_repos "$dir")"
    elif [ -e "$dir/.git" ]; then
        core="$dir"             # the layout before $DCORE/: the folder is the clone
    else
        repos="$(src_repos "$dir")"
    fi
    [ -n "$core$repos" ] || return 0
    S_LABEL+=("$1"); S_DIR+=("$dir"); S_CORE+=("$core"); S_REPOS+=("$repos"); S_N+=("")
}

load_sources() {
    local name d seen=" "
    DMODE="$(docker_mode)"
    case "$DMODE" in
        dev-multi)
            if [ -f "$EPHEM_ROOT/.dev-instances" ]; then
                while IFS= read -r name; do
                    [ -n "$name" ] || continue
                    seen="$seen$name "
                    add_source "odca$name/" "$EPHEM_ROOT/odca$name"
                done < "$EPHEM_ROOT/.dev-instances"
            fi
            # Folders the roster no longer lists still hold repositories.
            for d in "$EPHEM_ROOT"/odca*/; do
                [ -d "$d" ] || continue
                name="$(basename "$d")"; name="${name#odca}"
                case "$seen" in *" $name "*) continue ;; esac
                add_source "odca$name/" "${d%/}"
            done
            ;;
        dev)
            if [ -d "$EPHEM_ROOT/addons" ]; then add_source "addons/" "$EPHEM_ROOT/addons"
            else add_source "custom-addons/" "$EPHEM_ROOT/custom-addons"; fi
            ;;
    esac
    return 0
}

# Docker instance odcaX/ → native N: X when it is a free 1-9, then the
# lowest free numbers for the rest, in roster order.
map_instances() {
    local i k used=" " lbl
    for ((i = 0; i < ${#S_DIR[@]}; i++)); do
        lbl="${S_LABEL[$i]}"; k="${lbl#odca}"; k="${k%/}"
        if valid_n "$k" && [[ "$used" != *" $k "* ]]; then S_N[i]="$k"; used="$used$k "; fi
    done
    for ((i = 0; i < ${#S_DIR[@]}; i++)); do
        [ -z "${S_N[$i]}" ] || continue
        for k in 1 2 3 4 5 6 7 8 9; do
            if [[ "$used" != *" $k "* ]]; then S_N[i]="$k"; used="$used$k "; break; fi
        done
        [ -n "${S_N[$i]}" ] || die "More than nine Docker instances: the native setup has 1 to 9. Remove some from the Docker menu first."
    done
}

# ── What a clone holds ────────────────────────
g_branch()   { git -C "$1" symbolic-ref -q --short HEAD 2>/dev/null || echo "(detached)"; }
g_changes()  { git -C "$1" status --porcelain 2>/dev/null | wc -l | tr -d ' '; }
g_unpushed() { git -C "$1" rev-list --count --branches --not --remotes 2>/dev/null || echo 0; }
g_stashes()  { git -C "$1" stash list 2>/dev/null | wc -l | tr -d ' '; }
g_nbranch()  { git -C "$1" for-each-ref refs/heads 2>/dev/null | wc -l | tr -d ' '; }

changes_cell() {  # changes_cell DIR
    local c u s out
    [ -e "$1/.git" ] || { echo "not a clone"; return 0; }
    c="$(g_changes "$1")"; u="$(g_unpushed "$1")"; s="$(g_stashes "$1")"
    if [ "$c" = 0 ]; then out="clean"; else out="$c changed"; fi
    [ "$u" = 0 ] || out="$out, $u unpushed"
    [ "$s" = 0 ] || out="$out, $s stash"
    if [ "$c$u$s" = 000 ]; then echo "clean"; else echo "$YELLOW$V2_CS$out"; fi
}

plan_table() {
    local i n r mark cnt seen core dest
    v2_t_begin "Docker" "Native" "Branch" "Changes" "Becomes"
    for ((i = 0; i < ${#S_DIR[@]}; i++)); do
        n="${S_N[$i]}"; core="${S_CORE[$i]}"
        v2_t_add "$BOLD$V2_CS${S_LABEL[$i]}" "$BOLD${V2_CS}odca$n  :$(inst_port "$n")" "" "" ""
        cnt=0; [ -n "$core" ] && cnt=1
        for r in ${S_REPOS[$i]}; do cnt=$((cnt + 1)); done
        seen=0
        if [ -n "$core" ]; then
            seen=1; mark="├ "; [ "$cnt" = 1 ] && mark="└ "
            if [ -e "$(inst_core "$n")/.git" ]; then dest="$GREEN${V2_CS}already native: kept"
            else dest="worktree"; fi
            v2_t_add "" "$mark$CORE_NAME" "$(g_branch "$core")" "$(changes_cell "$core")" "$dest"
        fi
        for r in ${S_REPOS[$i]}; do
            seen=$((seen + 1)); mark="├ "; [ "$seen" = "$cnt" ] && mark="└ "
            if [ -e "$(inst_dir "$n")/$r" ]; then dest="$GREEN${V2_CS}already native: kept"
            else dest="copied"; fi
            v2_t_add "" "$mark$r" "$(g_branch "${S_DIR[$i]}/$r")" "$(changes_cell "${S_DIR[$i]}/$r")" "$dest"
        done
    done
    V2_T_DROP=4
    v2_t_draw
}

plan_notes() {
    echo ""
    echo "  Each instance keeps its branches, the commits never pushed and the files being"
    echo "  edited. The Docker folders are only read: they stay where they are as a copy."
    if [ "$DK_STATE" = read ]; then
        echo "  Each instance's database and filestore come along; other databases are kept as"
        echo "  backups. Docker itself is only stopped; removing it is offered at the end."
    else
        echo "  The databases and filestores come along too: $DK_STATE"
        echo "  Docker itself is only stopped; removing it is offered at the end."
    fi
    if ! native_installed; then
        echo ""
        echo "  Installs, into $NATIVE_HOME: Homebrew (when missing), PostgreSQL 16, Odoo 18.0,"
        echo "  a Python 3.12 virtualenv, wkhtmltopdf. Some 10-15 minutes the first time."
    fi
}

# ── The databases in Docker ───────────────────
# Every Docker mode has one Postgres container, ephem-db, whose unix socket
# trusts its superuser (db-config/pg_hba.conf). Filestores live on the Odoo
# volumes: <project>_odoo-data-X (dev-multi) or <project>_odoo-data (dev).
DK_DB=ephem-db
DK_SU=postgres
DK_STATE=""          # read | why the databases could not be listed
DK_DBS=()            # every database in it
DK_SIZE=()           # parallel: its size
DK_N=()              # parallel: the native instance it becomes ("" = a backup)
DK_FILES=()          # the compose files of this mode
NOT_COPIED=""        # databases left in Docker (a dump that failed, or Docker off)

docker_answers() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }
dk_running()  { [ "$(docker inspect -f '{{.State.Running}}' "$DK_DB" 2>/dev/null)" = true ]; }
dk_exists()   { docker inspect "$DK_DB" >/dev/null 2>&1; }
dk_psql()     { docker exec "$DK_DB" psql -U "$DK_SU" -d postgres -AtX -c "$1" </dev/null 2>/dev/null | tr -d '\r'; }
dk_project()  {
    docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$DK_DB" 2>/dev/null | grep . \
        || basename "$EPHEM_ROOT" | tr '[:upper:]' '[:lower:]'
}

dk_files() {
    DK_FILES=(-f "$EPHEM_ROOT/docker-compose.yml")
    if [ "$DMODE" = dev-multi ] && [ -f "$EPHEM_ROOT/docker-compose.dev-multi.yml" ]; then
        DK_FILES+=(-f "$EPHEM_ROOT/docker-compose.dev-multi.yml")
    elif [ -f "$EPHEM_ROOT/docker-compose.override.yml" ]; then
        DK_FILES+=(-f "$EPHEM_ROOT/docker-compose.override.yml")
    fi
}

# Docker Desktop started when it is installed but not running (asked first).
docker_up() {
    local i
    command -v docker >/dev/null 2>&1 || return 1
    docker info >/dev/null 2>&1 && return 0
    [ -d /Applications/Docker.app ] || return 1
    echo ""
    echo "  Docker Desktop is not running, and the databases are copied out of it."
    confirm "  Start Docker Desktop now?" Y || return 1
    open -a Docker || return 1
    printf '  Waiting for Docker'
    for i in $(seq 1 90); do
        if docker info >/dev/null 2>&1; then echo ""; return 0; fi
        printf '.'; sleep 2
    done
    echo ""; warn "Docker did not answer within 3 minutes."
    return 1
}

# The Postgres container alone, started when it is stopped.
dk_db_up() {
    local i
    dk_exists || return 1
    dk_running || docker start "$DK_DB" >/dev/null || return 1
    for i in $(seq 1 60); do
        docker exec "$DK_DB" pg_isready -q -U "$DK_SU" </dev/null >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

# DK_DBS and where each goes. Reads only a Postgres that already runs: the
# plan and the question change nothing.
load_dbs() {
    local line name size i j x
    DK_DBS=(); DK_SIZE=(); DK_N=()
    if ! command -v docker >/dev/null 2>&1; then DK_STATE="Docker is not installed here, so there are none to copy."; return 0; fi
    if ! docker info >/dev/null 2>&1; then DK_STATE="Docker Desktop is started for that during the move."; return 0; fi
    if ! dk_exists; then DK_STATE="there is no $DK_DB container, so none to copy."; return 0; fi
    if ! dk_running; then DK_STATE="$DK_DB is stopped; it is started for that during the move."; return 0; fi
    while IFS='|' read -r name size; do
        [ -n "$name" ] || continue
        if ! printf '%s' "$name" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_.-]*$'; then
            warn "Database '$name' has a name the scripts do not handle: left in Docker."
            NOT_COPIED="$NOT_COPIED $name"; continue
        fi
        DK_DBS+=("$name"); DK_SIZE+=("$size"); DK_N+=("")
    done < <(dk_psql "SELECT datname, pg_size_pretty(pg_database_size(datname)) FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres' ORDER BY 1")
    DK_STATE=read
    # dev-multi: instance X runs ephem_X (its dbfilter). dev: the only
    # database, or the one chosen (pick_dev_db).
    for ((i = 0; i < ${#S_DIR[@]}; i++)); do
        x="${S_LABEL[$i]#odca}"; x="${x%/}"
        for ((j = 0; j < ${#DK_DBS[@]}; j++)); do
            if [ "$DMODE" = dev-multi ] && [ "${DK_DBS[$j]}" = "ephem_$x" ]; then DK_N[j]="${S_N[$i]}"; fi
        done
    done
    if [ "$DMODE" = dev ] && [ "${#DK_DBS[@]}" -eq 1 ] && [ "${#S_N[@]}" -gt 0 ]; then DK_N[0]="${S_N[0]}"; fi
    return 0
}

# dev with several databases: which one becomes ephem_1 (the others: backups).
pick_dev_db() {
    local j a def=1
    [ "$DMODE" = dev ] && [ "${#DK_DBS[@]}" -gt 1 ] && [ "${#S_N[@]}" -gt 0 ] || return 0
    for ((j = 0; j < ${#DK_DBS[@]}; j++)); do [ -z "${DK_N[$j]}" ] || return 0; done
    for ((j = 0; j < ${#DK_DBS[@]}; j++)); do case "${DK_DBS[$j]}" in ephem*) def=$((j + 1)); break ;; esac; done
    echo ""
    echo "  The Docker instance has ${#DK_DBS[@]} databases; native instance ${S_N[0]} runs one, $(inst_db "${S_N[0]}")."
    for ((j = 0; j < ${#DK_DBS[@]}; j++)); do v2_opt "$((j + 1))" "${DK_DBS[$j]}  (${DK_SIZE[$j]})"; done
    echo "  The others are kept as backups."
    if [ "$ASSUME_YES" = 1 ]; then a="$def"; else read -r -p "  Which one becomes $(inst_db "${S_N[0]}")? [$def]: " a || a=""; fi
    a="${a:-$def}"
    if [[ "$a" =~ ^[0-9]+$ ]] && [ "$a" -ge 1 ] && [ "$a" -le "${#DK_DBS[@]}" ]; then DK_N[a - 1]="${S_N[0]}"
    else warn "No such number: every database is kept as a backup."; fi
}

db_table() {
    local j to
    [ "$DK_STATE" = read ] && [ "${#DK_DBS[@]}" -gt 0 ] || return 0
    echo ""
    v2_t_begin "Database" "Size" "Becomes"
    for ((j = 0; j < ${#DK_DBS[@]}; j++)); do
        if [ -n "${DK_N[$j]}" ]; then to="$(inst_db "${DK_N[$j]}")  (odca${DK_N[$j]}, with its filestore)"
        elif [ "$DMODE" = dev ] && [ "${#DK_DBS[@]}" -gt 1 ]; then to="asked during the move"
        else to="a backup: backups/from-docker/${DK_DBS[$j]}"; fi
        v2_t_add "${DK_DBS[$j]}" "${DK_SIZE[$j]}" "$to"
    done
    v2_t_draw
}

mf_get() { grep "^$2=" "$1/manifest.txt" 2>/dev/null | head -1 | cut -d'=' -f2- || true; }

# The filestore volumes to look in for DB: its own instance's first.
fs_volumes() {  # fs_volumes DB
    local proj pref
    proj="$(dk_project)"
    if [ "$DMODE" = dev-multi ]; then pref="${proj}_odoo-data-${1#ephem_}"; else pref="${proj}_odoo-data"; fi
    docker volume inspect "$pref" >/dev/null 2>&1 && echo "$pref"
    docker volume ls -q --filter "name=${proj}_odoo-data" 2>/dev/null | grep -E "^${proj}_odoo-data(-.*)?\$" | grep -vxF "$pref" || true
}

# One database out of Docker, in the format of dev.sh backup: db.dump and
# filestore.tar.gz in backups/from-docker/<name>/. .complete once verified;
# a run again skips it.
dump_one() {  # dump_one INDEX
    local db="${DK_DBS[$1]}" n="${DK_N[$1]}" out img vol rc fs="no"
    out="$DUMPS/$db"
    if [ -f "$out/.complete" ]; then ok "$db: already copied out ($out)"; return 0; fi
    rm -rf "$out"; ( umask 077; mkdir -p "$out" )
    if ! docker exec "$DK_DB" pg_dump -U "$DK_SU" -Fc --no-owner -d "$db" </dev/null > "$out/db.dump" \
       || ! docker exec -i "$DK_DB" pg_restore -l < "$out/db.dump" >/dev/null 2>&1; then
        rm -rf "$out"; warn "$db: pg_dump failed, left in Docker."
        NOT_COPIED="$NOT_COPIED $db"; return 0
    fi
    img="$(docker inspect -f '{{.Config.Image}}' "$DK_DB")"
    for vol in $(fs_volumes "$db"); do
        rc=0
        # shellcheck disable=SC2016  # $1 is expanded by the sh in the container
        docker run --rm -v "$vol:/fs:ro" --entrypoint sh "$img" -c '
            for d in "/fs/.local/share/Odoo/filestore/$1" "/fs/filestore/$1"; do
                [ -d "$d" ] && exec tar -czf - -C "$d" .
            done
            exit 3' sh "$db" </dev/null > "$out/filestore.tar.gz" 2>/dev/null || rc=$?
        if [ "$rc" = 0 ] && tar -tzf "$out/filestore.tar.gz" >/dev/null 2>&1; then fs="$vol"; break; fi
        rm -f "$out/filestore.tar.gz"
    done
    {
        echo "docker_db=$db"
        echo "native_instance=$n"
        echo "filestore_volume=$fs"
        echo "date=$(date '+%Y-%m-%d %H:%M:%S %z')"
    } > "$out/manifest.txt"
    touch "$out/.complete"
    if [ "$fs" = no ]; then
        ok "$db: db.dump ($(du -h "$out/db.dump" | awk '{print $1}')); no filestore found"
    else
        ok "$db: db.dump ($(du -h "$out/db.dump" | awk '{print $1}')), filestore.tar.gz ($(du -h "$out/filestore.tar.gz" | awk '{print $1}'))"
    fi
}

# Stop the stack (nothing removed), then copy every database out through its
# Postgres alone: no Odoo writes while the files are read, and the ports of
# the instances are free for the native ones.
copy_databases() {
    local j
    NOT_COPIED=""
    step "Docker: stopping the stack and copying the databases out"
    if ! docker_up; then
        if command -v docker >/dev/null 2>&1; then
            warn "Docker is not running: the databases stay in it (a run again copies them: $ME)."
            NOT_COPIED="$NOT_COPIED (every database: Docker was not running)"
        else
            ok "Docker is not installed: no database to copy"
        fi
        return 0
    fi
    dk_files
    if docker compose "${DK_FILES[@]}" stop; then ok "Containers stopped (not removed)"
    else warn "docker compose stop did not finish: an instance still running keeps its port."; fi
    if ! dk_db_up; then
        if dk_exists; then
            warn "$DK_DB does not start: the databases stay in Docker."
            NOT_COPIED="$NOT_COPIED (every database: $DK_DB did not start)"
        else
            ok "No $DK_DB container: no database to copy"
        fi
        return 0
    fi
    load_dbs
    pick_dev_db
    mkdir -p "$DUMPS"
    for ((j = 0; j < ${#DK_DBS[@]}; j++)); do dump_one "$j"; done
    [ "${#DK_DBS[@]}" -gt 0 ] || ok "No database in Docker"
    docker stop "$DK_DB" >/dev/null 2>&1 || true
}

native_db_exists() { [ "$("$PG_BIN/psql" -X -d postgres -Atc "SELECT 1 FROM pg_database WHERE datname = '$1'" 2>/dev/null)" = 1 ]; }

# Each instance's database from its copy; .restored once done, so a run
# again never replaces a database that has been worked on since.
restore_databases() {
    local d n db target
    KEPT=""
    for d in "$DUMPS"/*/; do
        [ -f "$d/.complete" ] || continue
        d="${d%/}"; n="$(mf_get "$d" native_instance)"; db="$(mf_get "$d" docker_db)"
        if [ -z "$n" ]; then KEPT="$KEPT $d"; continue; fi
        target="$(inst_db "$n")"
        if [ -f "$d/.restored" ]; then ok "$target: already restored from Docker's $db"; continue; fi
        if [ ! -f "$(inst_conf "$n")" ]; then warn "Instance $n was not created: Docker's $db stays a backup ($d)"; KEPT="$KEPT $d"; continue; fi
        if native_db_exists "$target"; then
            echo ""
            warn "$target already exists in this Mac's Postgres."
            if ! confirm "  Replace it with Docker's $db?" N; then
                echo "  Kept. Docker's copy: bash scripts/macos/dev.sh restore $n $d"
                KEPT="$KEPT $d"; continue
            fi
        fi
        step "Docker's $db → $target"
        if bash "$DEV" restore "$n" "$d" --yes; then touch "$d/.restored"
        else warn "Restoring $db into $target failed. The copy stays: bash scripts/macos/dev.sh restore $n $d"; KEPT="$KEPT $d"; fi
    done
}

# Once everything is done: the stack's containers, volumes and images.
offer_remove_docker() {
    local proj nc nv
    docker_answers || return 0
    dk_files
    proj="$(dk_project)"
    nc="$(docker ps -aq --filter "label=com.docker.compose.project=$proj" 2>/dev/null | grep -c . || true)"
    nv="$(docker volume ls -q --filter "label=com.docker.compose.project=$proj" 2>/dev/null | grep -c . || true)"
    [ "$nc" != 0 ] || [ "$nv" != 0 ] || return 0
    echo ""
    echo -e "  ${BOLD}The Docker stack${NC} is still on disk: $nc container(s), stopped; $nv volume(s), the"
    echo "  old databases and filestores; and the images it pulled (a few GB)."
    if [ -n "$NOT_COPIED" ]; then
        warn "Not copied out of Docker:$NOT_COPIED. Removing the volumes deletes that for good."
    else
        echo "  Every database was copied out above."
    fi
    if confirm "  Remove the containers, volumes and images now?" N; then
        if docker compose "${DK_FILES[@]}" down -v --rmi all --remove-orphans; then
            ok "Docker stack removed"
        else
            warn "docker compose down did not finish: see above. Again later: docker compose $(printf '%s ' "${DK_FILES[@]}" | sed "s#$EPHEM_ROOT/##g")down -v --rmi all"
        fi
    else
        echo "  Kept: bash manage.sh --docker still opens it. Remove it later:"
        echo "    cd $EPHEM_ROOT && docker compose $(printf '%s ' "${DK_FILES[@]}" | sed "s#$EPHEM_ROOT/##g")down -v --rmi all"
    fi
}

# ── The move ──────────────────────────────────
core_git() { git -C "$CORE_CLONE" "$@"; }

# The native ePHEM/ clone, made from a Docker clone instead of GitHub when it
# is not there yet: no download of the whole history, and the same remote URL
# (an ssh alias with a deploy key keeps working). Then one fetch from origin.
seed_core_clone() {  # seed_core_clone DOCKER-CLONE
    local src="$1" url first
    if [ -d "$CORE_CLONE/.git" ]; then ok "ePHEM/ already there: left as it is"; return 0; fi
    [ -z "$(ls -A "$CORE_CLONE" 2>/dev/null)" ] || die "$CORE_CLONE has files but is not a git clone: move it away, then run this again."
    step "The native ePHEM/ clone, made from ${src#"$EPHEM_ROOT"/}"
    url="$(git -C "$src" remote get-url origin 2>/dev/null || true)"
    [ -n "$url" ] || url="$CORE_REPO_URL"
    mkdir -p "$CORE_CLONE"
    git -c init.defaultBranch="$DEFAULT_BRANCH" -C "$CORE_CLONE" init -q
    core_git remote add origin "$url"
    core_git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
    core_git fetch -q --no-tags "$src" "+refs/remotes/origin/*:refs/remotes/origin/*"
    echo "  Fetching every branch from origin ($url)…"
    if ! core_git fetch -q origin; then
        warn "Could not reach origin: ePHEM/ starts from what the Docker clones knew. Later: $ME, or the menu's f (Fetch)."
    fi
    if core_git rev-parse -q --verify "refs/remotes/origin/$DEFAULT_BRANCH" >/dev/null; then
        core_git checkout -q --track -b "$DEFAULT_BRANCH" "origin/$DEFAULT_BRANCH"
    else
        first="$(core_git for-each-ref --count=1 --format='%(refname:short)' refs/remotes/origin | sed 's#^origin/##')"
        [ -n "$first" ] || die "$src knows no branch of origin: nothing to start ePHEM/ from."
        core_git checkout -q --track -b "$first" "origin/$first"
    fi
    ok "ePHEM/ ready, on $(g_branch "$CORE_CLONE"); origin: $url"
}

# Tracked changes and the list of untracked files, as one checksum: the same
# in the Docker clone and the new worktree when every file came over.
state_sum() {
    { git -C "$1" diff HEAD --binary; git -C "$1" ls-files --others --exclude-standard; } 2>/dev/null | shasum | awk '{print $1}'
}

copy_excludes() {  # copy_excludes DOCKER-CLONE
    local from="$1/.git/info/exclude" to line
    to="$(core_git rev-parse --git-common-dir)/info/exclude"
    case "$to" in /*) ;; *) to="$CORE_CLONE/$to" ;; esac
    [ -f "$from" ] || return 0
    mkdir -p "$(dirname "$to")"; touch "$to"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ""|"#"*) continue ;; esac
        grep -qxF -- "$line" "$to" || echo "$line" >> "$to"
    done < "$from"
}

import_core() {  # import_core N DOCKER-CLONE
    local n="$1" src="$2" dest cur sha b up nb s
    dest="$(inst_core "$n")"
    if [ -e "$dest/.git" ]; then
        ok "odca$n/$CORE_NAME already there: left as it is (the Docker one stays in ${src#"$EPHEM_ROOT"/})"
        return 0
    fi
    [ -z "$(ls -A "$dest" 2>/dev/null)" ] || die "$dest has files but is not a worktree: move it away, then run this again."

    # What that clone knew of origin (refs already here that are newer stay),
    # then every local branch, as odcaN/<branch>.
    core_git fetch -q --no-tags "$src" "refs/remotes/origin/*:refs/remotes/origin/*" 2>/dev/null || true
    core_git fetch -q --no-tags "$src" "refs/heads/*:refs/heads/odca$n/*" \
        || die "Could not bring the branches of $src into $CORE_CLONE (git said why, above). $src is unchanged."
    while IFS= read -r b; do
        [ -n "$b" ] || continue
        up="$(git -C "$src" for-each-ref --format='%(upstream:short)' "refs/heads/$b")"
        if [ -n "$up" ] && core_git rev-parse -q --verify "refs/remotes/$up" >/dev/null; then
            core_git branch -q --set-upstream-to="$up" "odca$n/$b" >/dev/null
        fi
    done < <(git -C "$src" for-each-ref --format='%(refname:short)' refs/heads)

    mkdir -p "$(inst_dir "$n")"
    core_git worktree prune
    cur="$(git -C "$src" symbolic-ref -q --short HEAD || true)"
    if [ -n "$cur" ]; then
        core_git worktree add -q "$dest" "odca$n/$cur"
    else
        sha="$(git -C "$src" rev-parse HEAD)"
        core_git fetch -q --no-tags "$src" "HEAD:refs/heads/odca$n/detached-${sha:0:8}"
        core_git worktree add -q --detach "$dest" "$sha"
    fi
    # The working files as they are in Docker: edited, new, deleted, ignored.
    rsync -a --delete --exclude=/.git "$src/" "$dest/"
    # What was staged there is staged here.
    if ! git -C "$src" diff --cached --quiet 2>/dev/null; then
        git -C "$src" diff --cached --binary | git -C "$dest" apply --cached \
            || warn "odca$n/$CORE_NAME: the staged changes arrived unstaged (git add them again)."
    fi
    # The clone's own ignore list (.git/info/exclude): the worktrees share
    # the one of ePHEM/, which gets its lines.
    copy_excludes "$src"

    nb="$(g_nbranch "$src")"
    if [ "$(git -C "$dest" rev-parse HEAD)" = "$(git -C "$src" rev-parse HEAD)" ] && [ "$(state_sum "$dest")" = "$(state_sum "$src")" ]; then
        if [ -n "$cur" ]; then
            ok "odca$n/$CORE_NAME: worktree on $(g_branch "$dest"), $(g_changes "$dest") changed file(s), $nb local branch(es) brought over"
        else
            ok "odca$n/$CORE_NAME: worktree detached at ${sha:0:8} (kept as branch odca$n/detached-${sha:0:8}), $(g_changes "$dest") changed file(s)"
        fi
    else
        warn "odca$n/$CORE_NAME differs from ${src#"$EPHEM_ROOT"/}: compare the two (git status in each) before deleting the Docker copy."
    fi
    s="$(g_stashes "$src")"
    [ "$s" = 0 ] || warn "$s stash(es) stay in the Docker copy: git -C $src stash list"
    return 0
}

import_repo() {  # import_repo N DOCKER-DIR NAME
    local n="$1" dest="$(inst_dir "$1")/$3"
    if [ -e "$dest" ]; then ok "odca$n/$3 already there: left as it is"; return 0; fi
    if [ "$3" = "$CORE_NAME" ]; then warn "odca$n/$3: that name is the ePHEM worktree's here. Not copied."; return 0; fi
    mkdir -p "$(inst_dir "$n")"
    rsync -a "$2/$3/" "$dest/"
    ok "odca$n/$3 copied ($(g_branch "$dest"))"
}

choose_home() {
    local a saved
    saved="$(grep '^EPHEM_NATIVE_HOME=' "$PENDING" 2>/dev/null | cut -d'=' -f2- || true)"
    if [ -n "$OPT_HOME" ]; then a="$OPT_HOME"
    elif [ -n "$saved" ]; then a="$saved"
    elif [ -n "${EPHEM_NATIVE_HOME:-}" ] || [ "$ASSUME_YES" = 1 ]; then a="$NATIVE_HOME"
    else
        echo ""
        echo "  Where should Odoo, the virtualenv, the ePHEM clone and the instances live?"
        read -r -p "  Folder [$NATIVE_HOME]: " a || a=""
        a="${a:-$NATIVE_HOME}"
    fi
    case "$a" in "~"*) a="$HOME${a#\~}" ;; esac
    case "$a" in /*) ;; *) die "The folder needs a full path (got: $a)" ;; esac
    case "${a%/}/" in "$EPHEM_ROOT"/*) die "The native home must not be inside the deployment repo ($EPHEM_ROOT)." ;; esac
    native_paths "$a"
    export EPHEM_NATIVE_HOME="$NATIVE_HOME"
    DUMPS="$BACKUP_DIR/from-docker"
}

do_move() {
    local i n first="" targets="" need_db="" r d
    choose_home
    trap 'if [ $? -ne 0 ] && [ -f "$PENDING" ]; then echo ""; err "The move stopped before the end. What is done is kept: bash manage.sh carries on from there."; fi' EXIT
    printf 'EPHEM_NATIVE_HOME=%s\nSTARTED=%s\n' "$NATIVE_HOME" "$(date '+%Y-%m-%d %H:%M')" > "$PENDING"

    copy_databases

    for ((i = 0; i < ${#S_DIR[@]}; i++)); do
        if [ -n "${S_CORE[$i]}" ]; then first="${S_CORE[$i]}"; break; fi
    done
    [ -z "$first" ] || seed_core_clone "$first"

    step "The native tools (scripts/macos/install.sh)"
    if [ "$ASSUME_YES" = 1 ]; then
        EPHEM_FROM_DOCKER=1 bash "$MAC_DIR/install.sh" --home "$NATIVE_HOME" --no-instances --yes
    else
        EPHEM_FROM_DOCKER=1 bash "$MAC_DIR/install.sh" --home "$NATIVE_HOME" --no-instances
    fi
    native_env || die "Homebrew is not found after install.sh ran."

    for ((i = 0; i < ${#S_DIR[@]}; i++)); do
        n="${S_N[$i]}"
        step "${S_LABEL[$i]} → odca$n/"
        [ -z "${S_CORE[$i]}" ] || import_core "$n" "${S_CORE[$i]}"
        for r in ${S_REPOS[$i]}; do import_repo "$n" "${S_DIR[$i]}" "$r"; done
        CREATE_HINT=0 bash "$DEV" create "$n"
        targets="$targets $n"
    done
    targets="${targets# }"

    restore_databases
    for n in $targets; do
        native_db_exists "$(inst_db "$n")" || need_db="$need_db $n"
    done
    if [ -n "$need_db" ]; then
        echo ""
        echo "  Databases not created yet:$(for n in $need_db; do printf ' %s' "$(inst_db "$n")"; done)"
        echo "  An empty Odoo database each (module base only, a few seconds per database); then"
        echo "  install the ePHEM modules (i in the menu), or restore a backup over it (d)."
        if confirm "  Create them now?" Y; then
            for n in $need_db; do bash "$DEV" initdb "$n" || warn "initdb $n failed: later, $V2_ME, Databases (d)"; done
        fi
    fi
    if [ -n "$targets" ] && confirm "  Start the instances now?" Y; then
        # shellcheck disable=SC2086  # one instance number per word
        bash "$DEV" start $targets || true
    fi

    rm -f "$PENDING"
    echo ""
    echo "─────────────────────────────────────────"
    ok "This Mac now runs ePHEM natively. bash manage.sh opens the native menu."
    echo ""
    echo "  The Docker folders are untouched; delete them once you have checked the native ones:"
    for ((i = 0; i < ${#S_DIR[@]}; i++)); do echo "    ${S_DIR[$i]}"; done
    if [ -n "$KEPT" ]; then
        echo "  Databases kept as backups (bash scripts/macos/dev.sh restore N FOLDER):"
        for d in $KEPT; do echo "    $d"; done
    fi
    [ -z "$NOT_COPIED" ] || warn "Left in Docker:$NOT_COPIED"
    offer_remove_docker
    echo ""
    echo "  More: docs/macos-native-dev.md"
}

# ── Start ─────────────────────────────────────
[ "$(id -u)" -ne 0 ] || die "Don't run this under sudo."

if [ "$OFFER" = 1 ]; then
    # Nothing to ask when this is not a terminal, nor once declined for good.
    [ -t 0 ] && [ -t 1 ] || exit "$STAY"
    [ -f "$DENV" ] || exit "$STAY"
    [ "$(denv_get MACOS_NATIVE_OFFER)" != never ] || [ -f "$PENDING" ] || exit "$STAY"
fi
[ -f "$DENV" ] || die "No .env here: this checkout has no Docker setup to move from. A fresh native setup: bash setup.sh (Developer → Native)"

load_sources
if [ "${#S_DIR[@]}" -eq 0 ]; then
    [ "$OFFER" = 1 ] && exit "$STAY"
    die "Nothing to move: this checkout is in $DMODE mode, with no developer instance holding a repository."
fi
if [ -f "$PENDING" ]; then
    saved="$(grep '^EPHEM_NATIVE_HOME=' "$PENDING" | cut -d'=' -f2- || true)"
    [ -z "$saved" ] || [ -n "$OPT_HOME" ] || native_paths "$saved"
elif [ "$OFFER" = 1 ] && [ -f "$NATIVE_MARKER" ]; then
    exit "$STAY"   # native already, and no move halfway: nothing to offer
fi
map_instances
load_dbs

if [ "$PLAN" = 1 ]; then
    v2_title "Move to native macOS: the plan" "Docker developer stack ($DMODE) → $NATIVE_HOME"
    plan_table
    db_table
    plan_notes
    echo ""
    echo "  Nothing was changed (--plan). To move: $ME"
    exit 0
fi

if [ -f "$PENDING" ]; then
    v2_title "ePHEM: the move to native macOS stopped halfway" "Started $(grep '^STARTED=' "$PENDING" | cut -d'=' -f2-), into $NATIVE_HOME"
    plan_table
    db_table
    echo ""
    echo "  Everything already done is kept; it carries on from there."
    echo ""
    v2_opt y "Carry on now"
    v2_opt n "Not now (bash manage.sh asks again; the Docker menu: bash manage.sh --docker)"
    echo ""
    if [ "$ASSUME_YES" = 1 ]; then A=y; else read -r -p "  > " A || A=n; fi
    case "$A" in
        y|Y|yes|"") do_move; exit 0 ;;
        *)
            # Half native: neither menu opens by itself until it is done.
            [ "$OFFER" = 1 ] && exit 1
            exit 0 ;;
    esac
fi

if [ "$OFFER" = 1 ]; then
    v2_title "ePHEM runs natively on macOS now" "This Mac still runs the developer instances in Docker ($DMODE)."
    echo "  Natively there is no VM between Odoo and your files: pages load faster and a"
    echo "  restart takes a couple of seconds. Moving takes your repositories and databases along:"
    echo ""
else
    v2_title "Move to native macOS" "Docker developer stack ($DMODE) → $NATIVE_HOME"
fi
plan_table
db_table
plan_notes
echo ""
v2_opt y "Move to native now"
if [ "$OFFER" = 1 ]; then
    v2_opt n "Not now: the Docker menu (asked again next time)"
    v2_opt never "Don't ask again on this Mac (later: $ME)"
else
    v2_opt n "Not now"
fi
echo ""
if [ "$ASSUME_YES" = 1 ]; then A=y; else read -r -p "  > " A || A=n; fi
case "$A" in
    y|Y|yes|YES) do_move; exit 0 ;;
    never|NEVER)
        denv_set MACOS_NATIVE_OFFER never
        echo "  Not asked again (MACOS_NATIVE_OFFER=never in .env). To move later: $ME"
        exit "$STAY" ;;
    *)  [ "$OFFER" = 1 ] && exit "$STAY"
        echo "  Nothing changed."; exit 0 ;;
esac
