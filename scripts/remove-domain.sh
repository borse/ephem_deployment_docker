#!/bin/bash
# ──────────────────────────────────────────────
# ePHEM — Remove domain(s)
#
# Stops serving a domain: drops its nginx server block and deletes its
# certificate (and the renewal job that goes with it). A domain that still
# sits on a shared certificate is taken off it instead, so the certificate
# keeps renewing for the names that remain.
#
# Databases and filestores are never touched — the tenant's data survives,
# only the way in disappears. Delete data from:
#   bash manage.sh → Advanced → Databases → Delete
#
# Usage:
#   ./scripts/remove-domain.sh training.pheoc.com
#   ./scripts/remove-domain.sh training.pheoc.com simex.pheoc.com
# ──────────────────────────────────────────────

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EPHEM_ROOT="$SCRIPT_DIR"
# shellcheck source=scripts/nginx-lib.sh
source "$SCRIPT_DIR/scripts/nginx-lib.sh"

if [ $# -lt 1 ]; then
    echo ""
    echo "Usage: ./scripts/remove-domain.sh DOMAIN [DOMAIN2] ..."
    echo ""
    echo "Examples:"
    echo "  ./scripts/remove-domain.sh training.pheoc.com"
    echo "  ./scripts/remove-domain.sh training.pheoc.com simex.pheoc.com"
    echo ""
    exit 1
fi

WANTED=("$@")

echo ""
echo "========================================="
echo "  ePHEM — Remove domain(s)"
echo "========================================="
echo ""

if [ ! -f "$NGINX_ACTIVE" ] || ! ssl_is_configured; then
    echo -e "${RED}✗${NC} No HTTPS configuration to remove a domain from."
    echo "  (This server serves every hostname over plain HTTP.)"
    exit 1
fi

mapfile -t CURRENT < <(active_domains)
if [ ${#CURRENT[@]} -eq 0 ]; then
    echo -e "${RED}✗${NC} No domains found in nginx/active.conf."
    exit 1
fi

echo "Currently served: ${CURRENT[*]}"
echo ""

# ── Step 1: what can actually be removed ─────
REMOVE=()
for d in "${WANTED[@]}"; do
    if ! printf '%s\n' "${CURRENT[@]}" | grep -qx "$d"; then
        echo -e "${YELLOW}!${NC} $d is not served here — skipping"
        continue
    fi
    printf '%s\n' "${REMOVE[@]:-}" | grep -qx "$d" && continue
    REMOVE+=("$d")
done

if [ ${#REMOVE[@]} -eq 0 ]; then
    echo ""
    echo "Nothing to do."
    exit 0
fi

# What is left afterwards
KEEP=()
for d in "${CURRENT[@]}"; do
    printf '%s\n' "${REMOVE[@]}" | grep -qx "$d" || KEEP+=("$d")
done

certs_refresh

# ── Step 2: show the damage, then confirm ────
echo -e "${BOLD}Will stop serving:${NC}"
for d in "${REMOVE[@]}"; do
    LIN="$(lineage_for_domain "$d")" || LIN=""
    if [ -z "$LIN" ]; then
        echo "  • $d   (no certificate found — nginx block only)"
    elif [ "$(cert_domains_of "$LIN")" = "$d" ]; then
        echo "  • $d   (certificate '$LIN' deleted)"
    else
        echo "  • $d   (taken off shared certificate '$LIN')"
    fi
done
echo ""
if [ ${#KEEP[@]} -eq 0 ]; then
    echo -e "${YELLOW}!${NC} That is every domain on this server. nginx would be left with no"
    echo "   HTTPS site at all, so the config falls back to HTTP-only."
    read -r -p "  Fall back to HTTP-only? [y/N]: " C
    [[ "${C:-N}" =~ ^[Yy]$ ]] || { echo "  Cancelled."; exit 0; }
else
    echo -e "${BOLD}Still served:${NC} ${KEEP[*]}"
    echo ""
    echo "  Databases and filestores are NOT touched — only the route in."
    read -r -p "  Continue? [y/N]: " C
    [[ "${C:-N}" =~ ^[Yy]$ ]] || { echo "  Cancelled."; exit 0; }
fi

# ── Step 3: nginx first ──────────────────────
# The config must stop referencing a certificate before that certificate is
# deleted, or the next nginx reload fails and takes every tenant with it.
echo ""
echo "Updating nginx..."
if [ ${#KEEP[@]} -eq 0 ]; then
    render_http_only_conf || exit 1
else
    render_active_conf "${KEEP[@]}" || exit 1
fi
nginx_apply || {
    echo -e "  ${RED}✗${NC} nginx was rolled back — no certificate was deleted."
    exit 1
}

# ── Step 4: certificates ─────────────────────
echo ""
echo "Cleaning up certificates..."
EMAIL="$(ssl_email)"
for d in "${REMOVE[@]}"; do
    LIN="$(lineage_for_domain "$d")" || LIN=""
    [ -z "$LIN" ] && continue

    COVERED="$(cert_domains_of "$LIN")"
    LEFT=()
    for c in $COVERED; do
        printf '%s\n' "${REMOVE[@]}" | grep -qx "$c" || LEFT+=("$c")
    done

    if [ ${#LEFT[@]} -eq 0 ]; then
        echo -e "  ${CYAN}→${NC} certbot delete --cert-name $LIN"
        if delete_cert "$LIN" >/dev/null 2>&1; then
            echo -e "  ${GREEN}✓${NC} certificate '$LIN' deleted"
        else
            echo -e "  ${YELLOW}!${NC} could not delete '$LIN' — remove it later with:"
            echo "     docker compose run --rm --entrypoint certbot certbot delete --cert-name $LIN"
        fi
    else
        # Shared certificate with survivors: re-issue it without the removed
        # names, otherwise renewal keeps validating a domain that is gone.
        echo -e "  ${CYAN}→${NC} re-issuing shared certificate '$LIN' without $d"
        if [ -z "$EMAIL" ]; then
            echo -e "  ${YELLOW}!${NC} SSL_EMAIL is not set in .env — skipping the re-issue."
            echo "     '$LIN' still lists $d and its renewal will fail once DNS is gone."
            continue
        fi
        if reissue_cert "$LIN" "$EMAIL" "${LEFT[@]}" 2>&1 | sed 's/^/     /'; then
            echo -e "  ${GREEN}✓${NC} '$LIN' now covers: ${LEFT[*]}"
        else
            echo -e "  ${YELLOW}!${NC} re-issue failed — '$LIN' still lists $d."
            echo "     Renewal keeps working until $d's DNS record disappears; fix it with"
            echo "     manage.sh → Manage domains → Split the shared certificate."
        fi
    fi
    certs_refresh
done

# ── Step 5: what is left behind ──────────────
echo ""
echo "========================================="
echo -e "${GREEN}✓ Removed: ${REMOVE[*]}${NC}"
echo ""
DBS=$(docker compose -f "$SCRIPT_DIR/docker-compose.yml" exec -T db \
        psql -U "$(grep '^POSTGRES_USER=' "$SCRIPT_DIR/.env" 2>/dev/null | cut -d= -f2- | xargs || echo odoo)" \
        -d postgres -t -A -c \
        "SELECT datname FROM pg_database WHERE datistemplate = false AND datname <> 'postgres';" \
        </dev/null 2>/dev/null | tr -d '\r')
LEFTOVER=()
for d in "${REMOVE[@]}"; do
    printf '%s\n' "$DBS" | grep -qx "${d%%.*}" && LEFTOVER+=("${d%%.*}")
done
if [ ${#LEFTOVER[@]} -gt 0 ]; then
    echo -e "${YELLOW}!${NC} These databases are still on the server, now unreachable:"
    printf '     • %s\n' "${LEFTOVER[@]}"
    echo ""
    echo "  Keep them (a domain can be added back later), or remove them:"
    echo "    bash manage.sh → Advanced → Databases → Backup, then Delete"
fi
echo "========================================="
echo ""
