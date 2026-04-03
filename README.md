#!/bin/bash
# ──────────────────────────────────────────────
# ePHEM Setup Script
# Run this once after cloning the repo.
# It checks everything is in place, then starts the system.
# ──────────────────────────────────────────────

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo ""
echo "========================================="
echo "  ePHEM Setup"
echo "========================================="
echo ""

ERRORS=0

# ── Check Docker ──────────────────────────────
if command -v docker &> /dev/null; then
    echo -e "${GREEN}✓${NC} Docker is installed"
else
    echo -e "${RED}✗${NC} Docker is not installed. Run: curl -fsSL https://get.docker.com | sh"
    ERRORS=$((ERRORS + 1))
fi

if docker compose version &> /dev/null; then
    echo -e "${GREEN}✓${NC} Docker Compose is available"
else
    echo -e "${RED}✗${NC} Docker Compose is not available. Update Docker."
    ERRORS=$((ERRORS + 1))
fi

# ── Check .env ────────────────────────────────
if [ -f ".env" ]; then
    echo -e "${GREEN}✓${NC} .env file exists"

    # Check if passwords were changed
    if grep -q "CHANGE_ME" .env; then
        echo -e "${RED}✗${NC} .env still has CHANGE_ME passwords. Edit .env and set real passwords."
        ERRORS=$((ERRORS + 1))
    else
        echo -e "${GREEN}✓${NC} Passwords have been set"
    fi
else
    echo -e "${YELLOW}!${NC} .env not found — creating from template..."
    cp .env.example .env
    echo -e "${RED}✗${NC} Edit .env now: nano .env (set your domain and passwords)"
    ERRORS=$((ERRORS + 1))
fi

# ── Check nginx config ───────────────────────
if [ ! -f "nginx/default.conf" ]; then
    echo -e "${RED}✗${NC} nginx/default.conf template is missing. Re-clone the repo."
    ERRORS=$((ERRORS + 1))
elif [ -f "nginx/active.conf" ]; then
    # active.conf exists — ssl-setup.sh created it previously
    echo -e "${GREEN}✓${NC} nginx/active.conf exists (custom config)"
else
    # No active.conf yet — copy the HTTP-only template
    cp nginx/default.conf nginx/active.conf
    echo -e "${GREEN}✓${NC} nginx/active.conf created from template"
fi

# ── Check custom-addons ──────────────────────
if [ -d "custom-addons" ] && [ "$(ls -A custom-addons/ 2>/dev/null | grep -v README)" ]; then
    echo -e "${GREEN}✓${NC} custom-addons/ has modules"
else
    echo -e "${YELLOW}!${NC} custom-addons/ is empty — cloning ePHEM modules..."
    rm -rf custom-addons
    git clone git@github.com:borse/ePHEM.git custom-addons
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓${NC} ePHEM modules downloaded"
    else
        echo -e "${RED}✗${NC} Failed to clone ePHEM. Check your internet connection."
        ERRORS=$((ERRORS + 1))
    fi
fi

# ── Check scripts ────────────────────────────
if [ -f "scripts/backup.sh" ]; then
    chmod +x scripts/backup.sh
    echo -e "${GREEN}✓${NC} Backup script is ready"
fi

if [ -f "scripts/ssl-setup.sh" ]; then
    chmod +x scripts/ssl-setup.sh
    echo -e "${GREEN}✓${NC} SSL setup script is ready"
fi

# ── Sync odoo.conf with .env passwords ──────
if [ -f "odoo.conf" ] && [ -f ".env" ]; then
    ADMIN_PASS=$(grep "^ODOO_ADMIN_PASSWORD=" .env | cut -d'=' -f2-)
    if [ -n "$ADMIN_PASS" ]; then
        sed -i "s|^admin_passwd.*|admin_passwd = $ADMIN_PASS|" odoo.conf
        echo -e "${GREEN}✓${NC} Odoo master password synced from .env"
    fi
fi

# ── Create backups directory ─────────────────
mkdir -p backups
echo -e "${GREEN}✓${NC} backups/ directory exists"

# ── Summary ──────────────────────────────────
echo ""
if [ $ERRORS -gt 0 ]; then
    echo -e "${RED}✗ $ERRORS issue(s) found. Fix them and run this script again.${NC}"
    echo ""
    exit 1
fi

echo -e "${GREEN}✓ Everything looks good!${NC}"
echo ""
echo "Starting ePHEM..."
echo ""

# ── Start containers ─────────────────────────
docker compose up -d
echo ""

# ── Wait for database to be ready ────────────
echo "Waiting for database..."
for i in $(seq 1 30); do
    if docker compose exec -T db pg_isready -U odoo -q 2>/dev/null; then
        echo -e "${GREEN}✓${NC} Database is ready"
        break
    fi
    if [ $i -eq 30 ]; then
        echo -e "${RED}✗${NC} Database did not start in time. Run: docker compose logs db"
        exit 1
    fi
    sleep 2
done

# ── Check if Odoo can connect to the database ─
echo "Checking database connection..."
sleep 5

ODOO_LOG=$(docker compose logs --tail=5 odoo 2>&1)
if echo "$ODOO_LOG" | grep -q "password authentication failed"; then
    echo ""
    echo -e "${YELLOW}! Database password mismatch detected.${NC}"
    echo "  This happens when POSTGRES_PASSWORD in .env was changed after the"
    echo "  database was first created. Fixing automatically..."
    echo ""

    # Read the password from .env
    ENV_PASSWORD=$(grep "^POSTGRES_PASSWORD=" .env | cut -d'=' -f2-)

    # Try to update the password using the default PostgreSQL auth
    docker compose exec -T db psql -U odoo -d postgres -c "ALTER USER odoo WITH PASSWORD '${ENV_PASSWORD}';" 2>/dev/null && {
        echo -e "${GREEN}✓${NC} Password synced. Restarting Odoo..."
        docker compose restart odoo
        sleep 5
    } || {
        echo -e "${RED}✗${NC} Could not fix automatically."
        echo ""
        echo "  To fix manually, reset the database:"
        echo "    docker compose down -v"
        echo "    docker compose up -d"
        echo ""
        echo "  WARNING: This deletes all data. Back up first if needed."
        exit 1
    }
fi

# ── Final status ─────────────────────────────
echo ""
echo "========================================="
echo ""
docker compose ps
echo ""
echo "========================================="
echo -e "${GREEN}ePHEM is running!${NC}"
echo ""

# Show smart next steps based on current state
if grep -v "^#" nginx/active.conf 2>/dev/null | grep -q "ssl_certificate"; then
    # SSL is already configured
    DOMAIN=$(grep "server_name" nginx/active.conf | grep -v "#" | head -1 | sed 's/.*server_name//;s/;//' | xargs | awk '{print $1}')
    echo "Your site is available at:"
    echo "  https://$DOMAIN"
else
    echo "Next steps:"
    echo "  1. Set up SSL:  ./scripts/ssl-setup.sh YOUR_DOMAIN YOUR_EMAIL"
    echo "     Example:     ./scripts/ssl-setup.sh ephem.health.gov.xx admin@health.gov.xx"
    echo "  2. Open in browser: http://YOUR_DOMAIN"
fi
echo ""