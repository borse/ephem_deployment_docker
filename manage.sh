#!/bin/bash
# ──────────────────────────────────────────────
# ePHEM Production Menu
# Day-to-day management of an installed server: tenants, SSL, updates,
# backups, health. Run from the repo directory:
#
#     bash manage.sh
#
# Everything here wraps the scripts/ tools and docker compose — each menu
# item prints the commands it runs, so this doubles as a cheat sheet.
# ──────────────────────────────────────────────
set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

if [ ! -f .env ] || [ ! -f docker-compose.yml ]; then
    echo -e "${RED}✗${NC} Run this from the ephem-deploy directory of an installed server"
    echo "  (.env not found — run 'bash setup.sh' first)."
    exit 1
fi

env_get() { grep "^$1=" .env 2>/dev/null | cut -d'=' -f2- | xargs || true; }
set_env_key() {  # set_env_key KEY VALUE — update or append KEY=VALUE in .env
    if grep -q "^$1=" .env; then
        sed -i "s|^$1=.*|$1=$2|" .env
    else
        echo "$1=$2" >> .env
    fi
}

DB_USER="$(env_get POSTGRES_USER)"; DB_USER="${DB_USER:-odoo}"

list_dbs() {
    docker compose exec -T db psql -U "$DB_USER" -d postgres -t -A -c \
        "SELECT datname FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres') ORDER BY datname;" \
        </dev/null 2>/dev/null | tr -d '\r'
}

# ── 1) Status & health ────────────────────────
menu_status() {
    echo -e "${CYAN}${BOLD}Status & health${NC}"
    echo ""
    docker compose ps
    echo ""
    echo -e "${BOLD}Databases:${NC}"
    local dbs; dbs=$(list_dbs)
    if [ -n "$dbs" ]; then echo "$dbs" | sed 's/^/  • /'; else echo "  (none, or database not running)"; fi
    echo ""
    echo -e "${BOLD}App image:${NC}  borrs/ephem:$(env_get EPHEM_IMAGE_TAG | grep . || echo 'latest  (! unpinned — set EPHEM_IMAGE_TAG in .env on production)')"
    echo -e "${BOLD}Disk:${NC}"
    df -h / | tail -1 | awk '{printf "  root: %s used of %s (%s)\n", $3, $2, $5}'
    echo ""
    echo -e "${BOLD}SSL certificate:${NC}"
    local cert_end
    cert_end=$(docker compose exec -T nginx sh -c \
        'for f in /etc/letsencrypt/live/*/fullchain.pem; do [ -f "$f" ] && openssl x509 -enddate -noout -in "$f"; done' \
        </dev/null 2>/dev/null | head -1)
    if [ -n "${cert_end:-}" ]; then echo "  ${cert_end/notAfter=/expires: }"; else echo "  none found (HTTP-only server, or nginx not running)"; fi
    echo ""
    echo -e "${BOLD}Last backup:${NC}"
    # shellcheck disable=SC2012
    ls -t backups/*.age backups/*.gz 2>/dev/null | head -1 | xargs -r ls -lh | awk '{print "  " $NF " (" $5 ", " $6 " " $7 " " $8 ")"}'
    [ -z "$(ls backups/*.age backups/*.gz 2>/dev/null)" ] && echo -e "  ${YELLOW}!${NC} no backups found — use menu item 8, and add the cron job (README → Backups)"
}

# ── 2) New tenant: domain + database ──────────
menu_new_tenant() {
    echo -e "${CYAN}${BOLD}Add a new domain + database (tenant)${NC}"
    echo ""
    echo "  One tenant = one domain + one database named after the domain's"
    echo "  FIRST label: training.health.gov.xx → database 'training'."
    echo "  The database is created directly with odoo-bin — the web database"
    echo "  manager stays disabled throughout."
    echo ""
    read -r -p "  Full domain (e.g. training.health.gov.xx), empty to cancel: " DOMAIN
    [ -z "${DOMAIN:-}" ] && { echo "  Cancelled."; return 0; }
    local DB="${DOMAIN%%.*}"
    if ! printf '%s' "$DB" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'; then
        echo -e "  ${RED}✗${NC} '$DB' is not a valid subdomain label (lowercase letters, digits, hyphens)."
        return 1
    fi
    if list_dbs | grep -qx "$DB"; then
        echo -e "  ${RED}✗${NC} Database '$DB' already exists."
        return 1
    fi
    echo ""
    echo "  Domain:   $DOMAIN"
    echo "  Database: $DB"
    read -r -p "  Continue? [Y/n]: " OK
    [[ "${OK:-Y}" =~ ^[Nn]$ ]] && { echo "  Cancelled."; return 0; }

    # 1. nginx + certificate (only applies once SSL is set up; an HTTP-only
    #    server answers for every hostname already)
    if [ -f nginx/active.conf ] && grep -q "ssl_certificate" nginx/active.conf; then
        echo ""
        echo -e "  ${CYAN}→${NC} Adding $DOMAIN to nginx + the SSL certificate..."
        echo "     (DNS for $DOMAIN must already point at this server)"
        bash scripts/add-domain.sh "$DOMAIN" || {
            echo -e "  ${RED}✗${NC} add-domain failed — fix that first (DNS? port 80?); no database was created."
            return 1
        }
    else
        echo -e "  ${YELLOW}!${NC} No SSL configured yet — skipping nginx/cert step (HTTP mode serves"
        echo "     any hostname). Set up SSL later with menu item 4."
    fi

    # 2. Multi-tenant routing must be on before a second database exists
    local NDBS; NDBS=$(list_dbs | grep -c . || true)
    if [ "$(env_get ODOO_DBFILTER)" = "" ] && [ "${NDBS:-0}" -ge 1 ]; then
        echo ""
        echo -e "  ${YELLOW}!${NC} ODOO_DBFILTER is not set. With more than one database, Odoo needs"
        echo "     it to pick the right database per domain (subdomain = db name)."
        read -r -p "  Set ODOO_DBFILTER=^%d\$ now? [Y/n]: " DF
        if [[ ! "${DF:-Y}" =~ ^[Nn]$ ]]; then
            set_env_key ODOO_DBFILTER '^%d$'
            if grep -q "^dbfilter" odoo.conf 2>/dev/null; then
                sed -i 's|^dbfilter = .*|dbfilter = ^%d$|' odoo.conf
            else
                echo 'dbfilter = ^%d$' >> odoo.conf
            fi
            echo -e "  ${GREEN}✓${NC} dbfilter set (subdomain = database name, exact match)"
        fi
    fi

    # 3. Create the database with odoo-bin (the entrypoint injects the DB
    #    credentials). Odoo is stopped so a stray web request can't race the
    #    creation and corrupt it.
    echo ""
    echo -e "  ${CYAN}→${NC} Creating database '$DB' (Odoo is stopped briefly)..."
    docker compose stop odoo >/dev/null
    if docker compose run --rm odoo odoo -d "$DB" -i base --without-demo=all --stop-after-init; then
        echo -e "  ${GREEN}✓${NC} Database '$DB' created"
    else
        echo -e "  ${RED}✗${NC} Database creation failed — check the output above."
        docker compose up -d odoo >/dev/null
        return 1
    fi
    docker compose up -d >/dev/null

    echo ""
    echo -e "  ${GREEN}✓ Tenant ready:${NC} https://$DOMAIN"
    echo ""
    echo "  Secure it now (first login):"
    echo "    • log in (admin/admin), change the admin password immediately"
    echo "    • enable two-factor authentication for admin"
    echo "    • Settings → General Settings → Customer Account: 'On invitation'"
}

# ── 3) Duplicate a database ───────────────────
menu_duplicate_db() {
    echo -e "${CYAN}${BOLD}Duplicate a database${NC} (e.g. training copies)"
    echo ""
    echo "  Existing databases:"
    list_dbs | sed 's/^/    • /'
    echo ""
    read -r -p "  Source database (empty to cancel): " SRC
    [ -z "${SRC:-}" ] && { echo "  Cancelled."; return 0; }
    read -r -p "  New database name(s), space-separated: " -a TARGETS
    [ "${#TARGETS[@]}" -eq 0 ] && { echo "  Cancelled."; return 0; }
    bash scripts/duplicate-db.sh "$SRC" "${TARGETS[@]}"
}

# ── 4) SSL setup / status ─────────────────────
menu_ssl() {
    echo -e "${CYAN}${BOLD}SSL (Let's Encrypt)${NC}"
    echo ""
    if [ -f nginx/active.conf ] && grep -q ssl_certificate nginx/active.conf; then
        echo "  SSL is configured. Current domains:"
        grep -m1 "server_name" nginx/active.conf | sed 's/.*server_name/   /;s/;//'
        echo ""
        echo "  Certificates renew automatically (certbot container, checked every 12h)."
        echo "  • Add a domain to the certificate:  menu item 2, or scripts/add-domain.sh"
        echo "  • Re-run from scratch:              bash scripts/ssl-setup.sh DOMAIN EMAIL"
        return 0
    fi
    echo "  SSL is NOT set up yet (HTTP only)."
    echo "  Requirements: a DNS record pointing at this server, ports 80+443 open"
    echo "  at your cloud provider."
    echo ""
    read -r -p "  Domain(s), comma-separated (empty to cancel): " DOMAINS
    [ -z "${DOMAINS:-}" ] && { echo "  Cancelled."; return 0; }
    read -r -p "  Email for expiry notices (use a team mailbox): " EMAIL
    [ -z "${EMAIL:-}" ] && { echo "  Cancelled."; return 0; }
    bash scripts/ssl-setup.sh "$DOMAINS" "$EMAIL"
}

# ── 5) Update the app image ───────────────────
menu_update_app() {
    echo -e "${CYAN}${BOLD}Update the ePHEM app image${NC}"
    echo ""
    local TAG; TAG=$(env_get EPHEM_IMAGE_TAG)
    echo "  Pinned version: ${TAG:-'(none — tracking latest; pin one on production!)'}"
    echo "  Released versions: https://hub.docker.com/r/borrs/ephem/tags"
    echo ""
    read -r -p "  New version to pin (e.g. 1.0.3), empty to keep '$TAG': " NEWTAG
    if [ -n "${NEWTAG:-}" ]; then
        set_env_key EPHEM_IMAGE_TAG "$NEWTAG"
        echo -e "  ${GREEN}✓${NC} EPHEM_IMAGE_TAG=$NEWTAG"
    fi
    echo ""
    read -r -p "  Back up before updating? [Y/n]: " B
    [[ ! "${B:-Y}" =~ ^[Nn]$ ]] && bash scripts/backup.sh
    echo ""
    echo -e "  ${CYAN}→${NC} docker compose pull && docker compose up -d"
    docker compose pull && docker compose up -d
    echo ""
    echo "  If this release includes module changes, run menu item 7 next"
    echo "  (update modules across databases). To roll back: re-run this item"
    echo "  with the previous version number."
}

# ── 6) Custom addons: fetch/switch branch, pull ─
menu_addons() {
    echo -e "${CYAN}${BOLD}Custom addons (ePHEM modules)${NC}"
    echo ""
    if [ ! -d custom-addons/.git ]; then
        echo -e "  ${RED}✗${NC} custom-addons/ is not a git clone on this server."
        return 1
    fi
    local cur; cur=$(git -C custom-addons branch --show-current 2>/dev/null || echo "?")
    echo "  Current branch: $cur"
    # Repair: an earlier version widened the fetch refspec, which makes every
    # fetch download ALL branches — on a slow server link that looks like a
    # freeze. Keep it narrowed to the branch in use.
    if [ "$cur" != "?" ] && [ -n "$cur" ] && \
       [ "$(git -C custom-addons config --get remote.origin.fetch 2>/dev/null)" = "+refs/heads/*:refs/remotes/origin/*" ]; then
        git -C custom-addons config remote.origin.fetch "+refs/heads/$cur:refs/remotes/origin/$cur"
        echo -e "  ${GREEN}✓${NC} repaired fetch config (was set to fetch every branch)"
    fi
    # Bounded check — never lets a slow network look like a hang.
    echo -n "  Checking origin... "
    if timeout 15 git -C custom-addons fetch --quiet origin "$cur" 2>/dev/null; then
        local behind; behind=$(git -C custom-addons rev-list HEAD..origin/"$cur" --count 2>/dev/null || echo "?")
        echo "behind by ${behind} commit(s)"
    else
        echo "unreachable or slow — skipped"
    fi
    echo ""
    echo -e "  ${YELLOW}!${NC} This changes the live code for EVERY database on this server."
    echo "     Take a backup first for anything beyond a routine pull."
    echo ""
    echo "  1) Pull latest on '$cur'"
    echo "  2) Fetch & switch to a different branch"
    echo "  3) Back"
    read -r -p "  Choose [1-3]: " A
    case "${A:-3}" in
        1)
            git -C custom-addons pull --ff-only || {
                echo -e "  ${RED}✗${NC} Pull failed (diverged or no access) — resolve manually."
                return 1
            }
            ;;
        2)
            read -r -p "  Branch name on origin: " BR
            [ -z "${BR:-}" ] && { echo "  Cancelled."; return 0; }
            # Validate FIRST — nothing is changed until the branch is known
            # to exist under exactly this name.
            if ! git -C custom-addons ls-remote --exit-code --heads origin "$BR" >/dev/null 2>&1; then
                echo -e "  ${RED}✗${NC} No branch named '$BR' on origin. Branches that exist:"
                git -C custom-addons ls-remote --heads origin 2>/dev/null \
                    | sed 's|.*refs/heads/|    • |' \
                    || echo "    (could not list — is the deploy key authorized?)"
                return 1
            fi
            # Re-point the (narrow) refspec at the new branch, then fetch —
            # only that one branch is ever downloaded, and git can resolve
            # it for switch/tracking. --depth 1 keeps shallow clones small.
            local DEPTH=""
            [ -f custom-addons/.git/shallow ] && DEPTH="--depth 1"
            ( cd custom-addons &&
              git config remote.origin.fetch "+refs/heads/$BR:refs/remotes/origin/$BR" &&
              git fetch $DEPTH origin &&
              { git switch "$BR" 2>/dev/null || git switch -c "$BR" --track "origin/$BR"; } &&
              git merge --ff-only "origin/$BR" &&
              git branch --set-upstream-to="origin/$BR" "$BR"
            ) || { echo -e "  ${RED}✗${NC} Fetch/switch failed — see the git output above."; return 1; }
            echo -e "  ${GREEN}✓${NC} custom-addons now on '$BR'"
            ;;
        *) return 0 ;;
    esac
    echo ""
    read -r -p "  Apply the new code now (update modules on all databases + restart)? [Y/n]: " U
    if [[ ! "${U:-Y}" =~ ^[Nn]$ ]]; then
        bash scripts/update-modules.sh --auto
    else
        echo "  Remember: the new code is NOT active until modules are updated"
        echo "  (menu item 7) and Odoo is restarted (docker compose restart odoo)."
    fi
}

# ── 9) Database manager lock ──────────────────
menu_db_manager() {
    echo -e "${CYAN}${BOLD}Web database manager${NC} (/web/database/manager)"
    echo ""
    local CUR; CUR=$(env_get ODOO_LIST_DB)
    echo "  Current state: ODOO_LIST_DB=${CUR:-True}"
    echo ""
    echo "  Keep it DISABLED on production — it can create, drop and download"
    echo "  databases, protected only by the master password. (Creating a new"
    echo "  tenant via menu item 2 does not need it.)"
    echo ""
    if [ "${CUR:-True}" = "False" ]; then
        read -r -p "  Enable it temporarily? [y/N]: " E
        [[ "${E:-N}" =~ ^[Yy]$ ]] || { echo "  Left disabled."; return 0; }
        set_env_key ODOO_LIST_DB True
        sed -i 's/^list_db = .*/list_db = True/' odoo.conf
        echo -e "  ${YELLOW}!${NC} Enabled. Come back and DISABLE it as soon as you are done."
    else
        read -r -p "  Disable it now (recommended)? [Y/n]: " D
        [[ "${D:-Y}" =~ ^[Nn]$ ]] && { echo "  Left enabled."; return 0; }
        set_env_key ODOO_LIST_DB False
        sed -i 's/^list_db = .*/list_db = False/' odoo.conf
        echo -e "  ${GREEN}✓${NC} Disabled."
    fi
    docker compose restart odoo >/dev/null 2>&1 && echo "  Odoo restarted."
}

# ── 11) Security check ────────────────────────
menu_security() {
    echo -e "${CYAN}${BOLD}Security check${NC}"
    echo ""
    echo -e "${BOLD}Database role:${NC}"
    bash scripts/harden-db-role.sh || true
    echo ""
    echo -e "${BOLD}Settings:${NC}"
    local LDB DBF TAG
    LDB=$(env_get ODOO_LIST_DB); DBF=$(env_get ODOO_DBFILTER); TAG=$(env_get EPHEM_IMAGE_TAG)
    [ "${LDB:-True}" = "False" ] \
        && echo -e "  ${GREEN}✓${NC} database manager disabled (ODOO_LIST_DB=False)" \
        || echo -e "  ${YELLOW}!${NC} database manager ENABLED — disable it via menu item 9"
    [ -n "$DBF" ] \
        && echo -e "  ${GREEN}✓${NC} dbfilter set ($DBF)" \
        || echo -e "  ${YELLOW}!${NC} ODOO_DBFILTER not set — required once you have several databases"
    [ -n "$TAG" ] \
        && echo -e "  ${GREEN}✓${NC} app image pinned (EPHEM_IMAGE_TAG=$TAG)" \
        || echo -e "  ${YELLOW}!${NC} app image not pinned — set EPHEM_IMAGE_TAG in .env"
    [ -n "$(env_get BACKUP_AGE_RECIPIENT)" ] \
        && echo -e "  ${GREEN}✓${NC} backups are encrypted (BACKUP_AGE_RECIPIENT set)" \
        || echo -e "  ${YELLOW}!${NC} backups NOT encrypted — set BACKUP_AGE_RECIPIENT (README → Backups)"
    [ -n "$(env_get BACKUP_PING_URL)" ] \
        && echo -e "  ${GREEN}✓${NC} backup monitoring ping configured" \
        || echo -e "  ${YELLOW}!${NC} no backup monitoring — set BACKUP_PING_URL (README → Backups)"
    echo ""
    echo "  Host-level checklist (SSH, firewall, OS updates): see HARDENING.md"
}

# ── 12) nginx upload size limit ───────────────
menu_upload_limit() {
    echo -e "${CYAN}${BOLD}Upload size limit (nginx)${NC}"
    echo ""
    echo "  Uploads bigger than this limit get '413 Request Entity Too Large' —"
    echo "  typically when restoring a large database through the database"
    echo "  manager. The limit applies to every upload (attachments too)."
    echo ""
    if [ ! -f nginx/active.conf ]; then
        echo -e "  ${RED}✗${NC} nginx/active.conf not found — run setup.sh first."
        return 1
    fi
    local CUR
    CUR=$(grep -m1 -o 'client_max_body_size[[:space:]]*[0-9]*[MmGg]' nginx/active.conf | awk '{print $NF}')
    echo "  Current limit: ${CUR:-unknown}"
    read -r -p "  New limit (e.g. 300M or 2G), empty to cancel: " VAL
    [ -z "${VAL:-}" ] && { echo "  Cancelled."; return 0; }
    if ! printf '%s' "$VAL" | grep -Eq '^[0-9]+[MmGg]$'; then
        echo -e "  ${RED}✗${NC} '$VAL' is not a valid size — use a number plus M or G (e.g. 500M, 1G)."
        return 1
    fi
    # Persist in .env so a future ssl-setup.sh run keeps the value, and
    # apply to the live config.
    set_env_key NGINX_MAX_UPLOAD "$VAL"
    sed -i "s|client_max_body_size[[:space:]]*[0-9]*[MmGg];|client_max_body_size ${VAL};|g" nginx/active.conf
    if docker compose exec -T nginx nginx -t >/dev/null 2>&1 && \
       docker compose exec -T nginx nginx -s reload >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} Limit is now $VAL (nginx reloaded, no downtime)."
    else
        echo -e "  ${YELLOW}!${NC} Config updated but nginx did not reload — apply it with:"
        echo "     docker compose restart nginx"
    fi
}

# ── Menu loop ─────────────────────────────────
while true; do
    echo ""
    echo -e "${BOLD}ePHEM production menu${NC}   ($(docker compose ps --status=running 2>/dev/null | grep -q odoo && echo -e "${GREEN}running${NC}" || echo -e "${RED}stopped${NC}"))"
    echo "  1) Status & health"
    echo "  2) Add a new domain + database (tenant)"
    echo "  3) Duplicate a database (training copies)"
    echo "  4) SSL — set up HTTPS / show status"
    echo "  5) Update the ePHEM app image"
    echo "  6) Custom addons — pull / switch branch"
    echo "  7) Update modules across databases"
    echo "  8) Back up now"
    echo "  9) Web database manager — enable/disable"
    echo " 10) Follow Odoo logs (Ctrl-C to stop)"
    echo " 11) Security check"
    echo " 12) Upload size limit (fix '413 Request Entity Too Large')"
    echo "  0) Exit"
    echo ""
    read -r -p "Choose [0-12]: " CH
    echo ""
    case "${CH:-}" in
        1)  menu_status ;;
        2)  menu_new_tenant ;;
        3)  menu_duplicate_db ;;
        4)  menu_ssl ;;
        5)  menu_update_app ;;
        6)  menu_addons ;;
        7)  bash scripts/update-modules.sh ;;
        8)  bash scripts/backup.sh; echo ""; ls -lht backups/ 2>/dev/null | head -5 ;;
        9)  menu_db_manager ;;
        10) docker compose logs -f --tail=100 odoo || true ;;
        11) menu_security ;;
        12) menu_upload_limit ;;
        0)  echo "Bye. Re-open anytime:  bash manage.sh"; exit 0 ;;
        *)  echo -e "${YELLOW}!${NC} Invalid choice — pick 0-12." ;;
    esac
done
