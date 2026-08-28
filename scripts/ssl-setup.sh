#!/bin/bash
# ──────────────────────────────────────────────
# ePHEM SSL Setup Script
# Run after setup.sh to enable HTTPS.
#
# How it works:
#   - nginx/default.conf  = HTTP-only template (in Git, never modified)
#   - nginx/active.conf   = what NGINX actually uses (git-ignored, generated)
#   - This script gets ONE certificate PER DOMAIN, then writes one HTTPS
#     server block per domain into active.conf
#   - git pull never breaks SSL because it never touches active.conf
#
# One certificate per domain (not one shared certificate listing them all)
# means a domain can be added or removed on its own, and one dead DNS record
# cannot block the renewal of everybody else's certificate.
#
# Usage: ./scripts/ssl-setup.sh DOMAIN[,DOMAIN2,...] EMAIL
# ──────────────────────────────────────────────

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

if [ $# -lt 2 ]; then
    echo ""
    echo "Usage: ./scripts/ssl-setup.sh DOMAIN EMAIL"
    echo ""
    echo "Examples:"
    echo "  ./scripts/ssl-setup.sh ephem.health.gov.ye admin@health.gov.ye"
    echo "  ./scripts/ssl-setup.sh ephem.health.gov.ye,training.ephem.health.gov.ye admin@health.gov.ye"
    echo ""
    exit 1
fi

DOMAINS="$1"
EMAIL="$2"
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EPHEM_ROOT="$SCRIPT_DIR"
# shellcheck source=scripts/nginx-lib.sh
source "$SCRIPT_DIR/scripts/nginx-lib.sh"

# Accept commas or spaces between domains
read -ra DOMAIN_ARRAY <<< "$(printf '%s' "$DOMAINS" | tr ',' ' ')"

echo ""
echo "========================================="
echo "  ePHEM SSL Setup"
echo "========================================="
echo ""
echo "Domain(s): ${DOMAIN_ARRAY[*]}"
echo "Email:     $EMAIL"
echo ""

for d in "${DOMAIN_ARRAY[@]}"; do
    if ! valid_domain "$d"; then
        echo -e "${RED}✗${NC} '$d' is not a valid domain name."
        exit 1
    fi
done

# ── Step 1: Make sure NGINX is running ───────
# If NGINX is broken, restore HTTP-only config so certbot can work
if [ "$(nginx_state)" != running ]; then
    echo -e "${YELLOW}!${NC} NGINX is not running. Restoring HTTP-only config..."
    cp "$NGINX_TEMPLATE" "$NGINX_ACTIVE"
    dc up -d nginx >/dev/null 2>&1
    sleep 3
fi

for i in $(seq 1 10); do
    [ "$(nginx_state)" = running ] && { echo -e "${GREEN}✓${NC} NGINX is running"; break; }
    if [ "$i" -eq 10 ]; then
        echo -e "${RED}✗${NC} NGINX won't start. Check: docker compose logs nginx"
        exit 1
    fi
    sleep 2
done

# ── Step 2: One certificate per domain ───────
echo ""
echo -e "${BOLD}Requesting one certificate per domain...${NC}"

certs_refresh
OK_DOMAINS=()
for d in "${DOMAIN_ARRAY[@]}"; do
    echo ""
    echo -e "  ${CYAN}→${NC} certbot certonly -d $d --cert-name $d"
    if issue_cert "$d" "$EMAIL" 2>&1 | sed 's/^/     /'; then
        echo -e "  ${GREEN}✓${NC} $d"
        OK_DOMAINS+=("$d")
    else
        # A server that still has ONE shared certificate cannot re-issue under
        # that same name here; the domain is already covered, so keep serving
        # it and point at split-certs.sh.
        certs_refresh
        if LIN="$(lineage_for_domain "$d")"; then
            echo -e "  ${YELLOW}!${NC} $d keeps its existing certificate '$LIN'"
            echo "     (give it one of its own: manage.sh → 2) Manage domains → Split)"
            OK_DOMAINS+=("$d")
        else
            echo -e "  ${RED}✗${NC} $d — certificate request failed, leaving it out"
        fi
    fi
done

if [ ${#OK_DOMAINS[@]} -eq 0 ]; then
    echo ""
    echo -e "${RED}✗ No certificate could be issued.${NC}"
    echo ""
    echo "Check that:"
    echo "  - Your domain points to this server (run: dig +short ${DOMAIN_ARRAY[0]})"
    echo "  - Ports 80 and 443 are open (run: sudo ufw allow 80 && sudo ufw allow 443)"
    echo "  - NGINX is running (run: docker compose ps)"
    echo ""
    exit 1
fi

echo ""
echo -e "${GREEN}✓ Certificate(s) obtained!${NC}"

# Remember the email so add-domain.sh can issue certificates unattended.
if [ -f "$SCRIPT_DIR/.env" ]; then
    if grep -q "^SSL_EMAIL=" "$SCRIPT_DIR/.env"; then
        sed -i "s|^SSL_EMAIL=.*|SSL_EMAIL=$EMAIL|" "$SCRIPT_DIR/.env"
    else
        echo "SSL_EMAIL=$EMAIL" >> "$SCRIPT_DIR/.env"
    fi
fi

# ── Step 3: Write HTTPS config to active.conf ─
echo ""
echo "Enabling HTTPS..."
certs_refresh
render_active_conf "${OK_DOMAINS[@]}" || exit 1
echo -e "${GREEN}✓ NGINX config updated${NC}"

# ── Step 4: Reload NGINX ─────────────────────
echo ""
if ! nginx_apply; then
    echo ""
    echo -e "${RED}✗ NGINX failed with the SSL config. Rolling back to HTTP...${NC}"
    cp "$NGINX_TEMPLATE" "$NGINX_ACTIVE"
    dc restart nginx >/dev/null 2>&1
    echo "NGINX is back on HTTP. Check: docker compose logs nginx"
    exit 1
fi

echo ""
echo "========================================="
echo -e "${GREEN}✓ SSL is active!${NC}"
echo ""
echo "Your site is now available at:"
for d in "${OK_DOMAINS[@]}"; do
    echo "  https://$d   (certificate: $d)"
done
echo ""
echo "Certificates renew automatically, each on its own schedule."
echo "Add or remove domains later:  bash manage.sh → 2) Manage domains"
echo "========================================="
echo ""
