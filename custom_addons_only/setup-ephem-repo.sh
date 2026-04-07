#!/bin/bash
# ──────────────────────────────────────────────
# ePHEM — Custom Addons Setup (VM / Bare Metal)
#
# Sets up SSH deploy key access and clones the
# ePHEM custom addons repository. Works on any
# server with Odoo installed (no Docker required).
#
# Usage:
#   bash setup-ephem-repo.sh
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
REPO="git@github-ephem-addons:borse/ePHEM.git"

echo ""
echo "========================================="
echo "  ePHEM — Custom Addons Setup"
echo "========================================="
echo ""

# ── Step 1: Ask for addons path ──────────────
# Check common locations and suggest a default
DEFAULT_PATH=""
if [ -d "/opt/odoo18/custom-addons" ]; then
    DEFAULT_PATH="/opt/odoo18/custom-addons"
elif [ -d "/opt/odoo/custom-addons" ]; then
    DEFAULT_PATH="/opt/odoo/custom-addons"
elif [ -d "/opt/odoo16/odca-national-master" ]; then
    DEFAULT_PATH="/opt/odoo16/odca-national-master"
elif [ -d "/opt/odoo16/custom-addons" ]; then
    DEFAULT_PATH="/opt/odoo16/custom-addons"
fi

echo "Where should the ePHEM modules be installed?"
echo ""
if [ -n "$DEFAULT_PATH" ]; then
    echo -e "  Detected: ${CYAN}$DEFAULT_PATH${NC}"
    echo ""
    read -p "Enter path (press Enter to use detected path): " USER_PATH
    ADDONS_PATH="${USER_PATH:-$DEFAULT_PATH}"
else
    echo "  Common locations:"
    echo "    /opt/odoo18/custom-addons"
    echo "    /opt/odoo/custom-addons"
    echo "    /opt/odoo16/odca-national-master"
    echo ""
    read -p "Enter the full path to your custom addons folder: " ADDONS_PATH
fi

if [ -z "$ADDONS_PATH" ]; then
    echo -e "${RED}✗${NC} No path provided."
    exit 1
fi

echo ""

# ── Step 2: Ask for branch ───────────────────
echo "Which branch do you want to use?"
echo ""
echo "  1) 18_national_dev       — Odoo 18 development (recommended)"
echo "  2) 18_national_master    — Odoo 18 stable"
echo "  3) 16_national_dev       — Odoo 16 development"
echo "  4) 16_national_master    — Odoo 16 stable"
echo ""
read -p "Choose [1-4] (default: 1): " BRANCH_CHOICE

case "${BRANCH_CHOICE:-1}" in
    1) BRANCH="18_national_dev" ;;
    2) BRANCH="18_national_master" ;;
    3) BRANCH="16_national_dev" ;;
    4) BRANCH="16_national_master" ;;
    *) BRANCH="18_national_dev" ;;
esac

echo ""
echo "─────────────────────────────────────────"
echo -e "${BOLD}Path:${NC}   $ADDONS_PATH"
echo -e "${BOLD}Branch:${NC} $BRANCH"
echo "─────────────────────────────────────────"
echo ""

# ── Step 3: Generate SSH deploy key ──────────
if [ -f "$DEPLOY_KEY" ]; then
    echo -e "${GREEN}✓${NC} Deploy key already exists"
else
    echo "Generating SSH deploy key..."

    mkdir -p ~/.ssh
    chmod 700 ~/.ssh

    SERVER_NAME=$(hostname 2>/dev/null || echo "unknown")

    ssh-keygen -t ed25519 -f "$DEPLOY_KEY" -C "ephem-addons-${SERVER_NAME}" -N "" -q
    chmod 600 "$DEPLOY_KEY"
    chmod 644 "${DEPLOY_KEY}.pub"

    echo -e "${GREEN}✓${NC} Deploy key generated"
fi

# ── Step 4: Configure SSH ────────────────────
if ! grep -q "github-ephem-addons" "$SSH_CONFIG" 2>/dev/null; then
    cat >> "$SSH_CONFIG" << SSHEOF

Host github-ephem-addons
    HostName github.com
    User git
    IdentityFile $DEPLOY_KEY
    IdentitiesOnly yes
SSHEOF
    chmod 600 "$SSH_CONFIG"
    echo -e "${GREEN}✓${NC} SSH config updated"
else
    echo -e "${GREEN}✓${NC} SSH config already configured"
fi

# Trust GitHub host key
if ! grep -q "github.com" ~/.ssh/known_hosts 2>/dev/null; then
    ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null
    chmod 644 ~/.ssh/known_hosts
    echo -e "${GREEN}✓${NC} GitHub host key trusted"
fi

# ── Step 5: Test SSH access ──────────────────
echo ""
echo "Testing access to the ePHEM repository..."

SSH_OUTPUT="$(ssh -T git@github-ephem-addons 2>&1 || true)"

if echo "$SSH_OUTPUT" | grep -qi "successfully authenticated"; then
    echo -e "${GREEN}✓${NC} Access granted"
else
    # No access yet — show the key and instructions
    echo -e "${YELLOW}!${NC} Access not yet granted."
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  ACTION REQUIRED${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "  Send the following SSH key to the ePHEM team at:"
    echo ""
    echo -e "  ${BOLD}${CYAN}ephem@who.int${NC}"
    echo ""
    echo -e "  ${BOLD}Include your country/server name in the email subject.${NC}"
    echo ""
    echo -e "  ${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${GREEN}║  COPY EVERYTHING BETWEEN THE LINES AND PASTE IN YOUR EMAIL  ║${NC}"
    echo -e "  ${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${CYAN}$(cat ${DEPLOY_KEY}.pub)${NC}"
    echo ""
    echo -e "  ${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${GREEN}║  END OF KEY                                                 ║${NC}"
    echo -e "  ${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  Once the ePHEM team confirms, run this script again:"
    echo ""
    echo -e "  ${BOLD}bash setup-ephem-repo.sh${NC}"
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    exit 0
fi

# ── Step 6: Clone or update the repo ─────────
echo ""

if [ -d "$ADDONS_PATH/.git" ]; then
    echo "Updating existing ePHEM addons..."
    cd "$ADDONS_PATH"

    # Make sure we're on the right branch
    CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")
    if [ "$CURRENT_BRANCH" != "$BRANCH" ]; then
        echo "  Switching from '$CURRENT_BRANCH' to '$BRANCH'..."
        git fetch origin "$BRANCH"
        git checkout "$BRANCH"
    fi

    git pull origin "$BRANCH"
    cd - > /dev/null

    echo -e "${GREEN}✓${NC} ePHEM addons updated (branch: $BRANCH)"
else
    echo "Cloning ePHEM addons (this may take a few minutes)..."

    # Back up existing folder if it has files
    if [ -d "$ADDONS_PATH" ] && [ "$(ls -A "$ADDONS_PATH" 2>/dev/null)" ]; then
        BACKUP_PATH="${ADDONS_PATH}.backup.$(date +%Y%m%d_%H%M%S)"
        echo -e "${YELLOW}!${NC} Existing folder backed up to: $BACKUP_PATH"
        mv "$ADDONS_PATH" "$BACKUP_PATH"
    elif [ -d "$ADDONS_PATH" ]; then
        rm -rf "$ADDONS_PATH"
    fi

    # Create parent directory if needed
    mkdir -p "$(dirname "$ADDONS_PATH")"

    GIT_SSH_COMMAND="ssh -o ConnectTimeout=30" \
    git clone "$REPO" \
        --depth 1 \
        --branch "$BRANCH" \
        --single-branch \
        "$ADDONS_PATH" \
        --progress

    echo ""
    echo -e "${GREEN}✓${NC} ePHEM addons cloned (branch: $BRANCH)"
fi

# ── Step 7: Fix permissions ──────────────────
# Detect the Odoo user
ODOO_USER=""
for u in odoo odoo18 odoo16; do
    if id "$u" &>/dev/null; then
        ODOO_USER="$u"
        break
    fi
done

if [ -n "$ODOO_USER" ]; then
    echo "Setting ownership to $ODOO_USER..."
    chown -R "$ODOO_USER:$ODOO_USER" "$ADDONS_PATH" 2>/dev/null || true
    chmod -R 755 "$ADDONS_PATH"
    echo -e "${GREEN}✓${NC} Permissions set (owner: $ODOO_USER)"
else
    chmod -R 755 "$ADDONS_PATH"
    echo -e "${GREEN}✓${NC} Permissions set"
fi

# ── Step 8: Mark as safe directory for Git ───
git config --global --add safe.directory "$ADDONS_PATH" 2>/dev/null || true

# ── Summary ──────────────────────────────────
echo ""
echo "========================================="
echo -e "${GREEN}✓ ePHEM addons are ready!${NC}"
echo ""
echo "  Path:   $ADDONS_PATH"
echo "  Branch: $BRANCH"

# Count modules
MODULE_COUNT=$(find "$ADDONS_PATH" -maxdepth 1 -name "__manifest__.py" -o -name "__openerp__.py" 2>/dev/null | wc -l)
if [ "$MODULE_COUNT" -gt 0 ]; then
    echo "  Modules: $MODULE_COUNT"
fi

echo ""
echo "Next steps:"
echo "  1. Restart Odoo to load the new modules"
echo "  2. Go to Apps → Update Apps List"
echo "  3. Install the ePHEM modules"
echo ""
echo "To update later, run this script again:"
echo "  bash setup-ephem-repo.sh"
echo "========================================="
echo ""