#!/bin/bash
# ──────────────────────────────────────────────
# ePHEM: proxy-firewall.sh check (developer machine, not the server)
#
# Runs the rules script that `proxy-firewall.sh apply` installs against a real
# iptables, inside a throwaway container with a network namespace of its own
# (NET_ADMIN there; nothing on this machine is touched), with a DOCKER-USER
# chain made by hand the way Docker makes it. Checks the rules it adds, that a
# second start does not stack them, that a new address replaces the old hook,
# and that stop leaves nothing behind. Also checks the script is plain POSIX
# sh (Ubuntu runs it with dash).
#
# Needs: docker (alpine is pulled if missing), dash for the syntax check.
# Usage: bash scripts/test-proxy-firewall.sh
# ──────────────────────────────────────────────
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# write_rules_script and write_unit only: the file without its dispatch at
# the end. It sets -e on the way in; this test reports failures instead.
# shellcheck disable=SC1090
source <(sed '/^case "\${1:-}" in$/,$d' "$REPO/scripts/proxy-firewall.sh")
set +e

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  \033[0;32m✓\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[0;31m✗\033[0m %s\n' "$1"; }

write_rules_script 10.20.30.40 "10.0.0.5 192.168.0.0/24" "$T/rules"
write_rules_script 10.20.30.41 "10.0.0.5" "$T/rules2"
write_unit "$T/unit"
chmod a+r "$T"/*

echo "Generated files"
if command -v dash >/dev/null 2>&1; then
    dash -n "$T/rules" && ok "rules script parses as POSIX sh (dash)" || bad "rules script does not parse under dash"
else
    bad "dash not installed: POSIX check skipped"
fi
grep -q "^BIND='10.20.30.40'$" "$T/rules" && grep -q "^FROM='10.0.0.5 192.168.0.0/24'$" "$T/rules" \
    && ok "addresses written into the script, not read at boot" || bad "addresses missing from the script"
grep -q '^ExecStart=/usr/local/sbin/ephem-proxy-ports start$' "$T/unit" && grep -q '^PartOf=docker.service$' "$T/unit" \
    && ok "unit starts the rules after Docker and follows its restarts" || bad "unit file: $(xargs < "$T/unit")"

echo; echo "Against a real iptables (throwaway container)"
docker image inspect alpine:3 >/dev/null 2>&1 || docker pull -q alpine:3 >/dev/null 2>&1
out="$(docker run --rm --cap-add NET_ADMIN -v "$T:/t:ro" alpine:3 sh -c '
    apk add -q iptables >/dev/null 2>&1 || { echo NOIPTABLES; exit 0; }
    iptables -N DOCKER-USER && iptables -A DOCKER-USER -j RETURN
    sh /t/rules start && sh /t/rules start
    echo "== TWO"; iptables -S DOCKER-USER; iptables -S EPHEM-PROXY
    sh /t/rules2 start
    echo "== MOVED"; iptables -S DOCKER-USER; iptables -S EPHEM-PROXY
    sh /t/rules2 stop
    echo "== STOPPED"; iptables -S DOCKER-USER; iptables -S EPHEM-PROXY 2>&1 | head -1
    iptables -F DOCKER-USER && iptables -X DOCKER-USER
    echo "== NOCHAIN"; sh /t/rules start; echo "rc=$?"
' 2>&1)"
if printf '%s\n' "$out" | grep -q NOIPTABLES; then
    bad "could not install iptables in the container (network?)"
else
    section() { printf '%s\n' "$out" | awk -v s="== $1" '$0 == s { on = 1; next } /^== / { on = 0 } on'; }
    two="$(section TWO)"; moved="$(section MOVED)"; stopped="$(section STOPPED)"; nochain="$(section NOCHAIN)"
    n="$(printf '%s\n' "$two" | grep -c -- '-j EPHEM-PROXY')"
    [ "$n" -eq 2 ] && ok "two hooks in DOCKER-USER (8069, 8072), not stacked by a second start" || bad "$n hooks after two starts"
    printf '%s\n' "$two" | grep -- '-j EPHEM-PROXY' | grep -q -- '--ctorigdst 10.20.30.40' \
        && printf '%s\n' "$two" | grep -q -- '--ctorigdstport 8072' \
        && ok "hooks match the published address and both ports, original direction" || bad "hooks: $(printf '%s\n' "$two" | grep -- '-j EPHEM-PROXY' | xargs)"
    [ "$(printf '%s\n' "$two" | grep -n -- '-j EPHEM-PROXY' | head -1 | cut -d: -f1)" -lt "$(printf '%s\n' "$two" | grep -n -- '-j RETURN' | head -1 | cut -d: -f1)" ] \
        && ok "hooks come before Docker's RETURN" || bad "hooks after RETURN: never reached"
    printf '%s\n' "$two" | grep -q -- '-A EPHEM-PROXY -s 10.0.0.5/32 -j RETURN' \
        && printf '%s\n' "$two" | grep -q -- '-A EPHEM-PROXY -s 192.168.0.0/24 -j RETURN' \
        && [ "$(printf '%s\n' "$two" | grep -- '-A EPHEM-PROXY' | tail -1)" = "-A EPHEM-PROXY -j DROP" ] \
        && ok "chain lets the proxy addresses through and drops the rest" || bad "chain: $(printf '%s\n' "$two" | grep -- '-A EPHEM-PROXY' | xargs)"
    [ "$(printf '%s\n' "$moved" | grep -c -- '-j EPHEM-PROXY')" -eq 2 ] \
        && ! printf '%s\n' "$moved" | grep -q -- '--ctorigdst 10.20.30.40' \
        && ! printf '%s\n' "$moved" | grep -q '192.168.0.0/24' \
        && ok "a new address and proxy replace the old hooks and entries" || bad "after a change: $(printf '%s\n' "$moved" | xargs)"
    ! printf '%s\n' "$stopped" | grep -q EPHEM-PROXY && printf '%s\n' "$stopped" | grep -q -- '-A DOCKER-USER -j RETURN' \
        && ok "stop removes the hooks and the chain, leaves Docker's rule" || bad "after stop: $(printf '%s\n' "$stopped" | xargs)"
    printf '%s\n' "$nochain" | grep -q 'no DOCKER-USER chain' && printf '%s\n' "$nochain" | grep -q 'rc=1' \
        && ok "no DOCKER-USER chain (Docker down): refuses with a reason" || bad "without DOCKER-USER: $(printf '%s\n' "$nochain" | xargs)"
fi

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
