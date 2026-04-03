#!/bin/bash
# ──────────────────────────────────────────────
# ePHEM SSL Setup Script
# Run after setup.sh to enable HTTPS.
#
# How it works:
#   - nginx/default.conf  = HTTP-only template (in Git, never modified)
#   - nginx/active.conf   = what NGINX actually uses (git-ignored)
#   - This script gets a cert, then writes HTTPS config to active.conf
#   - git pull never breaks SSL because it never touches active.conf
#
# Usage: ./scripts/ssl-setup.sh DOMAIN EMAIL
# ──────────────────────────────────────────────

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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
NGINX_ACTIVE="$SCRIPT_DIR/nginx/active.conf"
NGINX_TEMPLATE="$SCRIPT_DIR/nginx/default.conf"

# Build the -d flags for certbot
CERTBOT_DOMAINS=""
IFS=',' read -ra DOMAIN_ARRAY <<< "$DOMAINS"
for d in "${DOMAIN_ARRAY[@]}"; do
    d=$(echo "$d" | xargs)
    CERTBOT_DOMAINS="$CERTBOT_DOMAINS -d $d"
done

FIRST_DOMAIN="${DOMAIN_ARRAY[0]}"

echo ""
echo "========================================="
echo "  ePHEM SSL Setup"
echo "========================================="
echo ""
echo "Domain(s): $DOMAINS"
echo "Email:     $EMAIL"
echo ""

# ── Step 1: Make sure NGINX is running ───────
# If NGINX is broken, restore HTTP-only config so certbot can work
NGINX_STATUS=$(docker compose -f "$SCRIPT_DIR/docker-compose.yml" ps nginx --format '{{.Status}}' 2>/dev/null || echo "unknown")
if echo "$NGINX_STATUS" | grep -qi "restarting\|exited"; then
    echo -e "${YELLOW}!${NC} NGINX is down. Restoring HTTP-only config..."
    cp "$NGINX_TEMPLATE" "$NGINX_ACTIVE"
    docker compose -f "$SCRIPT_DIR/docker-compose.yml" restart nginx
    sleep 3
fi

# Verify NGINX is up
for i in $(seq 1 10); do
    NGINX_STATUS=$(docker compose -f "$SCRIPT_DIR/docker-compose.yml" ps nginx --format '{{.Status}}' 2>/dev/null || echo "unknown")
    if echo "$NGINX_STATUS" | grep -qi "up"; then
        echo -e "${GREEN}✓${NC} NGINX is running"
        break
    fi
    if [ $i -eq 10 ]; then
        echo -e "${RED}✗${NC} NGINX won't start. Check: docker compose logs nginx"
        exit 1
    fi
    sleep 2
done

# ── Step 2: Get the certificate ──────────────
echo ""
echo "Requesting SSL certificate..."
echo ""

docker compose -f "$SCRIPT_DIR/docker-compose.yml" run --rm --entrypoint "" certbot \
    certbot certonly --webroot \
    -w /var/www/certbot \
    $CERTBOT_DOMAINS \
    --email "$EMAIL" \
    --agree-tos \
    --no-eff-email \
    --non-interactive \
    --keep-until-expiring

if [ $? -ne 0 ]; then
    echo ""
    echo -e "${RED}✗ Certificate request failed.${NC}"
    echo ""
    echo "Check that:"
    echo "  - Your domain points to this server (run: dig +short $FIRST_DOMAIN)"
    echo "  - Ports 80 and 443 are open (run: sudo ufw allow 80 && sudo ufw allow 443)"
    echo "  - NGINX is running (run: docker compose ps)"
    echo ""
    exit 1
fi

echo ""
echo -e "${GREEN}✓ Certificate obtained!${NC}"

# ── Step 3: Write HTTPS config to active.conf ─
echo ""
echo "Enabling HTTPS..."

SERVER_NAMES=""
for d in "${DOMAIN_ARRAY[@]}"; do
    d=$(echo "$d" | xargs)
    SERVER_NAMES="$SERVER_NAMES $d"
done

cat > "$NGINX_ACTIVE" << NGINXEOF
# ── Rate Limiting ──────────────────────────────
limit_req_zone \$binary_remote_addr zone=ephem_limit:10m rate=10r/s;
limit_conn_zone \$binary_remote_addr zone=conn_limit:10m;

# ── Upstreams ─────────────────────────────────
upstream odoo-backend {
    server odoo:8069;
}
upstream odoo-chat {
    server odoo:8072;
}

map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

# ── HTTP → HTTPS redirect ─────────────────────
server {
    listen 80;
    server_name$SERVER_NAMES;
    server_tokens off;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

# ── HTTPS server ──────────────────────────────
server {
    listen 443 ssl;
    http2 on;
    server_name$SERVER_NAMES;
    server_tokens off;

    ssl_certificate     /etc/letsencrypt/live/$FIRST_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$FIRST_DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;

    proxy_set_header X-Forwarded-Host  \$host;
    proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP         \$remote_addr;

    client_max_body_size 100M;
    proxy_read_timeout 720s;
    proxy_connect_timeout 720s;
    proxy_send_timeout 720s;

    location /websocket {
        proxy_pass http://odoo-chat;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header X-Forwarded-Host  \$host;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Real-IP         \$remote_addr;
    }

    location / {
        proxy_redirect off;
        proxy_pass http://odoo-backend;
        limit_req zone=ephem_limit burst=20 nodelay;
    }

    location ~* /web/static/ {
        proxy_cache_valid 200 90m;
        proxy_buffering on;
        expires 864000;
        proxy_pass http://odoo-backend;
    }

    gzip on;
    gzip_types text/css text/less text/plain text/xml
               application/xml application/json application/javascript;
}
NGINXEOF

echo -e "${GREEN}✓ NGINX config updated${NC}"

# ── Step 4: Reload NGINX ─────────────────────
echo ""
echo "Restarting NGINX..."
docker compose -f "$SCRIPT_DIR/docker-compose.yml" restart nginx

# Verify it started
sleep 3
NGINX_STATUS=$(docker compose -f "$SCRIPT_DIR/docker-compose.yml" ps nginx --format '{{.Status}}' 2>/dev/null || echo "unknown")
if echo "$NGINX_STATUS" | grep -qi "restarting\|exited"; then
    echo ""
    echo -e "${RED}✗ NGINX failed with SSL config. Rolling back to HTTP...${NC}"
    cp "$NGINX_TEMPLATE" "$NGINX_ACTIVE"
    docker compose -f "$SCRIPT_DIR/docker-compose.yml" restart nginx
    echo "NGINX is back on HTTP. Check: docker compose logs nginx"
    exit 1
fi

echo ""
echo "========================================="
echo -e "${GREEN}✓ SSL is active!${NC}"
echo ""
echo "Your site is now available at:"
for d in "${DOMAIN_ARRAY[@]}"; do
    d=$(echo "$d" | xargs)
    echo "  https://$d"
done
echo ""
echo "Certificates will renew automatically."
echo "========================================="
echo ""