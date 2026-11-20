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
#   • its own addons folder        odcaN/, a git worktree of the ePHEM clone
#   • its own odoo config          conf/odoo-N.conf
#   • its own database + filestore ephem_N, data/N/
#   • its own log                  logs/odoo-N.log
#
# Usage:
#   bash scripts/macos/dev.sh create N [BRANCH]     # worktree odcaN + config (default branch: 18_ephem_2)
#   bash scripts/macos/dev.sh initdb N [MODULES]    # create database ephem_N (base, plus MODULES)
#   bash scripts/macos/dev.sh start|stop|restart N  # N, several N, or all
#   bash scripts/macos/dev.sh status                # ports, databases, branches, health
#   bash scripts/macos/dev.sh logs N                # follow one instance
#   bash scripts/macos/dev.sh update N [MODULES]    # -u MODULES (default: every ePHEM module), then start again
#   bash scripts/macos/dev.sh install N MODULES     # -i MODULES, then start again
#   bash scripts/macos/dev.sh shell N               # Odoo shell on ephem_N
#   bash scripts/macos/dev.sh switch N BRANCH       # move odcaN to another branch
#   bash scripts/macos/dev.sh fetch                 # fetch every branch from origin (one fetch serves all instances)
#   bash scripts/macos/dev.sh backup N              # pg_dump + filestore into backups/
#   bash scripts/macos/dev.sh restore N [SOURCE]    # replace ephem_N from a backup (asks first)
#   bash scripts/macos/dev.sh conf N                # write conf/odoo-N.conf again (the old one is kept as .bak)
#   bash scripts/macos/dev.sh office start|stop|status   # optional document converter (a Docker container)
#   bash scripts/macos/dev.sh list | menu | help
#
# Branches. One clone (ePHEM/) and one worktree per instance share a single
# .git, and git refuses to check the same branch out twice. So instance N on
# BRANCH works on its own local branch, odcaN/BRANCH, which tracks
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

need_instance() {  # the instance exists (config + worktree)
    need_n "$1" "$2"
    [ -f "$(inst_conf "$1")" ] || die "Instance $1 has no config yet. Create it: $ME create $1"
    [ -d "$(inst_dir "$1")" ] || die "$(inst_dir "$1") is missing. Create it again: $ME create $1"
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

inst_branch() {
    local b; b=$(git -C "$(inst_dir "$1")" branch --show-current 2>/dev/null) || b=""
    echo "${b:-(detached)}"
}

# "2 ahead, 1 behind" of the branch this worktree tracks, from what the last
# fetch learned (no network).
inst_sync() {
    local d a b; d="$(inst_dir "$1")"
    git -C "$d" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1 || { echo "no upstream"; return 0; }
    a=$(git -C "$d" rev-list --count '@{upstream}..HEAD' 2>/dev/null || echo 0)
    b=$(git -C "$d" rev-list --count 'HEAD..@{upstream}' 2>/dev/null || echo 0)
    if [ "$a" = 0 ] && [ "$b" = 0 ]; then echo "up to date"
    elif [ "$b" = 0 ]; then echo "$a ahead"
    elif [ "$a" = 0 ]; then echo "$b behind"
    else echo "$a ahead, $b behind"; fi
}

inst_dirty() { [ -n "$(git -C "$(inst_dir "$1")" status --porcelain 2>/dev/null)" ]; }

# Put instance N on BASE: its own local branch odcaN/BASE, created from
# origin/BASE and tracking it the first time, simply checked out afterwards
# (what was committed on it earlier is still there).
checkout_instance_branch() {  # checkout_instance_branch N BASE
    local n="$1" base="$2" dir local_branch
    dir="$(inst_dir "$n")"; local_branch="odca$n/$base"
    core_git rev-parse --verify -q "refs/remotes/origin/$base" >/dev/null \
        || die "origin has no branch '$base' (after a fetch). See them: git -C $CORE_CLONE branch -r"
    if [ ! -d "$dir" ]; then
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

# ── CLAUDE.md per worktree ────────────────────
# What an AI coding agent started in odcaN/ has to know: which instance this
# is and how to stay inside it. Kept out of git through .git/info/exclude
# (one file for the clone and all its worktrees). When the repository tracks
# a CLAUDE.md of its own, that one is left alone and this goes to
# CLAUDE.local.md, which Claude Code reads as well.
AGENT_MARK="<!-- generated by scripts/macos/dev.sh: edits are lost when the instance is created or switched again -->"

write_agent_file() {  # write_agent_file N
    local n="$1" dir name file excl cur up
    dir="$(inst_dir "$n")"
    cur="$(inst_branch "$n")"
    up="$(git -C "$dir" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || true)"
    name="CLAUDE.md"
    if git -C "$dir" ls-files --error-unmatch CLAUDE.md >/dev/null 2>&1; then name="CLAUDE.local.md"; fi
    file="$dir/$name"
    if [ -f "$file" ] && ! grep -qF "$AGENT_MARK" "$file"; then
        warn "$file exists and was not written by dev.sh: left as it is"
        return 0
    fi
    excl="$(core_git rev-parse --git-common-dir)/info/exclude"
    case "$excl" in /*) ;; *) excl="$CORE_CLONE/$excl" ;; esac
    mkdir -p "$(dirname "$excl")"
    grep -qxF "/$name" "$excl" 2>/dev/null || echo "/$name" >> "$excl"
    cat > "$file" <<EOF
$AGENT_MARK
# ePHEM dev instance $n (native macOS)

You are working in **instance $n** of a multi-instance Odoo 18 developer setup.
Other instances (other \`odcaN/\` folders next to this one) belong to other agents.

| | |
|---|---|
| Instance | $n |
| This folder | \`$dir\` (a git worktree of \`$CORE_CLONE\`) |
| URL | $(inst_url "$n") (login of a new database: admin / admin) |
| Database | \`$(inst_db "$n")\` |
| Branch | \`$cur\`, tracking \`${up:-nothing}\` (now: \`git branch --show-current\`) |
| Config | \`$(inst_conf "$n")\` |
| Log | \`$(inst_log "$n")\` |
| Odoo source (read only) | \`$ODOO_SRC\` (branch $ODOO_BRANCH) |
| Python | \`$PY\` |

## Commands

Run them from anywhere. \`logs\` follows the file until Ctrl+C: to read the
log, use \`tail\` on it instead.

\`\`\`bash
bash $MAC_DIR/dev.sh status                 # every instance: port, database, branch, running or not
bash $MAC_DIR/dev.sh restart $n              # restart this instance
bash $MAC_DIR/dev.sh update $n eoc_base      # update modules (-u) on $(inst_db "$n"), then start again
bash $MAC_DIR/dev.sh update $n               # update every ePHEM module of this worktree
bash $MAC_DIR/dev.sh install $n my_module    # install a module that is not installed yet
bash $MAC_DIR/dev.sh shell $n                # Odoo shell on $(inst_db "$n") (reads a script from stdin too)
tail -n 200 $(inst_log "$n")
\`\`\`

Odoo runs with \`--dev=$(dev_flags)\`: a saved Python file restarts the server
by itself, and XML views are read from disk. A new field, a changed model, a
new file in a manifest or changed data still need \`update $n MODULE\`.

## Rules

- Work only in this folder and only on database \`$(inst_db "$n")\`. Never start, stop,
  update, restore or edit another instance (\`odca<other>/\`, \`ephem_<other>\`).
- Do not edit \`$ODOO_SRC\`, the virtualenv, or \`$CORE_CLONE\`.
- Commit on the current branch (\`$cur\`). It is local to this instance:
  do not push it, and do not merge into or push the base branch, unless the
  developer asks. Do not run \`git switch\`/\`git checkout\` to another branch here;
  changing branch is \`dev.sh switch $n BRANCH\`, and the developer decides it.
- Do not run \`git worktree\`, \`git gc --prune\` or \`git stash drop/clear\`: the
  object store is shared with the other instances.
EOF
    ok "$name written in odca$n/ (not tracked: .git/info/exclude)"
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

; This instance's worktree first, then extra-addons/*, then Odoo's own addons.
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
    [ -d "$(inst_dir "$1")" ] || die "$(inst_dir "$1") is missing. Create the instance: $ME create $1"
    if [ -f "$conf" ]; then cp -p "$conf" "$conf.bak"; fi
    write_conf "$1"
    ok "$conf written$( [ -f "$conf.bak" ] && echo " (previous: $conf.bak)")"
    if [ -n "$(inst_pid "$1")" ]; then echo "  Restart to apply: $ME restart $1"; fi
}

# ── create ────────────────────────────────────
cmd_create() {
    need_install
    need_n "${1:-}" "create"
    local n="$1" base="${2:-$DEFAULT_BRANCH}" dir conf
    dir="$(inst_dir "$n")"; conf="$(inst_conf "$n")"
    [ -d "$CORE_CLONE/.git" ] || die "$CORE_CLONE is not a clone yet. Run: bash scripts/macos/install.sh"

    step "Instance $n → $(inst_url "$n")  (db: $(inst_db "$n"), branch: $base)"
    if [ -e "$dir/.git" ]; then
        ok "odca$n/ already there (branch: $(inst_branch "$n")): left as it is"
        if [ -n "${2:-}" ] && [ "$(inst_branch "$n")" != "odca$n/$base" ]; then
            echo "  To move it to $base:  $ME switch $n $base"
        fi
    elif [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
        die "$dir has files but is not a worktree of $CORE_CLONE: move it away first."
    else
        fix_refspec
        echo "  Fetching $base from origin…"
        core_git fetch origin "$base" || die "Could not fetch '$base' from origin (does it exist? SSH access?)"
        checkout_instance_branch "$n" "$base"
        ok "odca$n/ is a worktree on its own branch odca$n/$base (tracks origin/$base)"
    fi

    if [ -f "$conf" ]; then
        ok "conf/odoo-$n.conf already there: left as it is  (write it again: $ME conf $n)"
    else
        write_conf "$n"
        ok "conf/odoo-$n.conf written (port $(inst_port "$n"), db $(inst_db "$n"))"
    fi
    write_agent_file "$n"
    if pg_ready && ! db_exists "$(inst_db "$n")"; then
        echo ""
        echo "  Next:  $ME initdb $n     (creates database $(inst_db "$n"); once)"
        echo "         $ME start $n"
    fi
}

# ── Running Odoo ──────────────────────────────
# The office converter the instances talk to (see cmd_office): on only when
# OFFICE=1 is recorded in conf/native.env.
odoo_env() {
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
    done < <(instances)
    if [ "$any" = 0 ]; then
        echo "  (none yet)   $ME create 1"
        return 0
    fi
    echo ""
    echo "  * = uncommitted changes   ? = database not created yet ($ME initdb N)"
    echo "  ORIGIN compares with the tracked branch as of the last fetch ($ME fetch)."
    if [ "$(nenv_get OFFICE)" = 1 ]; then echo "  Document converter: on (http://127.0.0.1:2003, $ME office status)"; fi
}

cmd_list() {
    need_install
    local n
    while IFS= read -r n; do [ -n "$n" ] && echo "  • $n → $(inst_url "$n")   (db: $(inst_db "$n"), addons: odca$n/, branch: $(inst_branch "$n"))"; done < <(instances)
}

cmd_logs() {
    need_install
    need_instance "${1:-}" logs
    [ -f "$(inst_log "$1")" ] || die "No log yet: instance $1 has never been started."
    exec tail -n 100 -F "$(inst_log "$1")"
}

# ── Modules ───────────────────────────────────
# What a routine update covers, as in scripts/stack-lib.sh
# (addons_update_modules): the eoc_*, ephem_* and cmp_* modules of the ePHEM
# worktree, and every module of a repository under extra-addons/. Odoo skips
# the names that are not installed in the database.
default_modules() {
    local n="$1" d m out=""
    for m in "$(inst_dir "$n")"/eoc_*/ "$(inst_dir "$n")"/ephem_*/ "$(inst_dir "$n")"/cmp_*/; do
        [ -f "$m/__manifest__.py" ] && out="$out,$(basename "$m")"
    done
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
    [ -n "$mods" ] || die "No ePHEM module found in $(inst_dir "$1")."
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
        err "odca$n has uncommitted changes: commit or stash them first."
        git -C "$(inst_dir "$n")" status --short | head -20 >&2
        exit 1
    fi
    local from; from="$(inst_branch "$n")"
    fix_refspec
    echo "  Fetching $base from origin…"
    core_git fetch origin "$base" || die "Could not fetch '$base' from origin (does it exist?)"
    checkout_instance_branch "$n" "$base"
    ok "odca$n: $from → odca$n/$base (tracks origin/$base). Commits on $from stay on that branch."
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
    local n
    while IFS= read -r n; do
        [ -n "$n" ] && echo "  • odca$n  $(inst_branch "$n"): $(inst_sync "$n")"
    done < <(instances)
    echo ""
    echo "  Bring an instance up to date with the branch it tracks:  git -C $NATIVE_HOME/odcaN pull"
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
        echo "commit=$(git -C "$(inst_dir "$n")" rev-parse HEAD 2>/dev/null || true)"
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
    if db_exists "$db"; then "$PG_BIN/dropdb" --force "$db"; fi
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

# ── Menu (bash manage.sh lands here on a native Mac setup) ─
cmd_help() {
    cat <<EOF

  create N [BRANCH]    worktree odcaN + config (default branch: $DEFAULT_BRANCH)
  initdb N [MODULES]   create database ephem_N
  start | stop | restart  N…|all
  status               ports, databases, branches, health
  logs N               follow the log (Ctrl+C to leave)
  update N [MODULES]   update modules, then start again
  install N MODULES    install modules, then start again
  shell N              Odoo shell
  switch N BRANCH      move the instance to another branch
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
        # A subshell: a command that stops with an error brings the menu back.
        ( dispatch "$@" ) || true
        read -r -p "  Enter to continue " line || exit 0
    done
}

dispatch() {
    local verb="${1:-status}"
    [ $# -gt 0 ] && shift
    case "$verb" in
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
        menu)    cmd_menu ;;
        help|-h|--help) echo "Usage: $ME VERB …"; cmd_help ;;
        *)       err "Unknown command: $verb"; echo "Usage: $ME VERB …"; cmd_help; exit 1 ;;
    esac
}

dispatch "$@"
