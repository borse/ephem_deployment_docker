#!/bin/bash
# ──────────────────────────────────────────────────────────────
# install.sh — the native macOS developer setup. bash setup.sh hands off
# here (Developer → Native); it can also be run directly, and run again:
# every step looks first and only does what is missing. It never deletes
# anything and never touches a shell profile.
#
# What it puts in place (see lib.sh for the layout of the native home):
#   1. Homebrew, and with it: PostgreSQL 16, uv, node, and the libraries
#      the Python packages build against or load
#   2. Rosetta on Apple Silicon (the patched wkhtmltopdf is Intel only)
#   3. PostgreSQL 16 as a service, with the unprivileged app role the
#      Docker stack creates in db-init/01-app-role.sh
#   4. the Odoo 18.0 source and one Python 3.12 virtualenv
#   5. wkhtmltopdf 0.12.6 with patched Qt, and rtlcss
#   6. the ePHEM clone and one worktree + config per instance
#
# Usage:
#   bash scripts/macos/install.sh [options]
#     --home DIR          the native home (default: ~/Developer/ephem)
#     --instances "1 2 3" the instances to create (default: 1 2 3)
#     --branch NAME       their branch (default: 18_ephem_2)
#     --no-instances      stop after the tools; create instances later with dev.sh
#     --update-odoo       also pull the Odoo source and reinstall its requirements
#     --yes               take the default answer to every question
#
# sudo: this script never calls it. Homebrew's own installer asks for the
# password once, when Homebrew is not there yet.
# ──────────────────────────────────────────────────────────────
set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

OPT_HOME=""
OPT_INSTANCES="1 2 3"
OPT_BRANCH="$DEFAULT_BRANCH"
OPT_NO_INSTANCES=0
OPT_UPDATE_ODOO=0
ASSUME_YES=0
while [ $# -gt 0 ]; do
    case "$1" in
        --home)         OPT_HOME="${2:-}"; shift ;;
        --instances)    OPT_INSTANCES="${2:-}"; shift ;;
        --branch)       OPT_BRANCH="${2:-}"; shift ;;
        --no-instances) OPT_NO_INSTANCES=1 ;;
        --update-odoo)  OPT_UPDATE_ODOO=1 ;;
        --yes|-y)       ASSUME_YES=1 ;;
        -h|--help)      sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)              die "Unknown option: $1  (bash scripts/macos/install.sh --help)" ;;
    esac
    shift
done
export ASSUME_YES

[ "$(id -u)" -ne 0 ] || die "Don't run this under sudo: Homebrew refuses to, and every file would belong to root."

echo ""
echo "========================================="
echo "  ePHEM native developer setup (macOS)"
echo "========================================="

# ── Where ─────────────────────────────────────
if [ -z "$OPT_HOME" ] && [ -z "${EPHEM_NATIVE_HOME:-}" ] && [ ! -f "$NATIVE_MARKER" ] && [ "$ASSUME_YES" != 1 ]; then
    echo ""
    echo "Where should Odoo, the virtualenv, the ePHEM clone and the instances live?"
    echo "(Not inside this repo: $EPHEM_ROOT stays as it is.)"
    read -r -p "Folder [$NATIVE_HOME]: " OPT_HOME || OPT_HOME=""
fi
if [ -n "$OPT_HOME" ]; then
    case "$OPT_HOME" in "~"*) OPT_HOME="$HOME${OPT_HOME#\~}" ;; esac
    case "$OPT_HOME" in /*) ;; *) die "--home needs a full path (got: $OPT_HOME)" ;; esac
    native_paths "$OPT_HOME"
fi
case "$NATIVE_HOME/" in
    "$EPHEM_ROOT"/*) die "The native home must not be inside the deployment repo ($EPHEM_ROOT)." ;;
esac
mkdir -p "$NATIVE_HOME" "$CONF_DIR" "$DATA_DIR" "$LOG_DIR" "$RUN_DIR" "$TOOLS" "$EXTRA_ADDONS"
ok "Native home: $NATIVE_HOME"

# ── 1. Homebrew ───────────────────────────────
step "1/6  Homebrew and system libraries"
if ! brew_find; then
    echo "Homebrew is not installed. Its installer asks for your Mac password once"
    echo "(it creates /opt/homebrew) and takes a few minutes."
    confirm "Install Homebrew now?" Y || die "Install it yourself (https://brew.sh), then run this again."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
        || die "Homebrew's installer did not finish. Run it in a terminal of your own, then run this again:
    /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
    brew_find || die "Homebrew still not found after its installer ran."
fi
ok "Homebrew: $BREW"

# What each one is for:
#   postgresql@16   the database, the same major version as production; also
#                   pg_config and libpq, which psycopg2 builds against
#   uv              Python 3.12 and the virtualenv
#   node            rtlcss (right-to-left stylesheets: Arabic)
#   openldap        python-ldap builds against it
#   openssl@3       psycopg2 and python-ldap link to it
#   cairo           cairosvg loads libcairo
#   freetype        rl-renderPM (reportlab) builds against it
#   libmagic        python-magic loads it
FORMULAE="$PG_FORMULA uv node openldap openssl@3 cairo freetype libmagic"
MISSING=""
for f in $FORMULAE; do
    "$BREW" list --formula "$f" >/dev/null 2>&1 || MISSING="$MISSING $f"
done
if [ -n "$MISSING" ]; then
    echo "Installing with Homebrew:$MISSING"
    # shellcheck disable=SC2086  # one formula per word
    HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 "$BREW" install $MISSING
fi
ok "Homebrew packages present: $FORMULAE"
native_env

# ── 2. Rosetta ────────────────────────────────
if [ "$(uname -m)" = arm64 ] && ! arch -x86_64 /usr/bin/true 2>/dev/null; then
    step "Rosetta"
    echo "wkhtmltopdf with patched Qt (PDF reports with headers and footers) exists for"
    echo "Intel Macs only; on Apple Silicon it runs under Rosetta."
    if confirm "Install Rosetta now?" Y; then
        softwareupdate --install-rosetta --agree-to-license \
            || warn "Rosetta was not installed. Run it yourself: softwareupdate --install-rosetta --agree-to-license"
    fi
fi

# ── 3. PostgreSQL ─────────────────────────────
step "2/6  PostgreSQL 16"
if ! pg_ready; then
    OWNER="$(port_owner "$(db_port)")"
    [ -z "$OWNER" ] || die "Port $(db_port) is taken by another program (pid and name: $OWNER), and it is not a Postgres that answers. Stop it, or set DB_PORT in $NATIVE_ENV."
    "$BREW" services start "$PG_FORMULA"
    for _ in $(seq 1 30); do pg_ready && break; sleep 1; done
fi
pg_ready || die "Postgres did not start. Look at: brew services info $PG_FORMULA   and   $(brew_prefix)/var/log/$PG_FORMULA.log"
SERVER_VERSION="$(psql_admin -Atc 'SHOW server_version' 2>/dev/null || true)"
[ -n "$SERVER_VERSION" ] || die "A Postgres answers on port $(db_port), but your Mac account ($(id -un)) cannot log into it as a superuser.
  Is it another installation (Postgres.app, a Docker port)? Stop it, then run this again."
case "$SERVER_VERSION" in
    16.*) ok "PostgreSQL $SERVER_VERSION running as a Homebrew service (starts with the Mac)" ;;
    *)    warn "The Postgres on port $(db_port) is version $SERVER_VERSION, not 16: production runs 16." ;;
esac

# The app role, as db-init/01-app-role.sh creates it in the Docker stack:
# LOGIN + CREATEDB and nothing else. Odoo needs CREATEDB to create its
# databases; it is never a superuser. Run again, this puts the role back to
# exactly that and to the password in conf/native.env.
nenv_default DB_USER odoo
nenv_default DB_PORT 5432
nenv_default DB_PASSWORD "$(gen_secret 16)"
nenv_default BIND_HOST 127.0.0.1
nenv_default DEV_FLAGS xml,reload
nenv_default ADMIN_PASSWD 9090
nenv_default LOG_LEVEL info
nenv_default OFFICE 0
chmod 600 "$NATIVE_ENV"
native_env
ROLE="$(db_user)"
if [ "$ROLE" = "$(id -un)" ]; then
    warn "DB_USER equals your Mac account, the superuser of this Postgres: skipped. Odoo would run as a superuser; use another role name."
else
    psql_admin -q -v ON_ERROR_STOP=1 -v role="$ROLE" -v pw="$(nenv_get DB_PASSWORD)" <<'SQL'
SELECT format('CREATE ROLE %I', :'role')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'role') \gexec
ALTER ROLE :"role" LOGIN CREATEDB NOSUPERUSER NOCREATEROLE NOREPLICATION PASSWORD :'pw';
SQL
    ok "App role '$ROLE' (LOGIN CREATEDB, no superuser); its password is in conf/native.env"
fi

# ── 4. Odoo source and the virtualenv ─────────
step "3/6  Odoo $ODOO_BRANCH source"
if [ -f "$ODOO_SRC/odoo-bin" ]; then
    ok "odoo/ already there ($(git -C "$ODOO_SRC" log -1 --format='%h, %cd' --date=short 2>/dev/null || echo 'not a git clone'))"
    if [ "$OPT_UPDATE_ODOO" = 1 ]; then
        echo "  Pulling $ODOO_BRANCH…"
        git -C "$ODOO_SRC" pull --ff-only --depth 1 origin "$ODOO_BRANCH" || warn "Could not pull odoo/ (local changes?). Left as it is."
    fi
elif [ -n "$(ls -A "$ODOO_SRC" 2>/dev/null)" ]; then
    die "$ODOO_SRC has files but no odoo-bin: move it away, then run this again."
else
    echo "  Cloning $ODOO_REPO ($ODOO_BRANCH, latest commit only; a few hundred MB)…"
    git clone --depth 1 --branch "$ODOO_BRANCH" --single-branch "$ODOO_REPO" "$ODOO_SRC"
    ok "odoo/ cloned"
fi

step "4/6  Python $PYTHON_VERSION virtualenv"
if [ ! -x "$PY" ]; then
    uv venv --python "$PYTHON_VERSION" "$VENV"
fi
ok "venv/: $("$PY" --version 2>&1)"
# Installed again only when one of the two requirement files changed.
REQ_SUM="$(cat "$ODOO_SRC/requirements.txt" "$MAC_DIR/requirements-ephem.txt" | shasum -a 256 | awk '{print $1}')"
if [ "$(cat "$VENV/.ephem-requirements" 2>/dev/null || true)" = "$REQ_SUM" ]; then
    ok "Python packages already installed (requirements unchanged)"
else
    P="$(brew_prefix)"
    # Where the packages that are compiled here find their headers and
    # libraries: psycopg2 (pg_config is on PATH), python-ldap, rl-renderPM.
    export LDFLAGS="-L$P/opt/openssl@3/lib -L$P/opt/openldap/lib -L$P/opt/freetype/lib ${LDFLAGS:-}"
    export CPPFLAGS="-I$P/opt/openssl@3/include -I$P/opt/openldap/include -I$P/opt/freetype/include/freetype2 ${CPPFLAGS:-}"
    echo "  Installing Odoo's requirements.txt…"
    uv pip install --python "$PY" -r "$ODOO_SRC/requirements.txt"
    echo "  Installing what the ePHEM image adds (scripts/macos/requirements-ephem.txt)…"
    uv pip install --python "$PY" -r "$MAC_DIR/requirements-ephem.txt"
    echo "$REQ_SUM" > "$VENV/.ephem-requirements"
    ok "Python packages installed"
fi

# ── 5. wkhtmltopdf and rtlcss ─────────────────
step "5/6  wkhtmltopdf (patched Qt) and rtlcss"
WK="$TOOLS/wkhtmltox/bin/wkhtmltopdf"
if [ -x "$WK" ] && "$WK" --version 2>/dev/null | grep -q "with patched qt"; then
    ok "$("$WK" --version)"
else
    TMP="$(mktemp -d)"
    echo "  Downloading $(basename "$WKHTML_URL")…"
    curl -fSL --progress-bar -o "$TMP/wkhtmltox.pkg" "$WKHTML_URL"
    GOT="$(shasum -a 256 "$TMP/wkhtmltox.pkg" | awk '{print $1}')"
    if [ "$GOT" != "$WKHTML_SHA256" ]; then
        rm -rf "$TMP"
        die "wkhtmltox.pkg does not have the expected checksum (got $GOT). Not installed."
    fi
    # Unpacked into tools/ instead of installed: the package's installer
    # only untars this same archive into /usr/local, and needs sudo for it.
    pkgutil --expand-full "$TMP/wkhtmltox.pkg" "$TMP/pkg"
    mkdir -p "$TOOLS/wkhtmltox"
    tar -xzf "$TMP/pkg/Payload/usr/local/share/wkhtmltox-installer/wkhtmltox.tar.gz" -C "$TOOLS/wkhtmltox"
    rm -rf "$TMP"
    if "$WK" --version 2>/dev/null | grep -q "with patched qt"; then
        ok "$("$WK" --version)  → tools/wkhtmltox/"
    else
        warn "wkhtmltopdf is unpacked in tools/wkhtmltox/ but does not run (Rosetta missing?). PDF reports will fail until it does."
    fi
fi
if [ -x "$TOOLS/node/node_modules/.bin/rtlcss" ]; then
    ok "rtlcss present"
else
    mkdir -p "$TOOLS/node"
    if npm install --prefix "$TOOLS/node" --no-fund --no-audit --loglevel=error rtlcss; then
        ok "rtlcss installed → tools/node/"
    else
        warn "rtlcss was not installed: right-to-left languages (Arabic) will show unstyled. Later: npm install --prefix $TOOLS/node rtlcss"
    fi
fi

# ── Record the setup for manage.sh ────────────
cat > "$NATIVE_MARKER" <<EOF
# Written by scripts/macos/install.sh: this Mac has a native developer setup.
# bash manage.sh opens its menu (scripts/macos/dev.sh menu); delete this file
# and manage.sh is the Docker menu again. Not in git.
EPHEM_NATIVE_HOME=$NATIVE_HOME
EOF
ok "Recorded in $(basename "$NATIVE_MARKER"): bash manage.sh now opens the native menu"

# ── 6. ePHEM and the instances ────────────────
step "6/6  ePHEM and the instances"
if [ -d "$CORE_CLONE/.git" ]; then
    ok "ePHEM/ already cloned (branch: $(git -C "$CORE_CLONE" branch --show-current 2>/dev/null || true)): left as it is"
elif [ -n "$(ls -A "$CORE_CLONE" 2>/dev/null)" ]; then
    die "$CORE_CLONE has files but is not a git clone: move it away, then run this again."
else
    SSH_TEST="$(ssh -o BatchMode=yes -o ConnectTimeout=15 -T git@github.com 2>&1 || true)"
    if ! echo "$SSH_TEST" | grep -qi "successfully authenticated"; then
        err "Could not authenticate with GitHub over SSH (ssh -T git@github.com)."
        echo "  Developer mode clones borse/ePHEM with your own GitHub SSH key: add the key to"
        echo "  your GitHub account and ask the ePHEM team for collaborator access, then run"
        echo "  this again. Everything installed so far is kept. (README.md: GitHub SSH Key)"
        exit 1
    fi
    echo "  Cloning $CORE_REPO_URL (every branch; the working copy is on $OPT_BRANCH)…"
    git clone --branch "$OPT_BRANCH" "$CORE_REPO_URL" "$CORE_CLONE" \
        || die "Clone failed: does branch '$OPT_BRANCH' exist, and does your GitHub account have access to borse/ePHEM?"
    ok "ePHEM/ cloned: the base checkout, on $OPT_BRANCH"
fi

DEV="$MAC_DIR/dev.sh"
if [ "$OPT_NO_INSTANCES" = 1 ]; then
    echo ""
    echo "No instance created (--no-instances). Later: bash scripts/macos/dev.sh create 1"
    exit 0
fi

if [ "$ASSUME_YES" != 1 ]; then
    echo ""
    read -r -p "Instances to create (numbers 1-9, space-separated) [$OPT_INSTANCES]: " A || A=""
    OPT_INSTANCES="${A:-$OPT_INSTANCES}"
    read -r -p "Branch for the new ones [$OPT_BRANCH]: " A || A=""
    OPT_BRANCH="${A:-$OPT_BRANCH}"
fi
for n in $OPT_INSTANCES; do
    valid_n "$n" || die "'$n' is not an instance number (1 to 9)."
done
for n in $OPT_INSTANCES; do
    bash "$DEV" create "$n" "$OPT_BRANCH"
done

NEED_DB=""
for n in $OPT_INSTANCES; do
    [ "$("$PG_BIN/psql" -X -d postgres -Atc "SELECT 1 FROM pg_database WHERE datname = '$(inst_db "$n")'" 2>/dev/null)" = 1 ] || NEED_DB="$NEED_DB $n"
done
if [ -n "$NEED_DB" ]; then
    echo ""
    echo "Databases not created yet:$(for n in $NEED_DB; do printf ' %s' "$(inst_db "$n")"; done)"
    echo "An empty Odoo database each (module base only, a few seconds per database);"
    echo "the ePHEM modules are then installed (dev.sh install N MODULES, or Apps), or"
    echo "you restore a backup over it (dev.sh restore N SOURCE)."
    if confirm "Create them now?" Y; then
        for n in $NEED_DB; do bash "$DEV" initdb "$n"; done
    else
        echo "  Later: bash scripts/macos/dev.sh initdb N   (or: restore N SOURCE)"
    fi
fi

echo ""
# shellcheck disable=SC2086  # one instance number per word
bash "$DEV" start $OPT_INSTANCES || true
echo ""
bash "$DEV" status || true

FIRST="${OPT_INSTANCES%% *}"
cat <<EOF

─────────────────────────────────────────
Done. Each instance: its folder $NATIVE_HOME/odcaN (open that in your editor
or start your coding agent there), its database ephem_N, its port 80N0.
Login of a new database: admin / admin.  Master password: $(admin_passwd).

  bash manage.sh                          the menu
  bash scripts/macos/dev.sh status        every instance
  bash scripts/macos/dev.sh restart $FIRST     restart one
  bash scripts/macos/dev.sh install $FIRST eoc_base
  bash scripts/macos/dev.sh update $FIRST eoc_base
  bash scripts/macos/dev.sh logs $FIRST

PyCharm: interpreter $PY
More: docs/macos-native-dev.md
EOF
