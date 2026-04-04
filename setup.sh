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
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Cross-platform IP detection
get_server_ip() {
    hostname -I 2>/dev/null | awk '{print $1}' ||
    ipconfig getifaddr en0 2>/dev/null ||
    ip route get 1 2>/dev/null | awk '{print $7; exit}' ||
    echo "127.0.0.1"
}

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

    # Check domain setting
    ENV_DOMAIN=$(grep "^DOMAIN=" .env | cut -d'=' -f2- | xargs)
    if [ -n "$ENV_DOMAIN" ]; then
        echo -e "${GREEN}✓${NC} Domain: $ENV_DOMAIN"
    else
        SERVER_IP=$(get_server_ip)
        echo -e "${YELLOW}!${NC} No domain set — running in IP mode ($SERVER_IP)"
    fi
else
    echo -e "${YELLOW}!${NC} .env not found — creating from template..."
    cp .env.example .env
    echo -e "${RED}✗${NC} Edit .env now: nano .env (set your passwords)"
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
if [ -d "custom-addons/.git" ]; then
    echo -e "${GREEN}✓${NC} custom-addons/ has modules (Git repo)"
else
    echo -e "${YELLOW}!${NC} Downloading ePHEM modules..."
    rm -rf custom-addons

    DEPLOY_KEY="$HOME/.ssh/ephem_addons_deploy"
    ADDONS_CLONED=false

    # Try: Private repo via deploy key (if key exists)
    if [ -f "$DEPLOY_KEY" ]; then
        echo "  Testing deploy key access..."
        SSH_OUTPUT="$(ssh -T git@github-ephem-addons 2>&1 || true)"

        if echo "$SSH_OUTPUT" | grep -qi "successfully authenticated"; then
            echo -e "  ${GREEN}✓${NC} Access granted"
            echo "  Cloning ePHEM modules (this may take a few minutes)..."
            echo ""

            # Clone the repo — show all progress
            GIT_SSH_COMMAND="ssh -o ConnectTimeout=30 -v" \
            GIT_TRACE=1 \
            git clone git@github-ephem-addons:borse/ePHEM.git \
                --depth 1 \
                --branch 18_national_dev \
                --single-branch \
                custom-addons \
                --progress

            if [ $? -eq 0 ]; then
                echo ""
                echo -e "${GREEN}✓${NC} ePHEM modules downloaded"
                ADDONS_CLONED=true
            else
                echo -e "${RED}✗${NC} Clone failed. The key has access but the branch may not exist."
                mkdir -p custom-addons
            fi
        else
            echo -e "${YELLOW}!${NC} Deploy key exists but access not yet granted"
            mkdir -p custom-addons
        fi
    fi

    # No key or no access — generate deploy key
    if [ "$ADDONS_CLONED" = false ]; then
        mkdir -p custom-addons
        NEEDS_ADDONS_ACCESS=true

        if [ ! -f "$DEPLOY_KEY" ]; then
            echo -e "${YELLOW}!${NC} Generating deploy key for ePHEM addons..."
            mkdir -p ~/.ssh
            chmod 700 ~/.ssh

            SERVER_NAME=$(hostname 2>/dev/null || echo "unknown")

            ssh-keygen -t ed25519 -f "$DEPLOY_KEY" -C "ephem-addons-${SERVER_NAME}" -N "" -q
            chmod 600 "$DEPLOY_KEY"
            chmod 644 "${DEPLOY_KEY}.pub"

            # Configure SSH host alias
            if ! grep -q "github-ephem-addons" "$HOME/.ssh/config" 2>/dev/null; then
                cat >> "$HOME/.ssh/config" << SSHEOF

Host github-ephem-addons
    HostName github.com
    User git
    IdentityFile $DEPLOY_KEY
    IdentitiesOnly yes
SSHEOF
                chmod 600 "$HOME/.ssh/config"
            fi

            # Trust GitHub host key
            if ! grep -q "github.com" ~/.ssh/known_hosts 2>/dev/null; then
                ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null
                chmod 644 ~/.ssh/known_hosts
            fi

            echo -e "${GREEN}✓${NC} Deploy key generated"
        else
            echo -e "${YELLOW}!${NC} Deploy key exists — waiting for ePHEM team to grant access"
        fi
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

if [ -f "scripts/add-domain.sh" ]; then
    chmod +x scripts/add-domain.sh
    echo -e "${GREEN}✓${NC} Add domain script is ready"
fi

if [ -f "scripts/duplicate-db.sh" ]; then
    chmod +x scripts/duplicate-db.sh
    echo -e "${GREEN}✓${NC} Duplicate database script is ready"
fi

if [ -f "scripts/update-modules.sh" ]; then
    chmod +x scripts/update-modules.sh
    echo -e "${GREEN}✓${NC} Update modules script is ready"
fi

if [ -f "scripts/request-addons-access.sh" ]; then
    chmod +x scripts/request-addons-access.sh
fi

if [ -f "scripts/clone-addons.sh" ]; then
    chmod +x scripts/clone-addons.sh
fi

# ── Generate odoo.conf from .env ─────────────
if [ -f ".env" ]; then

    # Clean Windows line endings from .env if present
    if sed --version 2>/dev/null | grep -q GNU; then
        sed -i 's/\r$//' .env
    else
        sed -i '' 's/\r$//' .env
    fi

    # Read values from .env
    ADMIN_PASS=$(grep "^ODOO_ADMIN_PASSWORD=" .env | cut -d'=' -f2- | xargs)
    DB_FILTER=$(grep "^ODOO_DBFILTER=" .env | cut -d'=' -f2- | xargs)
    LIST_DB=$(grep "^ODOO_LIST_DB=" .env | cut -d'=' -f2- | xargs)

    # Defaults
    ADMIN_PASS="${ADMIN_PASS:-}"
    LIST_DB="${LIST_DB:-True}"

    # If password is missing or still placeholder, generate one
    if [ -z "$ADMIN_PASS" ] || [ "$ADMIN_PASS" = "CHANGE_ME" ]; then
        ADMIN_PASS=$(openssl rand -base64 16 2>/dev/null || echo "ephem-$(date +%s)")
        echo -e "${YELLOW}!${NC} ODOO_ADMIN_PASSWORD not set — generated: $ADMIN_PASS"
        echo -e "${YELLOW}!${NC} Save this password or set ODOO_ADMIN_PASSWORD in .env"
    fi

    # Write odoo.conf fresh
    cat > odoo.conf << ODOOEOF
[options]
; Generated by setup.sh — do not edit manually.
; Change values in .env and re-run: bash setup.sh

admin_passwd = $ADMIN_PASS

; Addons
addons_path = /mnt/extra-addons,/usr/lib/python3/dist-packages/odoo/addons

; Proxy
proxy_mode = True

; Workers
workers = 4
max_cron_threads = 1
limit_memory_hard = 2684354560
limit_memory_soft = 2147483648
limit_request = 8192
limit_time_cpu = 600
limit_time_real = 1200

; Ports
xmlrpc_port = 8069
gevent_port = 8072

; Logging
log_level = info

; Database
list_db = $LIST_DB
ODOOEOF

    # Append dbfilter only if set
    if [ -n "$DB_FILTER" ]; then
        echo "dbfilter = $DB_FILTER" >> odoo.conf
    fi

    echo -e "${GREEN}✓${NC} odoo.conf generated (admin_passwd = $ADMIN_PASS)"

    if [ -n "$DB_FILTER" ]; then
        echo -e "${GREEN}✓${NC} Database filter: $DB_FILTER"
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
docker compose restart odoo
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

# Detect domain and email from .env
ENV_DOMAIN=$(grep "^DOMAIN=" .env 2>/dev/null | cut -d'=' -f2- | xargs)
ENV_EMAIL=$(grep "^SSL_EMAIL=" .env 2>/dev/null | cut -d'=' -f2- | xargs)
SERVER_IP=$(get_server_ip)

# Show smart next steps based on current state
if grep -v "^#" nginx/active.conf 2>/dev/null | grep -q "ssl_certificate"; then
    # SSL is already configured
    DOMAIN=$(grep "server_name" nginx/active.conf | grep -v "#" | head -1 | sed 's/.*server_name//;s/;//' | xargs | awk '{print $1}')
    echo "Your site is available at:"
    echo "  https://$DOMAIN"
elif [ -n "$ENV_DOMAIN" ]; then
    # Domain is set but SSL not configured yet
    echo "Your site is available at:"
    echo "  http://$ENV_DOMAIN"
    echo ""
    echo "To enable HTTPS, run:"
    echo "  bash scripts/ssl-setup.sh $ENV_DOMAIN $ENV_EMAIL"
else
    # No domain — IP-only mode
    echo "Your site is available at:"
    echo "  http://$SERVER_IP"
    echo ""
    echo "To set up a domain later, edit .env and set DOMAIN=yourdomain.com"
    echo "Then run: bash scripts/ssl-setup.sh yourdomain.com your@email.com"
fi
echo ""

# ── Show deploy key if addons access is needed ─
if [ "${NEEDS_ADDONS_ACCESS:-false}" = true ] && [ -f "$HOME/.ssh/ephem_addons_deploy.pub" ]; then
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  ePHEM CUSTOM MODULES — ACTION REQUIRED${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "  ePHEM is running, but without custom modules."
    echo "  To get the ePHEM modules, send the key below to:"
    echo ""
    echo -e "  ${BOLD}${CYAN}ephem@who.int${NC}"
    echo ""
    echo -e "  ${BOLD}Include your country/server name in the email subject.${NC}"
    echo ""
    echo -e "  ${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${GREEN}║  COPY EVERYTHING BETWEEN THE LINES AND PASTE IN YOUR EMAIL  ║${NC}"
    echo -e "  ${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${CYAN}$(cat $HOME/.ssh/ephem_addons_deploy.pub)${NC}"
    echo ""
    echo -e "  ${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${GREEN}║  END OF KEY                                                 ║${NC}"
    echo -e "  ${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  Once the ePHEM team confirms your key has been added, re-run:"
    echo ""
    echo -e "  ${BOLD}bash setup.sh${NC}"
    echo ""
    echo "  The setup script will download the modules automatically."
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
fi