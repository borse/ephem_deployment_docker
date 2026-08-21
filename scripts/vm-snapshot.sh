#!/bin/bash
# ──────────────────────────────────────────────
# ePHEM VM Snapshot
#
# Takes one database + its filestore off a CLASSIC (non-Docker) Odoo server
# and writes them as a snapshot folder, in exactly the layout the dockerised
# production menu restores from:
#
#     /home/ephem-snapshots/DBNAME_20260822_013000/
#       ├── database.sql.gz
#       ├── filestore.tar.gz
#       └── manifest
#
# Drop that folder into ephem-deploy/backups/ on the production server and it
# appears in the Restore list on its own (manage.sh → Advanced → Databases →
# Restore). No unpacking, no psql by hand.
#
# This script is STANDALONE on purpose: copy just this file to the VM, it
# needs nothing else from the repo.
#
#     scp scripts/vm-snapshot.sh you@vm:~/
#     ssh you@vm 'bash vm-snapshot.sh'
#
# Run it as root, or as the user that owns the filestore (usually 'odoo') —
# the filestore is normally mode 700 and unreadable to anyone else.
# ──────────────────────────────────────────────
set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

case "${1:-}" in
    -h|--help)
        sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
        exit 0 ;;
esac

say()  { echo -e "$@"; }
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}!${NC} $*"; }
die()  { echo -e "  ${RED}✗${NC} $*" >&2; exit 1; }

echo ""
say "${CYAN}${BOLD}ePHEM VM snapshot${NC}  (classic install → production menu)"
echo ""

# ── 1. PostgreSQL connection ──────────────────
read -r -p "  PostgreSQL host [localhost]: " PGHOST;  PGHOST="${PGHOST:-localhost}"
read -r -p "  PostgreSQL port [5432]: "      PGPORT;  PGPORT="${PGPORT:-5432}"
read -r -p "  Database user [odoo]: "        PGUSER;  PGUSER="${PGUSER:-odoo}"
# Local installs usually authenticate by peer/trust when you are root or the
# odoo user, so an empty password is normal and not an error.
read -r -s -p "  Password (empty if this server uses peer/trust auth): " PGPASSWORD
echo ""
export PGHOST PGPORT PGUSER
[ -n "${PGPASSWORD:-}" ] && export PGPASSWORD || unset PGPASSWORD

command -v psql >/dev/null 2>&1 || die "psql is not installed. sudo apt install -y postgresql-client"

echo ""
echo -n "  Connecting... "
SRV_VER=$(psql -d postgres -tAc "SHOW server_version;" 2>/dev/null | tr -d '\r' | awk '{print $1}')
if [ -z "$SRV_VER" ]; then
    echo ""
    die "Could not connect as '$PGUSER' to $PGHOST:$PGPORT.
     Check the user, the password, and that pg_hba.conf allows this login."
fi
SRV_MAJOR="${SRV_VER%%.*}"
echo "server is PostgreSQL $SRV_VER"

# ── 2. Pick a pg_dump that is new enough ──────
# pg_dump refuses to dump a server newer than itself ("server version
# mismatch"), and a VM with several clusters installed often has an older one
# first on PATH. Choose deliberately instead of hoping.
PGDUMP=""
BEST=0
for c in /usr/lib/postgresql/*/bin/pg_dump /usr/pgsql-*/bin/pg_dump; do
    [ -x "$c" ] || continue
    v=$("$c" --version 2>/dev/null | awk '{print $NF}'); v="${v%%.*}"
    printf '%s' "$v" | grep -Eq '^[0-9]+$' || continue
    if [ "$v" -ge "$SRV_MAJOR" ] && [ "$v" -gt "$BEST" ]; then BEST="$v"; PGDUMP="$c"; fi
done
if [ -z "$PGDUMP" ] && command -v pg_dump >/dev/null 2>&1; then
    v=$(pg_dump --version 2>/dev/null | awk '{print $NF}'); v="${v%%.*}"
    if printf '%s' "$v" | grep -Eq '^[0-9]+$' && [ "$v" -ge "$SRV_MAJOR" ]; then
        PGDUMP=$(command -v pg_dump); BEST="$v"
    fi
fi
if [ -z "$PGDUMP" ]; then
    say ""
    warn "No pg_dump of version $SRV_MAJOR or newer was found on this machine."
    echo "     Installed: $(ls -1d /usr/lib/postgresql/*/bin/pg_dump 2>/dev/null | tr '\n' ' ')${NC}"
    echo "     Install a matching client, then run this again:"
    echo "       sudo apt install -y postgresql-client-$SRV_MAJOR"
    read -r -p "  Or type the full path to a pg_dump to use anyway (empty to abort): " PGDUMP
    [ -z "${PGDUMP:-}" ] && die "Aborted."
    [ -x "$PGDUMP" ] || die "Not executable: $PGDUMP"
else
    ok "Using $PGDUMP (version $BEST)"
fi

# ── 3. Filestore location ─────────────────────
# Odoo keeps attachments at <data_dir>/filestore/<database>. Where data_dir
# lands depends on how the server was installed, so read the config first and
# fall back to the two paths the packages actually use.
DETECTED=""
for conf in /etc/odoo/odoo.conf /etc/odoo.conf /etc/odoo-server.conf \
            /opt/odoo/odoo.conf /opt/odoo/odoo-server.conf; do
    [ -f "$conf" ] || continue
    d=$(grep -E '^[[:space:]]*data_dir[[:space:]]*=' "$conf" 2>/dev/null \
        | head -1 | cut -d'=' -f2- | xargs)
    if [ -n "$d" ] && [ -d "$d/filestore" ]; then DETECTED="$d/filestore"; break; fi
done
if [ -z "$DETECTED" ]; then
    for d in /var/lib/odoo/filestore /var/lib/odoo/.local/share/Odoo/filestore \
             /opt/odoo/.local/share/Odoo/filestore /home/odoo/.local/share/Odoo/filestore; do
        [ -d "$d" ] && { DETECTED="$d"; break; }
    done
fi
echo ""
read -r -p "  Filestore folder [${DETECTED:-not found, type it}]: " FILESTORE
FILESTORE="${FILESTORE:-$DETECTED}"
FILESTORE="${FILESTORE%/}"
[ -z "$FILESTORE" ] && die "A filestore path is required."
if [ ! -d "$FILESTORE" ]; then
    warn "$FILESTORE does not exist — the snapshot will hold the database only."
elif [ ! -r "$FILESTORE" ]; then
    die "$FILESTORE is not readable by $(whoami).
     Re-run with sudo, or as the user that owns it (usually 'odoo')."
else
    # Echoed because `read -p` shows nothing when input is piped, and because
    # picking up the wrong filestore is a silent way to ship an empty tenant.
    ok "Filestore: $FILESTORE"
fi

# ── 4. Which database ─────────────────────────
echo ""
echo "  Databases on this server:"
psql -d postgres -tAc \
    "SELECT datname || '  (' || pg_size_pretty(pg_database_size(datname)) || ')'
       FROM pg_database WHERE datistemplate = false AND datname <> 'postgres'
      ORDER BY datname;" 2>/dev/null | tr -d '\r' | sed 's/^/    • /'
echo ""
read -r -p "  Database to snapshot: " DB
[ -z "${DB:-}" ] && die "Cancelled."
printf '%s' "$DB" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$' \
    || die "'$DB' is not a valid database name (letters, digits, . _ -)."
[ "$(psql -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$DB';" 2>/dev/null | tr -d '\r')" = "1" ] \
    || die "No database named '$DB' on this server."

HAS_FS=no
[ -d "$FILESTORE/$DB" ] && HAS_FS=yes
[ "$HAS_FS" = no ] && warn "No $FILESTORE/$DB — this tenant has no attachments, or the path is wrong."

# ── 5. Where to write it ──────────────────────
echo ""
DEFAULT_OUT="/home/ephem-snapshots"
read -r -p "  Write the snapshot under [$DEFAULT_OUT]: " OUTROOT
OUTROOT="${OUTROOT:-$DEFAULT_OUT}"; OUTROOT="${OUTROOT%/}"
if ! mkdir -p "$OUTROOT" 2>/dev/null; then
    warn "Cannot create $OUTROOT (needs root?) — using $HOME/ephem-snapshots instead."
    OUTROOT="$HOME/ephem-snapshots"
    mkdir -p "$OUTROOT" || die "Cannot create $OUTROOT either."
fi
TS=$(date +%Y%m%d_%H%M%S)
DIR="$OUTROOT/${DB}_${TS}"
mkdir -p "$DIR" || die "Cannot create $DIR"
# Dumps are health data in the clear. Keep them off other accounts on the box.
chmod 700 "$DIR"

# ── 6. Dump ───────────────────────────────────
echo ""
say "${CYAN}→${NC} Snapshot: $DIR"
echo "     dumping '$DB'..."
if ! "$PGDUMP" -d "$DB" </dev/null | gzip > "$DIR/database.sql.gz" \
   || ! gzip -t "$DIR/database.sql.gz" 2>/dev/null; then
    rm -rf "$DIR"
    die "pg_dump failed or produced a corrupt file — snapshot discarded."
fi
# Cheap sanity check that this really is an Odoo database and not, say, a
# leftover template someone named similarly. grep stops at the first hit,
# which kills gunzip with SIGPIPE — under `set -o pipefail` that would read as
# a failed check on a perfectly good dump, so step around pipefail here.
set +o pipefail
gunzip -c "$DIR/database.sql.gz" | grep -qm1 'ir_module_module'
SANE=$?
set -o pipefail
if [ "$SANE" -ne 0 ]; then
    rm -rf "$DIR"
    die "'$DB' does not look like an Odoo database (no ir_module_module) — discarded."
fi
ok "database.sql.gz    ($(du -h "$DIR/database.sql.gz" | cut -f1))"

if [ "$HAS_FS" = yes ]; then
    echo "     archiving filestore..."
    rc=0
    # tar exit 1 = "file changed while reading", routine on a live server.
    # Exit 2+ is a real failure.
    tar -czf "$DIR/filestore.tar.gz" -C "$FILESTORE" "$DB" 2>/dev/null || rc=$?
    if [ "$rc" -gt 1 ] || ! gzip -t "$DIR/filestore.tar.gz" 2>/dev/null; then
        rm -rf "$DIR"
        die "Filestore archive failed (tar exit $rc) — snapshot discarded."
    fi
    [ "$rc" -eq 1 ] && warn "files changed while archiving (normal on a live server)"
    ok "filestore.tar.gz   ($(du -h "$DIR/filestore.tar.gz" | cut -f1))"
fi

{ echo "database=$DB"
  echo "created=$(date '+%Y-%m-%d %H:%M:%S')"
  echo "db_dump=yes"
  echo "filestore=$HAS_FS"
  echo "host=$(hostname)"
  echo "source=vm-snapshot.sh"
  echo "pg_version=$SRV_VER"
} > "$DIR/manifest"
chmod 600 "$DIR"/*
ok "Snapshot ready: $DIR  ($(du -sh "$DIR" | cut -f1))"

# ── 7. How to move it ─────────────────────────
VM_USER=$(whoami)
VM_HOST=$(printf '%s' "${SSH_CONNECTION:-}" | awk '{print $3}')
[ -z "$VM_HOST" ] && VM_HOST=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -z "$VM_HOST" ] && VM_HOST="VM_IP"

echo ""
read -r -p "  Production server ssh target (e.g. ephem@10.0.0.5), empty to skip: " PROD
PROD="${PROD:-USER@PRODUCTION_HOST}"
read -r -p "  ephem-deploy path on production [/home/${PROD%%@*}/ephem-deploy]: " PRODPATH
PRODPATH="${PRODPATH:-/home/${PROD%%@*}/ephem-deploy}"; PRODPATH="${PRODPATH%/}"

FOLDER="${DB}_${TS}"
echo ""
say "${BOLD}────────────────────────────────────────────────────────${NC}"
say "${BOLD}Moving it${NC}"
echo ""
echo "  Written as $(whoami), mode 700 — copy it as that same user (or root),"
echo "  or hand it to yourself first:  sudo chown -R \$USER $DIR"
echo ""
say "${CYAN}A) Straight from this VM to production${NC} (fastest, no desktop hop)"
echo "   Run HERE, on this VM:"
echo ""
echo "     scp -r $DIR $PROD:$PRODPATH/backups/"
echo ""
echo "   Large filestore, or a shaky link? Use rsync, it resumes:"
echo ""
echo "     rsync -avP $DIR $PROD:$PRODPATH/backups/"
echo ""
say "${CYAN}B) Via your desktop${NC} (Windows cmd or PowerShell)"
echo ""
echo "   Download:"
echo "     scp -r $VM_USER@$VM_HOST:$DIR %USERPROFILE%\\Downloads\\"
echo ""
echo "   Upload to production:"
echo "     scp -r %USERPROFILE%\\Downloads\\$FOLDER $PROD:$PRODPATH/backups/"
echo ""
echo "   (On macOS or Linux use ~/Downloads instead of %USERPROFILE%\\Downloads\\)"
echo ""
say "${CYAN}C) Then restore it on production${NC}"
echo ""
echo "     ssh $PROD"
echo "     cd $PRODPATH && bash manage.sh"
echo "       → 11) Advanced"
echo "       → 2) Databases"
echo "       → 2) Restore        ← '$DB' is already in the list"
echo ""
echo "   Landing it in backups/ is what puts it in that list. Anywhere else"
echo "   works too: paste the full path at the same prompt instead."
echo ""
say "${BOLD}────────────────────────────────────────────────────────${NC}"
warn "This folder holds patient data in the clear. Delete it from both the"
echo "     VM and your desktop once production shows the tenant restored:"
echo "       rm -rf $DIR"
echo ""
