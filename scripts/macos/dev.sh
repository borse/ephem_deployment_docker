#!/bin/bash
# ──────────────────────────────────────────────────────────────
# dev.sh — the native macOS counterpart of scripts/dev-instances.sh:
# several Odoo dev servers side by side, running straight on the Mac,
# all sharing ONE Postgres (Homebrew, postgresql@16) with SEPARATE
# databases. Set up once by scripts/macos/install.sh (bash setup.sh →
# Developer → Native).
#
# Instance N gets:
#   • its own port                 80N0 (8010, 8020, 8030, …)
#   • its own folder               odcaN/: ePHEM-core/ (a git worktree of the
#                                  ePHEM clone) plus any repository added next
#                                  to it (dev.sh repo add N …), as in Docker
#   • its own odoo config          conf/odoo-N.conf
#   • its own database + filestore ephem_N, data/N/
#   • its own log                  logs/odoo-N.log
#
# Usage:
#   bash scripts/macos/dev.sh new                   # add an instance: asks number, branch, database
#   bash scripts/macos/dev.sh remove N              # delete an instance: database, files, folder (asks first)
#   bash scripts/macos/dev.sh create N [BRANCH]     # the same as new, without questions: odcaN/ePHEM-core + config (default branch: 18_ephem_2)
#   bash scripts/macos/dev.sh initdb N [MODULES]    # create database ephem_N (base, plus MODULES)
#   bash scripts/macos/dev.sh start|stop|restart N  # N, several N, or all
#   bash scripts/macos/dev.sh status                # ports, databases, branches, health
#   bash scripts/macos/dev.sh logs N                # follow one instance
#   bash scripts/macos/dev.sh update N [MODULES]    # -u MODULES (default: every ePHEM module), then start again
#   bash scripts/macos/dev.sh install N MODULES     # -i MODULES, then start again
#   bash scripts/macos/dev.sh shell N               # Odoo shell on ephem_N
#   bash scripts/macos/dev.sh switch N BRANCH       # move odcaN/ePHEM-core to another branch
#   bash scripts/macos/dev.sh repo add N REPO [BRANCH]  # clone another addon repository into odcaN/ (owner/name, or a git URL)
#   bash scripts/macos/dev.sh repo list [N]         # each instance's repositories: branch, modules, state
#   bash scripts/macos/dev.sh repo pull N [NAME]    # pull ePHEM-core and the instance's repositories (fast-forward only)
#   bash scripts/macos/dev.sh repo switch N NAME BRANCH  # move one added repository to another branch
#   bash scripts/macos/dev.sh repo remove N NAME    # delete an added repository (asks first)
#   bash scripts/macos/dev.sh migrate [N|all]       # move instances of the old layout (odcaN/ = the worktree) into odcaN/ePHEM-core/
#   bash scripts/macos/dev.sh fetch                 # fetch every branch from origin (one fetch serves all instances)
#   bash scripts/macos/dev.sh backup N              # pg_dump + filestore into backups/
#   bash scripts/macos/dev.sh restore N [SOURCE]    # replace ephem_N from a backup (asks first)
#   bash scripts/macos/dev.sh conf N                # write conf/odoo-N.conf again (the old one is kept as .bak)
#   bash scripts/macos/dev.sh office start|stop|status   # optional document converter (a Docker container)
#   bash scripts/macos/dev.sh list | menu | help
#
# Branches. One clone (ePHEM/) and one worktree per instance share a single
# .git, and git refuses to check the same branch out twice. So instance N on
# BRANCH works on its own local branch, odcaN/BRANCH (in odcaN/ePHEM-core), which tracks
# origin/BRANCH: three instances can all follow 18_ephem_2, each commits on
# its own branch, and every worktree sees the others' branches at once (no
# push, no fetch). docs/macos-native-dev.md has the merge-back steps.
# ──────────────────────────────────────────────────────────────
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

ME="bash scripts/macos/dev.sh"

need_install() {
    native_installed || die "No native setup found in $NATIVE_HOME. Run: bash setup.sh  (Developer → Native), or bash scripts/macos/install.sh"
    native_env || die "Homebrew is not installed. Run: bash scripts/macos/install.sh"
}

need_n() {  # need_n N VERB
    valid_n "${1:-}" || die "Usage: $ME $2 N   (N is an instance number, 1 to 9)"
}

need_instance() {  # the instance exists (config + ePHEM-core worktree, new layout)
    need_n "$1" "$2"
    [ -f "$(inst_conf "$1")" ] || die "Instance $1 has no config yet. Create it: $ME create $1"
    [ -d "$(inst_dir "$1")" ] || die "$(inst_dir "$1") is missing. Create it again: $ME create $1"
    if inst_old_layout "$1"; then
        die "odca$1/ still has the old layout (odca$1/ itself is the ePHEM worktree). Move it into odca$1/$CORE_NAME/ first: $ME migrate $1"
    fi
    [ -e "$(inst_core "$1")/.git" ] || die "$(inst_core "$1") is missing. Create it again: $ME create $1"
}

# "all", or nothing at all, means every instance; else the numbers given.
resolve_targets() {  # resolve_targets VERB [N…|all] → TARGETS
    local verb="$1"; shift
    TARGETS=()
    if [ $# -eq 0 ] || [ "$1" = all ]; then
        local n; while IFS= read -r n; do [ -n "$n" ] && TARGETS+=("$n"); done < <(instances)
        [ "${#TARGETS[@]}" -gt 0 ] || die "No instance yet. Create one: $ME create 1"
        return 0
    fi
    local n
    for n in "$@"; do need_instance "$n" "$verb"; TARGETS+=("$n"); done
}

db_exists() { [ "$("$PG_BIN/psql" -X -d postgres -Atc "SELECT 1 FROM pg_database WHERE datname = '$1'" 2>/dev/null)" = 1 ]; }

need_pg() {
    pg_ready && return 0
    die "Postgres does not answer on 127.0.0.1:$(db_port). Start it: brew services start $PG_FORMULA"
}

# ── Git ───────────────────────────────────────
core_git() { git -C "$CORE_CLONE" "$@"; }

# A clone made with --single-branch only ever sees that one branch. Make the
# fetch refspec the full one, so `git fetch` brings every branch of origin.
fix_refspec() {
    local want="+refs/heads/*:refs/remotes/origin/*"
    if [ "$(core_git config --get-all remote.origin.fetch 2>/dev/null)" != "$want" ]; then
        core_git config remote.origin.fetch "$want"
        ok "origin now tracks every branch (the fetch refspec was narrower)"
    fi
}

# The ePHEM worktree of instance N: odcaN/ePHEM-core, or odcaN itself while
# the instance has the old layout (so status still reads it before migrate).
inst_wt() { if inst_old_layout "$1"; then inst_dir "$1"; else inst_core "$1"; fi; }

inst_branch() {
    local b; b=$(git -C "$(inst_wt "$1")" branch --show-current 2>/dev/null) || b=""
    echo "${b:-(detached)}"
}

# The origin branch instance N follows: odcaN/18_ephem_2 → 18_ephem_2.
inst_base() { local b; b="$(inst_branch "$1")"; echo "${b#odca$1/}"; }

# "2 ahead, 1 behind" of the branch this worktree tracks, from what the last
# fetch learned (no network).
inst_sync() { repo_sync "$(inst_wt "$1")"; }

repo_sync() {  # repo_sync DIR
    local d="$1" a b
    git -C "$d" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1 || { echo "no upstream"; return 0; }
    a=$(git -C "$d" rev-list --count '@{upstream}..HEAD' 2>/dev/null || echo 0)
    b=$(git -C "$d" rev-list --count 'HEAD..@{upstream}' 2>/dev/null || echo 0)
    if [ "$a" = 0 ] && [ "$b" = 0 ]; then echo "up to date"
    elif [ "$b" = 0 ]; then echo "$a ahead"
    elif [ "$a" = 0 ]; then echo "$b behind"
    else echo "$a ahead, $b behind"; fi
}

inst_dirty() { repo_dirty "$(inst_wt "$1")"; }
repo_dirty() { [ -n "$(git -C "$1" status --porcelain 2>/dev/null)" ]; }
repo_branch() { local b; b=$(git -C "$1" branch --show-current 2>/dev/null) || b=""; echo "${b:-(detached)}"; }
# Commits in DIR that no remote branch has (lost if the folder is deleted).
repo_unpushed() { git -C "$1" rev-list --count HEAD --not --remotes 2>/dev/null || echo 0; }
module_count() { local m c=0; for m in "$1"/*/__manifest__.py; do [ -f "$m" ] && c=$((c + 1)); done; echo "$c"; }
module_names() { local m out=""; for m in "$1"/*/__manifest__.py; do [ -f "$m" ] && out="$out,$(basename "$(dirname "$m")")"; done; echo "${out#,}"; }

# Put instance N on BASE: its own local branch odcaN/BASE, created from
# origin/BASE and tracking it the first time, simply checked out afterwards
# (what was committed on it earlier is still there).
checkout_instance_branch() {  # checkout_instance_branch N BASE
    local n="$1" base="$2" dir local_branch
    dir="$(inst_core "$n")"; local_branch="odca$n/$base"
    core_git rev-parse --verify -q "refs/remotes/origin/$base" >/dev/null \
        || die "origin has no branch '$base' (after a fetch). See them: git -C $CORE_CLONE branch -r"
    if [ ! -d "$dir" ]; then
        mkdir -p "$(inst_dir "$n")"
        core_git worktree prune
        if core_git rev-parse --verify -q "refs/heads/$local_branch" >/dev/null; then
            core_git worktree add "$dir" "$local_branch"
        else
            core_git worktree add --track -b "$local_branch" "$dir" "origin/$base"
        fi
    elif core_git rev-parse --verify -q "refs/heads/$local_branch" >/dev/null; then
        git -C "$dir" switch "$local_branch"
    else
        git -C "$dir" switch --track -c "$local_branch" "origin/$base"
    fi
}

# ── CLAUDE.md per instance ────────────────────
# What an AI coding agent started in odcaN/ (or in a repository inside it)
# has to know: which instance this is and how to stay inside it. It sits in
# odcaN/ itself, outside every repository, so nothing has to keep it out of
# git; Claude Code reads the CLAUDE.md of the folders above where it starts.
AGENT_MARK="<!-- generated by scripts/macos/dev.sh: edits are lost when the instance is created, switched or its repositories change -->"
OLD_AGENT_MARK="<!-- generated by scripts/macos/dev.sh: edits are lost"

write_agent_file() {  # write_agent_file N
    local n="$1" dir core file cur up r repos="" f
    dir="$(inst_dir "$n")"; core="$(inst_core "$n")"
    cur="$(inst_branch "$n")"
    up="$(git -C "$core" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || true)"
    file="$dir/CLAUDE.md"
    if [ -f "$file" ] && ! grep -qF "$OLD_AGENT_MARK" "$file"; then
        warn "$file exists and was not written by dev.sh: left as it is"
        return 0
    fi
    # The copy an older dev.sh wrote inside the worktree: replaced by this one.
    for f in CLAUDE.md CLAUDE.local.md; do
        if [ -f "$core/$f" ] && grep -qF "$OLD_AGENT_MARK" "$core/$f"; then rm -f "$core/$f"; fi
    done
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        repos="$repos
| \`$r/\` | $(git -C "$dir/$r" remote get-url origin 2>/dev/null || echo 'no remote'), branch \`$(repo_branch "$dir/$r")\`, $(module_count "$dir/$r") module(s) |"
    done < <(inst_repos "$n")
    cat > "$file" <<EOF
$AGENT_MARK
# ePHEM dev instance $n (native macOS)

You are working in **instance $n** of a multi-instance Odoo 18 developer setup.
Other instances (other \`odcaN/\` folders next to this one) belong to other agents.

| | |
|---|---|
| Instance | $n |
| This folder | \`$dir\` |
| URL | $(inst_url "$n") (login of a new database: admin / admin) |
| Database | \`$(inst_db "$n")\` |
| Config | \`$(inst_conf "$n")\` |
| Log | \`$(inst_log "$n")\` |
| Odoo source (read only) | \`$ODOO_SRC\` (branch $ODOO_BRANCH) |
| Python | \`$PY\` |

Repositories in this folder (Odoo's addons path, in this order; on a module
name clash the first one wins):

| Folder | What |
|---|---|
| \`$CORE_NAME/\` | ePHEM, a git worktree of \`$CORE_CLONE\`: branch \`$cur\`, tracking \`${up:-nothing}\` |$repos

## Commands

Run them from anywhere. \`logs\` follows the file until Ctrl+C: to read the
log, use \`tail\` on it instead.

\`\`\`bash
bash $MAC_DIR/dev.sh status                 # every instance: port, database, branch, running or not
bash $MAC_DIR/dev.sh restart $n              # restart this instance
bash $MAC_DIR/dev.sh update $n eoc_base      # update modules (-u) on $(inst_db "$n"), then start again
bash $MAC_DIR/dev.sh update $n               # update every module of this instance's repositories
bash $MAC_DIR/dev.sh install $n my_module    # install a module that is not installed yet
bash $MAC_DIR/dev.sh shell $n                # Odoo shell on $(inst_db "$n") (reads a script from stdin too)
bash $MAC_DIR/dev.sh repo list $n            # the repositories of this instance
tail -n 200 $(inst_log "$n")
\`\`\`

Odoo runs with \`--dev=$(dev_flags)\`: a saved Python file restarts the server
by itself, and XML views are read from disk. A new field, a changed model, a
new file in a manifest or changed data still need \`update $n MODULE\`.

## Rules

- Work only in this folder and only on database \`$(inst_db "$n")\`. Never start, stop,
  update, restore or edit another instance (\`odca<other>/\`, \`ephem_<other>\`).
- Do not edit \`$ODOO_SRC\`, the virtualenv, or \`$CORE_CLONE\`.
- In \`$CORE_NAME/\`, commit on the current branch (\`$cur\`). It is local to this
  instance: do not push it, and do not merge into or push the base branch, unless
  the developer asks. Do not run \`git switch\`/\`git checkout\` to another branch
  there; changing branch is \`dev.sh switch $n BRANCH\`, and the developer decides it.
- The other repositories here are ordinary clones on a shared branch: commit
  there only when asked, and never push unless the developer asks. Adding or
  removing one is \`dev.sh repo add|remove $n …\`, decided by the developer.
- Do not run \`git worktree\`, \`git gc --prune\` or \`git stash drop/clear\` in
  \`$CORE_NAME/\`: its object store is shared with the other instances.
EOF
    ok "CLAUDE.md written in odca$n/"
}

# ── Config ────────────────────────────────────
write_conf() {  # write_conf N
    local n="$1" conf
    conf="$(inst_conf "$n")"
    mkdir -p "$CONF_DIR" "$LOG_DIR" "$RUN_DIR" "$(inst_data "$n")"
    ( umask 077; cat > "$conf" <<CONF
[options]
; AUTO-GENERATED by scripts/macos/dev.sh for native instance $n.
; Written again by:  $ME conf $n   (the previous file is kept as .bak)
; All instances share one Postgres; this one is pinned to database $(inst_db "$n").

admin_passwd = $(admin_passwd)

; $CORE_NAME first, then this instance's other repositories (odca$n/*), then
; extra-addons/*, then Odoo's own addons. dev.sh repo add/remove rewrites it.
addons_path = $(inst_addons_path "$n")
data_dir = $(inst_data "$n")

; Listens on this Mac only. For the LAN: BIND_HOST=0.0.0.0 in conf/native.env,
; then $ME conf $n and restart.
http_interface = $(bind_host)
http_port = $(inst_port "$n")
gevent_port = $(inst_gevent "$n")
proxy_mode = False

; The app role (LOGIN CREATEDB, no superuser). Its password is not here: the
; launcher exports PGPASSWORD from conf/native.env.
db_host = 127.0.0.1
db_port = $(db_port)
db_user = $(db_user)
db_password = False
db_name = False
; Pin this instance to its own database so you can't log into the wrong one.
dbfilter = ^$(inst_db "$n")\$
list_db = True

; workers=0 = threading mode, required for --dev=reload
workers = 0
max_cron_threads = 1

logfile = $(inst_log "$n")
log_level = $(log_level)
CONF
    )
}

cmd_conf() {
    need_install
    need_n "${1:-}" conf
    local conf; conf="$(inst_conf "$1")"
    [ -e "$(inst_wt "$1")/.git" ] || die "$(inst_core "$1") is missing. Create the instance: $ME create $1"
    if [ -f "$conf" ]; then cp -p "$conf" "$conf.bak"; fi
    write_conf "$1"
    ok "$conf written$( [ -f "$conf.bak" ] && echo " (previous: $conf.bak)")"
    if [ -n "$(inst_pid "$1")" ]; then echo "  Restart to apply: $ME restart $1"; fi
}

# ── create ────────────────────────────────────
cmd_create() {
    need_install
    need_n "${1:-}" "create"
    local n="$1" base="${2:-$DEFAULT_BRANCH}" core conf
    core="$(inst_core "$n")"; conf="$(inst_conf "$n")"
    [ -d "$CORE_CLONE/.git" ] || die "$CORE_CLONE is not a clone yet. Run: bash scripts/macos/install.sh"

    step "Instance $n → $(inst_url "$n")  (db: $(inst_db "$n"), branch: $base)"
    # An instance of the old layout (install.sh run again over it): moved first.
    if inst_old_layout "$n"; then migrate_one "$n"; fi
    if [ -e "$core/.git" ]; then
        ok "odca$n/$CORE_NAME/ already there (branch: $(inst_branch "$n")): left as it is"
        if [ -n "${2:-}" ] && [ "$(inst_branch "$n")" != "odca$n/$base" ]; then
            echo "  To move it to $base:  $ME switch $n $base"
        fi
    elif [ -n "$(ls -A "$core" 2>/dev/null)" ]; then
        die "$core has files but is not a worktree of $CORE_CLONE: move it away first."
    else
        fix_refspec
        echo "  Fetching $base from origin…"
        core_git fetch origin "$base" || die "Could not fetch '$base' from origin (does it exist? SSH access?)"
        checkout_instance_branch "$n" "$base"
        ok "odca$n/$CORE_NAME/ is a worktree on its own branch odca$n/$base (tracks origin/$base)"
    fi

    if [ -f "$conf" ]; then
        ok "conf/odoo-$n.conf already there: left as it is  (write it again: $ME conf $n)"
    else
        write_conf "$n"
        ok "conf/odoo-$n.conf written (port $(inst_port "$n"), db $(inst_db "$n"))"
    fi
    write_agent_file "$n"
    if [ "${CREATE_HINT:-1}" = 1 ] && pg_ready && ! db_exists "$(inst_db "$n")"; then
        echo ""
        echo "  Next:  $ME initdb $n     (creates database $(inst_db "$n"); once)"
        echo "         $ME start $n"
    fi
}

# ── Running Odoo ──────────────────────────────
# The office converter the instances talk to (see cmd_office): on only when
# OFFICE=1 is recorded in conf/native.env.
odoo_env() {
    # Colored log levels, as the Docker dev stack does (ODOO_PY_COLORS=1 in
    # the compose override): Odoo then colors logs/odoo-N.log too, not only
    # a terminal, so `logs N` looks like scripts/dev-logs.sh. ODOO_PY_COLORS=
    # (set but empty) in the environment turns it off.
    export ODOO_PY_COLORS="${ODOO_PY_COLORS-1}"
    if [ "$(nenv_get OFFICE)" = 1 ]; then
        export EPHEM_OFFICE_URL="http://127.0.0.1:2003" EPHEM_OFFICE_CONVERTER=1
    else
        export EPHEM_OFFICE_CONVERTER=0
    fi
}

odoo_bin() {  # odoo_bin N ARGS…   (foreground)
    local n="$1"; shift
    odoo_env
    "$PY" "$ODOO_SRC/odoo-bin" "$@" -c "$(inst_conf "$n")"
}

start_one() {
    local n="$1" pid owner port log
    port="$(inst_port "$n")"; log="$(inst_log "$n")"
    pid="$(inst_pid "$n")"
    if [ -n "$pid" ]; then ok "instance $n already running (pid $pid) → $(inst_url "$n")"; return 0; fi
    for port in "$(inst_port "$n")" "$(inst_gevent "$n")"; do
        owner="$(port_owner "$port")"
        if [ -n "$owner" ]; then
            err "instance $n: port $port is taken by another program (pid and name: $owner)."
            echo "  The Docker instances use the same ports: stop them first (bash scripts/dev-instances.sh down)." >&2
            return 1
        fi
    done
    db_exists "$(inst_db "$n")" || warn "database $(inst_db "$n") does not exist yet: $ME initdb $n  (or create it in the browser)"
    mkdir -p "$LOG_DIR" "$RUN_DIR"
    odoo_env
    # A session of its own, so closing the terminal does not take Odoo with
    # it. Python does it (os.setsid, then exec): no nohup in between, which
    # would drop DYLD_FALLBACK_LIBRARY_PATH (see lib.sh). The pid stays the
    # same across the exec and across --dev=reload restarts.
    # shellcheck disable=SC2016
    "$PY" -c 'import os, sys; os.setsid(); os.execv(sys.argv[1], sys.argv[1:])' \
        "$PY" "$ODOO_SRC/odoo-bin" -c "$(inst_conf "$n")" --dev="$(dev_flags)" \
        >> "$log" 2>&1 < /dev/null &
    echo $! > "$(inst_pidf "$n")"
    local i
    for i in $(seq 1 60); do
        if [ -z "$(inst_pid "$n")" ]; then
            err "instance $n stopped right after starting. Last lines of $log:"
            tail -n 25 "$log" >&2 || true
            return 1
        fi
        if curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:$(inst_port "$n")/web/health" 2>/dev/null; then
            ok "instance $n running (pid $(inst_pid "$n")) → $(inst_url "$n")"
            return 0
        fi
        sleep 1
    done
    warn "instance $n started (pid $(inst_pid "$n")) but does not answer yet: $ME logs $n"
}

stop_one() {
    local n="$1" pid i
    pid="$(inst_pid "$n")"
    if [ -z "$pid" ]; then echo "  instance $n is not running"; rm -f "$(inst_pidf "$n")"; return 0; fi
    kill -TERM "$pid" 2>/dev/null || true
    for i in $(seq 1 20); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || true
        sleep 0.5
    fi
    rm -f "$(inst_pidf "$n")"
    ok "instance $n stopped"
}

cmd_start()   { need_install; need_pg; resolve_targets start "$@"; local n rc=0; for n in "${TARGETS[@]}"; do start_one "$n" || rc=1; done; return $rc; }
cmd_stop()    { need_install; resolve_targets stop "$@"; local n; for n in "${TARGETS[@]}"; do stop_one "$n"; done; }
cmd_restart() { need_install; need_pg; resolve_targets restart "$@"; local n rc=0; for n in "${TARGETS[@]}"; do stop_one "$n"; start_one "$n" || rc=1; done; return $rc; }

# ── status ────────────────────────────────────
cmd_status() {
    need_install
    local n pid state db any=0
    echo -e "${CYAN}${BOLD}Native instances${NC}  ($NATIVE_HOME)"
    if pg_ready; then
        echo -e "  Postgres: ${GREEN}running${NC} on 127.0.0.1:$(db_port)  ($("$PG_BIN/postgres" --version 2>/dev/null | awk '{print $3}'), role $(db_user))"
    else
        echo -e "  Postgres: ${RED}not answering${NC} on 127.0.0.1:$(db_port)   (brew services start $PG_FORMULA)"
    fi
    echo ""
    printf '  %-3s %-24s %-9s %-34s %-18s %s\n' N URL DB BRANCH ORIGIN STATE
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        any=1
        pid="$(inst_pid "$n")"
        if [ -n "$pid" ]; then
            if curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:$(inst_port "$n")/web/health" 2>/dev/null; then
                state="${GREEN}running${NC} (pid $pid)"
            else
                state="${YELLOW}starting or not answering${NC} (pid $pid)"
            fi
        else
            state="stopped"
        fi
        db="$(inst_db "$n")"
        if pg_ready && ! db_exists "$db"; then db="$db?"; fi
        printf '  %-3s %-24s %-9s %-34s %-18s %b\n' "$n" "$(inst_url "$n")" "$db" \
            "$(inst_branch "$n")$(inst_dirty "$n" && echo ' *')" "$(inst_sync "$n")" "$state"
        if inst_old_layout "$n"; then
            echo -e "      ${YELLOW}old layout${NC}: odca$n/ is the worktree itself. Move it into odca$n/$CORE_NAME/: $ME migrate $n"
        fi
        local r rd
        while IFS= read -r r; do
            [ -n "$r" ] || continue
            rd="$(inst_dir "$n")/$r"
            printf '      + %-30s %-34s %s\n' "$r/" "$(repo_branch "$rd")$(repo_dirty "$rd" && echo ' *')" "$(repo_sync "$rd")"
        done < <(inst_repos "$n")
    done < <(instances)
    if [ "$any" = 0 ]; then
        echo "  (none yet)   $ME create 1"
        return 0
    fi
    echo ""
    echo "  * = uncommitted changes   ? = database not created yet ($ME initdb N)   + = a repository next to $CORE_NAME"
    echo "  ORIGIN compares with the tracked branch as of the last fetch ($ME fetch)."
    if [ "$(nenv_get OFFICE)" = 1 ]; then echo "  Document converter: on (http://127.0.0.1:2003, $ME office status)"; fi
}

cmd_list() {
    need_install
    local n
    while IFS= read -r n; do [ -n "$n" ] && echo "  • $n → $(inst_url "$n")   (db: $(inst_db "$n"), folder: odca$n/, branch: $(inst_branch "$n"))"; done < <(instances)
}

cmd_logs() {
    need_install
    need_instance "${1:-}" logs
    [ -f "$(inst_log "$1")" ] || die "No log yet: instance $1 has never been started."
    exec tail -n 100 -F "$(inst_log "$1")"
}

# ── Modules ───────────────────────────────────
# What a routine update covers, as in scripts/stack-lib.sh
# (addons_update_modules): the eoc_*, ephem_* and cmp_* modules of
# ePHEM-core, and every module of the instance's other repositories and of a
# repository under extra-addons/. Odoo skips the names that are not installed
# in the database.
default_modules() {
    local n="$1" d m r core out=""
    core="$(inst_core "$n")"
    for m in "$core"/eoc_*/ "$core"/ephem_*/ "$core"/cmp_*/; do
        [ -f "$m/__manifest__.py" ] && out="$out,$(basename "$m")"
    done
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        for m in "$(inst_dir "$n")/$r"/*/; do
            [ -f "$m/__manifest__.py" ] && out="$out,$(basename "$m")"
        done
    done < <(inst_repos "$n")
    for d in "$EXTRA_ADDONS"/*/; do
        [ -d "$d" ] || continue
        for m in "$d"*/; do
            [ -f "$m/__manifest__.py" ] && out="$out,$(basename "$m")"
        done
    done
    echo "${out#,}"
}

# One odoo-bin run that stops when it is done, shown on screen and appended
# to the instance's log.
run_once() {  # run_once N ARGS…
    local n="$1" rc=0; shift
    set +e
    odoo_bin "$n" "$@" --logfile= --stop-after-init 2>&1 | tee -a "$(inst_log "$n")"
    rc=${PIPESTATUS[0]}
    set -e
    return "$rc"
}

cmd_initdb() {
    need_install; need_pg
    need_instance "${1:-}" initdb
    local n="$1" mods="base${2:+,$2}" db
    db="$(inst_db "$n")"
    if db_exists "$db"; then
        die "Database $db already exists. Install modules into it with: $ME update $n  (or -i from the Apps menu). To start over, drop it yourself: dropdb $db"
    fi
    local was=""; was="$(inst_pid "$n")"
    [ -n "$was" ] && stop_one "$n"
    step "Creating database $db (modules: $mods, no demo data). Login afterwards: admin / admin"
    mkdir -p "$LOG_DIR"
    if run_once "$n" -d "$db" -i "$mods" --without-demo=all; then
        ok "database $db created"
    else
        die "initdb failed: see the output above (also in $(inst_log "$n"))"
    fi
    if [ -n "$was" ]; then start_one "$n"; fi
}

# update N [MODULES] (-u) and install N MODULES (-i): stop the instance, one
# odoo-bin run on its database, start it again if it was running.
modules_run() {  # modules_run -u|-i N MODULES
    local flag="$1" n="$2" mods="$3" db was word rc=0
    db="$(inst_db "$n")"
    if [ "$flag" = -i ]; then word="install"; else word="update"; fi
    db_exists "$db" || die "Database $db does not exist yet: $ME initdb $n"
    was="$(inst_pid "$n")"
    [ -n "$was" ] && stop_one "$n"
    step "$word on $db: $mods"
    run_once "$n" -d "$db" "$flag" "$mods" || rc=$?
    if [ "$rc" -eq 0 ]; then ok "$word finished"; else err "$word failed (exit $rc): see the output above (also in $(inst_log "$n"))"; fi
    if [ -n "$was" ]; then start_one "$n" || rc=1; else echo "  Instance $n was not running and is left stopped: $ME start $n"; fi
    return "$rc"
}

cmd_update() {
    need_install; need_pg
    need_instance "${1:-}" update
    local mods="${2:-}"
    [ -n "$mods" ] || mods="$(default_modules "$1")"
    [ -n "$mods" ] || die "No ePHEM module found in $(inst_dir "$1")/."
    modules_run -u "$1" "$mods"
}

cmd_install() {
    need_install; need_pg
    need_instance "${1:-}" install
    [ -n "${2:-}" ] || die "Usage: $ME install N MODULES   (comma-separated, e.g. eoc_base,eoc_signals)"
    modules_run -i "$1" "$2"
}

cmd_shell() {
    need_install; need_pg
    need_instance "${1:-}" shell
    local n="$1"; shift
    odoo_env
    exec "$PY" "$ODOO_SRC/odoo-bin" shell -c "$(inst_conf "$n")" -d "$(inst_db "$n")" --no-http --logfile= "$@"
}

# ── switch, fetch ─────────────────────────────
cmd_switch() {
    need_install
    need_instance "${1:-}" switch
    local n="$1" base="${2:-}"
    [ -n "$base" ] || die "Usage: $ME switch N BRANCH   (a branch of origin, e.g. $DEFAULT_BRANCH)"
    base="${base#origin/}"
    if inst_dirty "$n"; then
        err "odca$n/$CORE_NAME has uncommitted changes: commit or stash them first."
        git -C "$(inst_core "$n")" status --short | head -20 >&2
        exit 1
    fi
    local from; from="$(inst_branch "$n")"
    fix_refspec
    echo "  Fetching $base from origin…"
    core_git fetch origin "$base" || die "Could not fetch '$base' from origin (does it exist?)"
    checkout_instance_branch "$n" "$base"
    ok "odca$n/$CORE_NAME: $from → odca$n/$base (tracks origin/$base). Commits on $from stay on that branch."
    write_agent_file "$n"
    echo ""
    echo "  A different branch usually means different models: update the database next."
    echo "    $ME update $n"
}

cmd_fetch() {
    need_install
    [ -d "$CORE_CLONE/.git" ] || die "$CORE_CLONE is not a clone."
    fix_refspec
    echo "  Fetching every branch from origin (one fetch serves every instance)…"
    core_git fetch --prune origin
    ok "fetched"
    local n r rd
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        echo "  • odca$n  $(inst_branch "$n"): $(inst_sync "$n")"
        while IFS= read -r r; do
            [ -n "$r" ] || continue
            rd="$(inst_dir "$n")/$r"
            git -C "$rd" fetch --prune --quiet origin 2>/dev/null || warn "odca$n/$r: fetch failed"
            echo "      + $r  $(repo_branch "$rd"): $(repo_sync "$rd")"
        done < <(inst_repos "$n")
    done < <(instances)
    echo ""
    echo "  Bring an instance up to date with what it tracks:  $ME repo pull N"
}

# ── backup, restore ───────────────────────────
filestore_dir() { echo "$(inst_data "$1")/filestore/$(inst_db "$1")"; }

cmd_backup() {
    need_install; need_pg
    need_instance "${1:-}" backup
    local n="$1" db dest fs
    db="$(inst_db "$n")"; fs="$(filestore_dir "$n")"
    db_exists "$db" || die "Database $db does not exist: nothing to back up."
    dest="$BACKUP_DIR/${db}_$(date +%Y%m%d-%H%M%S)"
    ( umask 077; mkdir -p "$dest" )
    step "Backing up $db → $dest"
    "$PG_BIN/pg_dump" -Fc --no-owner -d "$db" -f "$dest/db.dump"
    ok "db.dump ($(du -h "$dest/db.dump" | awk '{print $1}'))"
    if [ -d "$fs" ]; then
        tar -czf "$dest/filestore.tar.gz" -C "$fs" .
        ok "filestore.tar.gz ($(du -h "$dest/filestore.tar.gz" | awk '{print $1}'))"
    else
        echo "  (no filestore yet: nothing has been uploaded to this database)"
    fi
    {
        echo "instance=$n"
        echo "database=$db"
        echo "date=$(date '+%Y-%m-%d %H:%M:%S %z')"
        echo "branch=$(inst_branch "$n")"
        echo "commit=$(git -C "$(inst_core "$n")" rev-parse HEAD 2>/dev/null || true)"
        local r
        while IFS= read -r r; do
            [ -n "$r" ] && echo "repo.$r=$(repo_branch "$(inst_dir "$n")/$r") $(git -C "$(inst_dir "$n")/$r" rev-parse HEAD 2>/dev/null || true)"
        done < <(inst_repos "$n")
        echo "odoo_commit=$(git -C "$ODOO_SRC" rev-parse HEAD 2>/dev/null || true)"
    } > "$dest/manifest.txt"
    echo ""
    echo "  Restore it:  $ME restore $n $dest"
}

# SOURCE is one of:
#   a folder written by `backup` (db.dump, filestore.tar.gz)
#   a .zip from Odoo's database manager or from the Docker stack's backup
#       (dump.sql and filestore/ inside)
#   a .dump (pg_dump -Fc), .sql or .sql.gz file (database only)
# No SOURCE: the latest backup of this instance.
cmd_restore() {
    need_install; need_pg
    local yes=0 neutralize=0 args=() a
    for a in "$@"; do
        case "$a" in
            --yes|-y)     yes=1 ;;
            --neutralize) neutralize=1 ;;
            *)            args+=("$a") ;;
        esac
    done
    need_instance "${args[0]:-}" restore
    local n="${args[0]}" src="${args[1]:-}" db fs was tmp="" dump="" fsarchive="" fsdir=""
    db="$(inst_db "$n")"; fs="$(filestore_dir "$n")"
    if [ -z "$src" ]; then
        src=$(ls -1d "$BACKUP_DIR/${db}"_* 2>/dev/null | sort | tail -1 || true)
        [ -n "$src" ] || die "No backup of $db in $BACKUP_DIR. Give one: $ME restore $n SOURCE"
    fi
    [ -e "$src" ] || die "$src does not exist."

    if [ -d "$src" ]; then
        dump="$src/db.dump"; [ -f "$dump" ] || die "$src has no db.dump: not a folder written by '$ME backup'."
        [ -f "$src/filestore.tar.gz" ] && fsarchive="$src/filestore.tar.gz"
    else
        case "$src" in
            *.zip)
                tmp="$(mktemp -d)"
                unzip -q "$src" -d "$tmp" || { rm -rf "$tmp"; die "Could not unpack $src"; }
                dump="$tmp/dump.sql"; [ -f "$dump" ] || { rm -rf "$tmp"; die "$src has no dump.sql inside: not an Odoo backup zip."; }
                [ -d "$tmp/filestore" ] && fsdir="$tmp/filestore"
                ;;
            *.dump|*.sql|*.sql.gz) dump="$src" ;;
            *) die "Don't know how to restore $src (a backup folder, .zip, .dump, .sql or .sql.gz)." ;;
        esac
    fi

    echo ""
    echo -e "  ${BOLD}Restore into instance $n${NC}"
    echo "    from:      $src"
    echo "    database:  $db   $(db_exists "$db" && echo "(exists: it will be DROPPED and replaced)" || echo "(new)")"
    if [ -n "$fsarchive$fsdir" ]; then
        echo "    filestore: $fs   $([ -d "$fs" ] && echo "(exists: it will be DELETED and replaced)" || echo "(new)")"
    else
        echo "    filestore: not in this source, the current one is left as it is"
    fi
    echo ""
    if [ "$yes" != 1 ]; then
        read -r -p "  Type the database name ($db) to go ahead: " a || a=""
        [ "$a" = "$db" ] || { [ -n "$tmp" ] && rm -rf "$tmp"; echo "  Nothing changed."; exit 1; }
    fi

    was="$(inst_pid "$n")"
    [ -n "$was" ] && stop_one "$n"
    if db_exists "$db"; then drop_db "$db"; fi
    "$PG_BIN/createdb" -E UTF8 -T template0 "$db"
    case "$dump" in
        *.dump)   "$PG_BIN/pg_restore" --no-owner --no-privileges -d "$db" "$dump" ;;
        *.sql.gz) gunzip -c "$dump" | "$PG_BIN/psql" -X -q -v ON_ERROR_STOP=0 -d "$db" >/dev/null ;;
        *)        "$PG_BIN/psql" -X -q -v ON_ERROR_STOP=0 -d "$db" -f "$dump" >/dev/null ;;
    esac
    ok "database $db restored"
    if [ -n "$fsarchive$fsdir" ]; then
        rm -rf "$fs"; mkdir -p "$fs"
        if [ -n "$fsarchive" ]; then tar -xzf "$fsarchive" -C "$fs"; else cp -R "$fsdir"/. "$fs"/; fi
        ok "filestore restored"
    fi
    [ -n "$tmp" ] && rm -rf "$tmp"
    if [ "$neutralize" = 1 ]; then
        echo "  Neutralizing (scheduled actions, mail servers and the like are turned off)…"
        odoo_bin "$n" neutralize -d "$db" --logfile= || warn "neutralize failed: the database is restored but still live-configured"
    else
        echo "  A copy of a production database? Turn off its mail servers and scheduled"
        echo "  actions before starting it:  $ME restore $n SOURCE --neutralize"
    fi
    if [ -n "$was" ]; then start_one "$n"; fi
    echo "  The code and the database may differ now:  $ME update $n"
}

# ── Office converter (optional) ───────────────
# ePHEM AI never runs LibreOffice itself: it posts old Office files to a
# small HTTP service (borrs/ephem-office, the `office` service of the Docker
# stack). A LibreOffice installed on the Mac would not be used. This runs
# that same image as one container on 127.0.0.1:2003, for the developers who
# work on that feature; it needs Docker Desktop. Everything else works
# without it (EPHEM_OFFICE_CONVERTER=0: ePHEM AI says the converter is off).
OFFICE_NAME="ephem-office-native"
cmd_office() {
    need_install
    case "${1:-status}" in
        start)
            command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 \
                || die "Docker is not running. The converter is a container: start Docker Desktop first."
            if [ -n "$(docker ps -aq -f "name=^${OFFICE_NAME}\$")" ]; then
                docker start "$OFFICE_NAME" >/dev/null
            else
                docker run -d --name "$OFFICE_NAME" --restart unless-stopped --init --read-only \
                    --tmpfs /tmp:size=1g --cap-drop ALL --security-opt no-new-privileges \
                    --pids-limit 256 --memory 2g -p 127.0.0.1:2003:2003 \
                    "borrs/ephem-office:latest" >/dev/null
            fi
            nenv_set OFFICE 1
            ok "converter running on http://127.0.0.1:2003. Restart the instances to use it: $ME restart all"
            ;;
        stop)
            docker stop "$OFFICE_NAME" >/dev/null 2>&1 || true
            nenv_set OFFICE 0
            ok "converter stopped. Restart the instances: $ME restart all"
            ;;
        status)
            if [ "$(nenv_get OFFICE)" = 1 ]; then
                if curl -fsS -o /dev/null --max-time 3 http://127.0.0.1:2003/health 2>/dev/null; then
                    ok "converter on and answering (http://127.0.0.1:2003)"
                else
                    warn "converter is on in conf/native.env but does not answer: $ME office start"
                fi
            else
                echo "  converter off (ePHEM AI does not read .doc, .ppt, .rtf, .odt).  $ME office start"
            fi
            ;;
        *) die "Usage: $ME office start|stop|status" ;;
    esac
}

# ── new: add an instance, step by step ────────
# The asking version of create + initdb + start: number, branch, database.
# In the menu (bash manage.sh) it is the command `new`.

# Asks for a branch of origin; sets PICKED_BRANCH. Enter takes the default,
# a full name is taken as it is, anything else is searched for.
pick_branch() {
    local list a matches count i
    list=$(core_git for-each-ref --format='%(refname:strip=3)' refs/remotes/origin | grep -vx HEAD || true)
    PICKED_BRANCH=""
    while true; do
        echo ""
        echo "  Which branch?"
        echo "    Enter          $DEFAULT_BRANCH (the default)"
        echo "    a name         for example 18_national_main"
        echo "    part of a name to choose among the branches that contain it (for example: uganda)"
        echo "    ?              every branch of origin"
        read -r -p "  Branch [$DEFAULT_BRANCH]: " a || return 1
        a="${a:-$DEFAULT_BRANCH}"; a="${a#origin/}"
        if [ "$a" = "?" ]; then
            matches="$list"
        elif printf '%s\n' "$list" | grep -qxF -- "$a"; then
            PICKED_BRANCH="$a"; return 0
        else
            matches=$(printf '%s\n' "$list" | grep -iF -- "$a" || true)
        fi
        count=$(printf '%s\n' "$matches" | grep -c . || true)
        if [ "$count" -eq 0 ]; then
            warn "origin has no branch that contains '$a'."
            continue
        fi
        if [ "$count" -eq 1 ]; then
            PICKED_BRANCH="$matches"
            echo "  → $PICKED_BRANCH"
            return 0
        fi
        echo ""
        printf '%s\n' "$matches" | awk '{ printf "    %3d) %s\n", NR, $0 }'
        read -r -p "  Number (Enter to search again): " i || return 1
        if [[ "$i" =~ ^[0-9]+$ ]] && [ "$i" -ge 1 ] && [ "$i" -le "$count" ]; then
            PICKED_BRANCH=$(printf '%s\n' "$matches" | sed -n "${i}p")
            return 0
        fi
    done
}

# A copy of another instance's database and filestore, taken while that
# instance keeps running (pg_dump reads one consistent snapshot).
copy_instance_db() {  # copy_instance_db FROM TO
    local from="$1" to="$2" src dst
    src="$(inst_db "$from")"; dst="$(inst_db "$to")"
    "$PG_BIN/createdb" -E UTF8 -T template0 "$dst"
    "$PG_BIN/pg_dump" -Fc --no-owner -d "$src" | "$PG_BIN/pg_restore" --no-owner --no-privileges -d "$dst" \
        || warn "the copy reported errors (above): check $dst before relying on it"
    if [ -d "$(filestore_dir "$from")" ]; then
        mkdir -p "$(inst_data "$to")/filestore"
        cp -R "$(filestore_dir "$from")" "$(filestore_dir "$to")"
    fi
    ok "database $dst is a copy of $src (filestore included)"
}

cmd_new() {
    need_install; need_pg
    [ -d "$CORE_CLONE/.git" ] || die "$CORE_CLONE is not a clone yet. Run: bash scripts/macos/install.sh"
    local i free="" n a base dbsrc="" dbmode others=""
    for i in 1 2 3 4 5 6 7 8 9; do
        if [ -f "$(inst_conf "$i")" ] || [ -e "$(inst_dir "$i")" ]; then
            others="$others $i"
        elif [ -z "$free" ]; then
            free="$i"
        fi
    done
    [ -n "$free" ] || die "Instances 1 to 9 all exist: there is no number left."

    step "New instance"
    echo "  Existing:${others:- none}"
    read -r -p "  Number of the new instance [$free]: " a || exit 1
    n="${a:-$free}"
    valid_n "$n" || die "'$n' is not an instance number (1 to 9)."
    if [ -f "$(inst_conf "$n")" ] || [ -e "$(inst_dir "$n")" ]; then
        die "Instance $n already exists. To move it to another branch: $ME switch $n BRANCH"
    fi

    fix_refspec
    echo "  Fetching the branch list from origin…"
    core_git fetch --prune --quiet origin || warn "Could not reach origin: choosing among the branches known from the last fetch."
    pick_branch || exit 1
    base="$PICKED_BRANCH"

    echo ""
    echo "  Database $(inst_db "$n"):"
    echo "    1) empty: module base only (a few seconds)"
    echo "    2) a copy of another instance's database"
    echo "    3) none for now (later: $ME initdb $n, or restore $n SOURCE)"
    read -r -p "  Choose [1-3] (default: 1): " dbmode || exit 1
    dbmode="${dbmode:-1}"
    if db_exists "$(inst_db "$n")"; then
        warn "a database $(inst_db "$n") is already there: it is kept and used as it is."
        dbmode=3
    fi
    if [ "$dbmode" = 2 ]; then
        read -r -p "  Copy from instance (one of:$others): " dbsrc || exit 1
        valid_n "$dbsrc" && db_exists "$(inst_db "$dbsrc")" \
            || die "Instance '$dbsrc' has no database to copy. Nothing was created."
    fi

    echo ""
    echo -e "  ${BOLD}Instance $n${NC}: $(inst_url "$n"), folder odca$n/ ($CORE_NAME/ on branch odca$n/$base, tracks origin/$base),"
    case "$dbmode" in
        2) echo "  database $(inst_db "$n") copied from $(inst_db "$dbsrc")." ;;
        3) echo "  no new database." ;;
        *) echo "  database $(inst_db "$n") empty." ;;
    esac
    confirm "  Create it?" Y || { echo "  Nothing was created."; return 0; }

    CREATE_HINT=0 cmd_create "$n" "$base"
    case "$dbmode" in
        2) copy_instance_db "$dbsrc" "$n" ;;
        3) ;;
        *) cmd_initdb "$n" ;;
    esac
    echo ""
    start_one "$n" || true
    if [ "$dbmode" = 2 ]; then
        echo "  If odca$n's branch differs from odca$dbsrc's, bring the copy in line with the code:"
        echo "    $ME update $n"
    fi
    echo "  Folder for your editor or coding agent: $(inst_dir "$n")"
    echo "  Another addon repository next to $CORE_NAME (a country's, for example):"
    echo "    $ME repo add $n OWNER/REPO"
}

# ── remove: take an instance away ─────────────
# Deletes the instance's database, filestore, worktree folder, config and
# log. Kept: its backups, and every commit (a branch odcaN/… that holds
# commits its origin branch does not have is left in the ePHEM clone).
# Stops, without touching anything, when the worktree has uncommitted
# changes (--force discards them). Asks for the database name first.
cmd_remove() {
    need_install; need_pg
    local yes=0 force=0 backup="" args=() a
    for a in "$@"; do
        case "$a" in
            --yes|-y)    yes=1 ;;
            --force)     force=1 ;;
            --no-backup) backup=no ;;
            *)           args+=("$a") ;;
        esac
    done
    need_n "${args[0]:-}" remove
    local n="${args[0]}" db dir wt conf has_db=0 b branches="" kept="" r rd risky=""
    db="$(inst_db "$n")"; dir="$(inst_dir "$n")"; conf="$(inst_conf "$n")"; wt="$(inst_wt "$n")"
    [ -f "$conf" ] || [ -e "$dir" ] || die "There is no instance $n."
    db_exists "$db" && has_db=1

    if [ -e "$wt/.git" ] && inst_dirty "$n" && [ "$force" != 1 ]; then
        err "odca$n/$( inst_old_layout "$n" || echo "$CORE_NAME") has uncommitted changes: commit them (they then stay on its branch), or discard them, first."
        git -C "$wt" status --short | head -20 >&2
        echo "  To remove the instance and lose these changes:  $ME remove $n --force" >&2
        exit 1
    fi
    # The added repositories are plain clones: deleting the folder deletes
    # whatever is not committed and pushed.
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        rd="$dir/$r"
        if repo_dirty "$rd" || [ "$(repo_unpushed "$rd")" != 0 ]; then risky="$risky $r"; fi
    done < <(inst_repos "$n")
    if [ -n "$risky" ] && [ "$force" != 1 ]; then
        err "odca$n has repositories with uncommitted or unpushed work:$risky"
        echo "  Commit and push it first, or lose it with:  $ME remove $n --force" >&2
        exit 1
    fi
    # The local branches of this instance, and which of them hold commits
    # that are nowhere on origin.
    branches=$(core_git for-each-ref --format='%(refname:short)' "refs/heads/odca$n/" 2>/dev/null || true)
    for b in $branches; do
        if [ -n "$(core_git rev-list -1 "$b" --not --remotes=origin 2>/dev/null || true)" ]; then kept="$kept $b"; fi
    done

    echo ""
    echo -e "  ${BOLD}Remove instance $n${NC}  ($(inst_url "$n"))"
    if [ "$has_db" = 1 ]; then
        echo "    database   $db: DROPPED"
    else
        echo "    database   $db: none"
    fi
    echo "    files      $(inst_data "$n") (filestore, sessions): DELETED"
    if [ -e "$dir" ]; then
        echo "    folder     $dir: DELETED$( [ "$force" = 1 ] && inst_dirty "$n" && echo ', uncommitted changes included')"
        local note
        while IFS= read -r r; do
            [ -n "$r" ] || continue
            note=""
            case " $risky " in *" $r "*) note=" (its uncommitted or unpushed work too)" ;; esac
            echo "               with odca$n/$r/$note"
        done < <(inst_repos "$n")
    fi
    echo "    config     $conf, its log: DELETED"
    if [ -n "$kept" ]; then
        echo "    commits    kept: branch(es)$kept hold commits that origin does not have and stay in $CORE_CLONE"
    else
        echo "    commits    nothing to keep: the instance has no commit that origin does not have"
    fi
    echo "    backups    $BACKUP_DIR: kept"
    echo ""
    if [ "$yes" != 1 ]; then
        if [ "$has_db" = 1 ] && [ -z "$backup" ]; then
            if confirm "  Back up $db first?" Y; then backup=yes; else backup=no; fi
        fi
        read -r -p "  Type the database name ($db) to remove instance $n: " a || a=""
        [ "$a" = "$db" ] || { echo "  Nothing changed."; exit 1; }
    fi

    if [ "$has_db" = 1 ] && [ "$backup" = yes ]; then cmd_backup "$n"; fi
    stop_one "$n"
    if [ "$has_db" = 1 ]; then
        drop_db "$db"
        db_exists "$db" && die "database $db is still there: nothing else was removed."
        ok "database $db dropped"
    fi
    if [ -e "$wt/.git" ]; then
        # The generated CLAUDE.md is not part of the worktree: git would refuse.
        if inst_old_layout "$n"; then rm -f "$wt/CLAUDE.md" "$wt/CLAUDE.local.md"; fi
        if [ "$force" = 1 ]; then
            core_git worktree remove --force "$wt"
        else
            core_git worktree remove "$wt"
        fi
    fi
    if [ -d "$dir" ] && ! inst_old_layout "$n"; then
        while IFS= read -r r; do
            [ -n "$r" ] && rm -rf "${dir:?}/$r" && echo "  odca$n/$r/ deleted"
        done < <(inst_repos "$n")
        if [ -f "$dir/CLAUDE.md" ] && grep -qF "$OLD_AGENT_MARK" "$dir/CLAUDE.md"; then rm -f "$dir/CLAUDE.md"; fi
        rm -f "$dir/.DS_Store"
        rmdir "$dir" 2>/dev/null || warn "$dir still holds files dev.sh did not put there: left where it is"
    fi
    core_git worktree prune
    ok "odca$n/ removed"
    for b in $branches; do
        case " $kept " in
            *" $b "*) echo "  branch $b kept (it has commits of its own)" ;;
            *)        core_git branch -D "$b" >/dev/null 2>&1 && echo "  branch $b deleted (nothing of its own on it)" ;;
        esac
    done
    rm -rf "$(inst_data "$n")"
    rm -f "$conf" "$conf.bak" "$(inst_log "$n")" "$(inst_pidf "$n")"
    ok "instance $n removed; port $(inst_port "$n") is free again"
    if [ -n "$kept" ]; then
        echo "  Its commits: git -C $CORE_CLONE log$kept"
    fi
}

# ── migrate: the old layout → odcaN/ePHEM-core ─
# Until this layout, odcaN/ itself was the ePHEM worktree. git moves the
# worktree (branch, commits, uncommitted and untracked files go with it), the
# config follows, and the generated CLAUDE.md moves up into odcaN/.
migrate_one() {  # migrate_one N
    local n="$1" dir core tmp was owner
    dir="$(inst_dir "$n")"; core="$(inst_core "$n")"
    inst_old_layout "$n" || { ok "odca$n/ already has the $CORE_NAME/ layout"; return 0; }
    [ -e "$dir/$CORE_NAME" ] && die "odca$n/$CORE_NAME already exists inside the old worktree: move it away first."
    was="$(inst_pid "$n")"
    owner="$(port_owner "$(inst_port "$n")")"
    if [ -z "$was" ] && [ -n "$owner" ]; then
        die "port $(inst_port "$n") is in use by pid and name: $owner (an instance started from PyCharm?). Stop it, then: $ME migrate $n"
    fi
    [ -n "$was" ] && stop_one "$n"
    step "odca$n/ → odca$n/$CORE_NAME/"
    tmp="$NATIVE_HOME/.odca$n-moving"
    [ -e "$tmp" ] && die "$tmp exists (an earlier move stopped halfway?). Look at it, then remove it and run this again."
    core_git worktree move "$dir" "$tmp"
    mkdir -p "$dir"
    if ! core_git worktree move "$tmp" "$core"; then
        rmdir "$dir" 2>/dev/null || true
        core_git worktree move "$tmp" "$dir" || true
        die "Could not move the worktree into odca$n/$CORE_NAME: odca$n/ is back as it was."
    fi
    ok "worktree moved: branch $(inst_branch "$n"), its commits and uncommitted changes went with it"
    if [ -f "$(inst_conf "$n")" ]; then
        cp -p "$(inst_conf "$n")" "$(inst_conf "$n").bak"
        write_conf "$n"
        ok "conf/odoo-$n.conf: addons_path now starts at odca$n/$CORE_NAME (previous: odoo-$n.conf.bak)"
    fi
    write_agent_file "$n"
    [ -n "$was" ] && start_one "$n"
    return 0
}

cmd_migrate() {
    need_install
    local n any=0
    if [ $# -eq 0 ] || [ "$1" = all ]; then
        while IFS= read -r n; do
            [ -n "$n" ] || continue
            if inst_old_layout "$n"; then migrate_one "$n"; any=1; fi
        done < <(instances)
        [ "$any" = 1 ] || ok "every instance already has the $CORE_NAME/ layout"
    else
        for n in "$@"; do need_n "$n" migrate; migrate_one "$n"; done
    fi
    echo "  Editors and agents: open odcaN/ (or odcaN/$CORE_NAME for the ePHEM repository alone)."
}

# ── repo: the other addon repositories of an instance ─
# The Docker developer stack's "Add a repository": a git repository whose top
# level holds Odoo modules, cloned into odcaN/<name>/ next to ePHEM-core and
# put on this instance's addons path after it. One clone per instance, so
# each instance can follow its own branch of it.

# owner/name (GitHub over SSH, like the ePHEM clone), git@…, ssh://, https://
# or a local path → the URL to clone.
repo_url() {
    case "$1" in
        git@*|ssh://*|https://*|http://*|file://*|/*) echo "$1" ;;
        [A-Za-z0-9_.-]*/[A-Za-z0-9_.-]*) echo "git@github.com:${1%.git}.git" ;;
        *) return 1 ;;
    esac
}

restart_if_running() {  # restart_if_running N
    if [ -n "$(inst_pid "$1")" ]; then
        stop_one "$1"; start_one "$1" || true
    else
        echo "  Instance $1 is not running: the change applies at its next start."
    fi
}

need_repo() {  # need_repo N NAME → REPO_DIR
    [ -n "${2:-}" ] || die "Which repository? $ME repo list $1"
    [ "$2" != "$CORE_NAME" ] || die "$CORE_NAME is the ePHEM worktree: $ME switch $1 BRANCH changes its branch."
    REPO_DIR="$(inst_dir "$1")/$2"
    [ -d "$REPO_DIR" ] || die "odca$1 has no repository '$2'. See them: $ME repo list $1"
}

cmd_repo_add() {
    need_install
    local args=() name="" a
    while [ $# -gt 0 ]; do
        case "$1" in
            --name)   name="${2:-}"; shift ;;
            --name=*) name="${1#--name=}" ;;
            *)        args+=("$1") ;;
        esac
        shift
    done
    need_instance "${args[0]:-}" "repo add"
    local n="${args[0]}" spec="${args[1]:-}" branch="${args[2]:-}" url target base cnt dups="" m was
    [ -n "$spec" ] || die "Usage: $ME repo add N REPO [BRANCH] [--name FOLDER]   (REPO: owner/name, e.g. borse/ePHEM_uganda, or a git URL)"
    url="$(repo_url "$spec")" || die "Not a repository I can read: '$spec'. Examples: borse/ePHEM_uganda   git@github.com:OCA/web.git   https://github.com/OCA/web"
    if [ -z "$name" ]; then name="$(basename "${spec%/}")"; name="${name%.git}"; fi
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "Folder names: letters, digits, dot, dash and underscore."
    [ "$name" != "$CORE_NAME" ] || die "$CORE_NAME is the ePHEM worktree itself."
    target="$(inst_dir "$n")/$name"
    [ -e "$target" ] && die "odca$n/$name already exists. Another folder name: --name OTHER"

    step "Add $spec to instance $n (odca$n/$name)"
    GIT_TERMINAL_PROMPT=0 git ls-remote --heads "$url" >/dev/null 2>&1 \
        || die "Cannot read $url: wrong name, or your SSH key has no access to it (try: git ls-remote $url)."
    if [ -z "$branch" ]; then
        base="$(inst_base "$n")"
        if [ -n "$base" ] && GIT_TERMINAL_PROMPT=0 git ls-remote --exit-code --heads "$url" "$base" >/dev/null 2>&1; then
            branch="$base"
            echo "  Branch $branch: the one $CORE_NAME follows."
        else
            branch="$(GIT_TERMINAL_PROMPT=0 git ls-remote --symref "$url" HEAD 2>/dev/null | awk '/^ref:/ { sub("refs/heads/", "", $2); print $2; exit }')"
            echo "  Branch ${branch:-?}: the repository's default ($CORE_NAME's ${base:-branch} is not one of its branches)."
        fi
    fi
    echo -e "  ${CYAN}→${NC} git clone --branch $branch $url odca$n/$name"
    GIT_TERMINAL_PROMPT=0 git clone --progress ${branch:+--branch "$branch"} "$url" "$target" \
        || { rm -rf "$target"; die "Clone failed: see the git output above (wrong branch, or no access)."; }

    cnt="$(module_count "$target")"
    if [ "$cnt" -eq 0 ]; then
        warn "odca$n/$name has no Odoo module at its top level (<module>/__manifest__.py): it is NOT on the addons path."
    else
        ok "odca$n/$name: $cnt module(s) on $(repo_branch "$target")"
        for m in "$target"/*/__manifest__.py; do
            m="$(basename "$(dirname "$m")")"
            [ -f "$(inst_core "$n")/$m/__manifest__.py" ] && dups="$dups $m"
        done
        [ -n "$dups" ] && warn "also in $CORE_NAME, whose copy wins:$dups"
    fi
    cp -p "$(inst_conf "$n")" "$(inst_conf "$n").bak"
    write_conf "$n"
    ok "conf/odoo-$n.conf: addons_path updated"
    write_agent_file "$n"
    restart_if_running "$n"
    if [ "$cnt" -gt 0 ]; then
        echo ""
        echo "  Its modules: $(module_names "$target")"
        echo "  Install the ones you need:  $ME install $n MODULE[,MODULE…]   (or Apps → Update Apps List)"
    fi
}

cmd_repo_list() {
    need_install
    local n r rd list
    if [ -n "${1:-}" ]; then need_instance "$1" "repo list"; list="$1"; else list="$(instances)"; fi
    for n in $list; do
        echo -e "  ${BOLD}odca$n${NC}  ($(inst_url "$n"), $(inst_db "$n"))"
        if inst_old_layout "$n"; then
            echo "    (old layout: $ME migrate $n)"
            continue
        fi
        printf '    %-26s %-34s %-18s %s\n' "$CORE_NAME/" "$(inst_branch "$n")$(inst_dirty "$n" && echo ' *')" "$(inst_sync "$n")" "$(module_count "$(inst_core "$n")") modules"
        while IFS= read -r r; do
            [ -n "$r" ] || continue
            rd="$(inst_dir "$n")/$r"
            printf '    %-26s %-34s %-18s %s\n' "$r/" "$(repo_branch "$rd")$(repo_dirty "$rd" && echo ' *')" "$(repo_sync "$rd")" "$(module_count "$rd") modules, $(git -C "$rd" remote get-url origin 2>/dev/null || echo 'no remote')"
        done < <(inst_repos "$n")
    done
    echo ""
    echo "  * = uncommitted changes. ORIGIN as of the last fetch ($ME fetch)."
}

cmd_repo_pull() {
    need_install
    need_instance "${1:-}" "repo pull"
    local n="$1" r d rc=0 names
    if [ -n "${2:-}" ]; then need_repo "$n" "$2"; names="$2"; else names="$CORE_NAME $(inst_repos "$n" | tr '\n' ' ')"; fi
    for r in $names; do
        d="$(inst_dir "$n")/$r"
        echo -e "  ${CYAN}→${NC} odca$n/$r ($(repo_branch "$d"))"
        if repo_dirty "$d"; then warn "  uncommitted changes: skipped (commit or stash them first)"; rc=1; continue; fi
        GIT_TERMINAL_PROMPT=0 git -C "$d" pull --ff-only || { err "  odca$n/$r: not a fast-forward (local commits?): merge it yourself"; rc=1; }
    done
    echo "  New or changed modules need an update:  $ME update $n"
    return "$rc"
}

cmd_repo_switch() {
    need_install
    need_instance "${1:-}" "repo switch"
    need_repo "$1" "${2:-}"
    local n="$1" name="$2" branch="${3:-}" d
    d="$REPO_DIR"
    [ -n "$branch" ] || die "Usage: $ME repo switch N NAME BRANCH"
    branch="${branch#origin/}"
    if repo_dirty "$d"; then
        err "odca$n/$name has uncommitted changes: commit or stash them first."
        git -C "$d" status --short | head -20 >&2
        exit 1
    fi
    GIT_TERMINAL_PROMPT=0 git -C "$d" fetch origin "+refs/heads/$branch:refs/remotes/origin/$branch" \
        || die "origin of odca$n/$name has no branch '$branch'."
    if git -C "$d" rev-parse --verify -q "refs/heads/$branch" >/dev/null; then
        git -C "$d" switch "$branch"
    else
        git -C "$d" switch --track -c "$branch" "origin/$branch"
    fi
    ok "odca$n/$name is on $branch"
    write_conf "$n"; write_agent_file "$n"
    restart_if_running "$n"
    echo "  Different code usually means different models:  $ME update $n"
}

cmd_repo_remove() {
    need_install
    local yes=0 force=0 args=() a
    for a in "$@"; do
        case "$a" in
            --yes|-y) yes=1 ;;
            --force)  force=1 ;;
            *)        args+=("$a") ;;
        esac
    done
    need_instance "${args[0]:-}" "repo remove"
    need_repo "${args[0]}" "${args[1]:-}"
    local n="${args[0]}" name="${args[1]}" d unp
    d="$REPO_DIR"; unp="$(repo_unpushed "$d")"
    if { repo_dirty "$d" || [ "$unp" != 0 ]; } && [ "$force" != 1 ]; then
        err "odca$n/$name has uncommitted changes or $unp commit(s) no remote has:"
        git -C "$d" status --short | head -20 >&2
        echo "  Commit and push them first, or delete them with it:  $ME repo remove $n $name --force" >&2
        exit 1
    fi
    echo ""
    echo -e "  ${BOLD}Remove odca$n/$name${NC}: the folder is DELETED and its modules leave instance $n's addons path."
    echo "  Modules of it that are installed on $(inst_db "$n") should be uninstalled first (Apps),"
    echo "  or Odoo logs errors about them at every start."
    if [ "$yes" != 1 ]; then confirm "  Remove it?" N || { echo "  Nothing changed."; return 0; }; fi
    rm -rf "${d:?}"
    ok "odca$n/$name deleted"
    write_conf "$n"; write_agent_file "$n"
    restart_if_running "$n"
}

cmd_repo() {
    local sub="${1:-list}"
    [ $# -gt 0 ] && shift
    case "$sub" in
        add)           cmd_repo_add "$@" ;;
        list|ls)       cmd_repo_list "$@" ;;
        pull)          cmd_repo_pull "$@" ;;
        switch)        cmd_repo_switch "$@" ;;
        remove|rm)     cmd_repo_remove "$@" ;;
        *) die "Usage: $ME repo add N REPO [BRANCH] [--name FOLDER] | list [N] | pull N [NAME] | switch N NAME BRANCH | remove N NAME" ;;
    esac
}

# ── Menu (bash manage.sh lands here on a native Mac setup) ─
cmd_help() {
    cat <<EOF

  new                  add an instance: asks its number, its branch, its database
  remove N             delete an instance: its database, files and folder (asks first; commits are kept)
  create N [BRANCH]    the same as new, without questions: odcaN/$CORE_NAME + config (default branch: $DEFAULT_BRANCH)
  initdb N [MODULES]   create database ephem_N
  start | stop | restart  N…|all
  status               ports, databases, branches, health
  logs N               follow the log (Ctrl+C to leave)
  update N [MODULES]   update modules, then start again
  install N MODULES    install modules, then start again
  shell N              Odoo shell
  switch N BRANCH      move the instance's $CORE_NAME to another branch
  repo add N REPO [BRANCH]   add a repository next to $CORE_NAME (e.g. borse/ePHEM_uganda)
  repo list [N]        the repositories of each instance
  repo pull N [NAME]   pull them (fast-forward only)
  repo switch N NAME BRANCH  move an added repository to another branch
  repo remove N NAME   delete an added repository (asks first)
  migrate [N|all]      move an old-layout instance into odcaN/$CORE_NAME/
  fetch                fetch every branch from origin
  backup N             database + filestore into $BACKUP_DIR
  restore N [SOURCE] [--neutralize]
  conf N               write conf/odoo-N.conf again
  office start|stop|status
EOF
}

cmd_menu() {
    need_install
    local line docker_line=""
    if [ -f "$EPHEM_ROOT/.env" ]; then docker_line="  docker               the Docker menu of this checkout (bash manage.sh --docker)"; fi
    # Instances made before the ePHEM-core/ layout (a Mac set up with an
    # older checkout): offered once per menu start, in their own process so
    # a failure stops only the move.
    local old="" n
    while IFS= read -r n; do
        if [ -n "$n" ] && inst_old_layout "$n"; then old="$old $n"; fi
    done < <(instances)
    if [ -n "$old" ]; then
        echo ""
        echo -e "  ${YELLOW}!${NC} Instance(s)$old still have the old layout: odcaN/ itself is the ePHEM worktree."
        echo "     They move into odcaN/$CORE_NAME/, the layout of the Docker developer stack, so other"
        echo "     repositories can go next to ePHEM (repo add N …). Branches, commits and uncommitted"
        echo "     changes move with them; a running instance is restarted."
        if confirm "  Move them now?" Y; then
            # shellcheck disable=SC2086  # one word per instance number
            bash "$0" migrate $old || true
            echo "  Editors and coding agents opened in odcaN/ before: reopen them (PyCharm: the git roots are now odcaN/$CORE_NAME)."
            read -r -p "  Enter to continue " line || exit 0
        fi
    fi
    while true; do
        echo ""
        cmd_status || true
        echo ""
        echo -e "  ${BOLD}Type a command${NC} (the same words as $ME …):"
        cmd_help
        [ -n "$docker_line" ] && echo "$docker_line"
        echo "  x                    exit"
        echo ""
        read -r -p "  > " line || { echo ""; exit 0; }
        # shellcheck disable=SC2086  # the typed line is split into words on purpose
        set -- $line
        case "${1:-}" in
            "")         continue ;;
            x|X|q|exit) exit 0 ;;
            docker|d)   exec bash "$EPHEM_ROOT/manage.sh" --docker ;;
            menu)       continue ;;
            status)     continue ;;
        esac
        # Its own process, not a subshell: inside `( … ) || true` bash turns
        # `set -e` off, and a command that failed halfway would carry on. This
        # way a failed command stops as it does outside the menu, and the menu
        # comes back.
        bash "$0" "$@" || true
        read -r -p "  Enter to continue " line || exit 0
    done
}

dispatch() {
    local verb="${1:-status}"
    [ $# -gt 0 ] && shift
    case "$verb" in
        new|add) cmd_new ;;
        remove)  cmd_remove "$@" ;;
        create)  cmd_create "$@" ;;
        initdb)  cmd_initdb "$@" ;;
        start)   cmd_start "$@" ;;
        stop)    cmd_stop "$@" ;;
        restart) cmd_restart "$@" ;;
        status)  cmd_status ;;
        list)    cmd_list ;;
        logs)    cmd_logs "$@" ;;
        update)  cmd_update "$@" ;;
        install) cmd_install "$@" ;;
        shell)   cmd_shell "$@" ;;
        switch)  cmd_switch "$@" ;;
        fetch)   cmd_fetch ;;
        backup)  cmd_backup "$@" ;;
        restore) cmd_restore "$@" ;;
        conf)    cmd_conf "$@" ;;
        office)  cmd_office "$@" ;;
        repo|repos) cmd_repo "$@" ;;
        migrate) cmd_migrate "$@" ;;
        menu)    cmd_menu ;;
        help|-h|--help) echo "Usage: $ME VERB …"; cmd_help ;;
        *)       err "Unknown command: $verb"; echo "Usage: $ME VERB …"; cmd_help; exit 1 ;;
    esac
}

dispatch "$@"
