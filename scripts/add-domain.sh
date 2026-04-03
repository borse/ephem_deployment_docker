#!/bin/bash
# ──────────────────────────────────────────────
# ePHEM Add Domain Script
# Adds a new domain to the existing setup.
# Creates the database, expands the SSL cert,
# and updates the NGINX config.
#
# Usage: ./scripts/add-domain.sh training-server.pheoc.com
# ──────────────────────────────────────────────

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ $# -lt 1 ]; then
    echo ""
    echo "Usage: ./scripts/add-domain.sh NEW_DOMAIN"
    echo ""
    echo "Examples:"
    echo "  ./scripts/add-domain.sh training-server.pheoc.com"
    echo "  ./scripts/add-domain.sh simex.pheoc.com"
    echo ""
    exit 1
fi

NEW_DOMAIN="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NGINX_ACTIVE="$SCRIPT_DIR/nginx/active.conf"
ENV_FILE="$SCRIPT_DIR/.env"

echo ""
echo "========================================="
echo "  ePHEM — Add Domain"
echo "========================================="
echo ""
echo "New domain: $NEW_DOMAIN"
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

# ── Step 2: Check DNS ────────────────────────
echo "Checking DNS for $NEW_DOMAIN..."
RESOLVED_IP=$(dig +short "$NEW_DOMAIN" 2>/dev/null | head -1)
SERVER_IP=$(hostname -I | awk '{print $1}')

if [ -z "$RESOLVED_IP" ]; then
    echo -e "${RED}✗${NC} $NEW_DOMAIN does not resolve. Ask your IT team to create a DNS A record."
    exit 1
elif [ "$RESOLVED_IP" != "$SERVER_IP" ]; then
    echo -e "${YELLOW}!${NC} $NEW_DOMAIN resolves to $RESOLVED_IP but this server is $SERVER_IP"
    echo "  Make sure the DNS A record points to $SERVER_IP"
    echo ""
    read -p "Continue anyway? (y/n) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
else
    echo -e "${GREEN}✓${NC} $NEW_DOMAIN resolves to $SERVER_IP"
fi

# ── Step 3: Get existing domains from NGINX ──
EXISTING_DOMAINS=$(grep "server_name" "$NGINX_ACTIVE" | grep -v "#" | head -1 | sed 's/.*server_name//;s/;//' | xargs)

# Check if domain is already added
if echo "$EXISTING_DOMAINS" | grep -qw "$NEW_DOMAIN"; then
    echo -e "${YELLOW}!${NC} $NEW_DOMAIN is already in the NGINX config."
    echo ""
    echo "If you just need to create the database, go to:"
    echo "  https://$NEW_DOMAIN/web/database/manager"
    exit 0
fi

ALL_DOMAINS="$EXISTING_DOMAINS $NEW_DOMAIN"
echo -e "${GREEN}✓${NC} All domains: $ALL_DOMAINS"

# ── Step 4: Get email from .env ──────────────
EMAIL=$(grep "^SSL_EMAIL=" "$ENV_FILE" 2>/dev/null | cut -d'=' -f2-)
if [ -z "$EMAIL" ]; then
    echo ""
    read -p "Email for SSL certificate: " EMAIL
fi

# ── Step 5: Expand the SSL certificate ───────
echo ""
echo "Expanding SSL certificate to include $NEW_DOMAIN..."
echo ""

# Build -d flags for all domains
CERTBOT_DOMAINS=""
for d in $ALL_DOMAINS; do
    CERTBOT_DOMAINS="$CERTBOT_DOMAINS -d $d"
done

# Get the first domain (cert name)
FIRST_DOMAIN=$(echo "$EXISTING_DOMAINS" | awk '{print $1}')

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
    echo "Check that:"
    echo "  - $NEW_DOMAIN points to this server (dig +short $NEW_DOMAIN)"
    echo "  - Ports 80 and 443 are open"
    echo ""
    exit 1
fi

echo ""
echo -e "${GREEN}✓ Certificate expanded!${NC}"

# ── Step 6: Update NGINX config ──────────────
echo ""
echo "Updating NGINX config..."

# Replace server_name lines (both HTTP and HTTPS blocks)
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

# ── Step 8: Extract database name from subdomain ─
DB_NAME=$(echo "$NEW_DOMAIN" | cut -d'.' -f1)

echo ""
echo "========================================="
echo -e "${GREEN}✓ Domain added successfully!${NC}"
echo ""
echo "  Domain:   https://$NEW_DOMAIN"
echo "  Database: $DB_NAME"
echo ""
echo "Next: Create the '$DB_NAME' database at:"
echo "  https://$NEW_DOMAIN/web/database/manager"
echo ""
echo "Or duplicate an existing database from:"
echo "  https://$FIRST_DOMAIN/web/database/manager"
echo "========================================="
echo ""