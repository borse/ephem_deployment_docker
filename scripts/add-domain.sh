#!/bin/bash
# ──────────────────────────────────────────────
# ePHEM — Add domain(s)
#
# Gives each domain its OWN Let's Encrypt certificate and its own nginx
# server block. Nothing shared is expanded, so a later removal is a clean
# delete and one broken domain can never block another one's renewal.
#
# This adds routing only. It never creates a database: point the domain at a
# database of the same first label (training.pheoc.com → 'training') that you
# restore, duplicate or create from the Databases menu in manage.sh.
#
# Usage:
#   ./scripts/add-domain.sh training.pheoc.com
#   ./scripts/add-domain.sh training.pheoc.com simex.pheoc.com staging.pheoc.com
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
    echo "Usage: ./scripts/add-domain.sh DOMAIN [DOMAIN2] [DOMAIN3] ..."
    echo ""
    echo "Examples:"
    echo "  ./scripts/add-domain.sh training.pheoc.com"
    echo "  ./scripts/add-domain.sh training.pheoc.com simex.pheoc.com"
    echo ""
    exit 1
fi

NEW_DOMAINS=("$@")

echo ""
echo "========================================="
echo "  ePHEM — Add domain(s)"
echo "========================================="
echo ""
echo "Requested: ${NEW_DOMAINS[*]}"
echo ""

# ── Step 1: prerequisites ────────────────────
if [ ! -f "$NGINX_ACTIVE" ]; then
    echo -e "${RED}✗${NC} nginx/active.conf not found. Run setup.sh first."
    exit 1
fi

if ! ssl_is_configured; then
    echo -e "${RED}✗${NC} HTTPS is not set up yet, so there is nothing to add a domain to."
    echo "  This server answers on every hostname over HTTP already. Set up SSL"
    echo "  for all of your domains in one go:"
    echo ""
    echo "    bash scripts/ssl-setup.sh $(IFS=,; echo "${NEW_DOMAINS[*]}") you@example.org"
    echo ""
    exit 1
fi

# ── Step 2: which of them are actually new ───
mapfile -t CURRENT < <(active_domains)
echo "Currently served: ${CURRENT[*]:-(none)}"
echo ""

certs_refresh

CANDIDATES=()
for d in "${NEW_DOMAINS[@]}"; do
    if ! valid_domain "$d"; then
        echo -e "${RED}✗${NC} '$d' is not a valid domain name — skipping"
        continue
    fi
    if printf '%s\n' "${CURRENT[@]:-}" | grep -qx "$d"; then
        echo -e "${YELLOW}!${NC} $d is already served — skipping"
        continue
    fi
    if printf '%s\n' "${CANDIDATES[@]:-}" | grep -qx "$d"; then
        continue   # listed twice on the command line
    fi
    CANDIDATES+=("$d")
done

if [ ${#CANDIDATES[@]} -eq 0 ]; then
    echo ""
    echo "Nothing to do — every domain given is already configured."
    exit 0
fi

# ── Step 3: DNS ──────────────────────────────
echo ""
echo "Checking DNS (each domain must point at this server: $(server_ip))..."
TO_ADD=()
for d in "${CANDIDATES[@]}"; do
    OTHER_IP="$(dns_check "$d")"; RC=$?
    case $RC in
        0)  echo -e "  ${GREEN}✓${NC} $d" ;;
        1)  echo -e "  ${RED}✗${NC} $d does not resolve — ask IT for a DNS A record. Skipping."
            continue ;;
        2)  echo -e "  ${YELLOW}!${NC} $d resolves to $OTHER_IP, not $(server_ip)"
            read -r -p "     Try it anyway? [y/N]: " REPLY
            [[ "${REPLY:-N}" =~ ^[Yy]$ ]] || { echo "     Skipping $d"; continue; } ;;
    esac
    TO_ADD+=("$d")
done

if [ ${#TO_ADD[@]} -eq 0 ]; then
    echo ""
    echo -e "${RED}✗ No domain was ready to add.${NC}"
    exit 1
fi

# ── Step 4: email for the certificates ───────
EMAIL="$(ssl_email)"
if [ -z "$EMAIL" ]; then
    read -r -p "Email for certificate expiry notices: " EMAIL
    [ -z "${EMAIL:-}" ] && { echo "Cancelled."; exit 1; }
fi

# ── Step 5: one certificate per domain ───────
echo ""
echo -e "${BOLD}Issuing one certificate per domain${NC} (Let's Encrypt, webroot)"
ISSUED=()
FAILED=()
for d in "${TO_ADD[@]}"; do
    echo ""
    echo -e "  ${CYAN}→${NC} certbot certonly -d $d --cert-name $d"
    if issue_cert "$d" "$EMAIL" 2>&1 | sed 's/^/     /'; then
        ISSUED+=("$d")
    else
        echo -e "  ${RED}✗${NC} Certificate for $d failed — skipping this domain."
        FAILED+=("$d")
    fi
done

if [ ${#ISSUED[@]} -eq 0 ]; then
    echo ""
    echo -e "${RED}✗ No certificate was issued — nothing changed.${NC}"
    echo "  Check that the domains point here and ports 80/443 are open."
    exit 1
fi

# ── Step 6: rewrite nginx and reload ─────────
echo ""
echo "Updating nginx..."
certs_refresh
ALL=("${CURRENT[@]:-}" "${ISSUED[@]}")
CLEAN=()
for d in "${ALL[@]}"; do [ -n "$d" ] && CLEAN+=("$d"); done

render_active_conf "${CLEAN[@]}" || exit 1
nginx_apply || exit 1

# ── Summary ──────────────────────────────────
echo ""
echo "========================================="
echo -e "${GREEN}✓ Added: ${ISSUED[*]}${NC}"
[ ${#FAILED[@]} -gt 0 ] && echo -e "${RED}✗ Failed: ${FAILED[*]}${NC}"
echo ""
echo "Each one now has its own certificate, renewed on its own schedule."
echo ""
echo -e "${BOLD}No database was created.${NC} With dbfilter on (subdomain = database"
echo "name), each domain serves the database named after its first label:"
echo ""
for d in "${ISSUED[@]}"; do
    printf '  https://%-38s → database: %s\n' "$d" "${d%%.*}"
done
echo ""
echo "Put a database there with manage.sh → Advanced → Databases:"
echo "  • Restore    — a snapshot or a VM migration"
echo "  • Duplicate  — a copy of an existing tenant"
echo "  • Create     — a fresh empty database"
echo "========================================="
echo ""
