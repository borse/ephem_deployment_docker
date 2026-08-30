#!/bin/bash
# ──────────────────────────────────────────────
# ePHEM — nginx + Let's Encrypt helpers  (sourced, never run directly)
#
# The model: ONE certificate per domain, ONE nginx server block per domain.
#
#   /etc/letsencrypt/live/training.pheoc.com/fullchain.pem   ← its own cert
#   server { server_name training.pheoc.com; ... }           ← its own block
#
# Adding a domain issues one new certificate and appends one block; removing
# a domain deletes exactly those two things. Nothing shared has to be
# expanded, re-issued, or rebuilt — and a domain whose DNS is gone can never
# block the renewal of the certificates that are still in use.
#
# Older servers have ONE certificate covering every domain (certbot --expand).
# Those keep working: the renderer points a domain at its own certificate
# when it has one, and at the shared certificate that covers it otherwise.
# scripts/split-certs.sh migrates such a server to one certificate each.
#
# Server-wide nginx settings live in .env and are rendered into every server
# block, so they survive adding or removing a domain:
#
#   NGINX_MAX_UPLOAD   client_max_body_size            (max_upload)
#   NGINX_RPC_ALLOW    who may call /xmlrpc, /jsonrpc  (rpc_allow)
#
# Usage:  source "$(dirname "$0")/nginx-lib.sh"
# ──────────────────────────────────────────────

EPHEM_ROOT="${EPHEM_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
NGINX_ACTIVE="$EPHEM_ROOT/nginx/active.conf"
NGINX_TEMPLATE="$EPHEM_ROOT/nginx/default.conf"

# Only define colours the sourcing script has not defined already.
RED="${RED:-\033[0;31m}"
GREEN="${GREEN:-\033[0;32m}"
YELLOW="${YELLOW:-\033[1;33m}"
CYAN="${CYAN:-\033[0;36m}"
BOLD="${BOLD:-\033[1m}"
NC="${NC:-\033[0m}"

dc() { docker compose -f "$EPHEM_ROOT/docker-compose.yml" "$@"; }

# ── Certificates ──────────────────────────────
#
# Read what is on disk instead of parsing `certbot certificates`. That
# listing is written for humans and its field names move between versions
# (it said "Domains:" for years, current certbot says "Identifiers:"), and
# docker adds CR line endings whenever it allocates a TTY. A parser that
# quietly returns nothing here would make every domain look uncertified, so
# this reads live/*/fullchain.pem with openssl, which does not move.

# -T and </dev/null on every container call: without them `docker compose run`
# allocates a TTY, which eats the keystrokes meant for the next prompt in this
# script and puts CR line endings on everything it prints.
#
# The certbot image's entrypoint is the renew loop — clear it to run the CLI.
certbot_cli() { dc run --rm -T --entrypoint "" certbot certbot "$@" </dev/null; }
# ...and it carries an openssl binary, which nginx:alpine does not.
certbot_sh()  { dc run --rm -T --entrypoint sh certbot -c "$1" </dev/null; }

# name <TAB> domain domain ... <TAB> expiry, one line per certificate
_CERT_SCAN_SH='
for d in /etc/letsencrypt/live/*/; do
  [ -f "$d/fullchain.pem" ] || continue
  n=${d%/}; n=${n##*/}
  s=$(openssl x509 -noout -text -in "$d/fullchain.pem" 2>/dev/null \
      | grep -A1 "Subject Alternative Name" | tail -1 \
      | tr -d " " | tr "," "\n" | sed -n "s/^DNS://p" | tr "\n" " ")
  e=$(openssl x509 -noout -enddate -in "$d/fullchain.pem" 2>/dev/null | sed "s/notAfter=//")
  [ -n "$s" ] && printf "%s\t%s\t%s\n" "$n" "$s" "$e"
done
'

EPHEM_CERTS_TABLE=""
certs_refresh() {
    EPHEM_CERTS_TABLE="$(certbot_sh "$_CERT_SCAN_SH" 2>/dev/null | tr -d '\r' | grep -v '^[[:space:]]*$')"
}
certs_ready() { [ -n "$EPHEM_CERTS_TABLE" ] || certs_refresh; }

cert_lineages() {  # every certificate name on this server
    certs_ready
    printf '%s\n' "$EPHEM_CERTS_TABLE" | cut -f1 | grep .
}

cert_domains_of() {  # cert_domains_of LINEAGE → the names that certificate covers
    certs_ready
    printf '%s\n' "$EPHEM_CERTS_TABLE" | awk -F'\t' -v want="$1" '$1 == want { print $2; exit }' | xargs
}

cert_expiry_of() {  # cert_expiry_of LINEAGE → "Oct 27 20:08:45 2026 GMT"
    certs_ready
    printf '%s\n' "$EPHEM_CERTS_TABLE" | awk -F'\t' -v want="$1" '$1 == want { print $3; exit }'
}

lineage_exists() { cert_lineages | grep -qx "$1"; }

# Which certificate should serve this domain? Its own if it has one, otherwise
# the shared certificate that lists it (the pre-split layout).
lineage_for_domain() {  # lineage_for_domain DOMAIN → lineage name, or empty
    local d="$1" lin
    lineage_exists "$d" && { printf '%s' "$d"; return 0; }
    for lin in $(cert_lineages); do
        if printf '%s\n' "$(cert_domains_of "$lin")" | tr ' ' '\n' | grep -qx "$d"; then
            printf '%s' "$lin"; return 0
        fi
    done
    return 1
}

# Certificates that cover more than one domain — what split-certs.sh fixes.
shared_lineages() {
    local lin
    for lin in $(cert_lineages); do
        [ "$(cert_domains_of "$lin" | wc -w)" -gt 1 ] && echo "$lin"
    done
    return 0
}

issue_cert() {  # issue_cert DOMAIN EMAIL — one certificate, one name
    local d="$1" email="$2"
    certbot_cli certonly --webroot -w /var/www/certbot \
        -d "$d" --cert-name "$d" \
        --email "$email" --agree-tos --no-eff-email \
        --non-interactive --keep-until-expiring
}

# Re-issue an existing certificate with a smaller name list (used when a
# domain leaves a shared certificate). --renew-with-new-domains is what makes
# certbot accept a changed name list without asking.
reissue_cert() {  # reissue_cert LINEAGE EMAIL DOMAIN...
    local lin="$1" email="$2"; shift 2
    local args=() d out rc
    for d in "$@"; do args+=(-d "$d"); done
    out="$(certbot_cli certonly --webroot -w /var/www/certbot \
        "${args[@]}" --cert-name "$lin" \
        --email "$email" --agree-tos --no-eff-email \
        --non-interactive --force-renewal --renew-with-new-domains 2>&1)"; rc=$?
    # certbot older than that flag: the same run without it, where a changed
    # name list is accepted by default rather than confirmed.
    if [ $rc -ne 0 ] && printf '%s' "$out" | grep -qi "unrecognized arguments"; then
        out="$(certbot_cli certonly --webroot -w /var/www/certbot \
            "${args[@]}" --cert-name "$lin" \
            --email "$email" --agree-tos --no-eff-email \
            --non-interactive --force-renewal 2>&1)"; rc=$?
    fi
    printf '%s\n' "$out"
    return $rc
}

delete_cert() {  # delete_cert LINEAGE — removes the cert AND its renewal job
    certbot_cli delete --cert-name "$1" --non-interactive
}

# ── nginx config ──────────────────────────────

# Every domain nginx currently answers for on 443 (order preserved).
active_domains() {
    [ -f "$NGINX_ACTIVE" ] || return 0
    awk '
        /^[[:space:]]*#/            { next }
        /listen[[:space:]]+443/     { in443 = 1 }
        /^}/                        { in443 = 0 }
        in443 && /server_name/ {
            sub(/.*server_name[[:space:]]*/, ""); sub(/;.*/, "")
            n = split($0, a, /[[:space:]]+/)
            for (i = 1; i <= n; i++) if (a[i] != "" && a[i] != "_") print a[i]
        }' "$NGINX_ACTIVE" | awk '!seen[$0]++'
}

ssl_is_configured() {
    [ -f "$NGINX_ACTIVE" ] && grep -v '^[[:space:]]*#' "$NGINX_ACTIVE" | grep -q ssl_certificate
}

max_upload() {
    local v; v=$(grep "^NGINX_MAX_UPLOAD=" "$EPHEM_ROOT/.env" 2>/dev/null | cut -d'=' -f2- | xargs || true)
    # A unitless value is BYTES to nginx: NGINX_MAX_UPLOAD=300 would render
    # client_max_body_size 300; and every login RPC answers 413 "request too
    # large". Only a number plus M or G is accepted; anything else falls back.
    if ! printf '%s' "${v:-}" | grep -Eq '^[0-9]+[MmGg]$'; then
        [ -n "${v:-}" ] && printf 'nginx-lib: ignoring invalid NGINX_MAX_UPLOAD=%s (use e.g. 300M); using 100M
' "$v" >&2
        v=100M
    fi
    printf '%s' "$v"
}

ssl_email() {
    local v; v=$(grep "^SSL_EMAIL=" "$EPHEM_ROOT/.env" 2>/dev/null | cut -d'=' -f2- | xargs || true)
    printf '%s' "$v"
}

# ── RPC endpoints (/xmlrpc, /jsonrpc) ─────────
#
# They take a password straight from the request: no login page, no CSRF, no
# second factor, and the web client never uses them. So they are blocked at
# nginx unless NGINX_RPC_ALLOW in .env says otherwise:
#
#   (empty)                       deny all                    ← default
#   203.0.113.55 10.20.0.0/16     allow those, deny the rest  (space or comma separated)
#   all                           open to everyone
#
# Changed from: bash manage.sh → 11) Advanced → 4) RPC endpoints. Every
# entry ends up inside the nginx config, so only an address or a CIDR range
# gets through; anything else is refused loudly and left out.

valid_rpc_addr() {  # IPv4 (octets 0-255, /0-32) or IPv6 (/0-128), prefix optional
    local o='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
    printf '%s' "$1" | grep -Eq "^($o\.){3}$o(/([0-9]|[12][0-9]|3[0-2]))?\$" \
    || printf '%s' "$1" | grep -Eq '^([0-9A-Fa-f]{0,4}:){1,7}[0-9A-Fa-f]{0,4}(/([0-9]|[1-9][0-9]|1[01][0-9]|12[0-8]))?$'
}

rpc_allow() {  # → "" (blocked), "all", or the validated address list
    local raw a good=() bad=()
    raw=$(grep "^NGINX_RPC_ALLOW=" "$EPHEM_ROOT/.env" 2>/dev/null | cut -d'=' -f2- | tr ',' ' ' | xargs || true)
    [ -z "$raw" ] && return 0
    for a in $raw; do
        case "$a" in
            all|ALL) printf 'all'; return 0 ;;
        esac
        if valid_rpc_addr "$a"; then good+=("$a"); else bad+=("$a"); fi
    done
    [ ${#bad[@]} -gt 0 ] && printf 'nginx-lib: ignoring invalid NGINX_RPC_ALLOW entries: %s (not an IP address or CIDR range)\n' "${bad[*]}" >&2
    printf '%s' "${good[*]:-}"
}

rpc_state_text() {  # one line for menus and the security check
    local v; v="$(rpc_allow 2>/dev/null)"
    case "$v" in
        "")  printf 'blocked for everyone (default)' ;;
        all) printf 'OPEN to everyone' ;;
        *)   printf 'open to %s only' "$v" ;;
    esac
}

# Does the live config carry an RPC block at all? Configs rendered before the
# August 2026 hardening have none, and then nothing is blocked whatever .env
# says. Any re-render adds it.
rpc_block_present() {
    [ -f "$NGINX_ACTIVE" ] && grep -q '^[[:space:]]*location[[:space:]]*~[[:space:]]*\^/(xmlrpc|jsonrpc)' "$NGINX_ACTIVE"
}

# The location block itself, indented for a server { } body. The single
# source for the HTTPS renderer and the HTTP-only template alike.
_render_rpc_block() {
    local allow a
    allow="$(rpc_allow)"
    echo '    location ~ ^/(xmlrpc|jsonrpc) {'
    case "$allow" in
        "")
            echo '        # Blocked (NGINX_RPC_ALLOW is empty in .env)'
            echo '        deny all;'
            ;;
        all)
            echo '        # NGINX_RPC_ALLOW=all in .env: every address may call in'
            echo '        limit_req zone=ephem_limit burst=60 nodelay;'
            ;;
        *)
            echo '        # NGINX_RPC_ALLOW in .env: only these addresses may call in'
            for a in $allow; do echo "        allow $a;"; done
            echo '        deny all;'
            echo '        limit_req zone=ephem_limit burst=60 nodelay;'
            ;;
    esac
    echo '        proxy_pass http://odoo-backend;'
    echo '    }'
}

# Swap every RPC location block in FILE for the current one. Fails (1) when
# the file has none, so a caller never believes a setting was applied to a
# config that predates the block.
_apply_rpc_block() {  # _apply_rpc_block FILE
    local f="$1" block tmp
    grep -q '^[[:space:]]*location[[:space:]]*~[[:space:]]*\^/(xmlrpc|jsonrpc)' "$f" || return 1
    block="$(_render_rpc_block)"
    tmp="$(mktemp)"
    awk -v block="$block" '
        /^[[:space:]]*location[[:space:]]*~[[:space:]]*\^\/\(xmlrpc\|jsonrpc\)/ { print block; skip = 1; next }
        skip && /^[[:space:]]*}[[:space:]]*$/ { skip = 0; next }
        skip { next }
        { print }' "$f" > "$tmp" && mv "$tmp" "$f"
}

# One HTTPS server block. Everything domain-specific is the server_name and
# the two certificate paths; the rest is identical for every tenant.
_render_https_block() {  # _render_https_block DOMAIN LINEAGE MAX_UPLOAD
    local d="$1" lin="$2" max="$3"
    cat <<NGINXEOF

# ── $d ────────────────────────────────
server {
    listen 443 ssl;
    http2 on;
    server_name $d;
    server_tokens off;

    ssl_certificate     /etc/letsencrypt/live/$lin/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$lin/privkey.pem;
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

    client_max_body_size $max;
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

    # RPC endpoints: password auth with no login page and no CSRF — the
    # preferred credential-stuffing target. Odoo's own web client does not
    # use them, so blocking them does not affect normal browser use. Who may
    # call in is NGINX_RPC_ALLOW in .env (bash manage.sh → Advanced → RPC);
    # a hand edit here is lost on the next re-render.
$(_render_rpc_block)

    # Slow down repeated login attempts (POST-only zone above)
    location ~ ^/(web/login|web/session/authenticate) {
        limit_req zone=odoo_login burst=20 nodelay;
        proxy_redirect off;
        proxy_pass http://odoo-backend;
    }

    location /web/database/ {
        proxy_redirect off;
        proxy_pass http://odoo-backend;
        limit_req zone=ephem_db_mgr burst=10 nodelay;
    }

    location / {
        proxy_redirect off;
        proxy_pass http://odoo-backend;
        limit_req zone=ephem_limit burst=60 nodelay;
    }

    # \`expires\` (browser caching) does the work here. Odoo fingerprints its
    # asset URLs, so a shared proxy cache would add nothing but staleness.
    location ~* /web/static/ {
        proxy_buffering on;
        expires 864000;
        proxy_pass http://odoo-backend;
    }

    gzip on;
    gzip_types text/css text/less text/plain text/xml
               application/xml application/json application/javascript;
}
NGINXEOF
}

# Write nginx/active.conf from scratch for exactly these domains.
# Each domain is served by its own certificate when it has one; a domain
# still riding a shared certificate keeps using it. A domain with no
# certificate at all is skipped loudly — nginx refuses to start otherwise.
render_active_conf() {  # render_active_conf DOMAIN...
    local domains=("$@") max d lin rendered=0
    [ ${#domains[@]} -eq 0 ] && { echo -e "${RED}✗${NC} render_active_conf: no domains"; return 1; }
    max="$(max_upload)"

    local tmp; tmp="$(mktemp)"
    cat > "$tmp" <<NGINXEOF
# ──────────────────────────────────────────────
# GENERATED FILE — do not edit by hand.
# Written by scripts/ssl-setup.sh, add-domain.sh, remove-domain.sh,
# split-certs.sh and manage.sh (via scripts/nginx-lib.sh). Any manual change
# is lost the next time a domain is added or removed or a setting changes;
# the settings themselves live in .env (NGINX_MAX_UPLOAD, NGINX_RPC_ALLOW).
#
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# Domains:   ${domains[*]}
# ──────────────────────────────────────────────

# ── Rate Limiting ──────────────────────────────
# General zone: DoS mitigation only, sized for a real Odoo login (dozens of
# parallel images/RPCs; 10r/s burst 20 measurably 429'd half of them). The
# credential zones below stay strict, they are the actual protection.
limit_req_zone \$binary_remote_addr zone=ephem_limit:10m rate=30r/s;
limit_conn_zone \$binary_remote_addr zone=conn_limit:10m;
# The database manager is protected only by the Odoo master password — throttle
# it hard so the password can't be brute-forced. Normal use is a handful of
# requests; also set ODOO_LIST_DB=False in .env once your databases exist.
limit_req_zone \$binary_remote_addr zone=ephem_db_mgr:10m rate=10r/m;
# Throttle ONLY credential submissions (POST). Requests with an empty limit
# key are not counted, so GETs of the login page are never limited — which
# matters when a whole office shares one public address.
map \$request_method \$odoo_login_limit_key {
    default "";
    POST    \$binary_remote_addr;
}
limit_req_zone \$odoo_login_limit_key zone=odoo_login:10m rate=30r/m;
limit_req_status 429;

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

# ── HTTP → HTTPS, and the ACME challenge ──────
# default_server, so a domain being added answers the Let's Encrypt check
# before it has an HTTPS block of its own.
server {
    listen 80 default_server;
    server_name _;
    server_tokens off;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
NGINXEOF

    # Refuse to write a config that serves fewer domains than asked for. A
    # certificate this code cannot see (an unreadable volume, a certbot
    # output format it does not understand) would otherwise silently take
    # tenants offline — the failure that must never happen here.
    local missing=()
    for d in "${domains[@]}"; do
        lineage_for_domain "$d" >/dev/null || missing+=("$d")
    done
    if [ ${#missing[@]} -gt 0 ] && [ "${EPHEM_ALLOW_DROP:-0}" != "1" ]; then
        rm -f "$tmp"
        echo -e "  ${RED}✗${NC} No certificate found for: ${missing[*]}"
        echo -e "  ${RED}✗${NC} Nothing was changed — nginx keeps serving every domain it serves now."
        echo "     Certificates this server can see:"
        cert_lineages | sed 's/^/       • /' | grep . || echo "       (none — could the certbot container not start?)"
        echo "     Fix the certificate, or drop those domains deliberately with:"
        echo "       EPHEM_ALLOW_DROP=1 <the same command>"
        return 1
    fi

    for d in "${domains[@]}"; do
        if ! lin="$(lineage_for_domain "$d")"; then
            echo -e "  ${YELLOW}!${NC} $d has no certificate — dropped (EPHEM_ALLOW_DROP=1)"
            continue
        fi
        _render_https_block "$d" "$lin" "$max" >> "$tmp"
        rendered=$((rendered + 1))
    done

    if [ "$rendered" -eq 0 ]; then
        rm -f "$tmp"
        echo -e "  ${RED}✗${NC} No domain had a usable certificate — nginx config left untouched."
        return 1
    fi

    [ -f "$NGINX_ACTIVE" ] && cp "$NGINX_ACTIVE" "$NGINX_ACTIVE.bak"
    mv "$tmp" "$NGINX_ACTIVE"
    chmod 644 "$NGINX_ACTIVE"
    return 0
}

# Write nginx/active.conf for a server WITHOUT HTTPS: the template with the
# .env settings applied (upload limit, RPC access). A bare copy of the
# template would silently reset both. Used when the last domain is removed,
# when ssl-setup.sh has to fall back, and when a setting changes on an
# HTTP-only server.
render_http_only_conf() {
    local tmp max
    max="$(max_upload)"
    tmp="$(mktemp)"
    if ! sed "s|client_max_body_size[[:space:]]*[0-9]*[MmGg];|client_max_body_size ${max};|g" \
            "$NGINX_TEMPLATE" > "$tmp"; then
        rm -f "$tmp"
        echo -e "  ${RED}✗${NC} Could not read $NGINX_TEMPLATE"
        return 1
    fi
    if ! _apply_rpc_block "$tmp"; then
        rm -f "$tmp"
        echo -e "  ${RED}✗${NC} nginx/default.conf has no RPC block. Is the repo up to date? (git pull)"
        return 1
    fi
    [ -f "$NGINX_ACTIVE" ] && cp "$NGINX_ACTIVE" "$NGINX_ACTIVE.bak"
    mv "$tmp" "$NGINX_ACTIVE"
    chmod 644 "$NGINX_ACTIVE"
    return 0
}

# Re-render the live config as it is (same domains, or HTTP-only), picking
# up the current .env settings, then reload. What a settings change needs.
rerender_active_conf() {
    local domains=()
    if ssl_is_configured; then
        mapfile -t domains < <(active_domains)
        certs_refresh
        render_active_conf "${domains[@]}" || return 1
    else
        render_http_only_conf || return 1
    fi
    nginx_apply
}

nginx_state() {
    local cid; cid=$(dc ps -aq nginx 2>/dev/null | head -1)
    [ -z "$cid" ] && { echo absent; return; }
    case "$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null)" in
        running) echo running ;;
        "")      echo absent ;;
        *)       echo stopped ;;
    esac
}

# Test the new config and reload without dropping connections. On failure the
# previous config (.bak) goes back and nginx is reloaded again, so a bad
# render never takes the server down.
nginx_apply() {
    if [ "$(nginx_state)" != running ]; then
        dc up -d nginx >/dev/null 2>&1 || true
        sleep 3
        if [ "$(nginx_state)" = running ]; then
            echo -e "  ${GREEN}✓${NC} nginx started with the new config"
            return 0
        fi
        echo -e "  ${RED}✗${NC} nginx did not start — check: docker compose logs nginx"
        return 1
    fi

    if dc exec -T nginx nginx -t </dev/null >/dev/null 2>&1 && \
       dc exec -T nginx nginx -s reload </dev/null >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} nginx reloaded (no downtime)"
        return 0
    fi

    echo -e "  ${RED}✗${NC} nginx rejected the new config:"
    dc exec -T nginx nginx -t </dev/null 2>&1 | sed 's/^/     /'
    if [ -f "$NGINX_ACTIVE.bak" ]; then
        cp "$NGINX_ACTIVE.bak" "$NGINX_ACTIVE"
        dc exec -T nginx nginx -s reload </dev/null >/dev/null 2>&1 || dc restart nginx >/dev/null 2>&1
        echo -e "  ${YELLOW}!${NC} Rolled back to the previous config — the site is still up."
    fi
    return 1
}

# ── Domain checks ─────────────────────────────

valid_domain() {
    printf '%s' "$1" | grep -Eq '^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$'
}

server_ip() {
    hostname -I 2>/dev/null | awk '{print $1}' || ipconfig getifaddr en0 2>/dev/null || echo "127.0.0.1"
}

# 0 = points here, 1 = does not resolve, 2 = resolves elsewhere (prints the IP)
dns_check() {  # dns_check DOMAIN
    local d="$1" ip resolved
    ip="$(server_ip)"
    resolved=$(dig +short "$d" 2>/dev/null | grep -E '^[0-9.]+$' | head -1)
    [ -z "$resolved" ] && return 1
    [ "$resolved" = "$ip" ] && return 0
    printf '%s' "$resolved"
    return 2
}
