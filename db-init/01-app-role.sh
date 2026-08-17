#!/bin/sh
# ──────────────────────────────────────────────
# Creates the unprivileged application role for Odoo.
#
# Runs ONCE, when the postgres data volume is first initialized
# (docker-entrypoint-initdb.d semantics). Servers whose volume already
# exists are migrated by scripts/harden-db-role.sh instead (setup.sh
# runs it automatically).
#
# The app role gets LOGIN + CREATEDB and nothing else. Odoo needs
# CREATEDB to create tenant databases; it must never be a SUPERUSER —
# a compromised addon connecting as a superuser could read or drop every
# database and run OS commands inside this container via
# COPY ... FROM PROGRAM.
# ──────────────────────────────────────────────
set -eu

: "${ODOO_DB_USER:=odoo}"

if [ -z "${ODOO_DB_PASSWORD:-}" ]; then
    echo "ERROR: ODOO_DB_PASSWORD is not set — cannot create the app role" >&2
    exit 1
fi

if [ "$ODOO_DB_USER" = "$POSTGRES_USER" ]; then
    echo "WARNING: ODOO_DB_USER equals the superuser '$POSTGRES_USER' — skipping." >&2
    echo "         The app will run with SUPERUSER rights. Use a separate app role." >&2
    exit 0
fi

# psql -v variables (:"..." / :'...') quote the role name and password
# safely, whatever characters they contain.
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres \
     -v role="$ODOO_DB_USER" -v pw="$ODOO_DB_PASSWORD" <<'SQL'
CREATE ROLE :"role" LOGIN CREATEDB NOSUPERUSER NOCREATEROLE NOREPLICATION PASSWORD :'pw';
SQL

echo "Created application role '$ODOO_DB_USER' (LOGIN CREATEDB, no superuser)"
