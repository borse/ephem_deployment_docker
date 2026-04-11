#!/bin/bash
# ──────────────────────────────────────────────
# ePHEM Setup Script
# Run this once after cloning the repo.
# ──────────────────────────────────────────────

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

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
echo "What are you setting up?"
echo ""
echo -e "  ${BOLD}1)${NC} ${GREEN}Server deploy${NC}     — Production or staging server"
echo -e "  ${BOLD}2)${NC} ${YELLOW}Demo / Evaluate${NC}   — Try ePHEM locally (no development)"
echo -e "  ${BOLD}3)${NC} ${CYAN}Developer${NC}         — I'm a collaborator; I want to edit addons and use PyCharm"
echo ""
read -p "Choose [1-3]: " MODE_CHOICE

case "${MODE_CHOICE:-}" in
    1) MODE="server" ;;
    2) MODE="demo" ;;
    3) MODE="developer" ;;
    *)
        echo -e "${RED}✗${NC} Invalid choice. Run the script again and choose 1, 2, or 3."
        exit 1
        ;;
esac

echo ""
echo "─────────────────────────────────────────"
DEV_MODE=false

# ══════════════════════════════════════════════
# DEVELOPER MODE
# ══════════════════════════════════════════════
if [ "$MODE" = "developer" ]; then
    echo -e "${CYAN}${BOLD}Developer mode${NC}"
    echo ""
    echo "This mode:"
    echo "  • Clones ePHEM addons using YOUR personal GitHub SSH key"
    echo "  • Mounts custom-addons as read-write (live editing)"
    echo "  • Uses debug settings in odoo.conf (workers=0, log_level=debug)"
    echo ""
    echo "Prerequisite: your SSH key must be added to your GitHub account"
    echo "and you must be a collaborator on borse/ePHEM."
    echo ""

    echo "Verifying your GitHub SSH access..."
    SSH_TEST="$(ssh -T git@github.com 2>&1 || true)"

    if echo "$SSH_TEST" | grep -qi "successfully authenticated"; then
        GH_USER=$(echo "$SSH_TEST" | grep -oP "(?<=Hi )[^!]+" 2>/dev/null || echo "you")
        echo -e "${GREEN}✓${NC} Authenticated as: ${BOLD}$GH_USER${NC}"
    else
        echo -e "${RED}✗${NC} Could not authenticate with GitHub via SSH."
        echo ""
        echo "  Make sure you have an SSH key added to your GitHub account:"
        echo "  https://github.com/settings/keys"
        echo ""
        echo "  To generate a key if you don't have one:"
        echo "    ssh-keygen -t ed25519 -C \"your@email.com\""
        echo "    cat ~/.ssh/id_ed25519.pub   # copy this to GitHub"
        echo ""
        exit 1
    fi

    if [ -d "custom-addons/.git" ]; then
        echo -e "${GREEN}✓${NC} custom-addons/ already cloned"
        echo "  Checking for updates..."
        cd custom-addons
        if ! git fetch origin 2>/dev/null; then
            echo -e "${YELLOW}!${NC} Could not reach remote — skipping update check (no internet or SSH issue)"
            ADDONS_BEHIND=0
        else
            ADDONS_BEHIND=$(git rev-list HEAD..origin/$(git branch --show-current) --count 2>/dev/null || echo "0")
        fi
        cd ..

        if [ "$ADDONS_BEHIND" -gt 0 ] 2>/dev/null; then
            echo -e "${YELLOW}!${NC} custom-addons/ is $ADDONS_BEHIND commit(s) behind"
            echo ""
            read -p "  Pull updates now? [y/N]: " PULL_ADDONS
            if [[ "${PULL_ADDONS:-N}" =~ ^[Yy]$ ]]; then
                cd custom-addons && git pull && cd ..
                echo -e "${GREEN}✓${NC} custom-addons/ updated ($ADDONS_BEHIND commit(s))"
                ADDONS_UPDATED=true
            else
                echo "  Skipped — addons not updated"
                ADDONS_UPDATED=false
            fi
        else
            echo -e "${GREEN}✓${NC} custom-addons/ is up to date"
            ADDONS_UPDATED=false
        fi
    else
        echo ""
        echo "Which branch do you want to work on?"
        echo ""
        echo "  1) 18_national_dev    — Odoo 18 development (recommended)"
        echo "  2) 18_national_master — Odoo 18 stable"
        echo "  3) 16_national_dev    — Odoo 16 development"
        echo "  4) 16_national_master — Odoo 16 stable"
        echo ""
        read -p "Choose [1-4] (default: 1): " BRANCH_CHOICE
        case "${BRANCH_CHOICE:-1}" in
            2) BRANCH="18_national_master" ;;
            3) BRANCH="16_national_dev" ;;
            4) BRANCH="16_national_master" ;;
            *) BRANCH="18_national_dev" ;;
        esac

        echo ""
        echo "Cloning ePHEM addons (branch: $BRANCH)..."
        rm -rf custom-addons
        if git clone git@github.com:borse/ePHEM.git \
               --branch "$BRANCH" \
               --single-branch \
               custom-addons \
               --progress; then
            echo -e "${GREEN}✓${NC} custom-addons/ cloned (branch: $BRANCH)"
        else
            echo -e "${RED}✗${NC} Clone failed. Cleaning up..."
            rm -rf custom-addons
            echo ""
            echo "  Things to check:"
            echo "    • Is your SSH key added to GitHub? ssh -T git@github.com"
            echo "    • Do you have collaborator access on borse/ePHEM?"
            echo "    • Is there a network/firewall issue?"
            exit 1
        fi
    fi

    # Write developer docker-compose override
    cat > docker-compose.override.yml << 'OVERRIDE'
# Developer override — generated by setup.sh
# Do NOT commit this file. Add it to .gitignore.
services:
  odoo:
    volumes:
      - odoo-data:/var/lib/odoo
      - ./custom-addons:/mnt/extra-addons:rw
      - ./odoo.conf:/etc/odoo/odoo.conf
    ports:
      - "8069:8069"
      - "8072:8072"

  # Nginx is not needed for local development — Odoo is exposed directly above.
  # Disabling it avoids conflicts with port 80 already in use on the machine.
  nginx:
    profiles:
      - disabled

  # Certbot has nothing to do without nginx
  certbot:
    profiles:
      - disabled
OVERRIDE
    echo -e "${GREEN}✓${NC} docker-compose.override.yml created (nginx disabled, Odoo on :8069)"

    DEV_MODE=true

    echo ""
    echo -e "${CYAN}──────────────────────────────────────────────"
    echo -e "  Open in PyCharm"
    echo -e "──────────────────────────────────────────────${NC}"
    echo ""
    echo "  File → Open → select the custom-addons/ folder"
    echo ""
    echo "  Development cycle:"
    echo "    1. Edit any file in PyCharm"
    echo "    2. docker compose restart odoo"
    echo "    3. Test at http://localhost:8069"
    echo ""
    echo "  Watch logs:  docker compose logs -f odoo"
    echo ""
fi

ERRORS=0
ADDONS_UPDATED=false
IMAGE_UPDATED=false

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

# ── Check Docker socket access ────────────────
# If the user can't reach the Docker socket, add them to the docker group
# and re-exec this script in a new shell so the group takes effect immediately.
if ! docker info &> /dev/null; then
    if groups 2>/dev/null | grep -q '\bdocker\b'; then
        # Already in the group but still can't connect — something else is wrong
        echo -e "${RED}✗${NC} Cannot connect to Docker. Is the Docker daemon running?"
        echo "  Try: sudo systemctl start docker"
        ERRORS=$((ERRORS + 1))
    else
        echo -e "${YELLOW}!${NC} User '$USER' is not in the docker group."
        echo ""
        echo "  Run this command:"
        echo ""
        echo -e "  ${BOLD}sudo usermod -aG docker $USER${NC}"
        echo ""
        echo -e "  ${YELLOW}Then log out and log back in — this is required.${NC}"
        echo "  A new terminal or 'newgrp docker' is not enough;"
        echo "  you need a full logout so the group takes effect system-wide."
        echo ""
        echo "  After logging back in, run setup.sh again."
        echo ""
        exit 1
    fi
fi
echo -e "${GREEN}✓${NC} Docker socket is accessible"

# ── Check .env ────────────────────────────────
if [ -f ".env" ]; then
    echo -e "${GREEN}✓${NC} .env file exists"

    if grep -q "CHANGE_ME" .env; then
        if [ "$MODE" = "demo" ] || [ "$MODE" = "developer" ]; then
            echo -e "${YELLOW}!${NC} .env has CHANGE_ME — auto-generating passwords for local use..."
            AUTO_PG_PASS=$(openssl rand -base64 12 2>/dev/null || echo "ephem-$(date +%s)")
            if sed --version 2>/dev/null | grep -q GNU; then
                sed -i "s/CHANGE_ME/$AUTO_PG_PASS/g" .env
            else
                sed -i '' "s/CHANGE_ME/$AUTO_PG_PASS/g" .env
            fi
            echo -e "${GREEN}✓${NC} Passwords auto-set (fine for local use)"
        else
            echo -e "${RED}✗${NC} .env still has CHANGE_ME passwords."
            echo ""
            echo "  Edit your .env file and set real values:"
            echo ""
            echo "    nano .env"
            echo ""
            echo "  Required:"
            echo "    POSTGRES_PASSWORD   — strong password for the database"
            echo "    ODOO_ADMIN_PASSWORD — master password for Odoo"
            echo ""
            echo "  Recommended for production:"
            echo "    DOMAIN    — your domain name  (e.g. ephem.health.gov.xx)"
            echo "    SSL_EMAIL — your email address (e.g. admin@health.gov.xx)"
            echo ""
            echo "  Then run:  bash setup.sh"
            echo ""
            ERRORS=$((ERRORS + 1))
        fi
    else
        echo -e "${GREEN}✓${NC} Passwords have been set"
    fi

    ENV_DOMAIN=$(grep "^DOMAIN=" .env | cut -d'=' -f2- | xargs)
    if [ -n "$ENV_DOMAIN" ]; then
        echo -e "${GREEN}✓${NC} Domain: $ENV_DOMAIN"
    else
        SERVER_IP=$(get_server_ip)
        if [ "$MODE" = "server" ]; then
            echo -e "${YELLOW}!${NC} No domain set — running in IP mode ($SERVER_IP)"
            echo ""
            echo "  For production, set a domain in .env:"
            echo "    DOMAIN=$SERVER_IP   →   DOMAIN=ephem.health.gov.xx"
            echo "    SSL_EMAIL=          →   SSL_EMAIL=admin@health.gov.xx"
            echo ""
            echo "  Then run: bash setup.sh"
            echo "  And after that: bash scripts/ssl-setup.sh ephem.health.gov.xx admin@health.gov.xx"
            echo ""
        else
            echo -e "${GREEN}✓${NC} Local mode — will run on http://localhost"
        fi
    fi
else
    echo -e "${YELLOW}!${NC} .env not found — creating from template..."
    cp .env.example .env

    if [ "$MODE" = "demo" ] || [ "$MODE" = "developer" ]; then
        AUTO_PG_PASS=$(openssl rand -base64 12 2>/dev/null || echo "ephem-$(date +%s)")
        if sed --version 2>/dev/null | grep -q GNU; then
            sed -i "s/CHANGE_ME/$AUTO_PG_PASS/g" .env
        else
            sed -i '' "s/CHANGE_ME/$AUTO_PG_PASS/g" .env
        fi
        echo -e "${GREEN}✓${NC} .env created with auto-generated passwords"
    else
        echo ""
        echo -e "${YELLOW}  .env has been created from the template.${NC}"
        echo "  You must edit it before setup can continue."
        echo ""
        echo "    nano .env"
        echo ""
        echo "  Required:"
        echo "    POSTGRES_PASSWORD   — strong password for the database"
        echo "    ODOO_ADMIN_PASSWORD — master password for Odoo"
        echo ""
        echo "  Recommended for production:"
        echo "    DOMAIN    — your domain name  (e.g. ephem.health.gov.xx)"
        echo "    SSL_EMAIL — your email address (e.g. admin@health.gov.xx)"
        echo ""
        echo "  To generate strong passwords:"
        echo "    openssl rand -base64 24"
        echo ""
        echo "  Once done, run:  bash setup.sh"
        echo ""
        ERRORS=$((ERRORS + 1))
    fi
fi

# ── Nginx config ─────────────────────────────
if [ ! -f "nginx/active.conf" ] && [ -f "nginx/default.conf" ]; then
    cp nginx/default.conf nginx/active.conf
    echo -e "${GREEN}✓${NC} nginx/active.conf created from template"
elif [ -f "nginx/active.conf" ]; then
    echo -e "${GREEN}✓${NC} nginx/active.conf exists"
elif [ ! -f "nginx/default.conf" ] && [ "$MODE" = "server" ]; then
    echo -e "${RED}✗${NC} nginx/default.conf is missing. Re-clone the repo."
    ERRORS=$((ERRORS + 1))
fi

# ── Custom addons (server/demo — deploy key flow) ──
if [ "$MODE" != "developer" ]; then
    if [ -d "custom-addons/.git" ]; then
        echo -e "${GREEN}✓${NC} custom-addons/ has modules (Git repo)"
        echo "  Checking for updates..."
        cd custom-addons
        if ! git fetch origin 2>/dev/null; then
            echo -e "${YELLOW}!${NC} Could not reach remote — skipping update check (no internet or SSH issue)"
            ADDONS_BEHIND=0
        else
            ADDONS_BEHIND=$(git rev-list HEAD..origin/$(git branch --show-current) --count 2>/dev/null || echo "0")
        fi
        cd ..

        if [ "$ADDONS_BEHIND" -gt 0 ] 2>/dev/null; then
            echo -e "${YELLOW}!${NC} custom-addons/ is $ADDONS_BEHIND commit(s) behind"
            echo ""
            read -p "  Pull updates now? [y/N]: " PULL_ADDONS
            if [[ "${PULL_ADDONS:-N}" =~ ^[Yy]$ ]]; then
                cd custom-addons && git pull && cd ..
                echo -e "${GREEN}✓${NC} custom-addons/ updated ($ADDONS_BEHIND commit(s))"
                ADDONS_UPDATED=true
            else
                echo "  Skipped — addons not updated"
                ADDONS_UPDATED=false
            fi
        else
            echo -e "${GREEN}✓${NC} custom-addons/ is up to date"
            ADDONS_UPDATED=false
        fi
    else
        echo -e "${YELLOW}!${NC} Downloading ePHEM modules..."
        rm -rf custom-addons

        DEPLOY_KEY="$HOME/.ssh/ephem_addons_deploy"
        ADDONS_CLONED=false

        if [ -f "$DEPLOY_KEY" ]; then
            echo "  Testing deploy key access..."
            SSH_OUTPUT="$(ssh -T git@github-ephem-addons 2>&1 || true)"

            if echo "$SSH_OUTPUT" | grep -qi "successfully authenticated"; then
                echo -e "  ${GREEN}✓${NC} Access granted"
                echo "  Cloning ePHEM modules..."
                echo ""
                if GIT_SSH_COMMAND="ssh -o ConnectTimeout=30" \
                   git clone git@github-ephem-addons:borse/ePHEM.git \
                       --depth 1 \
                       --branch 18_national_dev \
                       --single-branch \
                       custom-addons \
                       --progress; then
                    echo ""
                    echo -e "${GREEN}✓${NC} ePHEM modules downloaded"
                    ADDONS_CLONED=true
                else
                    echo -e "${RED}✗${NC} Clone failed. Cleaning up partial clone..."
                    rm -rf custom-addons
                    mkdir -p custom-addons
                fi
            else
                echo -e "${YELLOW}!${NC} Deploy key exists but access not yet granted"
                mkdir -p custom-addons
            fi
        fi

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
fi

# ── Scripts ───────────────────────────────────
for script in scripts/backup.sh scripts/ssl-setup.sh scripts/add-domain.sh \
              scripts/duplicate-db.sh scripts/update-modules.sh \
              scripts/request-addons-access.sh scripts/clone-addons.sh; do
    [ -f "$script" ] && chmod +x "$script"
done
echo -e "${GREEN}✓${NC} Scripts are executable"

# ── Generate odoo.conf ────────────────────────
if [ -f ".env" ]; then
    if sed --version 2>/dev/null | grep -q GNU; then
        sed -i 's/\r$//' .env
    else
        sed -i '' 's/\r$//' .env
    fi

    ADMIN_PASS=$(grep "^ODOO_ADMIN_PASSWORD=" .env | cut -d'=' -f2- | xargs)
    DB_FILTER=$(grep "^ODOO_DBFILTER=" .env | cut -d'=' -f2- | xargs)
    LIST_DB=$(grep "^ODOO_LIST_DB=" .env | cut -d'=' -f2- | xargs)

    ADMIN_PASS="${ADMIN_PASS:-}"
    LIST_DB="${LIST_DB:-True}"

    if [ -z "$ADMIN_PASS" ] || [ "$ADMIN_PASS" = "CHANGE_ME" ]; then
        ADMIN_PASS=$(openssl rand -base64 16 2>/dev/null || echo "ephem-$(date +%s)")
        echo -e "${YELLOW}!${NC} Generated admin password: $ADMIN_PASS  (save this!)"
    fi

    if [ "$DEV_MODE" = "true" ]; then
        cat > odoo.conf << ODOOEOF
[options]
; Generated by setup.sh (DEVELOPER MODE)
; Re-run: bash setup.sh to regenerate

admin_passwd = $ADMIN_PASS

addons_path = /mnt/extra-addons,/usr/lib/python3/dist-packages/odoo/addons

proxy_mode = False

; workers=0 uses threading mode — required for dev_mode, simpler for local use
workers = 0
max_cron_threads = 1

xmlrpc_port = 8069
gevent_port = 8072

log_level = debug

; dev_mode enables asset reload, tour snippets, etc.
dev_mode = reload,qweb,werkzeug,xml

list_db = True
ODOOEOF
        echo -e "${GREEN}✓${NC} odoo.conf generated (developer: workers=0, log=debug, dev_mode=reload)"
    else
        cat > odoo.conf << ODOOEOF
[options]
; Generated by setup.sh — do not edit manually.
; Change values in .env and re-run: bash setup.sh

admin_passwd = $ADMIN_PASS

addons_path = /mnt/extra-addons,/usr/lib/python3/dist-packages/odoo/addons

proxy_mode = True

workers = 4
max_cron_threads = 1
limit_memory_hard = 2684354560
limit_memory_soft = 2147483648
limit_request = 8192
limit_time_cpu = 600
limit_time_real = 1200

xmlrpc_port = 8069
gevent_port = 8072

log_level = info

list_db = $LIST_DB
ODOOEOF
        echo -e "${GREEN}✓${NC} odoo.conf generated"
    fi

    if [ -n "${DB_FILTER:-}" ]; then
        echo "dbfilter = $DB_FILTER" >> odoo.conf
    fi
fi

mkdir -p backups
echo -e "${GREEN}✓${NC} backups/ directory exists"

# ── Summary ───────────────────────────────────
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

# ── Check for Docker image updates ──────────
echo ""
echo "Checking for Docker image updates..."
CURRENT_IMAGE=$(docker inspect --format='{{.Id}}' borrs/ephem:latest 2>/dev/null || echo "none")
REMOTE_DIGEST=$(docker manifest inspect borrs/ephem:latest 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('config',{}).get('digest','unknown'))" 2>/dev/null || echo "unknown")

if [ "$CURRENT_IMAGE" = "none" ]; then
    # Image not present at all — will be pulled automatically by docker compose
    echo -e "${GREEN}✓${NC} Image will be downloaded on first run"
    IMAGE_UPDATED=false
else
    read -p "  Check for Odoo image updates? [y/N]: " CHECK_IMAGE
    if [[ "${CHECK_IMAGE:-N}" =~ ^[Yy]$ ]]; then
        echo "  Pulling latest image (this may take a few minutes)..."
        if docker compose pull odoo 2>&1 | grep -q "Downloaded newer image\|Pull complete"; then
            echo -e "${GREEN}✓${NC} Image updated"
            IMAGE_UPDATED=true
        else
            echo -e "${GREEN}✓${NC} Image is already up to date"
            IMAGE_UPDATED=false
        fi
    else
        echo "  Skipped — image not updated"
        IMAGE_UPDATED=false
    fi
fi

# ── Write demo override (no nginx) ───────────
# Demo and developer both run locally — nginx is not needed and conflicts
# with port 80 if another web server is already running on this machine.
if [ "$MODE" = "demo" ]; then
    cat > docker-compose.override.yml << 'OVERRIDE'
# Demo override — generated by setup.sh
# Disables nginx so Odoo is accessible directly on :8069.
services:
  odoo:
    ports:
      - "8069:8069"
      - "8072:8072"

  nginx:
    profiles:
      - disabled

  certbot:
    profiles:
      - disabled
OVERRIDE
    echo -e "${GREEN}✓${NC} docker-compose.override.yml created (nginx disabled, Odoo on :8069)"
fi

docker compose up -d
docker compose restart odoo
echo ""

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

echo "Checking database connection..."
sleep 5

ODOO_LOG=$(docker compose logs --tail=5 odoo 2>&1)
if echo "$ODOO_LOG" | grep -q "password authentication failed"; then
    echo ""
    echo -e "${YELLOW}! Database password mismatch. Fixing automatically...${NC}"
    ENV_PASSWORD=$(grep "^POSTGRES_PASSWORD=" .env | cut -d'=' -f2-)
    docker compose exec -T db psql -U odoo -d postgres -c "ALTER USER odoo WITH PASSWORD '${ENV_PASSWORD}';" 2>/dev/null && {
        echo -e "${GREEN}✓${NC} Password synced. Restarting Odoo..."
        docker compose restart odoo
        sleep 5
    } || {
        echo -e "${RED}✗${NC} Could not fix automatically."
        echo "  To reset: docker compose down -v && docker compose up -d"
        exit 1
    }
fi

echo ""
echo "========================================="
echo ""
docker compose ps
echo ""
echo "========================================="
echo -e "${GREEN}ePHEM is running!${NC}"
echo ""

ENV_DOMAIN=$(grep "^DOMAIN=" .env 2>/dev/null | cut -d'=' -f2- | xargs)
ENV_EMAIL=$(grep "^SSL_EMAIL=" .env 2>/dev/null | cut -d'=' -f2- | xargs)
SERVER_IP=$(get_server_ip)

if [ "$MODE" = "developer" ]; then
    echo "ePHEM is ready for development:"
    echo ""
    echo "  http://localhost:8069"
    echo ""
    echo "Open in PyCharm:"
    echo "  File → Open → custom-addons/"
    echo ""
    echo "Development cycle:"
    echo "  1. Edit any file in custom-addons/"
    echo "  2. docker compose restart odoo"
    echo "  3. Refresh http://localhost:8069"
    echo ""
    echo "  docker compose logs -f odoo   (watch logs)"

elif [ "$MODE" = "demo" ]; then
    DEMO_ADMIN_PASS=$(grep "^ODOO_ADMIN_PASSWORD=" .env | cut -d'=' -f2- | xargs)
    echo "Your demo is available at:"
    echo "  http://localhost:8069       (on this machine)"
    if [ -n "$SERVER_IP" ] && [ "$SERVER_IP" != "127.0.0.1" ]; then
        echo "  http://$SERVER_IP:8069   (from other devices on the network)"
    fi
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  First time? Create a database:${NC}"
    echo ""
    echo "  1. Open the URL above in your browser"
    echo "  2. Fill in the database creation form"
    echo "  3. When asked for Master Password, use:"
    echo ""
    echo -e "     ${BOLD}${GREEN}$DEMO_ADMIN_PASS${NC}"
    echo ""
    echo "  (This is your ODOO_ADMIN_PASSWORD from .env)"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "When you're done:"
    echo "  docker compose down      — stop (keep data)"
    echo "  docker compose down -v   — stop and wipe all data"

else
    if grep -v "^#" nginx/active.conf 2>/dev/null | grep -q "ssl_certificate"; then
        DOMAIN=$(grep "server_name" nginx/active.conf | grep -v "#" | head -1 | sed 's/.*server_name//;s/;//' | xargs | awk '{print $1}')
        echo "Your site is available at:"
        echo "  https://$DOMAIN"
        echo ""
        echo "Next steps:"
        echo "  • Go to https://$DOMAIN/web/database/manager to create your database"
        echo "  • Set up automatic backups: crontab -e"
    elif [ -n "$ENV_DOMAIN" ]; then
        echo "Your site is available at:"
        echo "  http://$ENV_DOMAIN  (HTTP only)"
        echo ""
        echo "Next step — enable HTTPS:"
        echo "  bash scripts/ssl-setup.sh $ENV_DOMAIN $ENV_EMAIL"
        echo ""
        echo "Then run setup again to apply any remaining config:"
        echo "  bash setup.sh"
    else
        echo "Your site is available at:"
        echo "  http://$SERVER_IP  (no domain, no SSL)"
        echo ""
        echo -e "${YELLOW}For production, set a domain and SSL:${NC}"
        echo "  1. Edit .env:"
        echo "       DOMAIN=$SERVER_IP   →   DOMAIN=ephem.health.gov.xx"
        echo "       SSL_EMAIL=          →   SSL_EMAIL=admin@health.gov.xx"
        echo ""
        echo "  2. Run setup again:"
        echo "       bash setup.sh"
        echo ""
        echo "  3. Then set up SSL:"
        echo "       bash scripts/ssl-setup.sh ephem.health.gov.xx admin@health.gov.xx"
    fi
fi

echo ""

# ── Deploy key notice (server/demo only) ─────
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
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
fi
# ── Module update warning ─────────────────────
# Show this if addons were updated — make it impossible to miss
if [ "${ADDONS_UPDATED:-false}" = true ]; then
    echo ""
    echo -e "${RED}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                                                                  ║${NC}"
    echo -e "${RED}║   ⚠  ACTION REQUIRED — ODOO MODULE UPDATE NEEDED                ║${NC}"
    echo -e "${RED}║                                                                  ║${NC}"
    echo -e "${RED}╠══════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${RED}║                                                                  ║${NC}"
    echo -e "${RED}║  The custom addon code was updated, but Odoo's database has      ║${NC}"
    echo -e "${RED}║  not been told about the changes yet.                            ║${NC}"
    echo -e "${RED}║                                                                  ║${NC}"
    echo -e "${RED}║  Without running the module update, you may see:                 ║${NC}"
    echo -e "${RED}║    • Missing fields or buttons                                   ║${NC}"
    echo -e "${RED}║    • Old views not reflecting new changes                        ║${NC}"
    echo -e "${RED}║    • Errors on pages that used to work                           ║${NC}"
    echo -e "${RED}║                                                                  ║${NC}"
    echo -e "${RED}╠══════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${RED}║                                                                  ║${NC}"
    echo -e "${RED}║  Run this now:                                                   ║${NC}"
    echo -e "${RED}║                                                                  ║${NC}"
    echo -e "${RED}║    bash scripts/update-modules.sh                                ║${NC}"
    echo -e "${RED}║                                                                  ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
fi