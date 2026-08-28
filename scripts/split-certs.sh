#!/bin/bash
# ──────────────────────────────────────────────
# ePHEM — Split the shared certificate into one per domain
#
# Servers set up before per-domain certificates have ONE certificate listing
# every domain (certbot --expand). That has two problems:
#
#   • removing a domain means re-issuing the certificate for everyone else
#   • if ONE domain's DNS goes away, renewal fails for ALL of them, and every
#     tenant on the server loses HTTPS on the same day
#
# This gives every domain its own certificate and its own nginx server block,
# then shrinks or deletes the old shared certificate. Nothing goes offline:
# new certificates are issued first, nginx is switched over next, and the old
# certificate is only touched once nothing points at it.
#
# Usage:  ./scripts/split-certs.sh
# ──────────────────────────────────────────────

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EPHEM_ROOT="$SCRIPT_DIR"
# shellcheck source=scripts/nginx-lib.sh
source "$SCRIPT_DIR/scripts/nginx-lib.sh"

echo ""
echo "========================================="
echo "  ePHEM — one certificate per domain"
echo "========================================="
echo ""

if [ ! -f "$NGINX_ACTIVE" ] || ! ssl_is_configured; then
    echo -e "${RED}✗${NC} HTTPS is not set up on this server — nothing to split."
    exit 1
fi

certs_refresh
if [ -z "$EPHEM_CERTS_RAW" ]; then
    echo -e "${RED}✗${NC} Could not read the certificate list (is Docker running?)."
    exit 1
fi

mapfile -t SERVED < <(active_domains)
mapfile -t SHARED < <(shared_lineages)

echo -e "${BOLD}Certificates now:${NC}"
for lin in $(cert_lineages); do
    DOMS="$(cert_domains_of "$lin")"
    if [ "$(printf '%s' "$DOMS" | wc -w)" -gt 1 ]; then
        echo -e "  ${YELLOW}shared${NC}  $lin  →  $DOMS"
    else
        echo -e "  ${GREEN}single${NC}  $lin  →  $DOMS"
    fi
done
echo ""

if [ ${#SHARED[@]} -eq 0 ]; then
    echo -e "${GREEN}✓${NC} Every certificate already covers exactly one domain."
    echo ""
    read -r -p "  Rewrite nginx into one server block per domain anyway? [y/N]: " C
    [[ "${C:-N}" =~ ^[Yy]$ ]] || { echo "  Nothing to do."; exit 0; }
    render_active_conf "${SERVED[@]}" && nginx_apply
    exit $?
fi

# ── Plan ─────────────────────────────────────
# Domains that need a certificate of their own. A domain whose name is also
# the shared certificate's name is handled at the end: that lineage gets
# shrunk down to it, which leaves the file path — and so nginx — unchanged.
TO_ISSUE=()
TAIL_SHRINK=()   # "lineage domain" pairs to shrink after the switch
for lin in "${SHARED[@]}"; do
    for d in $(cert_domains_of "$lin"); do
        # A name the certificate carries but nginx does not serve is dead
        # weight: never re-issued, and dropped when the old certificate is
        # shrunk or deleted below.
        if ! printf '%s\n' "${SERVED[@]}" | grep -qx "$d"; then
            echo -e "  ${YELLOW}!${NC} '$lin' lists $d, which this server does not serve — dropping it"
            continue
        fi
        if [ "$d" = "$lin" ]; then
            TAIL_SHRINK+=("$lin")
            continue
        fi
        if lineage_exists "$d" && [ "$(cert_domains_of "$d")" = "$d" ]; then
            continue   # already has its own
        fi
        TO_ISSUE+=("$d")
    done
done

echo -e "${BOLD}Plan:${NC}"
[ ${#TO_ISSUE[@]} -gt 0 ] && printf '  issue new certificate for  %s\n' "${TO_ISSUE[@]}"
for lin in "${TAIL_SHRINK[@]}"; do
    echo "  shrink '$lin' down to just $lin (its own file path, no nginx change)"
done
for lin in "${SHARED[@]}"; do
    printf '%s\n' "${TAIL_SHRINK[@]:-}" | grep -qx "$lin" || echo "  delete '$lin' once every name it covers has its own"
done
echo "  rewrite nginx/active.conf: one server block per domain"
echo ""
echo "  Let's Encrypt allows 50 new certificates per week per registered"
echo "  domain; this run uses $(( ${#TO_ISSUE[@]} + ${#TAIL_SHRINK[@]} )) of them."
echo ""
read -r -p "  Continue? [y/N]: " C
[[ "${C:-N}" =~ ^[Yy]$ ]] || { echo "  Cancelled."; exit 0; }

EMAIL="$(ssl_email)"
if [ -z "$EMAIL" ]; then
    read -r -p "  Email for certificate expiry notices: " EMAIL
    [ -z "${EMAIL:-}" ] && { echo "  Cancelled."; exit 1; }
fi

# ── Step 1: issue the new certificates ───────
echo ""
echo -e "${BOLD}Issuing certificates${NC} (the old shared one keeps serving meanwhile)"
FAILED=()
for d in "${TO_ISSUE[@]:-}"; do
    [ -z "$d" ] && continue
    echo ""
    echo -e "  ${CYAN}→${NC} certbot certonly -d $d --cert-name $d"
    if issue_cert "$d" "$EMAIL" 2>&1 | sed 's/^/     /'; then
        echo -e "  ${GREEN}✓${NC} $d has its own certificate"
    else
        echo -e "  ${RED}✗${NC} $d failed — it stays on the shared certificate for now"
        FAILED+=("$d")
    fi
done

# ── Step 2: switch nginx over ────────────────
echo ""
echo "Rewriting nginx (one server block per domain)..."
certs_refresh
render_active_conf "${SERVED[@]}" || exit 1
nginx_apply || {
    echo -e "  ${RED}✗${NC} nginx was rolled back — the old shared certificate is untouched."
    exit 1
}

# ── Step 3: retire the shared certificates ───
# Only now, with nothing pointing at the old name list.
echo ""
echo "Retiring the shared certificate(s)..."
for lin in "${SHARED[@]}"; do
    STILL_NEEDED=()
    for d in $(cert_domains_of "$lin"); do
        printf '%s\n' "${FAILED[@]:-}" | grep -qx "$d" && STILL_NEEDED+=("$d")
    done

    if printf '%s\n' "${TAIL_SHRINK[@]:-}" | grep -qx "$lin"; then
        # This lineage is its own domain's certificate from now on.
        KEEPNAMES=("$lin" "${STILL_NEEDED[@]:-}")
        UNIQ=(); for n in "${KEEPNAMES[@]}"; do
            [ -n "$n" ] && ! printf '%s\n' "${UNIQ[@]:-}" | grep -qx "$n" && UNIQ+=("$n")
        done
        echo -e "  ${CYAN}→${NC} re-issuing '$lin' for: ${UNIQ[*]}"
        if reissue_cert "$lin" "$EMAIL" "${UNIQ[@]}" 2>&1 | sed 's/^/     /'; then
            echo -e "  ${GREEN}✓${NC} '$lin' now covers only ${UNIQ[*]}"
        else
            echo -e "  ${YELLOW}!${NC} could not shrink '$lin' — it still lists every old name."
            echo "     Harmless today (it is a valid certificate for $lin); re-run this"
            echo "     after the extra names' DNS records are gone."
        fi
    elif [ ${#STILL_NEEDED[@]} -eq 0 ]; then
        echo -e "  ${CYAN}→${NC} certbot delete --cert-name $lin"
        if delete_cert "$lin" >/dev/null 2>&1; then
            echo -e "  ${GREEN}✓${NC} '$lin' deleted"
        else
            echo -e "  ${YELLOW}!${NC} could not delete '$lin' — remove it with:"
            echo "     docker compose run --rm --entrypoint certbot certbot delete --cert-name $lin"
        fi
    else
        echo -e "  ${YELLOW}!${NC} '$lin' kept — still serving: ${STILL_NEEDED[*]}"
    fi
    certs_refresh
done

# ── Summary ──────────────────────────────────
echo ""
echo "========================================="
echo -e "${GREEN}✓ Done.${NC} Certificates now:"
certs_refresh
for lin in $(cert_lineages); do
    printf '  %-40s %s\n' "$lin" "$(cert_domains_of "$lin")"
done
echo ""
if [ ${#FAILED[@]} -gt 0 ]; then
    echo -e "${YELLOW}!${NC} Still sharing (issue failed): ${FAILED[*]}"
    echo "  Usually DNS: check each one points here, then re-run this."
    echo ""
fi
echo "From here on, adding or removing a domain touches only that domain."
echo "========================================="
echo ""
