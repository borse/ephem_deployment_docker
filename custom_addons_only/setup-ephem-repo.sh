#!/bin/bash
# ──────────────────────────────────────────────
# ePHEM — Custom Addons Setup (VM / Bare Metal)
#
# Sets up SSH deploy key access and clones the
# ePHEM custom addons repository. Works on any
# server with Odoo installed (no Docker required).
#
# Usage:
#   bash setup_ephem_repo.sh                        (auto-detect addons path)
#   bash setup_ephem_repo.sh /opt/odoo/custom-addons (specify path)
#   bash setup_ephem_repo.sh --branch 16_national_master /opt/odoo16/odca
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
DEFAULT_BRANCH="18_national_dev"

# ── Parse arguments ──────────────────────────
BRANCH="$DEFAULT_BRANCH"
ADDONS_PATH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --branch|-b) BRANCH="$2"; shift 2 ;;
        --help|-h)
            echo ""
            echo "Usage: bash setup_ephem_repo.sh [OPTIONS] [ADDONS_PATH]"
            echo ""
            echo "Options:"
            echo "  --branch, -b BRANCH   Git branch to clone (default: $DEFAULT_BRANCH)"
            echo "  --help, -h            Show this help"
            echo ""
            echo "Examples:"
            echo "  bash setup_ephem_repo.sh"
            echo "  bash setup_ephem_repo.sh /opt/odoo/custom-addons"
            echo "  bash setup_ephem_repo.sh --branch 16_national_master /opt/odoo16/odca"
            echo "  bash setup_ephem_repo.sh -b 18_national_dev /opt/odoo18/custom-addons"
            echo ""
            echo "Available branches:"
            echo "  18_national_dev          Odoo 18 development"
            echo "  18_national_master       Odoo 18 stable"
            echo "  16_national_dev          Odoo 16 development"
            echo "  16_national_master       Odoo 16 stable"
            echo ""
            exit 0
            ;;
        *) ADDONS_PATH="$1"; shift ;;
    esac
done

# Cross-platform IP detection
get_server_ip() {
    hostname -I 2>/dev/null | awk '{print $1}' ||
    ipconfig getifaddr en0 2>/dev/null ||
    ip route get 1 2>/dev/null | awk '{print $7; exit}' ||
    echo "127.0.0.1"
}

echo ""
echo "========================================="
echo "  ePHEM — Custom Addons Setup"
echo "========================================="
echo ""
echo -e "Branch: ${BOLD}$BRANCH${NC}"

# ── Step 1: Determine addons path ────────────
if [ -z "$ADDONS_PATH" ]; then
    # Try to auto-detect from common locations
    if [ -d "/opt/odoo18/custom-addons" ]; then
        ADDONS_PATH="/opt/odoo18/custom-addons"
    elif [ -d "/opt/odoo/custom-addons" ]; then
        ADDONS_PATH="/opt/odoo/custom-addons"
    elif [ -d "/opt/odoo16/odca-national-master" ]; then
        ADDONS_PATH="/opt/odoo16/odca-national-master"
    elif [ -d "/opt/odoo16/custom-addons" ]; then
        ADDONS_PATH="/opt/odoo16/custom-addons"
    else
        echo ""
        echo -e "${YELLOW}!${NC} Could not auto-detect addons path."
        echo ""
        echo "Common locations:"
        echo "  /opt/odoo18/custom-addons"
        echo "  /opt/odoo/custom-addons"
        echo "  /opt/odoo16/odca-national-master"
        echo ""
        read -p "Enter the full path to your custom addons folder: " ADDONS_PATH
        if [ -z "$ADDONS_PATH" ]; then
            echo -e "${RED}✗${NC} No path provided."
            exit 1
        fi
    fi
fi

echo -e "Path:   ${BOLD}$ADDONS_PATH${NC}"
echo ""

# ── Step 2: Generate SSH deploy key ──────────
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

# ── Step 3: Configure SSH ────────────────────
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

# ── Step 4: Test SSH access ──────────────────
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
    echo -e "  ${BOLD}bash setup_ephem_repo.sh $ADDONS_PATH${NC}"
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    exit 0
fi

# ── Step 5: Clone or update the repo ─────────
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

# ── Step 6: Fix permissions ──────────────────
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

# ── Step 7: Mark as safe directory for Git ───
git config --global --add safe.directory "$ADDONS_PATH" 2>/dev/null || true

# ── Summary ──────────────────────────────────
echo ""
echo "========================================="
echo -e "${GREEN}✓ ePHEM addons are ready!${NC}"
echo ""
echo "  Path:   $ADDONS_PATH"
echo "  Branch: $BRANCH"
echo ""

# Count modules
MODULE_COUNT=$(find "$ADDONS_PATH" -maxdepth 1 -name "__manifest__.py" -o -name "__openerp__.py" 2>/dev/null | wc -l)
if [ "$MODULE_COUNT" -gt 0 ]; then
    echo "  Modules found: $MODULE_COUNT"
fi

echo ""
echo "Next steps:"
echo "  1. Restart Odoo to load the new modules"
echo "  2. Go to Apps → Update Apps List"
echo "  3. Install the ePHEM modules"
echo ""
echo "To update later:"
echo "  bash setup_ephem_repo.sh $ADDONS_PATH"
echo "========================================="
echo ""