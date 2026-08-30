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
run_state() {  # run_state LABEL ENVVALUE EXPECTED_DIRECTIVES...
    local label="$1" state="$2"; shift 2
    local want="$*" got f out n nwant
    printf 'NGINX_MAX_UPLOAD=250M\nNGINX_RPC_ALLOW=%s\n' "$state" > "$T/.env"
    for kind in http https; do
        if [ "$kind" = http ]; then render_http_only_conf >/dev/null
        else render_active_conf a.example.org b.example.org >/dev/null; fi \
            || { bad "$label / $kind: render failed"; continue; }
        f="$T/out/${kind}_${label}.conf"; cp "$NGINX_ACTIVE" "$f"
        # One RPC block per server block: 1 on the HTTP-only config, one per
        # domain on HTTPS. Compare the first one; they are all rendered alike.
        n="$(grep -c 'location ~ ^/(xmlrpc|jsonrpc)' "$f")"; nwant=1; [ "$kind" = https ] && nwant=2
        [ "$n" -eq "$nwant" ] && ok "$label / $kind: $n RPC block(s)" || bad "$label / $kind: $n RPC block(s), wanted $nwant"
        got="$(awk '/location ~ \^\/\(xmlrpc\|jsonrpc\)/ { inb = 1 } inb { print } inb && /^    }/ { exit }' "$f" \
               | grep -E '^\s*(allow|deny)' | xargs)"
        [ "$got" = "$want" ] && ok "$label / $kind: block renders '$want'" \
                             || bad "$label / $kind: block renders '$got', wanted '$want'"
        grep -q 'client_max_body_size 250M;' "$f" && ok "$label / $kind: NGINX_MAX_UPLOAD applied" \
                                                  || bad "$label / $kind: NGINX_MAX_UPLOAD lost"
        if out="$(nginx_t "$f")"; then ok "$label / $kind: nginx -t"
        else bad "$label / $kind: nginx -t"; printf '%s\n' "$out" | sed 's/^/      /'; fi
    done
}
run_state blocked   ""                                        "deny all;"
run_state allowlist "203.0.113.55, 10.20.0.0/16 2001:db8::/32" "allow 203.0.113.55; allow 10.20.0.0/16; allow 2001:db8::/32; deny all;"
run_state everyone  "all"                                     ""
run_state invalid   "203.0.113.55 bogus;evil 1.2.3"           "allow 203.0.113.55; deny all;"

echo; echo "Template itself"
out="$(nginx_t "$REPO/nginx/default.conf")" && ok "nginx/default.conf: nginx -t" || { bad "nginx/default.conf: nginx -t"; printf '%s\n' "$out" | sed 's/^/      /'; }

sed -i '/location ~ ^\/(xmlrpc|jsonrpc)/,/^    }/d' "$T/nginx/default.conf"
render_http_only_conf >/dev/null 2>&1 && bad "template without an RPC block: rendered anyway" \
                                     || ok "template without an RPC block: refused"

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
