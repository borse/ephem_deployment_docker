#!/bin/bash
# ──────────────────────────────────────────────
# ePHEM Add Domain Script
# Adds one or more new domains to the existing setup.
# Expands the SSL cert and updates the NGINX config.
#
# Usage:
#   ./scripts/add-domain.sh training-server.pheoc.com
#   ./scripts/add-domain.sh training-server.pheoc.com simex.pheoc.com staging.pheoc.com
# ──────────────────────────────────────────────

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ $# -lt 1 ]; then
    echo ""
    echo "Usage: ./scripts/add-domain.sh DOMAIN [DOMAIN2] [DOMAIN3] ..."
    echo ""
    echo "Examples:"
    echo "  ./scripts/add-domain.sh training-server.pheoc.com"
    echo "  ./scripts/add-domain.sh training-server.pheoc.com simex.pheoc.com"
    echo ""
    exit 1
fi

NEW_DOMAINS=("$@")
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NGINX_ACTIVE="$SCRIPT_DIR/nginx/active.conf"
ENV_FILE="$SCRIPT_DIR/.env"

echo ""
echo "========================================="
echo "  ePHEM — Add Domain(s)"
echo "========================================="
echo ""
echo "New domain(s): ${NEW_DOMAINS[*]}"
echo ""

# ── Step 1: Check prerequisites ──────────────
if [ ! -f "$NGINX_ACTIVE" ]; then
    echo -e "${RED}✗${NC} nginx/active.conf not found. Run setup.sh and ssl-setup.sh first."
    exit 1
fi

if ! grep -v "^#" "$NGINX_ACTIVE" | grep -q "ssl_certificate"; then
    echo -e "${RED}✗${NC} SSL is not set up yet. Run ./scripts/ssl-setup.sh first."
    exit 1
fi

# ── Step 2: Check DNS for each domain ────────
SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || ipconfig getifaddr en0 2>/dev/null || echo "127.0.0.1")
DOMAINS_TO_ADD=()

for NEW_DOMAIN in "${NEW_DOMAINS[@]}"; do
    echo "Checking DNS for $NEW_DOMAIN..."
    RESOLVED_IP=$(dig +short "$NEW_DOMAIN" 2>/dev/null | head -1)

    if [ -z "$RESOLVED_IP" ]; then
        echo -e "${RED}✗${NC} $NEW_DOMAIN does not resolve. Ask your IT team to create a DNS A record."
        echo "  Skipping $NEW_DOMAIN"
        echo ""
        continue
    elif [ "$RESOLVED_IP" != "$SERVER_IP" ]; then
        echo -e "${YELLOW}!${NC} $NEW_DOMAIN resolves to $RESOLVED_IP but this server is $SERVER_IP"
        read -p "  Continue with $NEW_DOMAIN anyway? (y/n) " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "  Skipping $NEW_DOMAIN"
            echo ""
            continue
        fi
    else
        echo -e "${GREEN}✓${NC} $NEW_DOMAIN resolves to $SERVER_IP"
    fi

    DOMAINS_TO_ADD+=("$NEW_DOMAIN")
done

if [ ${#DOMAINS_TO_ADD[@]} -eq 0 ]; then
    echo ""
    echo -e "${RED}✗ No valid domains to add.${NC}"
    exit 1
fi

# ── Step 3: Get existing domains from NGINX ──
EXISTING_DOMAINS=$(grep "server_name" "$NGINX_ACTIVE" | grep -v "#" | head -1 | sed 's/.*server_name//;s/;//' | xargs)
FIRST_DOMAIN=$(echo "$EXISTING_DOMAINS" | awk '{print $1}')

# Filter out domains that are already added
ACTUALLY_NEW=()
for d in "${DOMAINS_TO_ADD[@]}"; do
    if echo "$EXISTING_DOMAINS" | grep -qw "$d"; then
        echo -e "${YELLOW}!${NC} $d is already configured — skipping"
    else
        ACTUALLY_NEW+=("$d")
    fi
done

if [ ${#ACTUALLY_NEW[@]} -eq 0 ]; then
    echo ""
    echo "All domains are already configured. Nothing to do."
    echo ""
    echo "To create databases, go to:"
    echo "  https://$FIRST_DOMAIN/web/database/manager"
    exit 0
fi

ALL_DOMAINS="$EXISTING_DOMAINS ${ACTUALLY_NEW[*]}"
echo ""
echo -e "${GREEN}✓${NC} All domains will be: $ALL_DOMAINS"

# ── Step 4: Get email from .env ──────────────
EMAIL=$(grep "^SSL_EMAIL=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2-)
if [ -z "$EMAIL" ]; then
    echo ""
    read -p "Email for SSL certificate: " EMAIL
fi

# ── Step 5: Expand the SSL certificate ───────
echo ""
echo "Expanding SSL certificate..."
echo ""

CERTBOT_DOMAINS=""
for d in $ALL_DOMAINS; do
    CERTBOT_DOMAINS="$CERTBOT_DOMAINS -d $d"
done

docker compose -f "$SCRIPT_DIR/docker-compose.yml" run --rm --entrypoint "" certbot \
    certbot certonly --webroot \
    -w /var/www/certbot \
    $CERTBOT_DOMAINS \
    --email "$EMAIL" \
    --agree-tos \
    --no-eff-email \
    --non-interactive \
    --expand \
    --cert-name "$FIRST_DOMAIN"

if [ $? -ne 0 ]; then
    echo ""
    echo -e "${RED}✗ Certificate expansion failed.${NC}"
    echo ""
    echo "Check that all domains point to this server and ports 80/443 are open."
    echo ""
    exit 1
fi

echo ""
echo -e "${GREEN}✓ Certificate expanded!${NC}"

# ── Step 6: Update NGINX config ──────────────
echo ""
echo "Updating NGINX config..."

sed -i "s|server_name $EXISTING_DOMAINS;|server_name $ALL_DOMAINS;|g" "$NGINX_ACTIVE"

echo -e "${GREEN}✓${NC} NGINX config updated"

# ── Step 7: Restart NGINX ────────────────────
echo ""
echo "Restarting NGINX..."
docker compose -f "$SCRIPT_DIR/docker-compose.yml" restart nginx

sleep 3
NGINX_STATUS=$(docker compose -f "$SCRIPT_DIR/docker-compose.yml" ps nginx --format '{{.Status}}' 2>/dev/null || echo "unknown")
if echo "$NGINX_STATUS" | grep -qi "restarting\|exited"; then
    echo -e "${RED}✗${NC} NGINX failed to restart. Check: docker compose logs nginx"
    exit 1
fi

echo -e "${GREEN}✓${NC} NGINX is running"

# ── Summary ──────────────────────────────────
echo ""
echo "========================================="
echo -e "${GREEN}✓ Domain(s) added successfully!${NC}"
echo ""

for d in "${ACTUALLY_NEW[@]}"; do
    DB_NAME=$(echo "$d" | cut -d'.' -f1)
    echo "  https://$d  →  database: $DB_NAME"
done

echo ""
echo "Create the database(s) at:"
echo "  https://$FIRST_DOMAIN/web/database/manager"
echo ""
echo "Make sure database names match the subdomain:"

for d in "${ACTUALLY_NEW[@]}"; do
    DB_NAME=$(echo "$d" | cut -d'.' -f1)
    echo "  $d  →  name the database '$DB_NAME'"
done

echo "========================================="
echo ""