#!/bin/bash
# ──────────────────────────────────────────────
# Native macOS developer setup: shared helpers (sourced by install.sh and
# dev.sh in this folder, never run).
#
# On a Mac, Odoo can run straight on macOS instead of in Docker: the files
# are read at full speed (no bind mount through a VM) and a restart takes
# about two seconds. Nothing here is used on Linux or under WSL.
#
# Two places:
#
#   the deployment repo     this checkout. Holds the scripts and one marker
#                           file, .macos-native, which records where the
#                           native home is (manage.sh reads it).
#   the native home         $EPHEM_NATIVE_HOME, ~/Developer/ephem by default:
#
#       odoo/               Odoo source, branch 18.0
#       venv/               one Python 3.12 virtualenv for every instance
#       ePHEM/              the main clone of borse/ePHEM (the base branch)
#       odca1/ odca2/ ...   one git worktree of that clone per instance
#       extra-addons/       other addon repositories, one subfolder each
#       tools/              patched wkhtmltopdf, rtlcss
#       conf/               odoo-N.conf per instance, native.env (settings)
#       data/N/             filestore and sessions of instance N
#       logs/odoo-N.log     its log
#       run/odoo-N.pid      its process
#       backups/            dev.sh backup
#
# Instance N: http://localhost:80N0, database ephem_N. (80N2 is its
# gevent_port, which Odoo only opens when it runs with workers; in the
# threaded mode used here live updates go through 80N0.)
# ──────────────────────────────────────────────

MAC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EPHEM_ROOT="${EPHEM_ROOT:-$(cd "$MAC_DIR/../.." && pwd)}"
NATIVE_MARKER="$EPHEM_ROOT/.macos-native"

RED="${RED:-\033[0;31m}"
GREEN="${GREEN:-\033[0;32m}"
YELLOW="${YELLOW:-\033[1;33m}"
CYAN="${CYAN:-\033[0;36m}"
BOLD="${BOLD:-\033[1m}"
NC="${NC:-\033[0m}"

ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}!${NC} $*"; }
err()  { echo -e "${RED}✗${NC} $*" >&2; }
die()  { err "$@"; exit 1; }
step() { echo ""; echo -e "${CYAN}${BOLD}$*${NC}"; }

[ "$(uname -s 2>/dev/null)" = Darwin ] || die "scripts/macos/ is for macOS only. On Linux and WSL: bash setup.sh"

# ── What the native setup mirrors ─────────────
# The borrs/ephem image is odoo:18 on Ubuntu 24.04: Odoo 18.0, Python 3.12,
# PostgreSQL 16 next to it, wkhtmltopdf 0.12.6 with patched Qt.
ODOO_REPO="https://github.com/odoo/odoo.git"
ODOO_BRANCH="18.0"
PYTHON_VERSION="3.12"
PG_FORMULA="postgresql@16"
CORE_REPO_URL="git@github.com:borse/ePHEM.git"
# The same default as CORE_BRANCH in scripts/stack-lib.sh (Docker modes).
DEFAULT_BRANCH="18_ephem_2"
# The package the wkhtmltopdf project published for macOS (Intel only, runs
# under Rosetta on Apple Silicon). The checksum is of the file as downloaded
# from that release page when this script was written.
WKHTML_URL="https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6-2/wkhtmltox-0.12.6-2.macos-cocoa.pkg"
WKHTML_SHA256="81a66b77b508fede8dbcaa67127203748376568b3673a17f6611b6d51e9894f8"

# ── The native home ───────────────────────────
# EPHEM_NATIVE_HOME in the environment, else what install.sh recorded in the
# marker file, else ~/Developer/ephem.
marker_get() { grep "^$1=" "$NATIVE_MARKER" 2>/dev/null | head -1 | cut -d'=' -f2- || true; }

native_paths() {  # native_paths [HOME]: every path below, from one root
    NATIVE_HOME="${1:-${EPHEM_NATIVE_HOME:-}}"
    [ -n "$NATIVE_HOME" ] || NATIVE_HOME="$(marker_get EPHEM_NATIVE_HOME)"
    [ -n "$NATIVE_HOME" ] || NATIVE_HOME="$HOME/Developer/ephem"
    NATIVE_HOME="${NATIVE_HOME%/}"
    ODOO_SRC="$NATIVE_HOME/odoo"
    VENV="$NATIVE_HOME/venv"
    PY="$VENV/bin/python"
    CORE_CLONE="$NATIVE_HOME/ePHEM"
    EXTRA_ADDONS="$NATIVE_HOME/extra-addons"
    TOOLS="$NATIVE_HOME/tools"
    CONF_DIR="$NATIVE_HOME/conf"
    DATA_DIR="$NATIVE_HOME/data"
    LOG_DIR="$NATIVE_HOME/logs"
    RUN_DIR="$NATIVE_HOME/run"
    BACKUP_DIR="$NATIVE_HOME/backups"
    NATIVE_ENV="$CONF_DIR/native.env"
}
native_paths

native_installed() { [ -f "$NATIVE_MARKER" ] && [ -x "$PY" ] && [ -f "$ODOO_SRC/odoo-bin" ]; }

# ── Settings (conf/native.env, mode 600) ──────
# KEY=VALUE lines, read one key at a time and never sourced.
nenv_get() { grep "^$1=" "$NATIVE_ENV" 2>/dev/null | head -1 | cut -d'=' -f2- || true; }

nenv_set() {  # nenv_set KEY VALUE: update or append
    local tmp
    mkdir -p "$CONF_DIR"
    [ -f "$NATIVE_ENV" ] || ( umask 077; : > "$NATIVE_ENV" )
    tmp="$(mktemp)"
    K="$1" V="$2" awk '
        index($0, ENVIRON["K"] "=") == 1 { print ENVIRON["K"] "=" ENVIRON["V"]; done = 1; next }
        { print }
        END { if (!done) print ENVIRON["K"] "=" ENVIRON["V"] }' "$NATIVE_ENV" > "$tmp" && cat "$tmp" > "$NATIVE_ENV"
    rm -f "$tmp"
}

nenv_default() {  # nenv_default KEY VALUE: write only when the key is absent
    grep -q "^$1=" "$NATIVE_ENV" 2>/dev/null || nenv_set "$1" "$2"
}

# The settings, with what applies when the file does not say.
db_user()      { local v; v=$(nenv_get DB_USER);      printf '%s' "${v:-odoo}"; }
db_port()      { local v; v=$(nenv_get DB_PORT);      printf '%s' "${v:-5432}"; }
bind_host()    { local v; v=$(nenv_get BIND_HOST);    printf '%s' "${v:-127.0.0.1}"; }
dev_flags()    { local v; v=$(nenv_get DEV_FLAGS);    printf '%s' "${v:-xml,reload}"; }
admin_passwd() { local v; v=$(nenv_get ADMIN_PASSWD); printf '%s' "${v:-9090}"; }
log_level()    { local v; v=$(nenv_get LOG_LEVEL);    printf '%s' "${v:-info}"; }

# ── Homebrew ──────────────────────────────────
# Found by its fixed locations, so nothing has to be added to a shell profile.
BREW=""
brew_find() {
    local b
    for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [ -x "$b" ]; then BREW="$b"; return 0; fi
    done
    BREW="$(command -v brew 2>/dev/null || true)"
    [ -n "$BREW" ]
}
brew_prefix() { "$BREW" --prefix; }

# PATH and library path for everything that builds or runs here: Homebrew,
# Postgres 16's own tools (the formula is keg-only: psql, pg_dump and
# pg_config are not linked into Homebrew's bin), wkhtmltopdf and rtlcss.
# DYLD_FALLBACK_LIBRARY_PATH is how cairocffi (cairosvg) finds Homebrew's
# libcairo; macOS drops the variable whenever a program of the system itself
# is started (nohup, env, sudo), so Odoo is started without one in between.
native_env() {
    brew_find || return 1
    local p; p="$(brew_prefix)"
    PG_BIN="$p/opt/$PG_FORMULA/bin"
    export PATH="$TOOLS/wkhtmltox/bin:$TOOLS/node/node_modules/.bin:$PG_BIN:$p/bin:$p/sbin:$PATH"
    export DYLD_FALLBACK_LIBRARY_PATH="$p/lib${DYLD_FALLBACK_LIBRARY_PATH:+:$DYLD_FALLBACK_LIBRARY_PATH}"
    # The app role's password, where the database driver and the pg_* tools
    # look for it by themselves: it is in no odoo-N.conf and on no command
    # line (the Docker stack does the same, see docker-compose.yml).
    export PGPASSWORD; PGPASSWORD="$(nenv_get DB_PASSWORD)"
    export PGHOST=127.0.0.1 PGPORT; PGPORT="$(db_port)"
    export PGUSER; PGUSER="$(db_user)"
}

# psql as the Mac account, the superuser of Homebrew's cluster, through the
# unix socket (no password). Maintenance only: Odoo never connects this way.
psql_admin() { env -u PGHOST -u PGUSER -u PGPASSWORD "$PG_BIN/psql" -X -p "$(db_port)" -d postgres "$@"; }

pg_ready() { "$PG_BIN/pg_isready" -q -h 127.0.0.1 -p "$(db_port)" 2>/dev/null; }

# ── Instances ─────────────────────────────────
# An instance is its number, 1 to 9. Everything else follows from it.
valid_n()     { [[ "${1:-}" =~ ^[1-9]$ ]]; }
inst_port()   { echo "80${1}0"; }
inst_gevent() { echo "80${1}2"; }
inst_db()     { echo "ephem_$1"; }
inst_dir()    { echo "$NATIVE_HOME/odca$1"; }
inst_conf()   { echo "$CONF_DIR/odoo-$1.conf"; }
inst_log()    { echo "$LOG_DIR/odoo-$1.log"; }
inst_pidf()   { echo "$RUN_DIR/odoo-$1.pid"; }
inst_data()   { echo "$DATA_DIR/$1"; }
inst_url()    { echo "http://localhost:$(inst_port "$1")"; }

# Every instance that has a config, in order.
instances() {
    local f n
    for f in "$CONF_DIR"/odoo-[1-9].conf; do
        [ -f "$f" ] || continue
        n="${f##*/odoo-}"; echo "${n%.conf}"
    done
}

# The pid of a running instance ("" when it is not running). A pid file whose
# process is gone, or is some other program by now, does not count.
inst_pid() {
    local pid; pid=$(cat "$(inst_pidf "$1")" 2>/dev/null || true)
    [[ "$pid" =~ ^[0-9]+$ ]] || return 0
    if ps -ww -p "$pid" -o command= 2>/dev/null | grep -qF "$(inst_conf "$1")"; then echo "$pid"; fi
}

# Who listens on a port: "pid command", or nothing.
port_owner() {
    # lsof exits 1 when nobody listens: not a failure here.
    { lsof -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null || true; } | awk 'NR > 1 { print $2, $1; exit }'
}

# DIR directly holds Odoo modules (name/__manifest__.py).
dir_has_modules() { local m; for m in "$1"/*/__manifest__.py; do [ -f "$m" ] && return 0; done; return 1; }

# addons_path of instance N: its own worktree first (its modules win over a
# same-named one elsewhere), then every repository under extra-addons/, then
# Odoo's own addons. odoo/odoo/addons (base) is added by Odoo itself.
inst_addons_path() {
    local out d
    out="$(inst_dir "$1")"
    for d in "$EXTRA_ADDONS"/*/; do
        [ -d "$d" ] || continue
        dir_has_modules "$d" && out="$out,${d%/}"
    done
    echo "$out,$ODOO_SRC/addons"
}

gen_secret() { openssl rand -hex "${1:-16}" 2>/dev/null || LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | head -c $(( ${1:-16} * 2 )); }

confirm() {  # confirm "Question" [default Y|N]; ASSUME_YES=1 answers the default
    local q="$1" def="${2:-Y}" a hint="[Y/n]"
    [ "$def" = N ] && hint="[y/N]"
    if [ "${ASSUME_YES:-0}" = 1 ]; then a="$def"; else read -r -p "$q $hint: " a || a="$def"; fi
    a="${a:-$def}"
    [[ "$a" =~ ^[Yy] ]]
}
