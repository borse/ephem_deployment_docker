#!/bin/bash
# ──────────────────────────────────────────────
# ePHEM — SSH host keys  (sourced, never run directly)
#
# `ssh-keyscan HOST >> known_hosts` trusts whoever answers first: on the one
# connection that matters (the first one, from a server that is about to
# receive a deploy key) a man in the middle would be written into known_hosts
# for good. For github.com the keys are therefore accepted only when their
# fingerprints are the ones GitHub publishes
# (docs.github.com → "GitHub's SSH key fingerprints"). Any other git host
# keeps the old trust on first use, but the fingerprints are printed so the
# operator can compare them with the host's own page.
# ──────────────────────────────────────────────

GITHUB_HOST_FINGERPRINTS=(
    "SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU"   # ED25519
    "SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM"   # ECDSA
    "SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s"   # RSA
)

# Trust HOST's SSH host keys, once. Returns 0 when HOST is trusted afterwards
# (already known, or added now), 1 when it could not be done safely.
known_host_add() {  # known_host_add HOST
    local host="$1" kh="$HOME/.ssh/known_hosts" scan line fp ok f keep=""
    mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
    if ssh-keygen -F "$host" -f "$kh" >/dev/null 2>&1; then return 0; fi
    scan=$(ssh-keyscan -T 10 -t ed25519,ecdsa,rsa "$host" 2>/dev/null) || scan=""
    if [ -z "$scan" ]; then
        echo "  Could not fetch the SSH host keys of $host (no network, or the host is down)." >&2
        return 1
    fi
    if [ "$host" = "github.com" ]; then
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            fp=$(printf '%s\n' "$line" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')
            ok=0
            for f in "${GITHUB_HOST_FINGERPRINTS[@]}"; do [ "$fp" = "$f" ] && ok=1; done
            [ "$ok" -eq 1 ] && keep+="$line"$'\n'
        done <<< "$scan"
        if [ -z "$keep" ]; then
            echo "  The SSH host keys answering for github.com do not match GitHub's published fingerprints." >&2
            echo "  Not trusting them: something between this server and GitHub may be impersonating it." >&2
            return 1
        fi
        scan="$keep"
    else
        echo "  First connection to $host. Its SSH host key fingerprints (compare with the host's documentation):" >&2
        printf '%s\n' "$scan" | ssh-keygen -lf - 2>/dev/null | sed 's/^/    /' >&2
    fi
    printf '%s\n' "$scan" >> "$kh"
    chmod 644 "$kh" 2>/dev/null || true
    return 0
}
