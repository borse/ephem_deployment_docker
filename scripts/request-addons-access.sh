#!/bin/bash
# ──────────────────────────────────────────────
# ePHEM — Request Access to Custom Addons
#
# This script generates a deploy key for read-only
# access to the private ePHEM addons repository.
#
# Usage: bash scripts/request-addons-access.sh
# ──────────────────────────────────────────────

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

DEPLOY_KEY="$HOME/.ssh/ephem_addons_deploy"
SSH_CONFIG="$HOME/.ssh/config"

echo ""
echo "========================================="
echo "  ePHEM — Request Addons Access"
echo "========================================="
echo ""

# ── Step 1: Check if key already exists ──────
if [ -f "$DEPLOY_KEY" ]; then
    echo -e "${YELLOW}!${NC} A deploy key already exists."
    echo ""
    echo "Your public key:"
    echo ""
    echo -e "${CYAN}$(cat ${DEPLOY_KEY}.pub)${NC}"
    echo ""
    echo "If access is already set up, test with:"
    echo "  ssh -T git@github-ephem-addons"
    echo ""

    read -p "Generate a new key? (y/n) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 0
    fi
fi

# ── Step 2: Ask for identifier ───────────────
echo ""
read -p "Enter your country or server name (e.g. yemen, training-01): " SERVER_NAME
SERVER_NAME="${SERVER_NAME:-unknown}"

# ── Step 3: Generate the key ─────────────────
echo ""
echo "Generating deploy key..."

mkdir -p ~/.ssh
chmod 700 ~/.ssh

ssh-keygen -t ed25519 -f "$DEPLOY_KEY" -C "ephem-addons-${SERVER_NAME}" -N "" -q

chmod 600 "$DEPLOY_KEY"
chmod 644 "${DEPLOY_KEY}.pub"

echo -e "${GREEN}✓${NC} Key generated"

# ── Step 4: Configure SSH ────────────────────
# Add the host alias if not already present
if ! grep -q "github-ephem-addons" "$SSH_CONFIG" 2>/dev/null; then
    cat >> "$SSH_CONFIG" << EOF

Host github-ephem-addons
    HostName github.com
    User git
    IdentityFile $DEPLOY_KEY
    IdentitiesOnly yes
EOF
    chmod 600 "$SSH_CONFIG"
    echo -e "${GREEN}✓${NC} SSH config updated"
else
    echo -e "${GREEN}✓${NC} SSH config already has github-ephem-addons"
fi

# ── Step 5: Trust GitHub host key ────────────
if ! grep -q "github.com" ~/.ssh/known_hosts 2>/dev/null; then
    ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null
    chmod 644 ~/.ssh/known_hosts
    echo -e "${GREEN}✓${NC} GitHub host key trusted"
fi

# ── Step 6: Show the public key ──────────────
echo ""
echo "========================================="
echo -e "${GREEN}✓ Deploy key ready!${NC}"
echo "========================================="
echo ""
echo "Send the following public key to the ePHEM team at:"
echo ""
echo -e "  ${BOLD}ephem@who.int${NC}"
echo ""
echo "Include your country/server name in the email subject."
echo ""
echo "─────────────────────────────────────────"
cat "${DEPLOY_KEY}.pub"
echo "─────────────────────────────────────────"
echo ""
echo "The ePHEM team will add it to the repository and confirm."
echo "Once they confirm, run:"
echo ""
echo "  bash scripts/clone-addons.sh"
echo ""
echo "In the meantime, you can use ePHEM without"
echo "custom modules — just run: bash setup.sh"
echo "========================================="
echo ""