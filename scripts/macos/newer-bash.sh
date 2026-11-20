#!/bin/bash
# ──────────────────────────────────────────────
# Prints the path of a bash 4 or later on this Mac, installing Homebrew's
# when there is none (asks first). Called by setup.sh, which then goes on
# under that bash.
#
# Why: macOS still ships bash 3.2 (2007), and scripts/stack-lib.sh, which
# setup.sh and the Docker menu load, needs bash 4. The native scripts in
# this folder (install.sh, dev.sh) run on 3.2 and never need this.
#
# Everything a person reads goes to stderr; stdout carries the path only.
# ──────────────────────────────────────────────
set -euo pipefail
exec 3>&1 1>&2

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

find_newer() {
    local b
    for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        if [ -x "$b" ] && "$b" -c '[ "${BASH_VERSINFO[0]}" -ge 4 ]' 2>/dev/null; then
            echo "$b"; return 0
        fi
    done
    return 1
}

if B="$(find_newer)"; then echo "$B" >&3; exit 0; fi

echo ""
echo "This Mac's own bash is version ${BASH_VERSION%%(*}, from 2007; setup.sh needs bash 4 or later."
if brew_find; then
    confirm "Install a current bash with Homebrew (brew install bash)?" Y || die "Install it yourself (brew install bash), then run bash setup.sh again."
else
    echo "Homebrew provides one. Homebrew is not installed yet: its installer asks for"
    echo "your Mac password once and takes a few minutes."
    confirm "Install Homebrew and a current bash now?" Y || die "Install them yourself (https://brew.sh, then: brew install bash), and run bash setup.sh again."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
        || die "Homebrew's installer did not finish. Run it in a terminal of your own, then run bash setup.sh again."
    brew_find || die "Homebrew still not found after its installer ran."
fi
HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1 "$BREW" install bash
B="$(find_newer)" || die "bash was installed but is not where Homebrew puts it. Run: $("$BREW" --prefix)/bin/bash setup.sh"
ok "bash $("$B" -c 'echo "$BASH_VERSION"') installed; your Terminal keeps using its own shell"
echo "$B" >&3
