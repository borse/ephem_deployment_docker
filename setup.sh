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
if [ -f "nginx/default.conf" ]; then
    echo -e "${GREEN}✓${NC} nginx/default.conf exists"
else
    echo -e "${RED}✗${NC} nginx/default.conf is missing. Re-clone the repo."
    ERRORS=$((ERRORS + 1))
fi

# ── Check custom-addons ──────────────────────
if [ -d "custom-addons" ] && [ "$(ls -A custom-addons/ 2>/dev/null | grep -v README)" ]; then
    echo -e "${GREEN}✓${NC} custom-addons/ has modules"
else
    echo -e "${YELLOW}!${NC} custom-addons/ is empty — cloning ePHEM modules..."
    rm -rf custom-addons
    git clone git@github.com:borse/ePHEM.git --depth 1 --branch 18_national_dev --single-branch custom-addons
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

# ── Create backups directory ─────────────────
mkdir -p backups
echo -e "${GREEN}✓${NC} backups/ directory exists"

# ── Summary ──────────────────────────────────
echo ""
if [ $ERRORS -gt 0 ]; then
    echo -e "${RED}✗ $ERRORS issue(s) found. Fix them and run this script again.${NC}"
    echo ""
    exit 1
else
    echo -e "${GREEN}✓ Everything looks good!${NC}"
    echo ""
    echo "Starting ePHEM..."
    echo ""
    docker compose up -d
    echo ""
    echo "========================================="
    echo ""
    docker compose ps
    echo ""
    echo "========================================="
    echo -e "${GREEN}ePHEM is running!${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Set up SSL:  ./scripts/ssl-setup.sh YOUR_DOMAIN YOUR_EMAIL"
    echo "     Example:     ./scripts/ssl-setup.sh ephem.health.gov.xx admin@health.gov.xx"
    echo "  2. Open in browser: http://YOUR_DOMAIN"
    echo ""
fi
