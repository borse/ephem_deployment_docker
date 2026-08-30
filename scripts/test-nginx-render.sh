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

echo; echo "Template itself"
out="$(nginx_t "$REPO/nginx/default.conf")" && ok "nginx/default.conf: nginx -t" || { bad "nginx/default.conf: nginx -t"; printf '%s\n' "$out" | sed 's/^/      /'; }

sed -i '/location ~ ^\/(xmlrpc|jsonrpc)/,/^    }/d' "$T/nginx/default.conf"
render_http_only_conf >/dev/null 2>&1 && bad "template without an RPC block: rendered anyway" \
                                     || ok "template without an RPC block: refused"

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
