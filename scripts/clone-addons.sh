#!/bin/bash
# ──────────────────────────────────────────────
# ePHEM — Clone Custom Addons (Private Repo)
#
# Uses the deploy key set up by request-addons-access.sh
# to clone the private ePHEM addons repository.
#
# Usage: bash scripts/clone-addons.sh
# ──────────────────────────────────────────────

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ADDONS_DIR="$SCRIPT_DIR/custom-addons"
DEPLOY_KEY="$HOME/.ssh/ephem_addons_deploy"
REPO="git@github-ephem-addons:borse/ePHEM.git"
BRANCH="18_national_dev"

echo ""
echo "========================================="
echo "  ePHEM — Clone Custom Addons"
echo "========================================="
echo ""

# ── Check deploy key exists ──────────────────
if [ ! -f "$DEPLOY_KEY" ]; then
    echo -e "${RED}✗${NC} No deploy key found."
    echo ""
    echo "Run this first to generate one:"
    echo "  bash scripts/request-addons-access.sh"
    echo ""
    exit 1
fi

# ── Test SSH access ──────────────────────────
echo "Testing access to the ePHEM repository..."
echo ""

SSH_OUTPUT="$(ssh -T git@github-ephem-addons 2>&1 || true)"

if echo "$SSH_OUTPUT" | grep -qi "successfully authenticated"; then
    echo -e "${GREEN}✓${NC} Access granted"
else
    echo -e "${RED}✗${NC} Access denied."
    echo ""
    echo "SSH output was:"
    echo "$SSH_OUTPUT"
    echo ""
    echo "Your deploy key has not been added to the repository yet,"
    echo "or your SSH config is not using the expected key."
    echo ""
    echo "Send your public key to the ePHEM team:"
    echo ""
    echo -e "${CYAN}$(cat "${DEPLOY_KEY}.pub")${NC}"
    echo ""
    exit 1
fi

# ── Clone or update ──────────────────────────
echo ""

if [ -d "$ADDONS_DIR/.git" ]; then
    echo "custom-addons/ already has a Git repo. Updating..."
    cd "$ADDONS_DIR"

    git fetch origin "$BRANCH"
    git checkout "$BRANCH"
    git pull origin "$BRANCH"

    cd "$SCRIPT_DIR"
    echo -e "${GREEN}✓${NC} Custom addons updated"
else
    echo "Cloning ePHEM addons..."

    # Remove placeholder if exists
    if [ -d "$ADDONS_DIR" ]; then
        rm -rf "$ADDONS_DIR"
    fi

    git clone "$REPO" \
        --depth 1 \
        --branch "$BRANCH" \
        --single-branch \
        "$ADDONS_DIR"

    echo -e "${GREEN}✓${NC} Custom addons cloned (branch: $BRANCH)"
fi

# ── Restart Odoo if running ──────────────────
if docker compose -f "$SCRIPT_DIR/docker-compose.yml" ps odoo --format '{{.Status}}' 2>/dev/null | grep -qi "up"; then
    echo ""
    echo "Restarting Odoo to load the new modules..."
    docker compose -f "$SCRIPT_DIR/docker-compose.yml" restart odoo
    echo -e "${GREEN}✓${NC} Odoo restarted"
    echo ""
    echo "Go to Apps → Update Apps List to see the new modules."
fi

echo ""
echo "========================================="
echo -e "${GREEN}✓ Custom addons are ready!${NC}"
echo "========================================="
echo ""