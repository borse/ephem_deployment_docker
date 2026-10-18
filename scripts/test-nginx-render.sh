#!/bin/bash
# ──────────────────────────────────────────────
# ePHEM — nginx-lib.sh render check (developer machine, not the server)
#
# Renders nginx/active.conf the way the tools do, for every NGINX_RPC_ALLOW
# state, HTTP-only and HTTPS alike, and asks the real nginx image whether
# the result is valid (nginx -t). Also checks the address validator.
# Nothing on this machine is touched: a throwaway directory stands in for
# the repo root and self-signed certificates stand in for Let's Encrypt.
#
# Needs: docker (nginx:alpine is pulled if missing), openssl.
# Usage: bash scripts/test-nginx-render.sh
# ──────────────────────────────────────────────
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/nginx" "$T/out" "$T/le/live/a.example.org" "$T/le/live/b.example.org"
cp "$REPO/nginx/default.conf" "$T/nginx/default.conf"
for d in a.example.org b.example.org; do
    openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=$d" \
        -keyout "$T/le/live/$d/privkey.pem" -out "$T/le/live/$d/fullchain.pem" >/dev/null 2>&1
done
chmod -R a+rX "$T/le"

export EPHEM_ROOT="$T"
# shellcheck source=nginx-lib.sh
source "$REPO/scripts/nginx-lib.sh"
# No certbot container here: pretend both domains have their own certificate.
certs_refresh() { EPHEM_CERTS_TABLE=$'a.example.org\ta.example.org\tx\nb.example.org\tb.example.org\tx'; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  \033[0;32m✓\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[0;31m✗\033[0m %s\n' "$1"; }

echo "Address validator"
for a in 203.0.113.55 0.0.0.0/0 10.20.0.0/16 1.2.3.4/32 ::1 2001:db8::1/64 2001:db8::/128 fe80::; do
    valid_rpc_addr "$a" && ok "accepts $a" || bad "rejects $a"
done
for a in 1.2.3.4/33 256.1.1.1 1.2.3 01.2.3.4 2001:db8::/129 "1.2.3.4;" deny all "" "10.0.0.1 10.0.0.2"; do
    valid_rpc_addr "$a" && bad "accepts '$a'" || ok "rejects '$a'"
done

nginx_t() {  # nginx_t FILE
    docker run --rm --add-host odoo:127.0.0.1 \
        -v "$1:/etc/nginx/conf.d/default.conf:ro" -v "$T/le:/etc/letsencrypt:ro" \
        nginx:alpine nginx -t 2>&1
}

echo; echo "Rendered configs"
block_of() {  # block_of FILE DOMAIN|"" → allow/deny lines of that server block's RPC location
    awk -v d="$2" '
        /^server[[:space:]]*\{/ { hit = (d == "") }
        d != "" && $0 ~ ("server_name[[:space:]]+" d ";") { hit = 1 }
        hit && /location ~ \^\/\(xmlrpc\|jsonrpc\)/ { inb = 1 }
        inb { print }
        inb && /^    }/ { exit }' "$1" | grep -E '^\s*(allow|deny)' | xargs
}
run_case() {  # run_case LABEL ALLOW OPEN WANT_HTTP WANT_A WANT_B
    local label="$1" allow="$2" open="$3" want_http="$4" want_a="$5" want_b="$6" f got n
    printf 'NGINX_MAX_UPLOAD=250M\nNGINX_RPC_ALLOW=%s\nNGINX_RPC_OPEN=%s\n' "$allow" "$open" > "$T/.env"
    # HTTP-only: one block, the server-wide default only
    if render_http_only_conf >/dev/null; then
        f="$T/out/http_${label}.conf"; cp "$NGINX_ACTIVE" "$f"
        n="$(grep -c 'location ~ ^/(xmlrpc|jsonrpc)' "$f")"
        [ "$n" -eq 1 ] && ok "$label / http: 1 RPC block" || bad "$label / http: $n RPC blocks"
        got="$(block_of "$f" "")"
        [ "$got" = "$want_http" ] && ok "$label / http: '$want_http'" || bad "$label / http: '$got', wanted '$want_http'"
        grep -q 'client_max_body_size 250M;' "$f" && ok "$label / http: upload limit kept" || bad "$label / http: upload limit lost"
        out="$(nginx_t "$f")" && ok "$label / http: nginx -t" || { bad "$label / http: nginx -t"; printf '%s\n' "$out" | sed 's/^/      /'; }
    else bad "$label / http: render failed"; fi
    # HTTPS: one block per domain, each decided on its own
    if render_active_conf a.example.org b.example.org >/dev/null; then
        f="$T/out/https_${label}.conf"; cp "$NGINX_ACTIVE" "$f"
        n="$(grep -c 'location ~ ^/(xmlrpc|jsonrpc)' "$f")"
        [ "$n" -eq 2 ] && ok "$label / https: 2 RPC blocks" || bad "$label / https: $n RPC blocks"
        got="$(block_of "$f" a.example.org)"
        [ "$got" = "$want_a" ] && ok "$label / https a: '$want_a'" || bad "$label / https a: '$got', wanted '$want_a'"
        got="$(block_of "$f" b.example.org)"
        [ "$got" = "$want_b" ] && ok "$label / https b: '$want_b'" || bad "$label / https b: '$got', wanted '$want_b'"
        grep -q 'client_max_body_size 250M;' "$f" && ok "$label / https: upload limit kept" || bad "$label / https: upload limit lost"
        out="$(nginx_t "$f")" && ok "$label / https: nginx -t" || { bad "$label / https: nginx -t"; printf '%s\n' "$out" | sed 's/^/      /'; }
    else bad "$label / https: render failed"; fi
}
#        label       ALLOW                                       OPEN                             http           a (open?)      b
run_case blocked     ""                                          ""                               "deny all;"    "deny all;"    "deny all;"
run_case allowlist   "203.0.113.55, 10.20.0.0/16 2001:db8::/32"  ""                               "allow 203.0.113.55; allow 10.20.0.0/16; allow 2001:db8::/32; deny all;" \
                                                                                                  "allow 203.0.113.55; allow 10.20.0.0/16; allow 2001:db8::/32; deny all;" \
                                                                                                  "allow 203.0.113.55; allow 10.20.0.0/16; allow 2001:db8::/32; deny all;"
run_case everyone    "all"                                       ""                               ""             ""             ""
run_case invalid     "203.0.113.55 bogus;evil 1.2.3"             ""                               "allow 203.0.113.55; deny all;" "allow 203.0.113.55; deny all;" "allow 203.0.113.55; deny all;"
run_case domain_a    ""                                          "a.example.org"                  "deny all;"    ""             "deny all;"
run_case domain_mix  "203.0.113.55"                              "b.example.org, not..a.domain"   "allow 203.0.113.55; deny all;" "allow 203.0.113.55; deny all;" ""
run_case domain_both ""                                          "a.example.org b.example.org"    "deny all;"    ""             ""

echo; echo ".env editing"
printf 'FOO=1\nNGINX_RPC_OPEN=a.example.org b.example.org\nBAR=2\n' > "$T/.env"
rpc_forget_domains b.example.org && [ "$(grep -c . "$T/.env")" -eq 3 ] && [ "$(rpc_open_domains)" = "a.example.org" ] \
    && ok "rpc_forget_domains drops one, keeps the rest and the other keys" || bad "rpc_forget_domains: $(cat "$T/.env" | xargs)"
rpc_forget_domains c.example.org && bad "rpc_forget_domains claims a change for an unlisted domain" || ok "rpc_forget_domains: unlisted domain is a no-op"
printf 'FOO=1\n' > "$T/.env"
env_write_key NGINX_RPC_OPEN "x.example.org" && [ "$(grep -c . "$T/.env")" -eq 2 ] && [ "$(rpc_open_domains)" = "x.example.org" ] \
    && ok "env_write_key appends a missing key" || bad "env_write_key append: $(cat "$T/.env" | xargs)"

echo; echo "Inode kept across renders (a docker single-file bind mount follows the inode)"
printf 'NGINX_MAX_UPLOAD=250M\nNGINX_RPC_ALLOW=\nNGINX_RPC_OPEN=\n' > "$T/.env"
render_http_only_conf >/dev/null; ino=$(stat -c %i "$NGINX_ACTIVE")
render_http_only_conf >/dev/null; [ "$(stat -c %i "$NGINX_ACTIVE")" = "$ino" ] && ok "render_http_only_conf writes in place" || bad "render_http_only_conf replaced the inode"
render_active_conf a.example.org b.example.org >/dev/null; [ "$(stat -c %i "$NGINX_ACTIVE")" = "$ino" ] && ok "render_active_conf writes in place" || bad "render_active_conf replaced the inode"

echo; echo "nginx_apply against a real container"
# dc() stands in for docker compose: one throwaway nginx container mounting
# the rendered file exactly the way docker-compose.yml does.
CT="ephem-apply-test-$$"
render_http_only_conf >/dev/null
docker run -d --name "$CT" --add-host odoo:127.0.0.1 -v "$NGINX_ACTIVE:/etc/nginx/conf.d/default.conf:ro" nginx:alpine >/dev/null
trap 'docker rm -f "$CT" >/dev/null 2>&1; rm -rf "$T"' EXIT
sleep 1
dc() {
    case "$*" in
        "ps -aq nginx")   docker ps -aq -f "name=^${CT}\$" ;;
        "exec -T nginx "*) shift 3; docker exec -i "$CT" "$@" ;;
        "run --rm --no-deps -T --entrypoint nginx nginx -t")
            docker run --rm --add-host odoo:127.0.0.1 -v "$NGINX_ACTIVE:/etc/nginx/conf.d/default.conf:ro" nginx:alpine nginx -t ;;
        "restart nginx")  docker restart "$CT" >/dev/null ;;
        "up -d nginx")    docker start "$CT" >/dev/null ;;
        *) echo "unexpected: dc $*" >&2; return 1 ;;
    esac
}
in_sync() { nginx_sees_host_conf; }
inside_has() { docker exec -i "$CT" grep -c "$1" /etc/nginx/conf.d/default.conf 2>/dev/null; }

# a) written in place: reload is enough
printf 'NGINX_MAX_UPLOAD=250M\nNGINX_RPC_ALLOW=all\n' > "$T/.env"; render_http_only_conf >/dev/null
out=$(nginx_apply); printf '%s\n' "$out" | grep -q 'reloaded' && in_sync && [ "$(inside_has 'deny all')" = 0 ] \
    && ok "in-place write: reloaded, container serves the new config" || { bad "in-place write"; printf '%s\n' "$out"; }
# b) replaced file (mv): the container is stale, nginx_apply must restart
printf 'NGINX_MAX_UPLOAD=250M\nNGINX_RPC_ALLOW=\n' > "$T/.env"
NGINX_ACTIVE="$T/out/staged.conf" render_http_only_conf >/dev/null; mv "$T/out/staged.conf" "$NGINX_ACTIVE"
in_sync && bad "stale detection: container should NOT see a renamed file" || ok "stale detection: renamed file not visible in the container"
out=$(nginx_apply); printf '%s\n' "$out" | grep -q 'restarted' && in_sync && [ "$(inside_has 'deny all')" = 1 ] \
    && ok "renamed file: restarted, container serves the new config" || { bad "renamed file"; printf '%s\n' "$out"; }
# c) broken config written in place: rejected, rolled back, still running
cp "$NGINX_ACTIVE" "$NGINX_ACTIVE.bak"; echo "this is not nginx;" >> "$NGINX_ACTIVE"
out=$(nginx_apply) && bad "broken in-place config was accepted" \
    || { printf '%s\n' "$out" | grep -q 'Rolled back' && in_sync && ! grep -q 'this is not nginx' "$NGINX_ACTIVE" && [ "$(docker inspect -f '{{.State.Status}}' "$CT")" = running ] \
         && ok "broken in-place config: rejected, rolled back, nginx still up" || { bad "broken in-place config"; printf '%s\n' "$out"; }; }
# d) broken config via rename: tested in a fresh container, rolled back, never loaded
cp "$NGINX_ACTIVE" "$NGINX_ACTIVE.bak"; { cat "$NGINX_ACTIVE"; echo "nor is this;"; } > "$T/out/broken.conf"; mv "$T/out/broken.conf" "$NGINX_ACTIVE"
out=$(nginx_apply) && bad "broken renamed config was accepted" \
    || { printf '%s\n' "$out" | grep -q 'never loaded' && ! grep -q 'nor is this' "$NGINX_ACTIVE" && [ "$(docker inspect -f '{{.State.Status}}' "$CT")" = running ] \
         && ok "broken renamed config: rejected in a fresh container, rolled back, nginx still up" || { bad "broken renamed config"; printf '%s\n' "$out"; }; }
docker rm -f "$CT" >/dev/null 2>&1
unset -f dc

echo; echo "What a client sees of the rendered HTTPS config (real nginx, self-signed certificates)"
printf 'NGINX_MAX_UPLOAD=250M\nNGINX_RPC_ALLOW=\nNGINX_RPC_OPEN=\n' > "$T/.env"
render_active_conf a.example.org b.example.org >/dev/null
# A stand-in for Odoo on 127.0.0.1:8069 (the --add-host below): answers with a
# session cookie and one the web client reads, so the cookie flags can be seen,
# and with the security headers Odoo sends itself: X-Frame-Options and a
# frame-ancestors policy on pages, default-src 'none' on files, none on /api/.
cat > "$T/out/fake-odoo.conf" <<'FAKE'
server {
    listen 127.0.0.1:8069;
    location / {
        add_header Set-Cookie "session_id=abc; Path=/";
        add_header Set-Cookie "cids=1; Path=/";
        add_header X-Content-Type-Options nosniff;
        add_header X-Frame-Options SAMEORIGIN;
        add_header Content-Security-Policy "frame-ancestors 'self'";
        return 200 "odoo";
    }
    location /web/content/ {
        add_header X-Content-Type-Options nosniff;
        add_header Content-Security-Policy "default-src 'none'";
        return 200 "file";
    }
    location /api/ { return 200 "api"; }
    location ~ /static/ { return 200 "static"; }
}
FAKE
TC="ephem-tls-test-$$"
trap 'docker rm -f "$TC" >/dev/null 2>&1; rm -rf "$T"' EXIT
if docker run -d --name "$TC" --add-host odoo:127.0.0.1 -p 127.0.0.1::443 \
       -v "$NGINX_ACTIVE:/etc/nginx/conf.d/default.conf:ro" \
       -v "$T/out/fake-odoo.conf:/etc/nginx/conf.d/fake-odoo.conf:ro" \
       -v "$T/le:/etc/letsencrypt:ro" nginx:alpine >/dev/null 2>&1; then
    sleep 2
    P="$(docker port "$TC" 443/tcp | head -1 | sed 's/.*://')"
    A="--resolve a.example.org:$P:127.0.0.1"
    hdrs="$(curl -sk -D - -o /dev/null $A "https://a.example.org:$P/web/login" 2>&1)"
    for h in 'strict-transport-security' 'x-frame-options' 'x-content-type-options' 'referrer-policy' \
             'content-security-policy: frame-ancestors' 'permissions-policy' 'x-permitted-cross-domain-policies'; do
        printf '%s\n' "$hdrs" | grep -qi "^$h" && ok "header sent: $h" || bad "header missing: $h"
    done
    for h in x-content-type-options x-frame-options content-security-policy; do
        n="$(printf '%s\n' "$hdrs" | grep -ci "^$h")"
        [ "$n" -eq 1 ] && ok "$h sent once on a page Odoo sends it on too" || bad "$h sent $n times on a page"
    done
    fh="$(curl -sk -D - -o /dev/null $A "https://a.example.org:$P/web/content/1" 2>&1 | grep -i '^content-security-policy' | tr -d '\r')"
    [ "$fh" = "content-security-policy: default-src 'none'" ] \
        && ok "a file keeps Odoo's own policy (default-src 'none'), alone" || bad "file CSP: $fh"
    fh="$(curl -sk -D - -o /dev/null $A "https://a.example.org:$P/api/x" 2>&1)"
    printf '%s\n' "$fh" | grep -qi "^content-security-policy: frame-ancestors 'self'" \
        && ok "an answer without a policy of its own gets frame-ancestors" || bad "no CSP added where Odoo sent none"
    # 100 requests as fast as one client can: the general zone (30 r/s, burst
    # 60) refuses some on an ordinary URL, none on static files and bundles.
    burst() { local i c=0; for i in $(seq 1 100); do [ "$(curl -sk -o /dev/null -w '%{http_code}' $A "https://a.example.org:$P$1")" = 429 ] && c=$((c + 1)); done; echo "$c"; }
    n="$(burst /web/static/x.js)"; [ "$n" -eq 0 ] && ok "web static files: no 429 in a burst of 100" || bad "web static files: $n of 100 refused"
    n="$(burst /eoc_base/static/src/x.png)"; [ "$n" -eq 0 ] && ok "module static files: no 429 in a burst of 100" || bad "module static files: $n of 100 refused"
    n="$(burst /web/assets/1/abc/web.assets_web.min.js)"; [ "$n" -eq 0 ] && ok "asset bundles: no 429 in a burst of 100" || bad "asset bundles: $n of 100 refused"
    sleep 3
    n="$(burst /odoo/action-1)"; [ "$n" -gt 0 ] && ok "an ordinary URL is still rate limited ($n of 100 refused)" || bad "an ordinary URL is no longer rate limited"
    printf '%s\n' "$hdrs" | grep -i '^server:' | grep -qE '^[Ss]erver: nginx\s*$' && ok "Server header carries no version" || bad "Server header: $(printf '%s\n' "$hdrs" | grep -i '^server:')"
    printf '%s\n' "$hdrs" | grep -i '^set-cookie: session_id' | grep -qi 'secure' \
        && printf '%s\n' "$hdrs" | grep -i '^set-cookie: session_id' | grep -qi 'httponly' \
        && ok "session_id cookie is Secure and HttpOnly" || bad "session_id cookie flags: $(printf '%s\n' "$hdrs" | grep -i '^set-cookie: session_id')"
    printf '%s\n' "$hdrs" | grep -i '^set-cookie: cids' | grep -qi 'httponly' \
        && bad "cids cookie was made HttpOnly (the web client reads it)" || ok "other cookies left alone (the web client reads them)"
    # A Host that is not one of ours, on a connection made for a real domain.
    # HTTP/2: nginx answers 421 itself. HTTP/1.1: the catch-all drops it (444).
    # Either way Odoo never sees the forged name.
    code="$(curl -sk -o /dev/null -w '%{http_code}' $A -H 'Host: evil.example.com' "https://a.example.org:$P/")"
    [ "$code" = 421 ] && ok "forged Host header over HTTP/2: 421, not passed on" || bad "forged Host header over HTTP/2: HTTP $code, wanted 421"
    code="$(curl -sk --http1.1 -o /dev/null -w '%{http_code}' $A -H 'Host: evil.example.com' "https://a.example.org:$P/")"
    [ "$code" = 000 ] && ok "forged Host header over HTTP/1.1: connection dropped (444), not passed on" || bad "forged Host header over HTTP/1.1: HTTP $code, wanted no answer"
    out="$(openssl s_client -connect "127.0.0.1:$P" -servername unknown.example.net </dev/null 2>&1)"
    printf '%s\n' "$out" | grep -q 'BEGIN CERTIFICATE' && bad "unknown name was given a certificate" || ok "unknown server name: handshake refused, no certificate shown"
    out="$(openssl s_client -connect "127.0.0.1:$P" -noservername </dev/null 2>&1)"
    printf '%s\n' "$out" | grep -q 'BEGIN CERTIFICATE' && bad "a request by IP address was given a certificate" || ok "no server name (browsing by IP): handshake refused, no certificate shown"
    out="$(openssl s_client -connect "127.0.0.1:$P" -servername a.example.org -tls1_2 -cipher 'ECDHE-RSA-AES256-GCM-SHA384' </dev/null 2>&1)"
    printf '%s\n' "$out" | grep -q 'Cipher is ECDHE-RSA-AES256-GCM-SHA384' && ok "TLS 1.2 with ECDHE + AES-GCM: accepted" || bad "TLS 1.2 ECDHE-GCM was refused"
    out="$(openssl s_client -connect "127.0.0.1:$P" -servername a.example.org -tls1_3 </dev/null 2>&1)"
    printf '%s\n' "$out" | grep -q 'TLSv1.3' && ok "TLS 1.3: accepted" || bad "TLS 1.3 was refused"
    out="$(openssl s_client -connect "127.0.0.1:$P" -servername a.example.org -tls1_2 -cipher 'AES256-SHA:AES256-GCM-SHA384@SECLEVEL=0' </dev/null 2>&1)"
    printf '%s\n' "$out" | grep -q 'BEGIN CERTIFICATE' && bad "a CBC / non forward-secret suite was accepted" || ok "CBC and non forward-secret suites: refused"
    docker rm -f "$TC" >/dev/null 2>&1
else
    bad "could not start the nginx container for the client checks"
fi

echo; echo "Proxy mode: the config for the nginx on another machine (render_proxy_conf)"
PD=ephem.example.org
mkdir -p "$T/le/live/$PD"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=$PD" \
    -keyout "$T/le/live/$PD/privkey.pem" -out "$T/le/live/$PD/fullchain.pem" >/dev/null 2>&1
chmod -R a+rX "$T/le"
PF="$(proxy_conf_path "$PD")"
nginx_t_proxy() {  # nginx_t_proxy IMAGE FILE
    docker run --rm -v "$2:/etc/nginx/conf.d/default.conf:ro" -v "$T/le:/etc/letsencrypt:ro" \
        "$1" sh -c 'mkdir -p /var/cache/nginx/ephem_ephem_example_org; nginx -t' 2>&1
}
docker image inspect nginx:1.18-alpine >/dev/null 2>&1 || docker pull -q nginx:1.18-alpine >/dev/null 2>&1
proxy_case() {  # proxy_case LABEL ALLOW OPEN WANT
    local label="$1" f got
    printf 'PROXY_DOMAIN=%s\nPROXY_BIND_HOST=10.20.30.40\nNGINX_MAX_UPLOAD=250M\nNGINX_RPC_ALLOW=%s\nNGINX_RPC_OPEN=%s\n' "$PD" "$2" "$3" > "$T/.env"
    rm -f "$PF"
    if render_proxy_conf >/dev/null 2>&1 && [ -f "$PF" ]; then
        f="$T/out/proxy_${label}.conf"; cp "$PF" "$f"
        got="$(block_of "$f" "$PD")"
        [ "$got" = "$4" ] && ok "proxy $label: RPC '$4'" || bad "proxy $label: RPC '$got', wanted '$4'"
        grep -q 'client_max_body_size 250M;' "$f" && ok "proxy $label: upload limit kept" || bad "proxy $label: upload limit lost"
        grep -q 'server 10.20.30.40:8069;' "$f" && grep -q 'server 10.20.30.40:8072;' "$f" \
            && ok "proxy $label: upstreams on PROXY_BIND_HOST, 8069 and 8072" || bad "proxy $label: upstreams wrong"
        grep -Eq 'odoo-backend|zone=ephem_limit|@[A-Z]+@' "$f" \
            && bad "proxy $label: a name of this stack's nginx or a placeholder left in" || ok "proxy $label: only its own prefixed names"
        out="$(nginx_t_proxy nginx:alpine "$f")" && ok "proxy $label: nginx -t (current)" || { bad "proxy $label: nginx -t (current)"; printf '%s\n' "$out" | sed 's/^/      /'; }
        out="$(nginx_t_proxy nginx:1.18-alpine "$f")" && ok "proxy $label: nginx -t (1.18, Ubuntu 20.04)" || { bad "proxy $label: nginx -t (1.18)"; printf '%s\n' "$out" | sed 's/^/      /'; }
    else bad "proxy $label: render failed"; fi
}
proxy_case blocked   ""                          ""    "deny all;"
proxy_case allowlist "203.0.113.55 10.20.0.0/16" ""    "allow 203.0.113.55; allow 10.20.0.0/16; deny all;"
proxy_case everyone  "all"                       ""    ""
proxy_case open      ""                          "$PD" ""
for bad_env in "PROXY_DOMAIN=" "PROXY_DOMAIN=not_a_domain" "PROXY_BIND_HOST=" "PROXY_BIND_HOST=0.0.0.0" "PROXY_BIND_HOST=10.0.0.1;evil" "PROXY_BIND_HOST=10.0.0.0/8"; do
    # the other key valid, this one broken
    key="${bad_env%%=*}"
    { [ "$key" = PROXY_DOMAIN ] || echo "PROXY_DOMAIN=$PD"
      [ "$key" = PROXY_BIND_HOST ] || echo "PROXY_BIND_HOST=10.20.30.40"
      echo "$bad_env"; } > "$T/.env"
    rm -f "$PF"
    render_proxy_conf >/dev/null 2>&1 && bad "proxy refuses $bad_env: rendered anyway" \
        || { [ -f "$PF" ] && bad "proxy refuses $bad_env: but wrote a file" || ok "proxy refuses $bad_env, writes nothing"; }
done

echo; echo "What a client and Odoo see through the proxy config (real nginx)"
printf 'PROXY_DOMAIN=%s\nPROXY_BIND_HOST=127.0.0.1\nNGINX_MAX_UPLOAD=250M\nNGINX_RPC_ALLOW=\nNGINX_RPC_OPEN=\n' "$PD" > "$T/.env"
render_proxy_conf >/dev/null
# Odoo stand-in on 127.0.0.1:8069 and :8072. /echo shows what reached Odoo.
cat > "$T/out/fake-odoo-proxy.conf" <<'FAKE'
server {
    listen 127.0.0.1:8069;
    location / {
        add_header Set-Cookie "session_id=abc; Path=/; HttpOnly";
        add_header Set-Cookie "cids=1; Path=/";
        add_header X-Frame-Options SAMEORIGIN;
        add_header Content-Security-Policy "frame-ancestors 'self'";
        return 200 "odoo";
    }
    location /echo { add_header X-Seen "$http_x_forwarded_host|$http_x_forwarded_proto|$http_x_forwarded_for|$host"; return 200 "echo"; }
    location ~ /static/ { return 200 "static"; }
    location /web/image/ { return 200 "image"; }
}
server {
    listen 127.0.0.1:8072;
    location /websocket { return 200 "gevent"; }
}
FAKE
PC="ephem-proxy-test-$$"
trap 'docker rm -f "$PC" >/dev/null 2>&1; rm -rf "$T"' EXIT
if docker run -d --name "$PC" -p 127.0.0.1::443 \
       -v "$PF:/etc/nginx/conf.d/default.conf:ro" \
       -v "$T/out/fake-odoo-proxy.conf:/etc/nginx/conf.d/fake-odoo.conf:ro" \
       -v "$T/le:/etc/letsencrypt:ro" nginx:alpine \
       sh -c 'mkdir -p /var/cache/nginx/ephem_ephem_example_org && chown nginx /var/cache/nginx/ephem_ephem_example_org && exec nginx -g "daemon off;"' >/dev/null 2>&1; then
    sleep 2
    P="$(docker port "$PC" 443/tcp | head -1 | sed 's/.*://')"
    A="--resolve $PD:$P:127.0.0.1"; B="https://$PD:$P"
    code() { curl -sk -o /dev/null -w '%{http_code}' $A "$@"; }
    hdrs="$(curl -sk -D - -o /dev/null $A "$B/web/login")"
    for h in strict-transport-security x-frame-options x-content-type-options referrer-policy content-security-policy permissions-policy; do
        n="$(printf '%s\n' "$hdrs" | grep -ci "^$h")"
        [ "$n" -eq 1 ] && ok "proxy: $h sent once" || bad "proxy: $h sent $n times"
    done
    printf '%s\n' "$hdrs" | grep -i '^set-cookie: session_id' | grep -qi 'secure' && ok "proxy: session_id cookie made Secure" || bad "proxy: session_id cookie not Secure"
    printf '%s\n' "$hdrs" | grep -i '^set-cookie: cids' | grep -qi 'httponly' && bad "proxy: cids made HttpOnly" || ok "proxy: cids stays readable by the web client"
    [ "$(code "$B/xmlrpc/2/common")" = 403 ] && ok "proxy: /xmlrpc refused (403)" || bad "proxy: /xmlrpc answered $(code "$B/xmlrpc/2/common")"
    [ "$(code "$B/web/database/manager")" = 403 ] && ok "proxy: database manager refused (403)" || bad "proxy: database manager answered"
    [ "$(code "$B/web/database/x/static/y")" = 403 ] && ok "proxy: no static location takes a database manager URL" || bad "proxy: /web/database/x/static/y got through"
    [ "$(code "$B/website/info")" = 404 ] && ok "proxy: /website/info hidden (404)" || bad "proxy: /website/info answered"
    [ "$(curl -sk $A "$B/websocket")" = gevent ] && ok "proxy: /websocket goes to port 8072" || bad "proxy: /websocket not routed to 8072"
    seen="$(curl -sk -D - -o /dev/null $A -H 'X-Forwarded-For: 6.6.6.6' -H 'X-Forwarded-Host: evil.example.com' "$B/echo" | grep -i '^x-seen' | tr -d '\r' | cut -d' ' -f2-)"
    case "$seen" in
        "$PD|https|"*"|$PD") [[ "$seen" != *6.6.6.6* ]] \
            && ok "proxy: Odoo gets the domain, https and the real client address only ($seen)" \
            || bad "proxy: a forged X-Forwarded-For reached Odoo ($seen)" ;;
        *) bad "proxy: Odoo saw '$seen'" ;;
    esac
    hit() { docker exec "$PC" sh -c "grep -c '\"GET $1 .*ucs=HIT' /var/log/nginx/$PD.access.log" 2>/dev/null || true; }
    code "$B/eoc_base/static/x.png" >/dev/null; code "$B/eoc_base/static/x.png" >/dev/null
    [ "$(hit /eoc_base/static/x.png)" -ge 1 ] && ok "proxy: module static file served from the cache the second time" || bad "proxy: static file never cached"
    code "$B/web/image/res.partner/1/avatar_128" >/dev/null; code "$B/web/image/res.partner/1/avatar_128" >/dev/null
    [ "$(hit /web/image/res.partner/1/avatar_128)" -eq 0 ] && ok "proxy: /web/image never cached" || bad "proxy: /web/image came from the cache"
    n=0; for i in $(seq 1 25); do [ "$(code -X POST -d 'login=x' "$B/web/login")" = 429 ] && n=$((n + 1)); done
    [ "$n" -ge 1 ] && ok "proxy: login POSTs throttled ($n of 25 refused)" || bad "proxy: login POSTs not throttled"
    docker rm -f "$PC" >/dev/null 2>&1
else
    bad "could not start the nginx container for the proxy checks"
fi

echo; echo "Template itself"
out="$(nginx_t "$REPO/nginx/default.conf")" && ok "nginx/default.conf: nginx -t" || { bad "nginx/default.conf: nginx -t"; printf '%s\n' "$out" | sed 's/^/      /'; }

sed -i '/location ~ ^\/(xmlrpc|jsonrpc)/,/^    }/d' "$T/nginx/default.conf"
render_http_only_conf >/dev/null 2>&1 && bad "template without an RPC block: rendered anyway" \
                                     || ok "template without an RPC block: refused"

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
