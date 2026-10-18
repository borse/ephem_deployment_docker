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
#   NGINX_MAX_UPLOAD   client_max_body_size                        (max_upload)
#   NGINX_RPC_ALLOW    who may call /xmlrpc, /jsonrpc, server-wide  (rpc_allow)
#   NGINX_RPC_OPEN     domains whose RPC is open to everyone        (rpc_open_domains)
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

# Domains, certificates and the nginx config mean nothing on a server where
# nginx does not run: Odoo reached directly on 8069 (SERVER_ACCESS=direct in
# .env), or behind an nginx on another machine (SERVER_ACCESS=proxy), where
# the domain and its certificate live. Starting nginx here would take ports
# 80 and 443. A script that works on nginx calls this first and stops when it
# fails.
nginx_in_use() {
    case "$(_env_val SERVER_ACCESS)" in
        direct)
            echo -e "\033[0;31m✗\033[0m This server runs without nginx: Odoo is reached directly on port 8069"
            echo "  (SERVER_ACCESS=direct in .env). Domains and SSL need nginx. To switch:"
            echo "    bash setup.sh   → 1) Server deploy → 2) nginx on ports 80/443"
            return 1 ;;
        proxy)
            echo -e "\033[0;31m✗\033[0m This server sits behind an nginx on another machine (SERVER_ACCESS=proxy"
            echo "  in .env): the domain and its certificate live there. The config that nginx"
            echo "  needs is $(proxy_conf_path "$(_env_val PROXY_DOMAIN)")."
            return 1 ;;
    esac
    return 0
}

# One .env value. `|| true`: a missing key must give "", not stop a set -e
# script (grep exits 1 on no match).
_env_val() { grep "^$1=" "$EPHEM_ROOT/.env" 2>/dev/null | cut -d'=' -f2- | xargs || true; }

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

# One grep, no pipeline. The old `grep -v | grep -q` raced under pipefail: on
# a config with a dozen domains the second grep quits at the first match, the
# first gets SIGPIPE writing the rest, and the pipeline reports "no HTTPS"
# a few percent of the time.
ssl_is_configured() {
    [ -f "$NGINX_ACTIVE" ] && grep -Eq '^[^#]*ssl_certificate' "$NGINX_ACTIVE"
}

# Membership test in plain bash. Not `printf | grep -q`: under pipefail a
# reader that quits early can fail the whole pipeline.
in_list() {  # in_list NEEDLE ITEM...
    local n="$1" x; shift
    for x in "$@"; do [ "$x" = "$n" ] && return 0; done
    return 1
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
# nginx unless .env says otherwise, at two levels:
#
#   NGINX_RPC_ALLOW   server-wide default, every domain
#     (empty)                       deny all                    ← default
#     203.0.113.55 10.20.0.0/16     allow those, deny the rest  (space or comma separated)
#     all                           open to everyone
#
#   NGINX_RPC_OPEN    domains whose RPC is open to everyone, whatever the
#                     default says (one server block per domain, so it can
#                     be decided per tenant; HTTP-only servers have one block
#                     for every hostname and only the default applies)
#     training.pheoc.com simex.pheoc.com
#
# Changed from: bash manage.sh → 11) Advanced → 4) RPC endpoints. Every
# entry ends up inside the nginx config, so only an address, a CIDR range or
# a domain name gets through; anything else is refused loudly and left out.

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

rpc_state_text() {  # the server-wide default, one line for menus and the security check
    local v; v="$(rpc_allow 2>/dev/null)"
    case "$v" in
        "")  printf 'blocked for everyone (default)' ;;
        all) printf 'OPEN to everyone' ;;
        *)   printf 'open to %s only' "$v" ;;
    esac
}

rpc_open_domains() {  # → the validated domain list from NGINX_RPC_OPEN
    local raw d good=() bad=()
    raw=$(grep "^NGINX_RPC_OPEN=" "$EPHEM_ROOT/.env" 2>/dev/null | cut -d'=' -f2- | tr ',' ' ' | xargs || true)
    [ -z "$raw" ] && return 0
    for d in $raw; do
        if valid_domain "$d"; then
            in_list "$d" "${good[@]:-}" || good+=("$d")
        else
            bad+=("$d")
        fi
    done
    [ ${#bad[@]} -gt 0 ] && printf 'nginx-lib: ignoring invalid NGINX_RPC_OPEN entries: %s (not a domain name)\n' "${bad[*]}" >&2
    printf '%s' "${good[*]:-}"
}

rpc_domain_open() {  # rpc_domain_open DOMAIN → 0 when its RPC is open per domain
    local d; for d in $(rpc_open_domains 2>/dev/null); do [ "$d" = "$1" ] && return 0; done
    return 1
}

rpc_domain_state() {  # rpc_domain_state DOMAIN → one line
    if rpc_domain_open "$1"; then printf 'OPEN to everyone (NGINX_RPC_OPEN)'; else rpc_state_text; fi
}

# Update or append KEY=VALUE in .env without sed -i, so it also works where
# sed wants -i ''. The file is rewritten in place to keep its permissions.
env_write_key() {  # env_write_key KEY VALUE
    local f="$EPHEM_ROOT/.env" tmp
    [ -f "$f" ] || return 1
    tmp="$(mktemp)"
    awk -v k="$1" -v v="$2" '
        index($0, k "=") == 1 { print k "=" v; done = 1; next }
        { print }
        END { if (!done) print k "=" v }' "$f" > "$tmp" && cat "$tmp" > "$f"
    rm -f "$tmp"
}

# Take domains out of NGINX_RPC_OPEN (remove-domain.sh calls this): a domain
# that is added back later must not return with its RPC silently open.
# Returns 0 when the list changed, 1 when there was nothing to drop.
rpc_forget_domains() {  # rpc_forget_domains DOMAIN...
    local d keep=() dropped=0
    for d in $(rpc_open_domains 2>/dev/null); do
        if in_list "$d" "$@"; then dropped=1; else keep+=("$d"); fi
    done
    [ "$dropped" -eq 1 ] || return 1
    env_write_key NGINX_RPC_OPEN "${keep[*]:-}"
}

# Does the live config carry an RPC block at all? Configs rendered before the
# August 2026 hardening have none, and then nothing is blocked whatever .env
# says. Any re-render adds it.
rpc_block_present() {
    [ -f "$NGINX_ACTIVE" ] && grep -q '^[[:space:]]*location[[:space:]]*~[[:space:]]*\^/(xmlrpc|jsonrpc)' "$NGINX_ACTIVE"
}

# The location block itself, indented for a server { } body. The single
# source for the HTTPS renderer (one call per domain), the HTTP-only template
# (no domain: the server-wide default alone) and the proxy mode config, whose
# upstream and rate limit zone carry names of their own.
_render_rpc_block() {  # _render_rpc_block [DOMAIN [UPSTREAM [ZONE]]]
    local d="${1:-}" up="${2:-odoo-backend}" zone="${3:-ephem_limit}" allow a
    echo '    location ~ ^/(xmlrpc|jsonrpc) {'
    if [ -n "$d" ] && rpc_domain_open "$d"; then
        echo "        # $d is listed in NGINX_RPC_OPEN (.env): every address may call in"
        echo "        limit_req zone=$zone burst=60 nodelay;"
        echo "        proxy_pass http://$up;"
        echo '    }'
        return 0
    fi
    allow="$(rpc_allow)"
    case "$allow" in
        "")
            echo '        # Blocked (NGINX_RPC_ALLOW is empty in .env)'
            echo '        deny all;'
            ;;
        all)
            echo '        # NGINX_RPC_ALLOW=all in .env: every address may call in'
            echo "        limit_req zone=$zone burst=60 nodelay;"
            ;;
        *)
            echo '        # NGINX_RPC_ALLOW in .env: only these addresses may call in'
            for a in $allow; do echo "        allow $a;"; done
            echo '        deny all;'
            echo "        limit_req zone=$zone burst=60 nodelay;"
            ;;
    esac
    echo "        proxy_pass http://$up;"
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
    # Protocols, ciphers and sessions are set once for every server above.

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;
    add_header Content-Security-Policy \$ephem_csp always;
    add_header Permissions-Policy "geolocation=(self), camera=(self), microphone=(self), payment=(), usb=()" always;
    add_header X-Permitted-Cross-Domain-Policies none always;
    # Odoo sends these two itself on some answers, with the same values; one
    # copy only, the one above, so no scanner reports a duplicate header.
    proxy_hide_header X-Content-Type-Options;
    proxy_hide_header X-Frame-Options;

    # The login session is never sent over plain HTTP and never readable by a
    # script, whatever Odoo itself decides. Only this cookie: the web client
    # reads the others (cids, tz, color_scheme).
    proxy_cookie_flags session_id secure httponly;

    proxy_set_header X-Forwarded-Host  \$host;
    proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Real-IP         \$remote_addr;

    client_max_body_size $max;
    # A client that stalls on the request headers, or stops sending a body,
    # is dropped (slowloris). Odoo's own slow work is the proxy_* timeouts.
    client_header_timeout 15s;
    client_body_timeout 60s;
    keepalive_timeout 30s;
    reset_timedout_connection on;
    proxy_read_timeout 720s;
    # Odoo is next door: a connection that is not made in seconds will not
    # be made (nginx stops at 75 s whatever is asked), so fail fast.
    proxy_connect_timeout 10s;
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
    # call in is decided in .env, per domain (NGINX_RPC_OPEN) or server-wide
    # (NGINX_RPC_ALLOW), from bash manage.sh → Advanced → RPC endpoints;
    # a hand edit here is lost on the next re-render.
$(_render_rpc_block "$d")

    # Slow down repeated login attempts (POST-only zone above). Password
    # reset and sign-up are the same kind of target (guessing, and mailing
    # strangers); /web/login also covers /web/login/totp, the 2FA code.
    location ~ ^/(web/login|web/session/authenticate|web/reset_password|web/signup) {
        limit_req zone=odoo_login burst=20 nodelay;
        proxy_redirect off;
        proxy_pass http://odoo-backend;
    }

    # ^~ so no regex location below can take a URL under it.
    location ^~ /web/database/ {
        proxy_redirect off;
        proxy_pass http://odoo-backend;
        limit_req zone=ephem_db_mgr burst=10 nodelay;
    }

    location / {
        proxy_redirect off;
        proxy_pass http://odoo-backend;
        limit_req zone=ephem_limit burst=60 nodelay;
    }

    # Asset bundles and every module's static files (/<module>/static/...):
    # the same for every visitor. The browser keeps them as long as Odoo says
    # (a year for the bundles, whose URL changes with their content, a week
    # for the rest). They stay out of the general rate limit, so the burst of
    # files of a first visit never meets a 429 when an office shares one
    # address.
    location ^~ /web/assets/ {
        proxy_pass http://odoo-backend;
    }
    location ~ ^/[^/]+/static/ {
        proxy_pass http://odoo-backend;
    }

    # The local basemap, when this server downloaded one (bash manage.sh:
    # Local basemap). The maps read the .pmtiles file in byte ranges, dozens
    # per view, so nginx serves it from disk instead of passing each range to
    # an Odoo worker. It is an OpenStreetMap extract, public data, so it needs
    # no login. \`expires\` rather than add_header, which would drop the
    # server level security headers in this location.
    location ^~ /ephem/basemap/ {
        alias /srv/basemaps/;
        default_type application/octet-stream;
        expires 1d;
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
# the settings themselves live in .env (NGINX_MAX_UPLOAD, NGINX_RPC_ALLOW,
# NGINX_RPC_OPEN).
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

# Odoo sends its own Content-Security-Policy on pages (frame-ancestors) and on
# files (default-src 'none', which stops an uploaded HTML or SVG file from
# running scripts). Ours goes only on answers that carry none, so there is one
# policy per answer and Odoo's file policy is never replaced. An empty value
# adds no header.
map \$upstream_http_content_security_policy \$ephem_csp {
    ""      "frame-ancestors 'self'";
    default "";
}

# ── TLS, for every HTTPS server below ─────────
# One place, in the http context, so the catch-all server and each domain
# negotiate alike (a connection is set up before nginx knows which server
# it is for). TLS 1.2 with forward secrecy and AEAD ciphers only; TLS 1.3
# uses its own fixed suites. The client picks among them (Mozilla
# "intermediate"), which is why prefer_server_ciphers is off.
ssl_protocols TLSv1.2 TLSv1.3;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
ssl_prefer_server_ciphers off;
ssl_ecdh_curve X25519:prime256v1:secp384r1;
ssl_session_cache shared:SSL:10m;
ssl_session_timeout 1d;
ssl_session_tickets off;

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

# ── Anything on 443 that is not one of our domains ──
# Without this, the first domain below answers for every name and for the
# bare IP address: it hands its certificate (and so the tenant's name) to
# any scanner, and passes a forged Host header on to Odoo. A handshake for an
# unknown name is refused outright; a request whose Host does not match
# the name it connected with (the handshake already done for a real domain)
# gets no answer at all.
server {
    listen 443 ssl default_server;
    server_name _;
    server_tokens off;
    ssl_reject_handshake on;
    return 444;
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

    _install_active_conf "$tmp"
}

# Put a rendered file in place of nginx/active.conf, keeping the .bak that
# nginx_apply rolls back to. Written INTO the existing file (cp), never
# renamed over it (mv): docker mounts a single file by inode, so a container
# started on the old inode keeps reading it after a rename, and `nginx -s
# reload` would then test and load the previous config. That is why an
# earlier version needed a container restart before a change showed.
_install_active_conf() {  # _install_active_conf TMPFILE
    [ -f "$NGINX_ACTIVE" ] && cp "$NGINX_ACTIVE" "$NGINX_ACTIVE.bak"
    cp "$1" "$NGINX_ACTIVE" && rm -f "$1"
    chmod 644 "$NGINX_ACTIVE"
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
    _install_active_conf "$tmp"
}

# Re-render the live config as it is (same domains, or HTTP-only), picking
# up the current .env settings, then reload. What a settings change needs.
#
# Two independent signs of HTTPS are checked: an ssl_certificate line, and
# any 443 server block with names. Either one selects the HTTPS renderer.
# The HTTP-only template is written only over a config that shows neither,
# because writing it over an HTTPS config would take every tenant off HTTPS.
rerender_active_conf() {
    local domains=()
    mapfile -t domains < <(active_domains)
    if ssl_is_configured || [ ${#domains[@]} -gt 0 ]; then
        if [ ${#domains[@]} -eq 0 ]; then
            echo -e "  ${RED}✗${NC} The HTTPS config lists no domains; nothing was re-rendered."
            return 1
        fi
        certs_refresh
        render_active_conf "${domains[@]}" || return 1
    else
        render_http_only_conf || return 1
    fi
    nginx_apply
}

# ── Proxy mode: the config for the nginx on the other machine ──
#
# SERVER_ACCESS=proxy: this server runs Odoo only, and an nginx on another
# machine (often a ministry's edge proxy, run by someone else) holds the
# domain and its certificate. That nginx is not ours to change, so this
# writes the config it needs into nginx/proxy/DOMAIN.conf, to copy there.
# It carries the protections of the nginx this stack runs itself, from the
# same .env settings (NGINX_MAX_UPLOAD, NGINX_RPC_ALLOW, NGINX_RPC_OPEN), and
# closes the database manager outright: databases are managed from manage.sh
# on this server.
#
# What differs from active.conf, and why:
#   names    that nginx serves other sites too, so every zone, upstream, map,
#            cache and log format carries a prefix made from the domain
#   headers  Host is the domain, and X-Forwarded-For is set to the client's
#            address rather than appended to: that nginx is the edge, nothing
#            a client writes into the header counts
#   cookies  Secure is added with proxy_cookie_path, which every nginx
#            version knows (proxy_cookie_flags needs 1.19.3, and Ubuntu 20.04
#            ships 1.18)
#   cache    the asset bundles and module static files are kept at the proxy:
#            across a network, every file of a first visit would otherwise
#            cross to Odoo again. Never /web/image or /web/content, which
#            answer under access rules
#   http2    the `listen ... http2` form, which every version still in use
#            accepts (1.25.1 and later only warn)
#
# PROXY_DOMAIN names the site and PROXY_BIND_HOST is the address of this
# server where Odoo answers it (8069 web, 8072 live updates), both in .env.

proxy_conf_path() {  # proxy_conf_path DOMAIN
    printf '%s/nginx/proxy/%s.conf' "$EPHEM_ROOT" "$1"
}

valid_ipv4() {  # a single IPv4 address, no prefix
    local o='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])'
    printf '%s' "$1" | grep -Eq "^($o\.){3}$o\$"
}

# Writes nginx/proxy/$PROXY_DOMAIN.conf from .env. Refuses (1), writing
# nothing, when the domain or the address is missing or malformed: both end
# up inside the config.
render_proxy_conf() {
    local d bind max p rpc f tmp
    d="$(_env_val PROXY_DOMAIN)"; bind="$(_env_val PROXY_BIND_HOST)"
    if ! valid_domain "$d"; then
        echo -e "  ${RED}✗${NC} PROXY_DOMAIN in .env is '${d}': the domain the proxy serves is needed (e.g. ephem.health.gov.xx)."
        return 1
    fi
    if ! valid_ipv4 "$bind" || [ "$bind" = 0.0.0.0 ]; then
        echo -e "  ${RED}✗${NC} PROXY_BIND_HOST in .env is '${bind}': the IPv4 address of this server the proxy connects to is needed."
        return 1
    fi
    max="$(max_upload)"
    p="ephem_$(printf '%s' "$d" | tr -c 'A-Za-z0-9' '_')"
    rpc="$(_render_rpc_block "$d" "${p}_odoo" "${p}_general")"
    f="$(proxy_conf_path "$d")"
    mkdir -p "$(dirname "$f")"
    tmp="$(mktemp)"
    # The values are checked above and hold no sed or awk metacharacter that
    # matters here (letters, digits, dots, hyphens, a size like 100M).
    _proxy_conf_template \
        | sed -e "s|@D@|$d|g" -e "s|@P@|$p|g" -e "s|@BIND@|$bind|g" -e "s|@MAX@|$max|g" \
              -e "s|@DATE@|$(date '+%Y-%m-%d %H:%M')|g" \
        | awk -v block="$rpc" '$0 == "@RPC@" { print block; next } { print }' > "$tmp"
    cp "$tmp" "$f" && rm -f "$tmp"
    chmod 644 "$f"
}

# The config with @placeholders@, in a quoted heredoc so that every nginx
# $variable stays as written (no backslash before each one).
_proxy_conf_template() {
    cat <<'PROXYEOF'
# ──────────────────────────────────────────────
# @D@: the nginx on the proxy machine, in front of ePHEM (Odoo 18) on
# @BIND@ (ephem-deploy, SERVER_ACCESS=proxy).
#
# GENERATED by ephem-deploy on the Odoo server, @DATE@. Its settings live in
# that server's .env (PROXY_DOMAIN, PROXY_BIND_HOST, NGINX_MAX_UPLOAD,
# NGINX_RPC_ALLOW, NGINX_RPC_OPEN) and bash manage.sh rewrites this file when
# one changes. Edit there and copy the file again; a hand edit here is lost.
#
# Install on the proxy machine:
#   sudo nginx -v           (1.25.1 or newer: see the note on listen below)
#   sudo cp @D@.conf /etc/nginx/sites-available/@D@
#   sudo ln -sf /etc/nginx/sites-available/@D@ /etc/nginx/sites-enabled/@D@
#   sudo mkdir -p /var/cache/nginx/@P@ && sudo chown www-data: /var/cache/nginx/@P@
#   sudo nginx -t && sudo systemctl reload nginx
# Keep a copy of the file it replaces outside /etc/nginx, where no include
# picks it up. The certificate is expected where certbot puts it
# (/etc/letsencrypt/live/@D@/); change the two ssl_certificate lines if this
# machine keeps it elsewhere. After the first install: sudo certbot renew --dry-run
#
# Everything above the first server block sits in nginx's http context,
# shared with every other site on that nginx, so every name starts with @P@.
# Never add an add_header inside a location below: nginx then drops every
# security header of the server block for that location.
# ──────────────────────────────────────────────

# Timing in the access log: urt = the time Odoo took, rt = the whole request.
# A slow page with a small urt is the network or the browser, a large urt is
# Odoo. ucs = HIT or MISS of the static cache below.
log_format @P@_timing '$remote_addr [$time_local] "$request" $status $body_bytes_sent '
                      'rt=$request_time urt=$upstream_response_time ucs=$upstream_cache_status '
                      '"$http_referer" "$http_user_agent"';

# ── Rate limiting ─────────────────────────────
# General zone: protection against floods only. One Odoo screen fires dozens
# of requests at once, so it is generous; the login zone is the real
# protection. Both count per client address: if every user reaches this
# nginx through one NAT address, they count as one.
limit_req_zone $binary_remote_addr zone=@P@_general:10m rate=30r/s;
# Only credential submissions (POST) count. GETs of the login page never do,
# which matters when a whole office shares one public address.
map $request_method $@P@_login_key {
    default "";
    POST    $binary_remote_addr;
}
limit_req_zone $@P@_login_key zone=@P@_login:10m rate=30r/m;

# ── Odoo ──────────────────────────────────────
# No upstream keepalive on purpose: Odoo's web workers close the connection
# after every answer, so a pool would never fill.
upstream @P@_odoo {
    server @BIND@:8069;
}
# The live update websocket (Odoo's gevent_port, served when workers > 0).
upstream @P@_odoo_ws {
    server @BIND@:8072;
}

map $http_upgrade $@P@_connection_upgrade {
    default upgrade;
    ''      close;
}

# Odoo sends its own Content-Security-Policy on pages (frame-ancestors) and on
# files (default-src 'none', which stops an uploaded HTML or SVG file from
# running scripts). Ours goes only on answers that carry none, so there is one
# policy per answer and Odoo's file policy is never replaced. An empty value
# adds no header.
map $upstream_http_content_security_policy $@P@_csp {
    ""      "frame-ancestors 'self'";
    default "";
}

# Copies of the asset bundles and module static files only (see below).
proxy_cache_path /var/cache/nginx/@P@ levels=1:2 keys_zone=@P@_static:10m
                 max_size=1g inactive=7d use_temp_path=off;

# ── HTTP: redirect only ───────────────────────
server {
    listen 80;
    listen [::]:80;
    server_name @D@;
    server_tokens off;

    return 301 https://@D@$request_uri;
}

# ── HTTPS ─────────────────────────────────────
server {
    # nginx 1.25.1 or newer: write `listen 443 ssl;` and add `http2 on;` (the
    # form below still works there, nginx -t only warns).
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name @D@;
    server_tokens off;

    ssl_certificate /etc/letsencrypt/live/@D@/fullchain.pem; # managed by Certbot
    ssl_certificate_key /etc/letsencrypt/live/@D@/privkey.pem; # managed by Certbot

    # Mozilla "intermediate": TLS 1.2 with forward secrecy and AEAD ciphers
    # only, TLS 1.3 with its own fixed suites; the client picks among them.
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    # A resumed TLS session skips most of the handshake: one round trip less
    # per reconnect, which counts on slow links.
    ssl_session_cache shared:@P@_ssl:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    # ── Security headers ──────────────────────
    # HSTS: browsers never try plain HTTP again for a year, so the session
    # cookie and the tokens in emailed links cannot leak on a first hop over
    # port 80. includeSubDomains left out: names under this one are not ours
    # to promise.
    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;
    add_header Content-Security-Policy $@P@_csp always;
    add_header Permissions-Policy "geolocation=(self), camera=(self), microphone=(self), payment=(), usb=()" always;
    add_header X-Permitted-Cross-Domain-Policies none always;
    # Odoo sends these two itself on some answers, with the same values; one
    # copy only, the one above, so no scanner reports a duplicate header.
    proxy_hide_header X-Content-Type-Options;
    proxy_hide_header X-Frame-Options;
    # Odoo 18 never marks its cookies Secure (session_id is already
    # HttpOnly). This adds Secure to every cookie it sets on path /, which is
    # all of them.
    proxy_cookie_path / "/; Secure";

    # ── To Odoo ───────────────────────────────
    # X-Forwarded-Host is what makes Odoo apply proxy_mode: without it Odoo
    # ignores every X-Forwarded header, sees all users as this nginx's address
    # and believes the site is plain HTTP.
    proxy_set_header Host              $host;
    proxy_set_header X-Forwarded-Host  $host;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header X-Forwarded-For   $remote_addr;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_redirect off;

    # nginx takes the whole answer quickly and feeds it to a slow client
    # itself, so an Odoo worker is free in milliseconds instead of waiting on
    # a phone on 3G. Bigger buffers keep large JSON answers in memory.
    proxy_buffering on;
    proxy_buffers 16 64k;
    proxy_buffer_size 16k;

    client_max_body_size @MAX@;
    # A client that stalls on its headers or stops sending a body is dropped
    # (slowloris). Odoo's own slow work (reports, imports) is the proxy_*
    # timeouts.
    client_header_timeout 15s;
    client_body_timeout 60s;
    send_timeout 60s;
    keepalive_timeout 75s;
    reset_timedout_connection on;
    # Fail fast when Odoo is not there; wait long when it is busy working.
    proxy_connect_timeout 10s;
    proxy_send_timeout 720s;
    proxy_read_timeout 720s;

    limit_req_status 429;

    access_log /var/log/nginx/@D@.access.log @P@_timing;
    error_log  /var/log/nginx/@D@.error.log warn;

    gzip on;
    gzip_comp_level 5;
    gzip_min_length 1024;
    gzip_proxied any;
    gzip_vary on;
    gzip_types text/plain text/css text/xml text/javascript
               application/javascript application/json application/xml image/svg+xml;

    # ── Live updates (bus, chat, notifications) ──
    # A location with its own proxy_set_header inherits none of the server
    # ones, so they are all repeated here.
    location /websocket {
        proxy_pass http://@P@_odoo_ws;
        proxy_http_version 1.1;
        proxy_set_header Upgrade           $http_upgrade;
        proxy_set_header Connection        $@P@_connection_upgrade;
        proxy_set_header Host              $host;
        proxy_set_header X-Forwarded-Host  $host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-For   $remote_addr;
        proxy_set_header X-Real-IP         $remote_addr;
    }

    # ── RPC endpoints ─────────────────────────
    # Password login with no login page and no CSRF token: the favourite
    # target of credential stuffing. The Odoo web client never uses them.
    # Opened per address from manage.sh on the Odoo server (Advanced → RPC
    # endpoints), which rewrites this file.
@RPC@

    # ── Database manager: closed ──────────────
    # Create, drop, back up (the whole database with its files) and restore,
    # guarded only by the master password. From the internet it has no use:
    # manage.sh on the Odoo server does all of this (Advanced → Databases).
    # ^~ so no regex location below can take a URL under it.
    location ^~ /web/database/ {
        deny all;
        proxy_pass http://@P@_odoo;
    }

    # Lists installed apps and versions when the website app is installed.
    location = /website/info {
        return 404;
    }

    # ── Credential submissions: throttled ─────
    # Password reset and sign up are the same kind of target (guessing, and
    # mailing strangers); /web/login also covers /web/login/totp, the 2FA code.
    location ~ ^/(web/login|web/session/authenticate|web/reset_password|web/signup) {
        limit_req zone=@P@_login burst=20 nodelay;
        proxy_pass http://@P@_odoo;
    }

    # ── Static files: cached here ─────────────
    # Only files that are the same for every visitor. /web/image and
    # /web/content are not cached: they carry attachments and record images
    # under access rules, and an anonymous request for the same URL gets a
    # placeholder or a 404 that a shared cache would then hand to logged in
    # users. A response that sets a cookie is never stored either (nginx's
    # own rule), so a visitor without a session never seeds the cache.
    #
    # Asset bundles: the URL holds a hash of the content, so a copy is kept as
    # long as Odoo says (a year, immutable) and is never stale. Odoo's own
    # headers decide, so debug bundles (max-age=0) are never stored.
    location ^~ /web/assets/ {
        proxy_pass http://@P@_odoo;
        proxy_cache @P@_static;
        proxy_cache_valid 200 1d;
        proxy_cache_lock on;
        proxy_cache_use_stale error timeout updating http_502 http_503 http_504;
    }

    # Module static files (/<module>/static/...): public by design, but not
    # hashed, so a module update can change a file under the same name. This
    # copy lasts an hour; the browser still gets Odoo's own headers (a week).
    location ~ ^/[^/]+/static/ {
        proxy_pass http://@P@_odoo;
        proxy_cache @P@_static;
        proxy_ignore_headers Cache-Control Expires;
        proxy_cache_valid 200 60m;
        proxy_cache_lock on;
        proxy_cache_use_stale error timeout updating http_502 http_503 http_504;
    }

    # ── Everything else ───────────────────────
    location / {
        limit_req zone=@P@_general burst=60 nodelay;
        proxy_pass http://@P@_odoo;
    }
}
PROXYEOF
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

# Does the running container read the same bytes that are on the host? See
# _install_active_conf: after a rename (mv, sed -i, most editors) it does
# not, and a reload would silently apply the previous file.
nginx_sees_host_conf() {
    local inside host
    inside=$(dc exec -T nginx md5sum /etc/nginx/conf.d/default.conf </dev/null 2>/dev/null | tr -d '\r' | cut -d' ' -f1)
    host=$(md5sum "$NGINX_ACTIVE" 2>/dev/null | cut -d' ' -f1)
    [ -n "$inside" ] && [ "$inside" = "$host" ]
}

# Test the new config in a throwaway container that mounts the host file
# fresh, for the case where the running one cannot see it.
nginx_test_fresh() {
    dc run --rm --no-deps -T --entrypoint nginx nginx -t </dev/null 2>&1
}

# Test the new config and reload without dropping connections. On failure the
# previous config (.bak) goes back and nginx is reloaded again, so a bad
# render never takes the server down. When the running container still reads
# an older inode of the file, a reload cannot pick the change up: the config
# is tested in a fresh container and nginx is restarted instead (about a
# second of downtime, said so on screen).
nginx_apply() {
    local out
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

    if nginx_sees_host_conf; then
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
    fi

    echo -e "  ${YELLOW}!${NC} The running nginx still reads an older copy of active.conf (the file"
    echo "     was replaced rather than rewritten), so a reload would not see the change."
    if out="$(nginx_test_fresh)"; then
        echo -e "  ${CYAN}→${NC} docker compose restart nginx"
        dc restart nginx >/dev/null 2>&1
        sleep 2
        if [ "$(nginx_state)" = running ] && nginx_sees_host_conf; then
            echo -e "  ${GREEN}✓${NC} nginx restarted with the new config (about a second of downtime)"
            return 0
        fi
        echo -e "  ${RED}✗${NC} nginx did not come back with the new config, check: docker compose logs nginx"
        return 1
    fi
    echo -e "  ${RED}✗${NC} nginx rejected the new config:"
    printf '%s\n' "$out" | sed 's/^/     /'
    if [ -f "$NGINX_ACTIVE.bak" ]; then
        cp "$NGINX_ACTIVE.bak" "$NGINX_ACTIVE"
        echo -e "  ${YELLOW}!${NC} Rolled back to the previous config; nginx never loaded the bad one."
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
