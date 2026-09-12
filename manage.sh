#!/bin/bash
# ──────────────────────────────────────────────
# ePHEM Menu
# Day-to-day management of an installed checkout, in whatever mode setup.sh
# left it (EPHEM_MODE in .env, see scripts/stack-lib.sh):
#
#   server            production menu: tenants, SSL, updates, backups, health
#   demo, dev         developer menu: addons, restart + logs, modules, doctor
#   dev-multi         the developer menu per instance (odca1, odca2, ...)
#
#     bash manage.sh              # dev-multi: the instance used last time
#     bash manage.sh 2            # dev-multi: pin odca2 (remembered in .env)
#
# Everything here wraps the scripts/ tools and docker compose. Each menu item
# prints the commands it runs, so this doubles as a cheat sheet.
# ──────────────────────────────────────────────
set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

if [ ! -f .env ] || [ ! -f docker-compose.yml ]; then
    echo -e "${RED}✗${NC} Run this from the ephem-deploy directory of an installed checkout"
    echo "  (.env not found: run 'bash setup.sh' first)."
    exit 1
fi

# Shared helpers:
#   scripts/stack-lib.sh   mode, compose files, instances, filestore routing
#   scripts/nginx-lib.sh   nginx + Let's Encrypt (active_domains, ssl_is_configured, cert_*)
for _lib in scripts/stack-lib.sh scripts/nginx-lib.sh; do
    if [ ! -f "$_lib" ]; then
        echo -e "${RED}✗${NC} $_lib is missing: run 'git pull' here first."
        exit 1
    fi
done
EPHEM_ROOT="$SCRIPT_DIR"
# shellcheck source=scripts/stack-lib.sh
source scripts/stack-lib.sh
# shellcheck source=scripts/nginx-lib.sh
source scripts/nginx-lib.sh

# Mode and, in dev-multi, the instance to act on. A wrong instance name is a
# hard stop: acting on the wrong odcaN by accident is what this menu exists
# to prevent.
if ! stack_init "${1:-}"; then
    if [ "$EPHEM_MODE" = dev-multi ] && [ ! -f docker-compose.dev-multi.yml ] && [ "${#INSTANCES[@]}" -gt 0 ]; then
        echo -e "${YELLOW}!${NC} $STACK_ERROR"
        read -r -p "  Regenerate it now (data is kept)? [Y/n]: " R
        [[ "${R:-Y}" =~ ^[Nn]$ ]] && exit 1
        bash scripts/dev-instances.sh up "${INSTANCES[@]}" || exit 1
        stack_init "${1:-}" || { echo -e "${RED}✗${NC} $STACK_ERROR"; exit 1; }
    else
        echo -e "${RED}✗${NC} $STACK_ERROR"
        exit 1
    fi
fi

# Installs that predate EPHEM_MODE: the mode was read off the files on disk.
# Record it, so every tool agrees from now on.
if [ "$EPHEM_MODE_SOURCE" = detected ]; then
    echo -e "${YELLOW}!${NC} EPHEM_MODE is not set in .env. From the files here this is: ${BOLD}$(ephem_mode_label)${NC}"
    read -r -p "  Record EPHEM_MODE=$EPHEM_MODE in .env? [Y/n]: " R
    if [[ ! "${R:-Y}" =~ ^[Nn]$ ]]; then
        ephem_mode_save "$EPHEM_MODE"
        echo -e "  ${GREEN}✓${NC} EPHEM_MODE=$EPHEM_MODE saved. Wrong? Edit .env, or re-run bash setup.sh."
    fi
fi
# dev-multi: remember the instance for next time.
if [ "$EPHEM_MODE" = dev-multi ] && [ "$(env_get EPHEM_INSTANCE)" != "$EPHEM_INSTANCE" ]; then
    stack_pin_instance "$EPHEM_INSTANCE"
fi

local_mode() { [ "$EPHEM_MODE" != server ]; }
# Where a few shared screens should send people, which differs by menu.
services_hint() { if local_mode; then echo "Stack menu, 6"; else echo "Advanced → 1"; fi; }
backup_item()   { if local_mode; then echo 10; else echo 7; fi; }

# Every menu takes b (back) and x (exit) besides its numbers; Enter alone is
# back as well. Sets CHOICE. x leaves the program from any depth.
ask_choice() {  # ask_choice "1-4" ["b, x"]
    local keys="${2:-b, x}"
    # EOF (stdin closed, a piped run) would otherwise spin the menu forever.
    read -r -p "  Choose [$1, $keys]: " CHOICE || { echo ""; echo "Bye. Re-open anytime:  bash manage.sh"; exit 0; }
    echo ""
    case "${CHOICE:-}" in
        x|X)    echo "Bye. Re-open anytime:  bash manage.sh"; exit 0 ;;
        b|B|"") CHOICE=b ;;
    esac
}
invalid_choice() { echo -e "  ${YELLOW}!${NC} Invalid choice."; }

# Wait until Odoo actually accepts connections on 8069 inside the container:
# the container is "running" seconds before the workers are ready.
wait_for_odoo() {  # wait_for_odoo [SECONDS]
    local secs="${1:-90}" i=0
    printf "  Waiting for Odoo (%s) to accept requests" "$ODOO_SVC"
    while [ "$i" -lt "$secs" ]; do
        if compose exec -T "$ODOO_SVC" python3 -c \
             "import socket,sys; s=socket.socket(); s.settimeout(2); sys.exit(s.connect_ex(('127.0.0.1',8069)))" \
             </dev/null >/dev/null 2>&1; then
            echo ""; echo -e "  ${GREEN}✓${NC} Odoo is answering (took ${i}s)"; return 0
        fi
        printf "."; sleep 2; i=$((i + 2))
    done
    echo ""
    echo -e "  ${YELLOW}!${NC} Still not answering after ${secs}s: check its log."
    return 1
}

BACKUP_DIR="$SCRIPT_DIR/backups"

# Database names typed by the operator end up inside `rm -rf` paths and SQL
# identifiers. Accept only what Odoo itself accepts, so a name can never
# escape the filestore directory or close a quoted identifier.
valid_db_name() { printf '%s' "$1" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$'; }

db_exists() {  # call valid_db_name first
    [ "$(compose exec -T db psql -U "$DB_USER" -d postgres -t -A -c \
        "SELECT 1 FROM pg_database WHERE datname = '$1';" \
        </dev/null 2>/dev/null | tr -d '\r')" = "1" ]
}

list_dbs_sized() {
    compose exec -T db psql -U "$DB_USER" -d postgres -t -A -c \
        "SELECT datname || '  (' || pg_size_pretty(pg_database_size(datname)) || ')'
           FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres')
          ORDER BY datname;" </dev/null 2>/dev/null | tr -d '\r'
}

# "dbname  (12M)", to read like the PostgreSQL listing above it. du prints
# the size first, so strip the path prefix only (a greedy .*/ eats the size).
# dev-multi: every instance's volume, tagged with the instance.
list_filestores() {
    local n
    if [ "$EPHEM_MODE" = dev-multi ]; then
        for n in "${INSTANCES[@]}"; do
            odoo_sh_on "odoo_$n" "du -sh $FILESTORE/* 2>/dev/null" 2>/dev/null | tr -d '\r' \
                | sed "s|^\([^[:space:]]*\)[[:space:]]*$FILESTORE/\(.*\)$|\2  (\1)  [odca$n]|"
        done
    else
        odoo_sh "du -sh $FILESTORE/* 2>/dev/null" 2>/dev/null | tr -d '\r' \
            | sed "s|^\([^[:space:]]*\)[[:space:]]*$FILESTORE/\(.*\)$|\2  (\1)|"
    fi
}

# ── Snapshots ─────────────────────────────────
# One snapshot = one folder under backups/, named <database>_<timestamp>,
# holding the database dump, the filestore archive and a manifest:
#
#     backups/ephem_2_20260822_004512/
#       ├── database.sql.gz
#       ├── filestore.tar.gz
#       └── manifest          (database=, created=, db_dump=, filestore=)
#
# Restore reads the database name from the manifest, never by splitting the
# folder name — "ephem_2_20260822_004512" cannot be cut back into name and
# timestamp reliably, because database names contain underscores too.
#
# scripts/backup.sh (menu item 7) is untouched and still writes its own
# whole-server snapshots as flat files here; its retention sweep only
# deletes files at the top level, so these folders are left alone.

manifest_get() { grep -m1 "^$2=" "$1/manifest" 2>/dev/null | cut -d'=' -f2-; }

# Snapshot one database + its filestore. Sets SNAPSHOT_DIR on success; on any
# failure the half-written folder is removed, because a partial snapshot in
# the restore list is worse than no snapshot at all.
snapshot_create() {  # snapshot_create DBNAME
    local DB="$1" TS DIR rc HAS_DB=no HAS_FS=no
    # dev-multi: the filestore lives on the instance's own volume, whichever
    # instance the menu is pinned to (fs_svc_for).
    local ODOO_SH_SVC; ODOO_SH_SVC=$(fs_svc_for "$DB")
    SNAPSHOT_DIR=""
    TS=$(date +%Y%m%d_%H%M%S)
    DIR="$BACKUP_DIR/${DB}_${TS}"

    if [ "$(svc_state db)" != "running" ]; then
        echo -e "  ${RED}✗${NC} The database container is not running — start it first ($(services_hint))."
        return 1
    fi
    if ! mkdir -p "$DIR"; then
        echo -e "  ${RED}✗${NC} Could not create $DIR"
        return 1
    fi
    echo -e "  ${CYAN}→${NC} Snapshot: backups/${DIR##*/}/"

    if db_exists "$DB"; then
        if ! compose exec -T db pg_dump -U "$DB_USER" "$DB" </dev/null | gzip > "$DIR/database.sql.gz" \
           || ! gzip -t "$DIR/database.sql.gz" 2>/dev/null; then
            echo -e "  ${RED}✗${NC} pg_dump failed or produced a corrupt file — snapshot discarded."
            rm -rf "$DIR"
            return 1
        fi
        HAS_DB=yes
        echo -e "     ${GREEN}✓${NC} database.sql.gz    ($(du -h "$DIR/database.sql.gz" | cut -f1))"
    else
        echo -e "     ${YELLOW}!${NC} no database named '$DB' — filestore only"
    fi

    if odoo_sh "test -d $FILESTORE/$DB" >/dev/null 2>&1; then
        rc=0
        # tar exit 1 = "file changed while reading", routine on a live system.
        odoo_sh "tar -czf - -C $FILESTORE $DB" > "$DIR/filestore.tar.gz" 2>/dev/null || rc=$?
        if [ "$rc" -gt 1 ] || ! gzip -t "$DIR/filestore.tar.gz" 2>/dev/null; then
            echo -e "  ${RED}✗${NC} Filestore archive failed (tar exit $rc) — snapshot discarded."
            rm -rf "$DIR"
            return 1
        fi
        [ "$rc" -eq 1 ] && echo -e "     ${YELLOW}!${NC} files changed while archiving (normal on a live system)"
        HAS_FS=yes
        echo -e "     ${GREEN}✓${NC} filestore.tar.gz   ($(du -h "$DIR/filestore.tar.gz" | cut -f1))"
        [ "$EPHEM_MODE" = dev-multi ] && echo "       (read from the volume of instance $(svc_instance "$ODOO_SH_SVC"))"
    else
        echo -e "     ${YELLOW}!${NC} no filestore directory for '$DB' — database only"
    fi

    if [ "$HAS_DB" = no ] && [ "$HAS_FS" = no ]; then
        echo -e "  ${RED}✗${NC} Nothing to snapshot for '$DB' — no database, no filestore."
        rm -rf "$DIR"
        return 1
    fi

    { echo "database=$DB"
      echo "created=$(date '+%Y-%m-%d %H:%M:%S')"
      echo "db_dump=$HAS_DB"
      echo "filestore=$HAS_FS"
      echo "host=$(hostname)"
    } > "$DIR/manifest"

    SNAPSHOT_DIR="$DIR"
    echo -e "  ${GREEN}✓${NC} Saved: backups/${DIR##*/}  ($(du -sh "$DIR" | cut -f1))"
    snapshot_prune "$DB"
}

# Every snapshot folder, newest first. A folder with neither artifact is
# skipped: it cannot restore anything.
snapshot_list_all() {
    ls -1dt "$BACKUP_DIR"/*/ 2>/dev/null | while IFS= read -r d; do
        d="${d%/}"
        { [ -f "$d/database.sql.gz" ] || [ -f "$d/filestore.tar.gz" ]; } && printf '%s\n' "$d"
    done
}

# Capped at 100 for the menu — a server with a year of snapshots should not
# scroll a thousand lines past the operator before the prompt appears.
snapshot_list() { snapshot_list_all | head -100; }

# Keep the newest SNAPSHOT_KEEP snapshots OF ONE DATABASE and remove the rest.
# Per database, not per server: a global cap would make "back up every
# database" evict the other tenants' snapshots on every run.
#
# Only folders whose manifest names this database are ever removed — anything
# hand-made, or copied in from another server, has no manifest and is left
# alone. Deleting backups automatically is worth being fussy about.
snapshot_prune() {  # snapshot_prune DBNAME
    local DB="$1" keep i dropped=0
    local -a MINE=()
    keep=$(env_get SNAPSHOT_KEEP); keep="${keep:-10}"
    # Anything non-numeric or 0 turns pruning off.
    printf '%s' "$keep" | grep -Eq '^[0-9]+$' || return 0
    [ "$keep" -lt 1 ] && return 0

    local d
    while IFS= read -r d; do
        [ "$(manifest_get "$d" database)" = "$DB" ] && MINE+=("$d")
    done < <(snapshot_list_all)

    [ "${#MINE[@]}" -le "$keep" ] && return 0
    for ((i = keep; i < ${#MINE[@]}; i++)); do
        [ -f "${MINE[$i]}/manifest" ] || continue
        rm -rf "${MINE[$i]}" && dropped=$((dropped + 1))
    done
    # Never prune silently: a backup disappearing without a word is how people
    # discover their retention policy at the worst possible moment.
    [ "$dropped" -gt 0 ] && \
        echo -e "     ${CYAN}·${NC} pruned $dropped older snapshot(s) of '$DB' (keeping the newest $keep)"
    return 0
}

# Point the restore at something that is not one of our own snapshot folders:
# a folder copied off another server, or the flat files scripts/backup.sh
# writes. Sets RS_SQL / RS_TAR (either may be empty) and RS_DB as a suggested
# target name. Returns 1 when the path yields nothing usable.
resolve_external_path() {  # resolve_external_path PATH
    local P="$1" n
    RS_SQL=""; RS_TAR=""; RS_DB=""
    P="${P/#\~/$HOME}"
    P="${P%/}"

    if [ -d "$P" ]; then
        [ -f "$P/database.sql.gz" ] && RS_SQL="$P/database.sql.gz"
        [ -f "$P/filestore.tar.gz" ] && RS_TAR="$P/filestore.tar.gz"
        # Not our layout — take the only dump / only archive in the folder.
        # More than one and we cannot guess: ask for the file itself.
        if [ -z "$RS_SQL" ]; then
            n=$(ls -1 "$P"/*.sql.gz "$P"/*.sql 2>/dev/null | wc -l)
            if [ "$n" -eq 1 ]; then RS_SQL=$(ls -1 "$P"/*.sql.gz "$P"/*.sql 2>/dev/null)
            elif [ "$n" -gt 1 ]; then
                echo -e "  ${YELLOW}!${NC} Several dumps in that folder — point at one file instead:"
                ls -1 "$P"/*.sql.gz "$P"/*.sql 2>/dev/null | sed 's|^|    • |'
                return 1
            fi
        fi
        if [ -z "$RS_TAR" ]; then
            n=$(ls -1 "$P"/*.tar.gz "$P"/*.tgz "$P"/*.tar 2>/dev/null | wc -l)
            if [ "$n" -eq 1 ]; then RS_TAR=$(ls -1 "$P"/*.tar.gz "$P"/*.tgz "$P"/*.tar 2>/dev/null)
            elif [ "$n" -gt 1 ]; then
                echo -e "  ${YELLOW}!${NC} Several archives in that folder — none picked automatically:"
                ls -1 "$P"/*.tar.gz "$P"/*.tgz "$P"/*.tar 2>/dev/null | sed 's|^|    • |'
                read -r -p "  Filestore archive to use (empty for none): " RS_TAR
                RS_TAR="${RS_TAR/#\~/$HOME}"
                [ -n "$RS_TAR" ] && [ ! -f "$RS_TAR" ] && {
                    echo -e "  ${RED}✗${NC} No such file: $RS_TAR"; return 1; }
            fi
        fi
        RS_DB=$(manifest_get "$P" database)
    elif [ -f "$P" ]; then
        case "$P" in
            *.sql.gz|*.sql) RS_SQL="$P" ;;
            *.tar.gz|*.tgz|*.tar) RS_TAR="$P" ;;
            *) echo -e "  ${RED}✗${NC} Not a dump or archive: $P"; return 1 ;;
        esac
        # Offer to pair it with the other half.
        if [ -n "$RS_SQL" ]; then
            read -r -p "  Filestore archive to restore with it (empty for none): " RS_TAR
            RS_TAR="${RS_TAR/#\~/$HOME}"
            [ -n "$RS_TAR" ] && [ ! -f "$RS_TAR" ] && {
                echo -e "  ${RED}✗${NC} No such file: $RS_TAR"; return 1; }
        fi
    else
        echo -e "  ${RED}✗${NC} No such file or folder: $P"
        return 1
    fi

    if [ -z "$RS_SQL" ] && [ -z "$RS_TAR" ]; then
        echo -e "  ${RED}✗${NC} Nothing restorable found at: $P"
        return 1
    fi
    # Suggest a name: manifest, else the dump filename with a trailing
    # _YYYYMMDD_HHMMSS stripped off (that is how backup.sh names them).
    if [ -z "$RS_DB" ] && [ -n "$RS_SQL" ]; then
        RS_DB=$(basename "$RS_SQL"); RS_DB="${RS_DB%.gz}"; RS_DB="${RS_DB%.sql}"
        RS_DB=$(printf '%s' "$RS_DB" | sed -E 's/_[0-9]{8}_[0-9]{6}$//')
    fi
    [ "$RS_DB" = "database" ] && RS_DB=""
    return 0
}

# Everything this server can restore, one line per restorable database:
#
#     epoch|kind|database|created|size|sqlfile|tarfile
#
# kind: snap = our own snapshot folder
#       auto = the flat files scripts/backup.sh writes (menu item 7 / cron)
#       age  = an encrypted run; its contents stay unknown until decrypted
#
# The two kinds are listed together on purpose: "what can I restore" is one
# question, and an operator should not have to know which tool wrote a backup
# before they can find it.
# YYYYMMDD_HHMMSS -> epoch. Sorting on file mtime instead would put a backup
# COPIED onto this server today above one taken here last week, which is the
# opposite of what the printed date says.
ts_epoch() { date -d "${1:0:4}-${1:4:2}-${1:6:2} ${1:9:2}:${1:11:2}:${1:13:2}" +%s 2>/dev/null; }

restore_sources() {
    local d f base ts db epoch created size tar
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        db=$(manifest_get "$d" database); [ -z "$db" ] && db="${d##*/}"
        created=$(manifest_get "$d" created)
        epoch=$(date -d "$created" +%s 2>/dev/null || true)
        [ -z "$epoch" ] && epoch=$(stat -c %Y "$d" 2>/dev/null || echo 0)
        [ -z "$created" ] && created=$(date -d "@$epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
        created="${created:0:16}"   # minutes: seconds would break the column
        size=$(du -sh "$d" 2>/dev/null | cut -f1)
        printf '%s|snap|%s|%s|%s|%s|%s\n' "$epoch" "$db" "$created" "$size" \
            "$([ -f "$d/database.sql.gz" ] && echo "$d/database.sql.gz")" \
            "$([ -f "$d/filestore.tar.gz" ] && echo "$d/filestore.tar.gz")"
    done < <(snapshot_list_all)

    # backup.sh names its dumps <database>_<YYYYMMDD>_<HHMMSS>.sql.gz and
    # writes ONE filestore_<same timestamp>.tar.gz for the whole run, holding
    # every database's attachments. Hand-made dumps without that exact suffix
    # are skipped here — paste their path instead.
    for f in "$BACKUP_DIR"/*_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9].sql.gz; do
        [ -f "$f" ] || continue
        base="${f##*/}"; base="${base%.sql.gz}"
        ts="${base: -15}"
        db="${base%_$ts}"
        [ -n "$db" ] || continue
        epoch=$(ts_epoch "$ts"); [ -z "$epoch" ] && epoch=$(stat -c %Y "$f" 2>/dev/null || echo 0)
        created="${ts:0:4}-${ts:4:2}-${ts:6:2} ${ts:9:2}:${ts:11:2}"
        size=$(du -h "$f" 2>/dev/null | cut -f1)
        tar="$BACKUP_DIR/filestore_${ts}.tar.gz"; [ -f "$tar" ] || tar=""
        printf '%s|auto|%s|%s|%s|%s|%s\n' "$epoch" "$db" "$created" "$size" "$f" "$tar"
    done

    for f in "$BACKUP_DIR"/*.tar.age; do
        [ -f "$f" ] || continue
        base="${f##*/}"; ts="${base%.tar.age}"
        epoch=$(ts_epoch "$ts"); [ -z "$epoch" ] && epoch=$(stat -c %Y "$f" 2>/dev/null || echo 0)
        created="${ts:0:4}-${ts:4:2}-${ts:6:2} ${ts:9:2}:${ts:11:2}"
        size=$(du -h "$f" 2>/dev/null | cut -f1)
        printf '%s|age|(encrypted)|%s|%s|%s|\n' "$epoch" "$created" "$size" "$f"
    done
}

# Decrypt one .tar.age run and let the operator pick a database out of it.
# Sets AGE_STAGE (the caller removes it — the unpacked files are plaintext
# health data), RS_SQL, RS_TAR, RS_DB.
age_unpack() {  # age_unpack AGEFILE
    local F="$1" KEY n i pick
    local -a DUMPS=()
    RS_SQL=""; RS_TAR=""; RS_DB=""; AGE_STAGE=""

    if ! command -v age >/dev/null 2>&1; then
        echo -e "  ${RED}✗${NC} 'age' is not installed on this server — sudo apt install -y age"
        return 1
    fi
    echo "  This run is encrypted. Decrypting needs the PRIVATE key that was"
    echo "  generated with age-keygen and kept off this server."
    read -r -p "  Path to the key file (empty to cancel): " KEY
    [ -z "${KEY:-}" ] && { echo "  Cancelled."; return 1; }
    KEY="${KEY/#\~/$HOME}"
    if [ ! -f "$KEY" ]; then
        echo -e "  ${RED}✗${NC} No such key file: $KEY"
        return 1
    fi

    AGE_STAGE="$BACKUP_DIR/.age_unpack_$$"
    mkdir -p "$AGE_STAGE" || return 1
    chmod 700 "$AGE_STAGE"
    echo -e "  ${CYAN}→${NC} Decrypting $(basename "$F")"
    if ! age -d -i "$KEY" "$F" | tar -x -C "$AGE_STAGE" 2>/dev/null; then
        echo -e "  ${RED}✗${NC} Decryption failed — wrong key, or the file is damaged."
        return 1
    fi
    chmod -R go-rwx "$AGE_STAGE" 2>/dev/null

    while IFS= read -r n; do [ -n "$n" ] && DUMPS+=("$n"); done \
        < <(ls -1 "$AGE_STAGE"/*.sql.gz 2>/dev/null)
    if [ "${#DUMPS[@]}" -eq 0 ]; then
        echo -e "  ${RED}✗${NC} No database dumps inside that run."
        return 1
    fi
    echo -e "  ${GREEN}✓${NC} Decrypted. Databases in this run:"
    for i in "${!DUMPS[@]}"; do
        n=$(basename "${DUMPS[$i]}"); n="${n%.sql.gz}"; n="${n%_*_*}"
        printf "    %2d) %-28s (%s)\n" "$((i + 1))" "$n" "$(du -h "${DUMPS[$i]}" | cut -f1)"
    done
    [ -f "$AGE_STAGE"/config_*.tar.gz ] 2>/dev/null && \
        echo "     (the run also carries config_*.tar.gz — .env, odoo.conf, nginx;"
    [ -f "$AGE_STAGE"/config_*.tar.gz ] 2>/dev/null && \
        echo "      not restored here, copy it out by hand if you need it)"
    echo ""
    read -r -p "  Which database? [1-${#DUMPS[@]}] (empty to cancel): " pick
    if ! printf '%s' "${pick:-}" | grep -Eq '^[0-9]+$' \
       || [ "$pick" -lt 1 ] || [ "$pick" -gt "${#DUMPS[@]}" ]; then
        echo "  Cancelled."
        return 1
    fi
    RS_SQL="${DUMPS[$((pick - 1))]}"
    RS_DB=$(basename "$RS_SQL"); RS_DB="${RS_DB%.sql.gz}"; RS_DB="${RS_DB%_*_*}"
    RS_TAR=$(ls -1 "$AGE_STAGE"/filestore_*.tar.gz 2>/dev/null | head -1)
    return 0
}

# Restore into TARGET_DB. SQL_FILE and TAR_FILE may each be empty. The caller
# has already confirmed, and taken the operator through the three warnings if
# this overwrites anything.
snapshot_restore() {  # snapshot_restore SQL_FILE TAR_FILE SRC_NAME TARGET_DB
    local SQLF="$1" TARF="$2" SRC="$3" TGT="$4" LOG errs mods rc CAT dirs pick

    if [ "$(svc_state db)" != "running" ]; then
        echo -e "  ${RED}✗${NC} The database container is not running — start it first ($(services_hint))."
        return 1
    fi

    # ── database ──────────────────────────────────────────────────────
    if [ -n "$SQLF" ]; then
        if db_exists "$TGT"; then
            drop_database "$TGT" || return 1
        fi
        echo -e "  ${CYAN}→${NC} Creating database '$TGT'"
        # template0: the cluster's template1 may carry local additions that
        # would collide with objects in the dump.
        if ! compose exec -T db psql -U "$DB_USER" -d postgres -c \
             "CREATE DATABASE \"$TGT\" WITH TEMPLATE template0 ENCODING 'UTF8';" </dev/null; then
            echo -e "  ${RED}✗${NC} Could not create '$TGT' — nothing was restored."
            return 1
        fi
        echo -e "  ${CYAN}→${NC} Loading $(basename "$SQLF") into '$TGT' (this can take a while)"
        CAT=cat; [ "${SQLF##*.}" = "gz" ] && CAT="gunzip -c"
        LOG=$(mktemp)
        rc=0
        $CAT "$SQLF" | compose exec -T db psql -U "$DB_USER" -q -d "$TGT" >"$LOG" 2>&1 || rc=$?
        errs=$(grep -c '^ERROR' "$LOG" 2>/dev/null || true)
        # psql exits 0 on a dump that produced errors, so trust the data, not
        # the exit code: an Odoo database with no ir_module_module is broken.
        mods=$(compose exec -T db psql -U "$DB_USER" -d "$TGT" -t -A -c \
               "SELECT count(*) FROM ir_module_module;" </dev/null 2>/dev/null | tr -d '\r')
        if ! printf '%s' "$mods" | grep -Eq '^[1-9][0-9]*$'; then
            echo -e "  ${RED}✗${NC} Restore failed — '$TGT' has no ir_module_module rows (psql exit $rc)."
            echo "     psql output kept at: $LOG"
            return 1
        fi
        if [ "${errs:-0}" -gt 0 ]; then
            echo -e "  ${YELLOW}!${NC} Loaded, but psql reported $errs error line(s): $LOG"
        else
            rm -f "$LOG"
        fi
        echo -e "  ${GREEN}✓${NC} Database '$TGT' restored ($mods modules)"
    else
        echo -e "  ${YELLOW}!${NC} No database dump in this restore — filestore only."
    fi

    # ── filestore ─────────────────────────────────────────────────────
    if [ -n "$TARF" ]; then
        local ODOO_SH_SVC; ODOO_SH_SVC=$(fs_svc_for "$TGT")
        [ "$EPHEM_MODE" = dev-multi ] && echo "  Filestore goes to the volume of instance $(svc_instance "$ODOO_SH_SVC")"
        echo -e "  ${CYAN}→${NC} Unpacking $(basename "$TARF")"
        # Unpack to a staging dir first. The archive is rooted at the SOURCE
        # database's name, so extracting straight into filestore/ would
        # overwrite that database's live attachments when the target name
        # differs — and backup.sh's archive holds EVERY database.
        local STAGE="$FS_PARENT/.restore_staging"
        odoo_sh "rm -rf $STAGE && mkdir -p $STAGE" >/dev/null 2>&1
        # Decompress on this side: tar cannot auto-detect compression on a
        # pipe (it has nothing to rewind), and hard-coding -z would reject a
        # plain .tar. Feeding it an uncompressed stream handles both.
        local TCAT=cat
        case "$TARF" in *.gz|*.tgz) TCAT="gunzip -c" ;; esac
        if ! $TCAT "$TARF" | odoo_pipe "tar -xf - -C $STAGE" >/dev/null 2>&1; then
            echo -e "  ${RED}✗${NC} Could not unpack the archive."
            odoo_sh "rm -rf $STAGE" >/dev/null 2>&1
            return 1
        fi
        # Which directory inside the archive is the filestore? Our snapshots
        # are rooted at the source database's name; scripts/backup.sh archives
        # the whole filestore, so it holds one directory per database.
        # Every candidate must be non-empty and a real directory — an empty
        # name would make "test -d $STAGE/" match the staging dir itself and
        # move the entire archive into place.
        dirs=$(odoo_sh "ls -1 $STAGE 2>/dev/null" | tr -d '\r' | grep . || true)
        pick=""
        if   [ -n "$SRC" ] && odoo_sh "test -d $STAGE/$SRC" >/dev/null 2>&1; then pick="$SRC"
        elif [ -n "$TGT" ] && odoo_sh "test -d $STAGE/$TGT" >/dev/null 2>&1; then pick="$TGT"
        elif [ "$(printf '%s\n' "$dirs" | grep -c .)" = "1" ] && valid_db_name "$dirs" \
             && odoo_sh "test -d $STAGE/$dirs" >/dev/null 2>&1; then pick="$dirs"
        fi
        if [ -z "$pick" ]; then
            echo "  This archive holds more than one filestore:"
            printf '%s\n' "$dirs" | sed 's/^/    • /'
            read -r -p "  Which one belongs to '$TGT'? (empty to skip the filestore): " pick
            if [ -z "$pick" ] || ! valid_db_name "$pick" \
               || ! odoo_sh "test -d $STAGE/$pick" >/dev/null 2>&1; then
                echo -e "  ${YELLOW}!${NC} Filestore skipped — attachments will be missing."
                odoo_sh "rm -rf $STAGE" >/dev/null 2>&1
                return 0
            fi
        fi
        odoo_sh "rm -rf $FILESTORE/$TGT && mkdir -p $FILESTORE && mv $STAGE/$pick $FILESTORE/$TGT && rm -rf $STAGE" \
            >/dev/null 2>&1
        if odoo_sh "test -d $FILESTORE/$TGT" >/dev/null 2>&1; then
            echo -e "  ${GREEN}✓${NC} Filestore restored  ($(filestore_size "$TGT"))"
        else
            echo -e "  ${RED}✗${NC} Filestore move failed — attachments will be missing."
            odoo_sh "rm -rf $STAGE" >/dev/null 2>&1
            return 1
        fi
    else
        echo -e "  ${YELLOW}!${NC} No filestore in this restore — attachments will be missing."
    fi
    return 0
}

db_size() {  # "" when the database does not exist
    compose exec -T db psql -U "$DB_USER" -d postgres -t -A -c \
        "SELECT pg_size_pretty(pg_database_size('$1'));" </dev/null 2>/dev/null | tr -d '\r'
}
filestore_size() {  # "" when there is no filestore for this database
    local ODOO_SH_SVC; ODOO_SH_SVC=$(fs_svc_for "$1")
    odoo_sh "du -sh $FILESTORE/$1 2>/dev/null | cut -f1" 2>/dev/null | tr -d '\r'
}

# Three escalating gates before anything is destroyed: see what goes, prove
# you mean THIS database by typing its name, then commit. Each asks a
# different question on purpose — three identical prompts only train people
# to hit Enter three times, and the middle one is the real check: a name
# typed from memory is not something you fat-finger.
confirm_destructive() {  # confirm_destructive DBNAME db|filestore|both [delete|overwrite]
    local DB="$1" MODE="$2" ACT="${3:-delete}" C DBSZ FSSZ LAST VERB
    [ "$MODE" != "filestore" ] && DBSZ=$(db_size "$DB")
    [ "$MODE" != "db" ] && FSSZ=$(filestore_size "$DB")

    if [ -z "${DBSZ:-}" ] && [ -z "${FSSZ:-}" ]; then
        echo -e "  ${YELLOW}!${NC} Nothing there for '$DB' — no such database, and no filestore."
        return 1
    fi

    # ── 1 of 3: exactly what disappears ──────────────────────────────
    echo ""
    echo -e "  ${RED}${BOLD}⚠  WARNING 1 of 3 — what will be destroyed${NC}"
    [ -n "${DBSZ:-}" ] && echo -e "     • PostgreSQL database ${BOLD}$DB${NC}  ($DBSZ) — every record in it"
    [ -n "${FSSZ:-}" ] && echo -e "     • Filestore ${BOLD}$DB${NC}  ($FSSZ) — every attachment and uploaded document"
    [ "$MODE" != "db" ] && [ -z "${FSSZ:-}" ] && echo "     • (no filestore directory for '$DB')"
    echo ""
    echo "     Anyone using this tenant loses access the moment it goes."
    [ "$ACT" = overwrite ] && echo "     The snapshot you chose replaces it — the current contents are lost."
    read -r -p "  Continue? [y/N]: " C
    [[ "${C:-N}" =~ ^[Yy]$ ]] || { echo "  Cancelled."; return 1; }

    # ── 2 of 3: it is permanent, and how old the safety net is ───────
    echo ""
    echo -e "  ${RED}${BOLD}⚠  WARNING 2 of 3 — this is permanent${NC}"
    echo "     There is no undo and no recycle bin. The only way back is a"
    echo "     snapshot or a backup taken BEFORE this point."
    LAST=$(snapshot_list | head -1)
    if [ -n "$LAST" ]; then
        echo "     Newest snapshot on this server: ${LAST##*/} ($(manifest_get "$LAST" created))"
    else
        echo -e "     ${YELLOW}!${NC} No snapshot exists in backups/ at all."
    fi
    echo ""
    read -r -p "  Type the database name '$DB' to confirm: " C
    [ "$C" = "$DB" ] || { echo "  Cancelled."; return 1; }

    # ── 3 of 3: authority ────────────────────────────────────────────
    echo ""
    echo -e "  ${RED}${BOLD}⚠  WARNING 3 of 3 — last chance${NC}"
    VERB="Deleting"; [ "$ACT" = overwrite ] && VERB="Overwriting"
    case "$MODE" in
        db)        echo "     $VERB the database '$DB' now. Nothing has been changed yet." ;;
        filestore) echo "     $VERB the filestore of '$DB' now. Nothing has been changed yet." ;;
        both)      echo "     $VERB the database AND filestore of '$DB' now. Nothing has been changed yet." ;;
    esac
    echo "     Nothing else is asked after this."
    echo ""
    read -r -p "  Type y to go ahead, anything else to walk away: " C
    [[ "${C:-N}" =~ ^[Yy]$ ]] || { echo "  Cancelled."; return 1; }
}

drop_database() {  # drop_database DBNAME
    echo -e "  ${CYAN}→${NC} Disconnecting sessions, then DROP DATABASE \"$1\""
    compose exec -T db psql -U "$DB_USER" -d postgres -c \
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
          WHERE datname = '$1' AND pid <> pg_backend_pid();" </dev/null >/dev/null 2>&1
    if compose exec -T db psql -U "$DB_USER" -d postgres -c "DROP DATABASE \"$1\";" </dev/null; then
        echo -e "  ${GREEN}✓${NC} Database '$1' dropped."
        return 0
    fi
    echo -e "  ${RED}✗${NC} Drop failed — see the output above."
    return 1
}

delete_filestore() {  # delete_filestore DBNAME
    local ODOO_SH_SVC; ODOO_SH_SVC=$(fs_svc_for "$1")
    if ! odoo_sh "test -d $FILESTORE/$1" >/dev/null 2>&1; then
        echo -e "  ${YELLOW}!${NC} No filestore directory for '$1' — nothing to delete."
        return 0
    fi
    echo -e "  ${CYAN}→${NC} rm -rf filestore/$1"
    if odoo_sh "rm -rf $FILESTORE/$1" >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} Filestore for '$1' deleted."
        return 0
    fi
    echo -e "  ${RED}✗${NC} Could not delete the filestore."
    return 1
}

# ── 1) Status & health ────────────────────────
menu_status() {
    echo -e "${CYAN}${BOLD}Status & health${NC}"
    echo ""
    compose ps
    echo ""
    echo -e "${BOLD}Databases:${NC}"
    local dbs; dbs=$(list_dbs)
    if [ -n "$dbs" ]; then echo "$dbs" | sed 's/^/  • /'; else echo "  (none, or database not running)"; fi
    echo ""
    echo -e "${BOLD}App image:${NC}  borrs/ephem:$(env_get EPHEM_IMAGE_TAG | grep . || echo 'latest  (! unpinned — set EPHEM_IMAGE_TAG in .env on production)')"
    echo -e "${BOLD}Disk:${NC}"
    df -h / | tail -1 | awk '{printf "  root: %s used of %s (%s)\n", $3, $2, $5}'
    echo ""
    echo -e "${BOLD}SSL certificate:${NC}"
    if ssl_is_configured; then
        certs_refresh
        local lin
        for lin in $(cert_lineages); do
            printf '  %-34s expires %s\n' "$lin" "$(cert_expiry_of "$lin")"
        done
        [ -z "$(cert_lineages)" ] && \
            echo -e "  ${YELLOW}!${NC} nginx serves HTTPS but no certificate could be read"
    else
        echo "  none (HTTP-only server)"
    fi
    echo ""
    echo -e "${BOLD}Last backup:${NC}"
    # shellcheck disable=SC2012
    ls -t backups/*.age backups/*.gz 2>/dev/null | head -1 | xargs -r ls -lh | awk '{print "  " $NF " (" $5 ", " $6 " " $7 " " $8 ")"}'
    [ -z "$(ls backups/*.age backups/*.gz 2>/dev/null)" ] && echo -e "  ${YELLOW}!${NC} no whole-server backup found — use menu item 7, and add the cron job (README → Backups)"
    local snap; snap=$(snapshot_list | head -1)
    if [ -n "$snap" ]; then
        echo "  newest snapshot: ${snap##*/} ($(manifest_get "$snap" created))"
    else
        echo "  no per-database snapshots yet (Advanced → Databases → Backup)"
    fi
}

# ── 2) Manage domains ─────────────────────────
# Domains are routing only: nginx server block + certificate. Databases live
# in the Databases menu — adding a domain never creates or touches one.
menu_domains() {
    while true; do
        echo -e "${CYAN}${BOLD}Manage domains${NC}"
        echo ""
        if ssl_is_configured; then
            echo -e "  ${BOLD}Served over HTTPS:${NC}"
            active_domains | sed 's/^/    • /' | grep . || echo "    (none)"
        else
            echo -e "  ${YELLOW}!${NC} HTTP only — this server answers on any hostname. Set up HTTPS"
            echo "     first (main menu → 3), then come back."
        fi
        echo ""
        echo "  A domain here is just the way in: nginx + its own certificate."
        echo "  The data behind it is a database of the same first label"
        echo "  (training.pheoc.com → 'training'), managed under Advanced."
        echo ""
        echo "  1) Add domain(s)       — one certificate each, no database created"
        echo "  2) Remove domain(s)    — drops nginx block + certificate, keeps the data"
        echo "  3) Split the shared certificate into one per domain"
        echo "  b) Back"
        echo "  x) Exit"
        ask_choice "1-3"
        case "$CHOICE" in
            1) menu_domain_add ;;
            2) menu_domain_remove ;;
            3) bash scripts/split-certs.sh ;;
            b) return 0 ;;
            *) invalid_choice ;;
        esac
        echo ""
    done
}

menu_domain_add() {
    echo -e "${CYAN}${BOLD}Add domain(s)${NC}"
    echo ""
    echo "  Space-separated for several at once:"
    echo "    training.pheoc.com simex.pheoc.com staging.pheoc.com"
    echo ""
    echo "  Each gets its OWN Let's Encrypt certificate, so removing one later"
    echo "  never disturbs the others. DNS for every domain must already point"
    echo "  at this server."
    echo ""
    read -r -a DOMAINS -p "  Domain(s), empty to cancel: "
    [ "${#DOMAINS[@]}" -eq 0 ] && { echo "  Cancelled."; return 0; }

    echo ""
    echo "  Each domain will serve the database named after its first label:"
    local d
    for d in "${DOMAINS[@]}"; do
        printf '    %-40s → database: %s\n' "$d" "${d%%.*}"
    done
    echo ""
    echo -e "  ${BOLD}No database is created${NC} — restore, duplicate or create one from"
    echo "  Advanced → Databases when you are ready."
    echo ""
    read -r -p "  Continue? [Y/n]: " OK
    [[ "${OK:-Y}" =~ ^[Nn]$ ]] && { echo "  Cancelled."; return 0; }

    if ssl_is_configured; then
        bash scripts/add-domain.sh "${DOMAINS[@]}" || return 1
    else
        echo ""
        echo -e "  ${YELLOW}!${NC} No HTTPS yet, so there is no nginx or certificate work to do —"
        echo "     an HTTP-only server already answers for every hostname. Set up"
        echo "     SSL with main menu → 3 and these domains will be included."
    fi

    # Multi-tenant routing must be on before a second database exists
    local NDBS; NDBS=$(list_dbs | grep -c . || true)
    if [ "$(env_get ODOO_DBFILTER)" = "" ] && [ "${NDBS:-0}" -ge 1 ]; then
        echo ""
        echo -e "  ${YELLOW}!${NC} ODOO_DBFILTER is not set. With more than one database, Odoo needs"
        echo "     it to pick the right database per domain (subdomain = db name)."
        read -r -p "  Set ODOO_DBFILTER=^%d\$ now? [Y/n]: " DF
        if [[ ! "${DF:-Y}" =~ ^[Nn]$ ]]; then
            set_env_key ODOO_DBFILTER '^%d$'
            if grep -q "^dbfilter" "$ODOO_CONF" 2>/dev/null; then
                sed -i 's|^dbfilter = .*|dbfilter = ^%d$|' "$ODOO_CONF"
            else
                echo 'dbfilter = ^%d$' >> "$ODOO_CONF"
            fi
            echo -e "  ${GREEN}✓${NC} dbfilter set (subdomain = database name, exact match)"
            offer_odoo_restart
        fi
    fi
}

menu_domain_remove() {
    echo -e "${CYAN}${BOLD}Remove domain(s)${NC}"
    echo ""
    if ! ssl_is_configured; then
        echo -e "  ${RED}✗${NC} No HTTPS configuration — there is no per-domain routing to remove."
        return 1
    fi
    echo "  Served now:"
    active_domains | sed 's/^/    • /' | grep . || { echo "    (none)"; return 1; }
    echo ""
    echo "  Removing a domain drops its nginx block and deletes its certificate."
    echo -e "  Its database and filestore are ${BOLD}kept${NC} — delete those separately"
    echo "  from Advanced → Databases if you really want the data gone."
    echo ""
    read -r -a DOMAINS -p "  Domain(s) to remove, space-separated (empty to cancel): "
    [ "${#DOMAINS[@]}" -eq 0 ] && { echo "  Cancelled."; return 0; }
    bash scripts/remove-domain.sh "${DOMAINS[@]}"
}

# ── 3) Duplicate a database ───────────────────
menu_duplicate_db() {
    echo -e "${CYAN}${BOLD}Duplicate a database${NC} (e.g. training copies)"
    echo ""
    echo "  Existing databases:"
    list_dbs | sed 's/^/    • /'
    echo ""
    read -r -p "  Source database (empty to cancel): " SRC
    [ -z "${SRC:-}" ] && { echo "  Cancelled."; return 0; }
    read -r -p "  New database name(s), space-separated: " -a TARGETS
    [ "${#TARGETS[@]}" -eq 0 ] && { echo "  Cancelled."; return 0; }
    bash scripts/duplicate-db.sh "$SRC" "${TARGETS[@]}"
}

# ── 4) SSL setup / status ─────────────────────
menu_ssl() {
    echo -e "${CYAN}${BOLD}SSL (Let's Encrypt)${NC}"
    echo ""
    if ssl_is_configured; then
        echo "  SSL is configured. Certificates on this server:"
        echo ""
        certs_refresh
        local lin doms
        for lin in $(cert_lineages); do
            doms="$(cert_domains_of "$lin")"
            if [ "$(printf '%s' "$doms" | wc -w)" -gt 1 ]; then
                printf "    %b%-34s%b %s\n" "$YELLOW" "$lin" "$NC" "shared by: $doms"
            else
                printf "    %-34s expires %s\n" "$lin" "$(cert_expiry_of "$lin")"
            fi
        done
        echo ""
        echo "  Certificates renew automatically (certbot container, checked every 12h)."
        echo "  • Add or remove a domain:  menu item 2 (Manage domains)"
        echo "  • Re-run from scratch:     bash scripts/ssl-setup.sh DOMAIN EMAIL"
        echo ""
        echo "  A certificate marked in yellow is shared by several domains: one dead"
        echo "  DNS record then blocks renewal for all of them. Menu item 2 → 3 splits"
        echo "  it into one certificate per domain."
        return 0
    fi
    echo "  SSL is NOT set up yet (HTTP only)."
    echo "  Requirements: a DNS record pointing at this server, ports 80+443 open"
    echo "  at your cloud provider."
    echo ""
    read -r -p "  Domain(s), comma-separated (empty to cancel): " DOMAINS
    [ -z "${DOMAINS:-}" ] && { echo "  Cancelled."; return 0; }
    read -r -p "  Email for expiry notices (use a team mailbox): " EMAIL
    [ -z "${EMAIL:-}" ] && { echo "  Cancelled."; return 0; }
    bash scripts/ssl-setup.sh "$DOMAINS" "$EMAIL"
}

# ── 5) Update the app image ───────────────────
menu_update_app() {
    echo -e "${CYAN}${BOLD}Update the ePHEM app image${NC}"
    echo ""
    local TAG; TAG=$(env_get EPHEM_IMAGE_TAG)
    echo "  Pinned version: ${TAG:-'(none — tracking latest; pin one on production!)'}"
    echo "  Released versions: https://hub.docker.com/r/borrs/ephem/tags"
    echo ""
    read -r -p "  New version to pin (e.g. 1.0.3), empty to keep '$TAG': " NEWTAG
    if [ -n "${NEWTAG:-}" ]; then
        # A tag that does not exist would be written to .env and break the
        # next `docker compose up`. Check the registry first (a typo, or a
        # menu key such as x typed here by habit, is refused).
        if ! printf '%s' "$NEWTAG" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'; then
            echo -e "  ${RED}✗${NC} '$NEWTAG' is not a valid image tag. Nothing changed."
            return 1
        fi
        echo -n "  Checking that borrs/ephem:$NEWTAG exists on Docker Hub... "
        if docker manifest inspect "borrs/ephem:$NEWTAG" >/dev/null 2>&1; then
            echo "yes"
        else
            echo "no"
            echo -e "  ${RED}✗${NC} No release 'borrs/ephem:$NEWTAG' (or Docker Hub is unreachable)."
            echo "     Released versions: https://hub.docker.com/r/borrs/ephem/tags"
            echo "     Nothing changed."
            return 1
        fi
        set_env_key EPHEM_IMAGE_TAG "$NEWTAG"
        echo -e "  ${GREEN}✓${NC} EPHEM_IMAGE_TAG=$NEWTAG"
    fi
    echo ""
    read -r -p "  Back up before updating? [Y/n]: " B
    [[ ! "${B:-Y}" =~ ^[Nn]$ ]] && bash scripts/backup.sh
    echo ""
    echo -e "  ${CYAN}→${NC} $(compose_cmd_text) pull && $(compose_cmd_text) up -d"
    compose pull && compose up -d
    echo ""
    echo "  If this release includes module changes, run menu item 6 next"
    echo "  (update modules across databases). To roll back: re-run this item"
    echo "  with the previous version number."
}

# ── 5) Custom addons: fetch/switch branch, pull ─
# server: custom-addons/, shared by every tenant. dev-multi: one odcaN/,
# asked for on every visit (ask_addons_instance below).

# dev-multi: which odcaN/ this visit works in. Asked every time, with the
# roster on screen: the pinned instance is only whatever the last run used,
# and pulling or switching the wrong folder is the accident this menu exists
# to prevent. Choosing another instance pins it, so Restart and Update
# modules then act on the folder whose code just changed.
ask_addons_instance() {
    local N
    echo -e "${CYAN}${BOLD}Addons: which instance?${NC}"
    echo ""
    instances_table
    echo ""
    read -r -p "  Work in the folder of instance [${INSTANCES[*]}] (Enter = $EPHEM_INSTANCE, odca$EPHEM_INSTANCE; b back): " N || return 1
    N="${N#odca}"
    N="${N:-$EPHEM_INSTANCE}"
    if ! inst_index "$N" >/dev/null; then
        case "$N" in
            b|B) return 1 ;;
            x|X) echo "Bye. Re-open anytime:  bash manage.sh"; exit 0 ;;
        esac
        echo -e "  ${RED}✗${NC} No instance named '$N'. Configured: ${INSTANCES[*]}"
        return 1
    fi
    if [ "$N" != "$EPHEM_INSTANCE" ]; then
        stack_use_instance "$N"
        stack_pin_instance "$N"
        FS_SVC_CACHE=()
        echo -e "  ${GREEN}✓${NC} Instance $N pinned: the menu now acts on odca$N, $ODOO_URL, database $ODOO_DB (remembered in .env)"
    fi
    echo ""
}

menu_addons() {
    if [ "$EPHEM_MODE" = dev-multi ]; then ask_addons_instance || return 1; fi
    local dir="$ADDONS_DIR" name="$ADDONS_NAME"
    echo -e "${CYAN}${BOLD}Addons: $name${NC}"
    echo ""
    if [ ! -d "$dir/.git" ]; then
        echo -e "  ${RED}✗${NC} $name/ is not a git clone."
        [ "$EPHEM_MODE" = dev-multi ] && \
            echo "     Populate it:  bash scripts/dev-instances.sh up $EPHEM_INSTANCE:18_national_dev"
        return 1
    fi
    local cur dirty=0
    cur=$(git -C "$dir" branch --show-current 2>/dev/null || echo "?")
    echo "  Current branch: ${cur:-(detached)}"
    if local_mode; then
        dirty=$(git -C "$dir" status --porcelain --untracked-files=no 2>/dev/null | grep -c .) || dirty=0
        echo "  Last commit:    $(git -C "$dir" log -1 --format='%h %ad %s' --date=short 2>/dev/null | cut -c1-90)"
        [ "${dirty:-0}" -gt 0 ] && echo -e "  ${YELLOW}!${NC} $dirty tracked file(s) with uncommitted changes (option 3 lists them)"
    else
        # Repair: an earlier version widened the fetch refspec, which makes
        # every fetch download ALL branches; on a slow server link that looks
        # like a freeze. Keep it narrowed to the branch in use.
        if [ "$cur" != "?" ] && [ -n "$cur" ] && \
           [ "$(git -C "$dir" config --get remote.origin.fetch 2>/dev/null)" = "+refs/heads/*:refs/remotes/origin/*" ]; then
            git -C "$dir" config remote.origin.fetch "+refs/heads/$cur:refs/remotes/origin/$cur"
            echo -e "  ${GREEN}✓${NC} repaired fetch config (was set to fetch every branch)"
        fi
    fi
    # SSH first: a passphrase-protected key with no agent would make every git
    # command below ask for it, and the bounded check under timeout fail.
    local remote ssh_ok=1
    remote=$(git -C "$dir" remote get-url origin 2>/dev/null || echo "")
    case "$remote" in git@*|ssh://*) ensure_github_ssh || ssh_ok=0 ;; esac
    # Bounded check: never lets a slow network look like a hang, and never
    # prompts (BatchMode): a prompt under timeout cannot be answered anyway.
    echo -n "  Checking origin... "
    if [ "$ssh_ok" -eq 0 ]; then
        echo "skipped (no SSH access without a prompt)"
    elif [ -n "$cur" ] && [ "$cur" != "?" ] && \
         GIT_SSH_COMMAND="ssh -o BatchMode=yes" timeout 15 git -C "$dir" fetch --quiet origin "$cur" </dev/null 2>/dev/null; then
        local behind ahead
        behind=$(git -C "$dir" rev-list HEAD..origin/"$cur" --count 2>/dev/null || echo "?")
        ahead=$(git -C "$dir" rev-list origin/"$cur"..HEAD --count 2>/dev/null || echo "?")
        echo "behind by ${behind} commit(s), ahead by ${ahead}"
    else
        echo "unreachable or slow, skipped"
    fi
    echo ""
    case "$EPHEM_MODE" in
        server)
            echo -e "  ${YELLOW}!${NC} This changes the live code for EVERY database on this server."
            echo "     Take a backup first for anything beyond a routine pull."
            ;;
        dev-multi)
            echo "  Only instance $EPHEM_INSTANCE uses this folder ($ODOO_URL, database $ODOO_DB)."
            ;;
    esac
    echo ""
    echo "  1) Pull latest on '$cur'"
    echo "  2) Fetch & switch to a different branch"
    local_mode && echo "  3) Show local changes (git status)"
    echo "  b) Back"
    echo "  x) Exit"
    if local_mode; then ask_choice "1-3"; else ask_choice "1-2"; fi
    case "$CHOICE" in
        1)
            git -C "$dir" pull --ff-only || {
                echo -e "  ${RED}✗${NC} Pull failed (diverged, local changes in the way, or no access): resolve manually."
                return 1
            }
            ;;
        2)
            read -r -p "  Branch name on origin: " BR
            [ -z "${BR:-}" ] && { echo "  Cancelled."; return 0; }
            # Validate FIRST: nothing is changed until the branch is known
            # to exist under exactly this name.
            if ! git -C "$dir" ls-remote --exit-code --heads origin "$BR" >/dev/null 2>&1; then
                echo -e "  ${RED}✗${NC} No branch named '$BR' on origin. Branches that exist:"
                git -C "$dir" ls-remote --heads origin 2>/dev/null \
                    | sed 's|.*refs/heads/|    • |' \
                    || echo "    (could not list: is the deploy key or your SSH key authorized?)"
                return 1
            fi
            if [ "$EPHEM_MODE" = server ]; then
                # Re-point the (narrow) refspec at the new branch, then fetch:
                # only that one branch is ever downloaded, and git can resolve
                # it for switch/tracking. --depth 1 keeps shallow clones small.
                local DEPTH=""
                [ -f "$dir/.git/shallow" ] && DEPTH="--depth 1"
                ( cd "$dir" &&
                  git config remote.origin.fetch "+refs/heads/$BR:refs/remotes/origin/$BR" &&
                  git fetch $DEPTH origin &&
                  { git switch "$BR" 2>/dev/null || git switch -c "$BR" --track "origin/$BR"; } &&
                  git merge --ff-only "origin/$BR" &&
                  git branch --set-upstream-to="origin/$BR" "$BR"
                ) || { echo -e "  ${RED}✗${NC} Fetch/switch failed: see the git output above."; return 1; }
            else
                # A developer clone tracks every branch (setup.sh widens the
                # refspec), so a plain fetch + switch does it. Uncommitted work
                # is carried over when it does not conflict; git refuses the
                # switch otherwise, and nothing is lost either way.
                if [ "${dirty:-0}" -gt 0 ]; then
                    echo -e "  ${YELLOW}!${NC} $dirty file(s) have uncommitted changes. They come along if they"
                    echo "     do not conflict with '$BR'; otherwise git refuses and nothing changes."
                    read -r -p "  Continue? [y/N]: " C
                    [[ "${C:-N}" =~ ^[Yy]$ ]] || { echo "  Cancelled."; return 0; }
                fi
                ( cd "$dir" &&
                  git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*" &&
                  git fetch origin "$BR" &&
                  { git switch "$BR" 2>/dev/null || git switch -c "$BR" --track "origin/$BR"; }
                ) || { echo -e "  ${RED}✗${NC} Fetch/switch failed: see the git output above."; return 1; }
                local lr
                lr=$(git -C "$dir" rev-list --left-right --count "$BR"...origin/"$BR" 2>/dev/null || echo "? ?")
                if [ "${lr%%[[:space:]]*}" = "0" ] && [ "${lr##*[[:space:]]}" != "0" ]; then
                    git -C "$dir" merge --ff-only "origin/$BR" >/dev/null 2>&1 && \
                        echo "  fast-forwarded '$BR' by ${lr##*[[:space:]]} commit(s)"
                elif [ "${lr%%[[:space:]]*}" != "0" ]; then
                    echo "  note: local '$BR' is ${lr%%[[:space:]]*} commit(s) ahead of origin, left as is"
                fi
            fi
            echo -e "  ${GREEN}✓${NC} $name now on '$BR'"
            ;;
        3)
            local_mode || { invalid_choice; return 0; }
            echo "  git -C $name status --short  (first 60 lines)"
            git -C "$dir" status --short 2>/dev/null | head -60 | sed 's/^/    /'
            [ "$(git -C "$dir" status --short 2>/dev/null | grep -c .)" -eq 0 ] && echo "    (clean)"
            return 0
            ;;
        b) return 0 ;;
        *) invalid_choice; return 0 ;;
    esac
    echo ""
    if [ "$EPHEM_MODE" = server ]; then
        read -r -p "  Apply the new code now (update modules on all databases + restart)? [Y/n]: " U
        if [[ ! "${U:-Y}" =~ ^[Nn]$ ]]; then
            bash scripts/update-modules.sh --auto
        else
            echo "  Remember: the new code is NOT active until modules are updated"
            echo "  (menu item 6) and Odoo is restarted (Advanced → 1)."
        fi
    else
        echo "  Apply the new code to $ODOO_SVC now?"
        echo "    1) Restart and follow the log"
        echo "    2) Update modules, then restart and follow the log"
        echo "    3) Later"
        ask_choice "1-3" "b"
        case "$CHOICE" in
            1) menu_restart_logs_local ;;
            2) menu_modules_local ;;
            *) echo "  Remember: new Python code needs a restart, new views and data a module update (menu 4 and 5)." ;;
        esac
    fi
}

# ── 9) Database manager lock ──────────────────
menu_db_manager() {
    echo -e "${CYAN}${BOLD}Web database manager${NC} (/web/database/manager)"
    echo ""
    local CUR; CUR=$(env_get ODOO_LIST_DB)
    echo "  Current state: ODOO_LIST_DB=${CUR:-True}"
    echo ""
    echo "  Keep it DISABLED on production — it can create, drop and download"
    echo "  databases, protected only by the master password. Neither adding a"
    echo "  domain (menu item 2) nor the Databases menu next door needs it."
    echo ""
    if [ "${CUR:-True}" = "False" ]; then
        read -r -p "  Enable it temporarily? [y/N]: " E
        [[ "${E:-N}" =~ ^[Yy]$ ]] || { echo "  Left disabled."; return 0; }
        set_env_key ODOO_LIST_DB True
        sed -i 's/^list_db = .*/list_db = True/' "$ODOO_CONF"
        echo -e "  ${YELLOW}!${NC} Enabled. Come back and DISABLE it as soon as you are done."
    else
        read -r -p "  Disable it now (recommended)? [Y/n]: " D
        [[ "${D:-Y}" =~ ^[Nn]$ ]] && { echo "  Left enabled."; return 0; }
        set_env_key ODOO_LIST_DB False
        sed -i 's/^list_db = .*/list_db = False/' "$ODOO_CONF"
        echo -e "  ${GREEN}✓${NC} Disabled."
    fi
    $(compose_cmd_text) restart $ODOO_SVC >/dev/null 2>&1 && echo "  Odoo restarted."
}

# ── 11) Security check ────────────────────────
menu_security() {
    echo -e "${CYAN}${BOLD}Security check${NC}"
    echo ""
    echo -e "${BOLD}Database role:${NC}"
    bash scripts/harden-db-role.sh || true
    echo ""
    echo -e "${BOLD}Settings:${NC}"
    local LDB DBF TAG
    LDB=$(env_get ODOO_LIST_DB); DBF=$(env_get ODOO_DBFILTER); TAG=$(env_get EPHEM_IMAGE_TAG)
    [ "${LDB:-True}" = "False" ] \
        && echo -e "  ${GREEN}✓${NC} database manager disabled (ODOO_LIST_DB=False)" \
        || echo -e "  ${YELLOW}!${NC} database manager ENABLED — disable it via Advanced → 3"
    local RPC; RPC=$(rpc_allow 2>/dev/null)
    if ! rpc_block_present; then
        echo -e "  ${YELLOW}!${NC} nginx config has no RPC block (predates the hardening): apply one via Advanced → 4"
    elif [ -z "$RPC" ]; then
        echo -e "  ${GREEN}✓${NC} RPC endpoints blocked (/xmlrpc, /jsonrpc)"
    elif [ "$RPC" = all ]; then
        echo -e "  ${YELLOW}!${NC} RPC endpoints OPEN to everyone: restrict them via Advanced → 4"
    else
        echo -e "  ${GREEN}✓${NC} RPC endpoints open to $RPC only"
    fi
    local RPC_OPEN; RPC_OPEN=$(rpc_open_domains 2>/dev/null)
    [ -n "$RPC_OPEN" ] && \
        echo -e "  ${YELLOW}!${NC} RPC OPEN to everyone on: $RPC_OPEN (per domain, block again via Advanced → 4)"
    [ -n "$DBF" ] \
        && echo -e "  ${GREEN}✓${NC} dbfilter set ($DBF)" \
        || echo -e "  ${YELLOW}!${NC} ODOO_DBFILTER not set — required once you have several databases"
    [ -n "$TAG" ] \
        && echo -e "  ${GREEN}✓${NC} app image pinned (EPHEM_IMAGE_TAG=$TAG)" \
        || echo -e "  ${YELLOW}!${NC} app image not pinned — set EPHEM_IMAGE_TAG in .env"
    [ -n "$(env_get BACKUP_AGE_RECIPIENT)" ] \
        && echo -e "  ${GREEN}✓${NC} backups are encrypted (BACKUP_AGE_RECIPIENT set)" \
        || echo -e "  ${YELLOW}!${NC} backups NOT encrypted — set BACKUP_AGE_RECIPIENT (README → Backups)"
    [ -n "$(env_get BACKUP_PING_URL)" ] \
        && echo -e "  ${GREEN}✓${NC} backup monitoring ping configured" \
        || echo -e "  ${YELLOW}!${NC} no backup monitoring — set BACKUP_PING_URL (README → Backups)"
    echo ""
    echo "  Host-level checklist (SSH, firewall, OS updates): see HARDENING.md"
}

# ── 12) nginx upload size limit ───────────────
menu_upload_limit() {
    echo -e "${CYAN}${BOLD}Upload size limit (nginx)${NC}"
    echo ""
    echo "  Uploads bigger than this limit get '413 Request Entity Too Large' —"
    echo "  typically when restoring a large database through the database"
    echo "  manager. The limit applies to every upload (attachments too)."
    echo ""
    if [ ! -f nginx/active.conf ]; then
        echo -e "  ${RED}✗${NC} nginx/active.conf not found — run setup.sh first."
        return 1
    fi
    local CUR
    CUR=$(grep -m1 -o 'client_max_body_size[[:space:]]*[0-9]*[MmGg]' nginx/active.conf | awk '{print $NF}')
    echo "  Current limit: ${CUR:-unknown}"
    read -r -p "  New limit (e.g. 300M or 2G), empty to cancel: " VAL
    [ -z "${VAL:-}" ] && { echo "  Cancelled."; return 0; }
    if ! printf '%s' "$VAL" | grep -Eq '^[0-9]+[MmGg]$'; then
        echo -e "  ${RED}✗${NC} '$VAL' is not a valid size — use a number plus M or G (e.g. 500M, 1G)."
        return 1
    fi
    # .env is the source of truth; the renderer writes it into every server
    # block. (An earlier version ran sed -i on active.conf: that renames the
    # file, the container keeps the old inode, and the reload changed nothing
    # until the next restart.)
    nginx_setting_apply NGINX_MAX_UPLOAD "$VAL" && \
        echo -e "  ${GREEN}✓${NC} Upload limit is now $VAL."
}

# Persist one nginx setting in .env, re-render active.conf from .env and
# apply. nginx_apply rolls the config back if nginx rejects it; .env is
# rolled back with it, so the two never disagree about what is in force.
nginx_setting_apply() {  # nginx_setting_apply KEY VALUE
    local KEY="$1" VAL="$2" PREV
    PREV=$(env_get "$KEY")
    set_env_key "$KEY" "$VAL"
    echo -e "  ${CYAN}→${NC} $KEY=$VAL  (.env), re-rendering nginx/active.conf"
    rerender_active_conf && return 0
    set_env_key "$KEY" "$PREV"
    echo -e "  ${RED}✗${NC} Not applied. .env is back to $KEY=$PREV and nginx"
    echo "     keeps serving what it served before."
    return 1
}

# ── 13.1) Start / stop / restart services ─────
menu_service() {
    echo -e "${CYAN}${BOLD}Services — start / stop / restart${NC}"
    echo ""
    printf "  Odoo: %s      Database: %s      nginx: %s\n" \
        "$(svc_state "$ODOO_SVC")" "$(svc_state db)" "$(svc_state nginx)"
    echo ""
    echo -e "  ${YELLOW}!${NC} While Odoo is stopped every tenant on this server is offline"
    echo "     (visitors get '502 Bad Gateway' from nginx). Sessions survive a"
    echo "     restart; anything a user was typing does not."
    echo ""
    echo "  1) Restart Odoo            ($(compose_cmd_text) restart $ODOO_SVC)"
    echo "  2) Stop Odoo               ($(compose_cmd_text) stop $ODOO_SVC)"
    echo "  3) Start Odoo              ($(compose_cmd_text) start $ODOO_SVC)"
    echo "  4) Restart nginx           ($(compose_cmd_text) restart nginx, about a second offline)"
    echo "  5) Restart everything      ($(compose_cmd_text) restart)"
    echo "  b) Back"
    echo "  x) Exit"
    ask_choice "1-5"
    case "$CHOICE" in
        1)
            svc_restart "$ODOO_SVC" || {
                echo -e "  ${RED}✗${NC} Restart failed — see the output above."; return 1; }
            wait_for_odoo
            ;;
        2)
            read -r -p "  Really stop Odoo and take every tenant offline? [y/N]: " C
            [[ "${C:-N}" =~ ^[Yy]$ ]] || { echo "  Cancelled."; return 0; }
            echo -e "  ${CYAN}→${NC} $(compose_cmd_text) stop $ODOO_SVC"
            compose stop "$ODOO_SVC" || {
                echo -e "  ${RED}✗${NC} Stop failed — see the output above."; return 1; }
            echo -e "  ${GREEN}✓${NC} Odoo stopped. It stays down across reboots until you start it"
            echo "     again here (option 3) — the database and nginx keep running."
            ;;
        3)
            # Creates the container when it never ran here, recreates it when
            # docker refuses the old one (stale config mount), starts it else.
            svc_start "$ODOO_SVC" || {
                echo -e "  ${RED}✗${NC} Start failed — see the output above."; return 1; }
            wait_for_odoo
            ;;
        4)
            # Picks up a renewed certificate or a config edit at once, and
            # re-attaches the active.conf mount (see nginx_apply). Odoo is
            # not touched; visitors see a blip of about a second.
            if [ "$(svc_state nginx)" = "absent" ]; then
                echo -e "  ${CYAN}→${NC} $(compose_cmd_text) up -d nginx"
                compose up -d nginx || {
                    echo -e "  ${RED}✗${NC} Start failed — see the output above."; return 1; }
            else
                echo -e "  ${CYAN}→${NC} $(compose_cmd_text) restart nginx"
                compose restart nginx || {
                    echo -e "  ${RED}✗${NC} Restart failed — see the output above."; return 1; }
            fi
            sleep 2
            if [ "$(svc_state nginx)" = "running" ]; then
                echo -e "  ${GREEN}✓${NC} nginx is running"
            else
                echo -e "  ${RED}✗${NC} nginx is not running, check: $(compose_cmd_text) logs nginx"
                echo "     (a broken nginx/active.conf is the usual cause)"
                return 1
            fi
            ;;
        5)
            read -r -p "  Restart Odoo, the database and nginx together? [y/N]: " C
            [[ "${C:-N}" =~ ^[Yy]$ ]] || { echo "  Cancelled."; return 0; }
            echo -e "  ${CYAN}→${NC} $(compose_cmd_text) restart"
            compose restart || {
                echo -e "  ${RED}✗${NC} Restart failed — see the output above."; return 1; }
            wait_for_odoo
            ;;
        b) return 0 ;;
        *) invalid_choice; return 0 ;;
    esac
    echo ""
    echo "  Now: Odoo $(svc_state "$ODOO_SVC"), database $(svc_state db), nginx $(svc_state nginx)"
}

# ── 13.2) Databases — backup / restore / delete ─
menu_db_admin() {
    echo -e "${CYAN}${BOLD}Databases${NC}"
    echo ""
    if [ "$(svc_state db)" != "running" ]; then
        echo -e "  ${RED}✗${NC} The database container is not running — start it first ($(services_hint))."
        return 1
    fi
    echo -e "  ${BOLD}In PostgreSQL:${NC}"
    list_dbs_sized | sed 's/^/    • /' | grep . || echo "    (none)"
    echo ""
    echo -e "  ${BOLD}Filestores on disk:${NC}"
    list_filestores | sed 's/^/    • /' | grep . || echo "    (none)"
    echo ""
    echo "  A tenant is BOTH: the database holds the records, the filestore"
    echo "  holds the attachments. A snapshot always carries the pair."
    echo ""
    echo "  1) Backup     — save a database + filestore into backups/"
    echo "  2) Restore    — put a snapshot back"
    echo "  3) Delete     — remove a database and/or its filestore"
    echo "  4) Duplicate  — copy one database into new ones (training copies)"
    echo "  5) Create     — fresh empty database(s) for a domain"
    echo "  b) Back"
    echo "  x) Exit"
    ask_choice "1-5"
    case "$CHOICE" in
        1) menu_db_backup ;;
        2) menu_db_restore ;;
        3) menu_db_delete ;;
        4) menu_duplicate_db ;;
        5) menu_db_create ;;
        b) return 0 ;;
        *) invalid_choice ;;
    esac
}

# ── 13.2.5) Create empty database(s) ──────────
# Adding a domain deliberately creates nothing; this is where an empty tenant
# comes from when it is not being restored or duplicated.
menu_db_create() {
    echo -e "${CYAN}${BOLD}Create empty database(s)${NC}"
    echo ""
    echo "  A fresh Odoo database, no demo data, first login admin/admin."
    echo "  Name it after the domain's first label so dbfilter routes to it:"
    echo "  training.pheoc.com → 'training'."
    echo ""
    echo "  Existing:"
    list_dbs | sed 's/^/    • /' | grep . || echo "    (none)"
    echo ""
    read -r -a NAMES -p "  New database name(s), space-separated (empty to cancel): "
    [ "${#NAMES[@]}" -eq 0 ] && { echo "  Cancelled."; return 0; }

    local n GOOD=()
    for n in "${NAMES[@]}"; do
        if ! valid_db_name "$n"; then
            echo -e "  ${RED}✗${NC} '$n' is not a valid database name — skipping"; continue
        fi
        if db_exists "$n"; then
            echo -e "  ${RED}✗${NC} '$n' already exists — skipping"; continue
        fi
        printf '%s\n' "${GOOD[@]:-}" | grep -qx "$n" && continue   # typed twice
        GOOD+=("$n")
    done
    [ "${#GOOD[@]}" -eq 0 ] && { echo "  Nothing to create."; return 1; }

    echo ""
    echo "  Will create: ${GOOD[*]}"
    echo -e "  ${YELLOW}!${NC} Odoo is stopped while they are created (a minute or two each),"
    echo "     so no web request can race the creation. Every tenant is offline"
    echo "     for that time."
    read -r -p "  Continue? [y/N]: " OK
    [[ "${OK:-N}" =~ ^[Yy]$ ]] || { echo "  Cancelled."; return 0; }

    compose stop "$ODOO_SVC" >/dev/null
    local FAILED=() MADE=()
    for n in "${GOOD[@]}"; do
        echo ""
        echo -e "  ${CYAN}→${NC} $(compose_cmd_text) run --rm $ODOO_SVC odoo -d $n -i base --without-demo=all"
        if compose run --rm -T --no-deps "$ODOO_SVC" odoo -d "$n" -i base --without-demo=all --stop-after-init </dev/null; then
            echo -e "  ${GREEN}✓${NC} '$n' created"
            MADE+=("$n")
        else
            echo -e "  ${RED}✗${NC} '$n' failed — see the output above."
            FAILED+=("$n")
        fi
    done
    if [ "$EPHEM_MODE" = dev-multi ]; then
        compose up -d "$ODOO_SVC" >/dev/null     # only this instance, not ones stopped on purpose
    else
        compose up -d >/dev/null
    fi
    wait_for_odoo

    echo ""
    [ "${#MADE[@]}" -gt 0 ] && echo -e "  ${GREEN}✓ Created:${NC} ${MADE[*]}"
    [ "${#FAILED[@]}" -gt 0 ] && echo -e "  ${RED}✗ Failed:${NC} ${FAILED[*]}"
    [ "${#MADE[@]}" -eq 0 ] && return 1
    echo ""
    echo "  Secure each one at first login:"
    echo "    • log in (admin/admin), change the admin password immediately"
    echo "    • enable two-factor authentication for admin"
    echo "    • Settings → General Settings → Customer Account: 'On invitation'"
}

# ── 13.2.1) Backup ────────────────────────────
menu_db_backup() {
    echo -e "${CYAN}${BOLD}Backup${NC}"
    echo ""
    echo "  Each snapshot is its own folder: backups/<database>_<timestamp>/,"
    echo "  holding database.sql.gz + filestore.tar.gz. The Restore menu reads"
    echo "  these folders back."
    echo ""
    echo "  (Menu item $(backup_item) is the different, whole-server job: every database at"
    echo "   once, encrypted, with retention — that is the one for cron.)"
    echo ""
    echo "  Keeping the newest $(env_get SNAPSHOT_KEEP | grep . || echo 10) snapshot(s) per database;"
    echo "  older ones are pruned automatically (SNAPSHOT_KEEP in .env, 0 = off)."
    echo ""
    echo "  1) Back up one database (+ its filestore)"
    echo "  2) Back up every database"
    echo "  b) Back"
    echo "  x) Exit"
    ask_choice "1-2"
    case "$CHOICE" in
        1)
            read -r -p "  Database name (empty to cancel): " DB
            [ -z "${DB:-}" ] && { echo "  Cancelled."; return 0; }
            valid_db_name "$DB" || {
                echo -e "  ${RED}✗${NC} '$DB' is not a valid database name (letters, digits, . _ -)."
                return 1; }
            echo ""
            snapshot_create "$DB"
            ;;
        2)
            local DBS OK=0 BAD=0 d
            DBS=$(list_dbs)
            [ -z "$DBS" ] && { echo "  No databases to back up."; return 0; }
            for d in $DBS; do
                echo ""
                if snapshot_create "$d"; then OK=$((OK + 1)); else BAD=$((BAD + 1)); fi
            done
            echo ""
            echo -e "  ${GREEN}✓${NC} $OK snapshot(s) written to backups/"
            [ "$BAD" -gt 0 ] && echo -e "  ${RED}✗${NC} $BAD failed — see the output above."
            ;;
        b) return 0 ;;
        *) invalid_choice ;;
    esac
}

# ── 13.2.2) Restore ───────────────────────────
menu_db_restore() {
    # Wrapper so the decrypted plaintext of an encrypted run is removed on
    # EVERY exit path, including a cancel half way through.
    AGE_STAGE=""
    local rc=0
    _menu_db_restore_body || rc=$?
    if [ -n "${AGE_STAGE:-}" ] && [ -d "$AGE_STAGE" ]; then
        rm -rf "$AGE_STAGE"
        echo "  (decrypted files removed from backups/)"
    fi
    return "$rc"
}

_menu_db_restore_body() {
    echo -e "${CYAN}${BOLD}Restore${NC}"
    echo ""
    # A run killed with Ctrl-C can strand decrypted dumps. Sweep anything left
    # over from more than an hour ago before showing the list.
    find "$BACKUP_DIR" -maxdepth 1 -type d -name '.age_unpack_*' -mmin +60 \
        -exec rm -rf {} + 2>/dev/null

    local -a ROWS=()
    local line
    while IFS= read -r line; do [ -n "$line" ] && ROWS+=("$line"); done \
        < <(restore_sources | sort -t'|' -k1,1nr | head -100)

    local i n kind db created size sqlf tarf what C
    if [ "${#ROWS[@]}" -eq 0 ]; then
        echo "  Nothing restorable in backups/ yet."
    else
        printf "  %3s  %-22s %-17s %7s  %s\n" "#" "DATABASE" "CREATED" "SIZE" "SOURCE"
    fi
    for i in "${!ROWS[@]}"; do
        IFS='|' read -r n kind db created size sqlf tarf <<< "${ROWS[$i]}"
        case "$kind" in
            snap) what="snapshot"
                  [ -n "$sqlf" ] && [ -n "$tarf" ] && what="snapshot · database + filestore"
                  [ -n "$sqlf" ] && [ -z "$tarf" ] && what="snapshot · database only"
                  [ -z "$sqlf" ] && what="snapshot · filestore only" ;;
            auto) what="automated backup"
                  [ -n "$tarf" ] && what="automated backup · + filestore"
                  [ -z "$tarf" ] && what="automated backup · database only" ;;
            age)  what="encrypted run · needs your key file" ;;
        esac
        printf "  %3d) %-22s %-17s %7s  %s\n" "$((i + 1))" "$db" "$created" "$size" "$what"
    done
    echo ""
    [ "${#ROWS[@]}" -gt 0 ] && echo "  Newest first (100 max)."
    echo "  Or paste a PATH to restore from somewhere else — a snapshot folder"
    echo "  copied off another server, a folder of dumps, or a single .sql.gz."
    echo ""
    read -r -p "  Number or path (empty to cancel): " N
    [ -z "${N:-}" ] && { echo "  Cancelled."; return 0; }

    local SQLF TARF SRC TGT FROM
    if printf '%s' "$N" | grep -Eq '^[0-9]+$'; then
        if [ "$N" -lt 1 ] || [ "$N" -gt "${#ROWS[@]}" ]; then
            echo -e "  ${RED}✗${NC} Pick a number between 1 and ${#ROWS[@]}, or paste a path."
            return 1
        fi
        IFS='|' read -r n kind db created size sqlf tarf <<< "${ROWS[$((N - 1))]}"
        echo ""
        if [ "$kind" = age ]; then
            age_unpack "$sqlf" || return 1
            SQLF="$RS_SQL"; TARF="$RS_TAR"; SRC="$RS_DB"
            FROM="$(basename "$sqlf") (decrypted)"
        else
            SQLF="$sqlf"; TARF="$tarf"; SRC="$db"
            FROM="backups/$(basename "${sqlf:-$tarf}")"
            [ "$kind" = snap ] && FROM="backups/$(basename "$(dirname "$sqlf")")"
        fi
    else
        echo ""
        resolve_external_path "$N" || return 1
        SQLF="$RS_SQL"; TARF="$RS_TAR"; SRC="$RS_DB"
        FROM="$N"
        echo -e "  ${GREEN}✓${NC} Found:"
        [ -n "$SQLF" ] && echo "     database:  $SQLF" || echo "     database:  (none)"
        [ -n "$TARF" ] && echo "     filestore: $TARF" || echo "     filestore: (none)"
    fi

    echo ""
    echo "  Restoring from: $FROM"
    if [ -n "$SRC" ]; then
        read -r -p "  Restore into database name [$SRC]: " TGT
        TGT="${TGT:-$SRC}"
    else
        read -r -p "  Restore into database name (required): " TGT
        [ -z "${TGT:-}" ] && { echo "  Cancelled."; return 0; }
    fi
    if ! valid_db_name "$TGT"; then
        echo -e "  ${RED}✗${NC} '$TGT' is not a valid database name (letters, digits, . _ -)."
        return 1
    fi

    # Is anything already sitting at the target? That turns a restore into an
    # overwrite, which gets the full destructive gate.
    local EX_DB=no EX_FS=no MODE="" ODOO_SH_SVC
    ODOO_SH_SVC=$(fs_svc_for "$TGT")
    db_exists "$TGT" && EX_DB=yes
    odoo_sh "test -d $FILESTORE/$TGT" >/dev/null 2>&1 && EX_FS=yes

    if [ "$EX_DB" = no ] && [ "$EX_FS" = no ]; then
        echo ""
        echo "  Nothing exists at '$TGT' yet — this creates it."
        read -r -p "  Restore now? [y/N]: " C
        [[ "${C:-N}" =~ ^[Yy]$ ]] || { echo "  Cancelled."; return 0; }
    else
        echo ""
        echo -e "  ${YELLOW}!${NC} '$TGT' already exists — restoring REPLACES it."
        if   [ "$EX_DB" = yes ] && [ "$EX_FS" = yes ]; then MODE=both
        elif [ "$EX_DB" = yes ];                       then MODE=db
        else                                                MODE=filestore; fi
        confirm_destructive "$TGT" "$MODE" overwrite || return 0
    fi

    echo ""
    snapshot_restore "$SQLF" "$TARF" "$SRC" "$TGT" || return 1
    echo ""
    echo -e "  ${GREEN}✓${NC} Restore complete: '$TGT'"
    echo -e "  ${YELLOW}!${NC} This is a MOVE, not a copy: the database keeps its original"
    echo "     identity (database.uuid) and everything in it — scheduled actions,"
    echo "     outgoing mail servers, payment credentials. If the source server"
    echo "     is still running this tenant, both will now act as the same"
    echo "     database. Shut the old one down, or expect duplicate emails."
    offer_odoo_restart
}

# ── 13.2.3) Delete ────────────────────────────
menu_db_delete() {
    echo -e "${CYAN}${BOLD}Delete${NC}"
    echo ""
    echo -e "  ${RED}!${NC} Nothing is deleted here without a snapshot being written first."
    echo "     If the snapshot fails, the delete is refused."
    echo ""
    echo "  1) Delete a database AND its filestore"
    echo "  2) Delete a database only (leaves the filestore)"
    echo "  3) Delete a filestore only (leaves the database)"
    echo "  b) Back"
    echo "  x) Exit"
    ask_choice "1-3"
    local A="$CHOICE"
    case "$A" in 1|2|3) ;; b) return 0 ;; *) invalid_choice; return 0 ;; esac

    read -r -p "  Database name (empty to cancel): " DB
    [ -z "${DB:-}" ] && { echo "  Cancelled."; return 0; }
    if ! valid_db_name "$DB"; then
        echo -e "  ${RED}✗${NC} '$DB' is not a valid database name (letters, digits, . _ -)."
        return 1
    fi

    # Snapshot BEFORE the warnings: the operator should be looking at a
    # written, verified backup while deciding, not at a promise of one.
    echo -e "  ${CYAN}→${NC} Taking a snapshot first..."
    if ! snapshot_create "$DB"; then
        echo ""
        echo -e "  ${RED}✗${NC} Snapshot failed — refusing to delete. Nothing was changed."
        return 1
    fi
    echo ""
    echo "  Recoverable from: backups/${SNAPSHOT_DIR##*/}  (Restore menu, option 2)"

    case "$A" in
        1)
            confirm_destructive "$DB" both || return 0
            drop_database "$DB" || return 1
            delete_filestore "$DB"
            offer_odoo_restart
            ;;
        2)
            confirm_destructive "$DB" db || return 0
            drop_database "$DB" || return 1
            echo -e "  ${YELLOW}!${NC} The filestore for '$DB' is still on disk — option 3 removes it."
            offer_odoo_restart
            ;;
        3)
            confirm_destructive "$DB" filestore || return 0
            delete_filestore "$DB" || return 1
            ;;
    esac
}

# Odoo caches a registry per database; after dropping one, a restart clears
# the stale entry (and any worker still holding it).
offer_odoo_restart() {
    [ "$(svc_state "$ODOO_SVC")" = "running" ] || return 0
    echo ""
    read -r -p "  Restart Odoo to clear its cached registry? [Y/n]: " R
    [[ "${R:-Y}" =~ ^[Nn]$ ]] && return 0
    svc_restart "$ODOO_SVC" && wait_for_odoo
}

# ── 13.4) RPC endpoints ───────────────────────
# /xmlrpc and /jsonrpc take a password straight from the request: no login
# page, no CSRF, no second factor, and the web client never uses them. They
# stay blocked at nginx unless a system has to call in. Two settings in
# .env, both rendered into the server blocks so they survive adding or
# removing domains (a hand edit to active.conf does not):
#   NGINX_RPC_OPEN    domains whose RPC is open to everyone (per tenant)
#   NGINX_RPC_ALLOW   the server-wide default for every other domain
menu_rpc() {
    echo -e "${CYAN}${BOLD}RPC endpoints${NC} (/xmlrpc, /jsonrpc)"
    echo ""
    if [ ! -f nginx/active.conf ]; then
        echo -e "  ${RED}✗${NC} nginx/active.conf not found, run setup.sh first."
        return 1
    fi
    local d OPEN; OPEN=$(rpc_open_domains 2>/dev/null)
    if ssl_is_configured; then
        echo -e "  ${BOLD}Per domain:${NC}"
        while IFS= read -r d; do
            [ -n "$d" ] && printf '    %-40s %s\n' "$d" "$(rpc_domain_state "$d")"
        done < <(active_domains)
        local SERVED=(); mapfile -t SERVED < <(active_domains)
        for d in $OPEN; do
            in_list "$d" "${SERVED[@]:-}" || printf '    %-40s %s\n' "$d" "in NGINX_RPC_OPEN but not served here"
        done
    else
        echo "  HTTP-only server: one server block answers for every hostname, so"
        echo "  only the server-wide setting applies."
    fi
    echo ""
    echo "  Server-wide default: $(rpc_state_text)"
    if ! rpc_block_present; then
        echo -e "  ${YELLOW}!${NC} The live nginx config has no RPC block yet (it predates the"
        echo "     hardening), so nothing is blocked right now. Any choice below"
        echo "     re-renders it."
    fi
    echo ""
    echo "  Odoo's own web client never calls these, so blocking them costs"
    echo "  browser users nothing. They accept a password straight from the"
    echo "  request (no login page, no CSRF, no second factor), which makes"
    echo "  them the first target for password guessing. Open a domain only"
    echo "  while something has to call in, and block it again afterwards."
    echo ""
    echo "  1) Open RPC for domain(s)        everyone may call that tenant's RPC"
    echo "  2) Block RPC for domain(s)       back to the server-wide default"
    echo "  3) Server-wide default           block / allow addresses / allow everyone"
    echo "  b) Back"
    echo "  x) Exit"
    ask_choice "1-3"
    case "$CHOICE" in
        1) menu_rpc_open ;;
        2) menu_rpc_close ;;
        3) menu_rpc_default ;;
        b) return 0 ;;
        *) invalid_choice ;;
    esac
}

menu_rpc_open() {
    if ! ssl_is_configured; then
        echo -e "  ${RED}✗${NC} Per-domain RPC needs HTTPS (one server block per domain)."
        echo "     On this HTTP-only server use 3) Server-wide default."
        return 1
    fi
    local d SERVED=() NEW=() ADDED=()
    mapfile -t SERVED < <(active_domains)
    for d in $(rpc_open_domains 2>/dev/null); do NEW+=("$d"); done
    echo "  Served now:"
    printf '    • %s\n' "${SERVED[@]}"
    echo ""
    echo -e "  ${YELLOW}!${NC} On an open domain every address on the internet can try passwords"
    echo "     against that tenant's /xmlrpc/2/common, throttled only by the"
    echo "     general rate limit. Block it again when the job is done."
    echo ""
    read -r -a DOMS -p "  Domain(s) to open, space separated (empty to cancel): "
    [ "${#DOMS[@]}" -eq 0 ] && { echo "  Cancelled."; return 0; }
    for d in "${DOMS[@]}"; do
        d="${d%,}"; [ -z "$d" ] && continue
        if ! in_list "$d" "${SERVED[@]}"; then
            echo -e "  ${RED}✗${NC} $d is not served here, skipping"; continue
        fi
        if in_list "$d" "${NEW[@]:-}"; then
            echo -e "  ${YELLOW}!${NC} $d is already open"; continue
        fi
        NEW+=("$d"); ADDED+=("$d")
    done
    [ "${#ADDED[@]}" -eq 0 ] && { echo "  Nothing to open."; return 0; }
    rpc_apply NGINX_RPC_OPEN "${NEW[*]}"
}

menu_rpc_close() {
    local d OPEN=() KEEP=() DROPPED=()
    for d in $(rpc_open_domains 2>/dev/null); do OPEN+=("$d"); done
    if [ "${#OPEN[@]}" -eq 0 ]; then
        echo "  No domain is open per domain; the server-wide default applies everywhere."
        return 0
    fi
    echo "  Open per domain now:"
    printf '    • %s\n' "${OPEN[@]}"
    echo ""
    read -r -a DOMS -p "  Domain(s) to block again, or 'all' (empty to cancel): "
    [ "${#DOMS[@]}" -eq 0 ] && { echo "  Cancelled."; return 0; }
    local WANT=()
    for d in "${DOMS[@]}"; do d="${d%,}"; [ -n "$d" ] && WANT+=("$d"); done
    if [ "${WANT[0]:-}" = all ]; then
        DROPPED=("${OPEN[@]}")
    else
        for d in "${OPEN[@]}"; do
            if in_list "$d" "${WANT[@]:-}"; then DROPPED+=("$d"); else KEEP+=("$d"); fi
        done
        for d in "${WANT[@]:-}"; do
            [ -n "$d" ] && ! in_list "$d" "${OPEN[@]}" \
                && echo -e "  ${YELLOW}!${NC} $d is not open per domain, skipping"
        done
    fi
    [ "${#DROPPED[@]}" -eq 0 ] && { echo "  Nothing to change."; return 0; }
    rpc_apply NGINX_RPC_OPEN "${KEEP[*]:-}"
}

menu_rpc_default() {
    echo -e "${BOLD}Server-wide default${NC} (every domain not listed as open)"
    echo ""
    echo "  Current: $(rpc_state_text)"
    echo ""
    echo "  1) Block for everyone (recommended)"
    echo "  2) Allow specific addresses only"
    echo "  3) Allow everyone"
    echo "  b) Back"
    echo "  x) Exit"
    ask_choice "1-3"
    local NEW a ADDRS=() GOOD=()
    case "$CHOICE" in
        1) NEW="" ;;
        2)
            echo "  IPv4 or IPv6 addresses, or CIDR ranges, space separated:"
            echo "    203.0.113.55 10.20.0.0/16"
            read -r -a ADDRS -p "  Addresses (empty to cancel): "
            [ "${#ADDRS[@]}" -eq 0 ] && { echo "  Cancelled."; return 0; }
            for a in "${ADDRS[@]}"; do
                a="${a%,}"
                [ -z "$a" ] && continue
                if valid_rpc_addr "$a"; then
                    in_list "$a" "${GOOD[@]:-}" || GOOD+=("$a")
                else
                    echo -e "  ${RED}✗${NC} '$a' is not an IP address or CIDR range, skipping"
                fi
            done
            [ "${#GOOD[@]}" -eq 0 ] && { echo "  No valid address given, nothing changed."; return 1; }
            NEW="${GOOD[*]}"
            ;;
        3)
            echo -e "  ${YELLOW}!${NC} Every address on the internet can then try passwords against"
            echo "     /xmlrpc/2/common on every domain, throttled only by the general"
            echo "     rate limit. To open one tenant, use 1) Open RPC for domain(s)."
            read -r -p "  Open the RPC endpoints to everyone, on every domain? [y/N]: " C
            [[ "${C:-N}" =~ ^[Yy]$ ]] || { echo "  Cancelled."; return 0; }
            NEW="all"
            ;;
        b) return 0 ;;
        *) invalid_choice; return 0 ;;
    esac
    rpc_apply NGINX_RPC_ALLOW "$NEW"
}

rpc_apply() {  # rpc_apply KEY VALUE — nginx_setting_apply, then the RPC state
    local OPEN
    nginx_setting_apply "$1" "$2" || return 1
    echo -e "  ${GREEN}✓${NC} Server-wide default: $(rpc_state_text)"
    OPEN=$(rpc_open_domains 2>/dev/null)
    [ -n "$OPEN" ] && echo -e "  ${GREEN}✓${NC} Open per domain: $OPEN"
    return 0
}

# ── 13) Advanced ──────────────────────────────
menu_advanced() {
    echo -e "${CYAN}${BOLD}Advanced${NC}"
    echo ""
    echo -e "  ${YELLOW}!${NC} These act on the whole server, and the database tools delete data"
    echo "     permanently. Everything routine lives in the main menu."
    echo ""
    echo "  1) Services — Odoo start / stop / restart, nginx restart"
    echo "  2) Databases — backup / restore / delete / duplicate"
    echo "  3) Web database manager — enable/disable"
    echo "  4) RPC endpoints (/xmlrpc, /jsonrpc): block / allow"
    echo "  b) Back"
    echo "  x) Exit"
    ask_choice "1-4"
    case "$CHOICE" in
        1) menu_service ;;
        2) menu_db_admin ;;
        3) menu_db_manager ;;
        4) menu_rpc ;;
        b) return 0 ;;
        *) invalid_choice ;;
    esac
}

# ══════════════════════════════════════════════
# Developer menus (demo, dev, dev-multi)
# ══════════════════════════════════════════════

# One line per instance: state, port, branch, uncommitted work, last commit.
instances_table() {
    local n st dirty
    printf "  %-5s %-14s %-6s %-34s %-10s %s\n" "NAME" "STATE" "PORT" "BRANCH" "CHANGES" "LAST COMMIT"
    for n in "${INSTANCES[@]}"; do
        st=$(svc_detail "odoo_$n")
        dirty=$(inst_dirty_count "$n")
        if [ "$dirty" -gt 0 ]; then dirty="$dirty file(s)"; else dirty="clean"; fi
        printf "  %-5s %-14s %-6s %-34s %-10s %s\n" "$n" "$st" "$(inst_port "$n")" "$(inst_branch "$n")" "$dirty" "$(inst_last_commit "$n")"
    done
}

image_summary() {  # "abc123def456, built 2026-09-01" or "(not pulled yet)"
    docker image inspect -f '{{.Id}} created {{.Created}}' "$(stack_image)" 2>/dev/null \
        | sed 's/^sha256:\([0-9a-f]\{12\}\)[0-9a-f]* created \(..........\).*/\1, built \2/' \
        || echo "(not pulled yet)"
}

# ── 1) Status (developer) ─────────────────────
menu_status_local() {
    echo -e "${CYAN}${BOLD}Status${NC}   $(ephem_mode_label)"
    echo ""
    if [ "$EPHEM_MODE" = dev-multi ]; then
        instances_table
        echo ""
        echo "  Pinned: instance $EPHEM_INSTANCE  ($ADDONS_NAME, $ODOO_URL, database $ODOO_DB)"
    else
        echo "  Odoo:    $(svc_detail "$ODOO_SVC")   $ODOO_URL"
        if [ -d "$ADDONS_DIR/.git" ]; then
            echo "  Addons:  $ADDONS_NAME on $(git -C "$ADDONS_DIR" branch --show-current 2>/dev/null || echo '?')   ($(git -C "$ADDONS_DIR" log -1 --format='%h %ad' --date=short 2>/dev/null))"
        else
            echo "  Addons:  $ADDONS_NAME (not a git clone)"
        fi
    fi
    echo "  Postgres: $(svc_detail db)"
    echo ""
    echo -e "${BOLD}Databases:${NC}"
    local dbs; dbs=$(list_dbs)
    if [ -n "$dbs" ]; then echo "$dbs" | sed 's/^/  • /'; else echo "  (none, or database not running)"; fi
    echo ""
    echo -e "${BOLD}App image:${NC}  $(stack_image)  $(image_summary)"
    echo -e "${BOLD}Disk:${NC}"
    df -h / | tail -1 | awk '{printf "  root: %s used of %s (%s)\n", $3, $2, $5}'
    echo ""
    local LEFT; LEFT=$(stack_leftovers)
    if [ -n "$LEFT" ]; then
        echo -e "${BOLD}Leftovers from another mode:${NC}"
        echo "$LEFT" | sed 's/^/  ! /'
        [ "$EPHEM_MODE" = dev-multi ] && echo "  Remove them from the Stack menu (6)."
        echo ""
    fi
    echo -e "${BOLD}Last backup:${NC}"
    # shellcheck disable=SC2012
    ls -t backups/*.age backups/*.gz 2>/dev/null | head -1 | xargs -r ls -lh | awk '{print "  " $NF " (" $5 ", " $6 " " $7 " " $8 ")"}'
    [ -z "$(ls backups/*.age backups/*.gz 2>/dev/null)" ] && echo "  no whole-server backup yet (menu 10)"
    local snap; snap=$(snapshot_list | head -1)
    if [ -n "$snap" ]; then
        echo "  newest snapshot: ${snap##*/} ($(manifest_get "$snap" created))"
    else
        echo "  no per-database snapshots yet (Databases → Backup)"
    fi
    echo ""
    echo -e "${BOLD}Docs:${NC}  README.md here   ·   https://github.com/borse/ephem_deployment_docker#readme   ·   https://github.com/borse/ePHEM"
}

# ── 2) Switch instance (dev-multi) ────────────
menu_switch_instance() {
    echo -e "${CYAN}${BOLD}Switch instance${NC}"
    echo ""
    instances_table
    echo ""
    read -r -p "  Instance to work on [${INSTANCES[*]}] (empty to keep $EPHEM_INSTANCE): " N
    [ -z "${N:-}" ] && return 0
    if ! inst_index "$N" >/dev/null; then
        echo -e "  ${RED}✗${NC} No instance named '$N'. Configured: ${INSTANCES[*]}"
        return 1
    fi
    stack_use_instance "$N"
    stack_pin_instance "$N"
    FS_SVC_CACHE=()
    echo -e "  ${GREEN}✓${NC} Instance $N: $ADDONS_NAME on $(inst_branch "$N"), $ODOO_URL, database $ODOO_DB (remembered in .env)"
}

# ── 4) Restart + follow the log ───────────────
# scripts/dev-logs.sh is the same script PyCharm run configs use. Its tail
# ends with Ctrl-C, which brings the menu back.
menu_restart_logs_local() {
    echo -e "  ${CYAN}→${NC} bash scripts/dev-logs.sh ${EPHEM_INSTANCE:-}   (Ctrl-C ends the log tail and returns here)"
    echo ""
    run_interruptible bash scripts/dev-logs.sh ${EPHEM_INSTANCE:+"$EPHEM_INSTANCE"} || true
}

# ── 5) Update or install modules ──────────────
# Through scripts/dev-logs.sh: it stops the server, runs the one-shot
# odoo -u/-i, starts the server again and tails the log, which is where a
# failed update shows.
menu_modules_local() {
    echo -e "${CYAN}${BOLD}Update or install modules${NC}   ($ODOO_SVC, code from $ADDONS_NAME)"
    echo ""
    local db="$ODOO_DB" MODS="" FLAG="-u" n
    if [ -z "$db" ]; then
        echo "  Databases:"
        list_dbs | sed 's/^/    • /' | grep . || echo "    (none, or database not running)"
        read -r -p "  Database (empty to cancel): " db
        [ -z "${db:-}" ] && { echo "  Cancelled."; return 0; }
        valid_db_name "$db" || { echo -e "  ${RED}✗${NC} '$db' is not a valid database name."; return 1; }
    fi
    echo "  Database: $db"
    echo ""
    echo "  1) Update every ePHEM module installed on $db (eoc_*, ephem_*, cmp_*)"
    echo "  2) Update specific modules"
    echo "  3) Install a module"
    echo "  b) Back"
    echo "  x) Exit"
    ask_choice "1-3"
    case "$CHOICE" in
        1)
            MODS=$(compose exec -T db psql -U "$DB_USER" -d "$db" -t -A -c \
                "SELECT string_agg(name, ',' ORDER BY name) FROM ir_module_module
                  WHERE state = 'installed'
                    AND (name LIKE 'eoc\_%' OR name LIKE 'ephem\_%' OR name LIKE 'cmp\_%');" \
                </dev/null 2>/dev/null | tr -d '\r')
            if [ -z "$MODS" ]; then
                echo -e "  ${RED}✗${NC} No ePHEM modules installed on '$db', or the database is not reachable."
                return 1
            fi
            n=$(printf '%s' "$MODS" | tr ',' '\n' | grep -c .)
            echo "  $n module(s): $MODS" | fold -s -w 96 | sed '2,$s/^/     /'
            ;;
        2) read -r -p "  Modules to update, comma-separated: " MODS ;;
        3) read -r -p "  Module(s) to install, comma-separated: " MODS; FLAG="-i" ;;
        b) return 0 ;;
        *) invalid_choice; return 0 ;;
    esac
    MODS=$(printf '%s' "${MODS:-}" | tr -d ' ')
    [ -z "$MODS" ] && { echo "  Cancelled."; return 0; }
    if ! printf '%s' "$MODS" | grep -Eq '^[A-Za-z0-9_]+(,[A-Za-z0-9_]+)*$'; then
        echo -e "  ${RED}✗${NC} Module names: letters, digits and underscores, separated by commas."
        return 1
    fi
    echo ""
    echo -e "  ${CYAN}→${NC} bash scripts/dev-logs.sh ${EPHEM_INSTANCE:-} $FLAG $MODS -d $db   (Ctrl-C ends the log tail)"
    echo ""
    run_interruptible bash scripts/dev-logs.sh ${EPHEM_INSTANCE:+"$EPHEM_INSTANCE"} "$FLAG" "$MODS" -d "$db" || true
}

# ── 6) Stack: start / stop / recreate ─────────
menu_stack_local() {
    local what="Odoo"
    [ "$EPHEM_MODE" = dev-multi ] && what="instance $EPHEM_INSTANCE"
    echo -e "${CYAN}${BOLD}Stack${NC}"
    echo ""
    if [ "$EPHEM_MODE" = dev-multi ]; then
        instances_table
        echo ""
        echo "  Postgres (shared): $(svc_detail db)"
    else
        echo "  Odoo: $(svc_detail "$ODOO_SVC")      Postgres: $(svc_detail db)"
    fi
    echo ""
    echo "  1) Start $what                ($(compose_cmd_text) start $ODOO_SVC)"
    echo "  2) Stop $what                 ($(compose_cmd_text) stop $ODOO_SVC)"
    echo "  3) Restart $what, no log tail ($(compose_cmd_text) restart $ODOO_SVC)"
    if [ "$EPHEM_MODE" = dev-multi ]; then
        echo "  4) Recreate the whole stack from the roster   (bash scripts/dev-instances.sh up ${INSTANCES[*]})"
        echo "  5) Stop the whole stack, keep data            (bash scripts/dev-instances.sh down)"
        echo "  6) Clean up leftovers from single-instance mode"
        echo "  7) Change the roster: add or remove instances (bash scripts/dev-instances.sh up <names>)"
        echo "  8) Full reset: wipe every database and filestore, keep addons   (dev-instances.sh down -v)"
        echo "  b) Back"
        echo "  x) Exit"
        ask_choice "1-8"
    else
        echo "  4) Start everything                           ($(compose_cmd_text) up -d)"
        echo "  5) Stop everything, keep data                 ($(compose_cmd_text) down)"
        echo "  6) Full reset: wipe the database and filestore, keep addons   ($(compose_cmd_text) down -v)"
        echo "  b) Back"
        echo "  x) Exit"
        ask_choice "1-6"
    fi
    case "$CHOICE" in
        1)
            svc_start "$ODOO_SVC" || return 1
            wait_for_odoo
            ;;
        2)
            compose stop "$ODOO_SVC" && echo -e "  ${GREEN}✓${NC} $ODOO_SVC stopped (start it again with option 1)."
            ;;
        3)
            svc_restart "$ODOO_SVC" || return 1
            wait_for_odoo
            ;;
        4)
            if [ "$EPHEM_MODE" = dev-multi ]; then
                echo "  Regenerates docker-compose.dev-multi.yml and the odoo-N.conf files, then"
                echo "  recreates every container in the roster (the shared Postgres restarts"
                echo "  too). Databases, filestores and addons folders are kept."
                read -r -p "  Continue? [y/N]: " C
                [[ "${C:-N}" =~ ^[Yy]$ ]] || { echo "  Cancelled."; return 0; }
                bash scripts/dev-instances.sh up "${INSTANCES[@]}"
            else
                compose up -d && wait_for_odoo
            fi
            ;;
        5)
            read -r -p "  Stop every container (data is kept)? [y/N]: " C
            [[ "${C:-N}" =~ ^[Yy]$ ]] || { echo "  Cancelled."; return 0; }
            if [ "$EPHEM_MODE" = dev-multi ]; then
                bash scripts/dev-instances.sh down
            else
                compose down
            fi
            ;;
        6)
            if [ "$EPHEM_MODE" = dev-multi ]; then menu_stack_leftovers; else menu_stack_wipe; fi
            ;;
        7)
            [ "$EPHEM_MODE" = dev-multi ] || { invalid_choice; return 0; }
            menu_stack_roster
            ;;
        8)
            [ "$EPHEM_MODE" = dev-multi ] || { invalid_choice; return 0; }
            menu_stack_wipe
            ;;
        b) return 0 ;;
        *) invalid_choice ;;
    esac
}

# dev-multi: the single-instance override file and the ephem-app container
# from before the switch. Harmless until a plain `docker compose` loads them.
menu_stack_leftovers() {
    local LEFT; LEFT=$(stack_leftovers)
    if [ -z "$LEFT" ]; then echo -e "  ${GREEN}✓${NC} Nothing left over."; return 0; fi
    echo "$LEFT" | sed 's/^/  ! /'
    echo ""
    echo "  Removing them: the override file goes (setup.sh writes it again if you"
    echo "  ever go back to single-instance mode) and the ephem-app container is"
    echo "  deleted. Its data volume (odoo-data) is NOT touched."
    read -r -p "  Remove them? [y/N]: " C
    [[ "${C:-N}" =~ ^[Yy]$ ]] || { echo "  Cancelled."; return 0; }
    retire_single_override || true
    if docker container inspect ephem-app >/dev/null 2>&1; then
        docker rm -f ephem-app >/dev/null && echo -e "  ${GREEN}✓${NC} removed container ephem-app"
    fi
}

# dev-multi: the roster is whatever scripts/dev-instances.sh up was last
# given. A new list regenerates the compose file and the odoo-N.conf files
# and recreates the containers. An instance left out loses its container
# only: its database, data volume and odcaN/ folder stay on disk.
menu_stack_roster() {
    echo -e "${CYAN}${BOLD}Change the roster${NC}"
    echo ""
    instances_table
    echo ""
    echo "  Give the complete new list. Keep the existing names in their current"
    echo "  order: the position in the list gives the ports. A new name gets an"
    echo "  odcaN/ folder; add :branch to clone ePHEM into it (4:18_national_dev),"
    echo "  otherwise it starts empty. A name left out keeps its database, data"
    echo "  volume and folder, it just stops being part of the stack."
    echo ""
    read -r -p "  New roster [${INSTANCES[*]}] (Enter = cancel): " NEW
    [ -z "${NEW:-}" ] && { echo "  Cancelled."; return 0; }
    read -r -p "  Recreate the stack as: $NEW ? [y/N]: " C
    [[ "${C:-N}" =~ ^[Yy]$ ]] || { echo "  Cancelled."; return 0; }
    # shellcheck disable=SC2086  # the roster is a word list on purpose
    bash scripts/dev-instances.sh up $NEW || return 1
    # dev-instances.sh re-pins when the pinned instance left the roster.
    stack_init "$(env_get EPHEM_INSTANCE)" || echo -e "  ${YELLOW}!${NC} $STACK_ERROR"
    FS_SVC_CACHE=()
    echo -e "  ${GREEN}✓${NC} Roster is now: ${INSTANCES[*]}   (pinned: instance $EPHEM_INSTANCE)"
}

# The one place here that deletes data wholesale. Every other Stack item
# keeps the volumes; this drops all of them: every database and every
# filestore of this checkout. Addons folders are host folders and stay.
menu_stack_wipe() {
    local addons="custom-addons/" dbs CONF
    [ "$EPHEM_MODE" = dev-multi ] && addons="The odcaN/ folders"
    echo -e "${CYAN}${BOLD}Full reset${NC}"
    echo ""
    echo -e "  ${RED}Deletes every database and filestore of this checkout${NC} (the postgres-data"
    echo "  and odoo-data volumes). $addons stay as they are, and so does .env."
    echo ""
    echo -e "${BOLD}Databases that go:${NC}"
    dbs=$(list_dbs)
    if [ -n "$dbs" ]; then echo "$dbs" | sed 's/^/  • /'; else echo "  (none listed, or the database is not running)"; fi
    echo ""
    echo "  Take a backup first if any of them matters: main menu $(backup_item), or Databases → Backup."
    read -r -p "  Type RESET to continue, anything else cancels: " CONF
    [ "${CONF:-}" = RESET ] || { echo "  Cancelled."; return 0; }
    if [ "$EPHEM_MODE" = dev-multi ]; then
        bash scripts/dev-instances.sh down -v || return 1
    else
        compose down -v || return 1
    fi
    echo -e "  ${GREEN}✓${NC} Volumes wiped, addons untouched. Start fresh: Stack → 4, then create the databases again."
}

# ── 7) Pull the app image ─────────────────────
menu_image_local() {
    echo -e "${CYAN}${BOLD}Update the app image${NC}   $(stack_image)"
    echo ""
    echo "  Now:  $(image_summary)"
    echo ""
    echo "  Pulls the newest image and recreates the Odoo container(s) on it."
    echo "  Databases, filestores and addons folders are untouched."
    [ "$EPHEM_MODE" = dev-multi ] && \
        echo "  Every instance in the roster is recreated and started, including ones stopped on purpose."
    read -r -p "  Continue? [y/N]: " C
    [[ "${C:-N}" =~ ^[Yy]$ ]] || { echo "  Cancelled."; return 0; }
    # A wrong-architecture image (Apple Silicon) is fixed before the pull, and
    # a failed pull is explained (WSL credential helper, registry, network).
    ensure_native_image_arch
    echo -e "  ${CYAN}→${NC} $(compose_cmd_text) pull && $(compose_cmd_text) up -d"
    docker_pull_with_diagnosis || return 1
    compose up -d || { echo -e "  ${RED}✗${NC} See the output above."; return 1; }
    echo "  Now:  $(image_summary)"
    wait_for_odoo
    echo "  If the release includes module changes, run menu 5 next."
}

# ── 8) Doctor ─────────────────────────────────
# The tools first: a missing docker, compose, git or ssh, or a stopped
# daemon, explains most "nothing works" reports before any log is worth
# reading.
check_prereqs() {
    local ok=1
    echo -e "${CYAN}${BOLD}Prerequisites${NC}"
    if command -v docker >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} docker     $(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')"
    else
        echo -e "  ${RED}✗${NC} docker not found: install Docker Engine or Docker Desktop"; ok=0
    fi
    if docker compose version >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} compose    $(docker compose version --short 2>/dev/null)"
    else
        echo -e "  ${RED}✗${NC} docker compose v2 not found"; ok=0
    fi
    if command -v git >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} git        $(git --version 2>/dev/null | awk '{print $3}')"
    else
        echo -e "  ${RED}✗${NC} git not found"; ok=0
    fi
    if command -v ssh >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} ssh        present"
    else
        echo -e "  ${RED}✗${NC} ssh not found"; ok=0
    fi
    if docker info >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} daemon     responding"
    else
        echo -e "  ${RED}✗${NC} Docker daemon not responding: is Docker running?"; ok=0
    fi
    echo ""
    [ "$ok" -eq 1 ]
}

menu_doctor_local() {
    check_prereqs || echo -e "  ${YELLOW}!${NC} Fix the missing prerequisite first; the log scan below may be empty."
    stack_doctor "$ODOO_SVC"
}

# ── Main menu, developer ──────────────────────
menu_main_local() {
    local st what
    while true; do
        echo ""
        st=$(svc_detail "$ODOO_SVC")
        case "$st" in
            running)       st="${GREEN}running${NC}" ;;
            "not created") st="${YELLOW}not created${NC}" ;;
            *)             st="${RED}$st${NC}" ;;
        esac
        echo -e "${BOLD}ePHEM developer menu${NC}   $(ephem_mode_label)"
        if [ "$EPHEM_MODE" = dev-multi ]; then
            what="instance $EPHEM_INSTANCE"
            echo -e "  Instance ${BOLD}$EPHEM_INSTANCE${NC}: $ADDONS_NAME on $(inst_branch "$EPHEM_INSTANCE")   $ODOO_URL   ($st)"
        else
            what="Odoo"
            echo -e "  $ADDONS_NAME on $(git -C "$ADDONS_DIR" branch --show-current 2>/dev/null || echo '?')   $ODOO_URL   ($st)"
        fi
        echo ""
        printf "  1) %s\n" "Status"
        [ "$EPHEM_MODE" = dev-multi ] && \
        printf "  2) %-44s (%s)\n" "Switch instance" "bash manage.sh <name> does the same"
        if [ "$EPHEM_MODE" = dev-multi ]; then
        printf "  3) %-44s (%s)\n" "Addons: pull, switch branch, local changes" "asks which odcaN/ first"
        else
        printf "  3) %s\n" "Addons ($ADDONS_NAME): pull, switch branch, local changes"
        fi
        printf "  4) %-44s (%s)\n" "Restart $what and follow the log" "scripts/dev-logs.sh ${EPHEM_INSTANCE:-}"
        printf "  5) %-44s (%s)\n" "Update or install modules" "scripts/dev-logs.sh ${EPHEM_INSTANCE:-} -u ..."
        printf "  6) %s\n" "Stack: start, stop, recreate, leftovers"
        printf "  7) %s\n" "Pull the latest app image and recreate"
        printf "  8) %s\n" "Doctor: prerequisites, then scan the log for known errors"
        printf "  9) %s\n" "Databases: backup, restore, delete, duplicate, create"
        printf " 10) %-44s (%s)\n" "Back up everything now" "scripts/backup.sh"
        printf "  x) %s\n" "Exit"
        echo ""
        ask_choice "1-10" "x"
        case "$CHOICE" in
            1)  menu_status_local ;;
            2)  if [ "$EPHEM_MODE" = dev-multi ]; then menu_switch_instance; else invalid_choice; fi ;;
            3)  menu_addons ;;
            4)  menu_restart_logs_local ;;
            5)  menu_modules_local ;;
            6)  menu_stack_local ;;
            7)  menu_image_local ;;
            8)  menu_doctor_local ;;
            9)  menu_db_admin ;;
            10) bash scripts/backup.sh; echo ""; ls -lht backups/ 2>/dev/null | head -5 ;;
            b)  ;;
            *)  echo -e "${YELLOW}!${NC} Invalid choice: pick 1-10, or x to exit." ;;
        esac
    done
}

# ── Main menu, server ─────────────────────────
menu_main_server() {
    while true; do
        echo ""
        case "$(svc_state "$ODOO_SVC")" in
            running) STATE="${GREEN}running${NC}" ;;
            stopped) STATE="${RED}stopped${NC}" ;;
            *)       STATE="${YELLOW}not created${NC}" ;;
        esac
        echo -e "${BOLD}ePHEM production menu${NC}   ($STATE)"
        echo "  1) Status & health"
        echo "  2) Manage domains — add / remove / certificates"
        echo "  3) SSL — set up HTTPS / show status"
        echo "  4) Update the ePHEM app image"
        echo "  5) Custom addons — pull / switch branch"
        echo "  6) Update modules across databases"
        echo "  7) Back up now"
        echo "  8) Follow Odoo logs (Ctrl-C to stop)"
        echo "  9) Security check"
        echo " 10) Upload size limit (fix '413 Request Entity Too Large')"
        echo " 11) Advanced — service, databases, database manager, RPC endpoints"
        echo "  x) Exit"
        echo ""
        ask_choice "1-11" "x"
        case "$CHOICE" in
            1)  menu_status ;;
            2)  menu_domains ;;
            3)  menu_ssl ;;
            4)  menu_update_app ;;
            5)  menu_addons ;;
            6)  bash scripts/update-modules.sh ;;
            7)  bash scripts/backup.sh; echo ""; ls -lht backups/ 2>/dev/null | head -5 ;;
            8)  run_interruptible compose logs -f --tail=100 "$ODOO_SVC" || true ;;
            9)  menu_security ;;
            10) menu_upload_limit ;;
            11) menu_advanced ;;
            0)  echo "Bye. Re-open anytime:  bash manage.sh"; exit 0 ;;   # old habit, still works
            b)  ;;
            *)  echo -e "${YELLOW}!${NC} Invalid choice: pick 1-11, or x to exit." ;;
        esac
    done
}

# ── Menu loop ─────────────────────────────────
if local_mode; then
    menu_main_local
else
    menu_main_server
fi
