#!/bin/bash
# ──────────────────────────────────────────────
# ePHEM Setup Script
# Run this once after cloning the repo.
# ──────────────────────────────────────────────

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

get_server_ip() {
    # Try each source in turn, checking OUTPUT (not exit code): on macOS
    # `hostname -I` fails but the awk pipeline still exits 0, so an exit-code
    # `||` chain would never reach the BSD/`ipconfig` fallbacks.
    local ip=""
    ip=$(hostname -I 2>/dev/null | awk '{print $1}') || true
    [ -n "$ip" ] || ip=$(ipconfig getifaddr en0 2>/dev/null) || true   # macOS (Ethernet/primary)
    [ -n "$ip" ] || ip=$(ipconfig getifaddr en1 2>/dev/null) || true   # macOS (Wi-Fi on some models)
    [ -n "$ip" ] || ip=$(ip route get 1 2>/dev/null | awk '{print $7; exit}') || true
    [ -n "$ip" ] || ip="127.0.0.1"
    printf '%s\n' "$ip"
}

# True when running inside WSL (Docker is Docker Desktop on the Windows host).
is_wsl() {
    grep -qiE "microsoft|wsl" /proc/version 2>/dev/null || [ -n "${WSL_DISTRO_NAME:-}" ]
}

# Cross-platform URL opener: macOS `open`, WSL `wslview`/`explorer.exe`,
# Linux `xdg-open`. Returns non-zero if no opener is available.
open_url() {
    local url="$1"
    if command -v open >/dev/null 2>&1; then open "$url" >/dev/null 2>&1
    elif command -v wslview >/dev/null 2>&1; then wslview "$url" >/dev/null 2>&1
    elif command -v explorer.exe >/dev/null 2>&1; then explorer.exe "$url" >/dev/null 2>&1
    elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$url" >/dev/null 2>&1
    else return 1; fi
}
have_opener() {
    command -v open >/dev/null 2>&1 || command -v wslview >/dev/null 2>&1 \
        || command -v explorer.exe >/dev/null 2>&1 || command -v xdg-open >/dev/null 2>&1
}

# Echoes the platform family: mac | windows | wsl | linux | unknown.
detect_platform() {
    case "$(uname -s 2>/dev/null || echo unknown)" in
        Darwin) echo mac ;;
        MINGW*|MSYS*|CYGWIN*) echo windows ;;
        Linux) if is_wsl; then echo wsl; else echo linux; fi ;;
        *) echo unknown ;;
    esac
}

# Beginner-friendly, step-by-step guidance shown when `ssh -T git@github.com`
# does not authenticate. Used by both the single- and multi-instance dev flows.
github_ssh_help() {
    local plat; plat="$(detect_platform)"
    echo ""
    echo -e "  ${BOLD}What developer mode needs (one-time):${NC}"
    echo "    Developer mode clones the ePHEM addons with YOUR personal GitHub"
    echo "    identity over SSH. Two things must both be true:"
    echo "      1. An SSH key exists on this machine and is added to your GitHub account."
    echo "      2. Your GitHub account has collaborator access to borse/ePHEM."
    echo ""
    if [ "$plat" = "wsl" ]; then
        echo -e "  ${YELLOW}On Windows:${NC} run every command below in the ${BOLD}Ubuntu${NC} terminal, not"
        echo "    PowerShell — the key must live in WSL's ~/.ssh (that's what setup.sh uses)."
        echo ""
    fi
    echo -e "  ${BOLD}Step 1${NC}  See if you already have a key (if it prints one, skip Step 2):"
    echo "            cat ~/.ssh/id_ed25519.pub"
    echo ""
    echo -e "  ${BOLD}Step 2${NC}  Create one (just press Enter at every prompt):"
    echo "            ssh-keygen -t ed25519 -C \"your@email.com\""
    echo ""
    echo -e "  ${BOLD}Step 3${NC}  Copy the PUBLIC key and add it to GitHub:"
    echo "            cat ~/.ssh/id_ed25519.pub          # copy the whole line"
    echo "            → https://github.com/settings/keys → 'New SSH key' → paste → save"
    echo ""
    echo -e "  ${BOLD}Step 4${NC}  Ask the ePHEM team to add your GitHub username as a collaborator"
    echo "            on borse/ePHEM (if they haven't already)."
    echo ""
    echo -e "  ${BOLD}Step 5${NC}  Verify, then re-run setup:"
    echo "            ssh -T git@github.com     # expect: Hi <you>! You've successfully authenticated"
    echo "            bash setup.sh"
    echo ""
}

# Poll until the Docker daemon answers, or time out. $1 = number of 3s tries.
wait_for_docker() {
    local tries="${1:-40}" i
    for i in $(seq 1 "$tries"); do
        docker info >/dev/null 2>&1 && return 0
        printf '.'
        sleep 3
    done
    return 1
}

# Make sure a working Docker Engine + Compose v2 exist BEFORE the rest of setup.
# Installing is opt-in (always asks first). On macOS/Windows/WSL, Docker Desktop
# is a GUI app on the host, so there we can only guide + wait for it to come up.
ensure_docker_ready() {
    local plat SUDO=""
    plat="$(detect_platform)"
    [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1 && SUDO="sudo"

    # Running under Git Bash / MSYS on bare Windows (not WSL). ePHEM expects a
    # Linux environment — point the user at WSL before going further.
    if [ "$plat" = "windows" ]; then
        echo -e "${YELLOW}!${NC} You're running in Git Bash / MSYS, not WSL."
        echo "  ePHEM is designed to run inside WSL (Ubuntu). Set it up once:"
        echo ""
        echo "    1. Open PowerShell as Administrator and run:"
        echo -e "         ${BOLD}wsl --install -d Ubuntu${NC}"
        echo "    2. Reboot if asked, then open the 'Ubuntu' app from the Start menu."
        echo "    3. Inside Ubuntu, install git, clone the repo, and run: bash setup.sh"
        echo ""
        echo "  (Bind-mounts and Docker volumes are much faster under WSL than Git Bash.)"
        exit 1
    fi

    # ── 1. Is the docker CLI present at all? ──────────────────
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${YELLOW}!${NC} Docker is not installed on this machine."
        case "$plat" in
            linux)
                echo "  I can install Docker Engine for you using Docker's official script."
                read -p "  Install Docker now? [Y/n]: " DO_INSTALL
                if [[ "${DO_INSTALL:-Y}" =~ ^[Nn]$ ]]; then
                    echo "  No problem — install it yourself, then re-run this script:"
                    echo "    curl -fsSL https://get.docker.com | sh"
                    exit 1
                fi
                echo "  Installing Docker Engine (you may be prompted for your sudo password)…"
                if curl -fsSL https://get.docker.com | sh; then
                    echo -e "  ${GREEN}✓${NC} Docker Engine installed"
                    $SUDO systemctl enable --now docker >/dev/null 2>&1 \
                        || $SUDO service docker start >/dev/null 2>&1 || true
                    if ! groups 2>/dev/null | grep -q '\bdocker\b'; then
                        $SUDO usermod -aG docker "$USER" 2>/dev/null || true
                        echo ""
                        echo -e "  ${YELLOW}!${NC} Added '$USER' to the docker group — this needs a full re-login."
                        echo "     Log out and back in, then run:  bash setup.sh"
                        exit 0
                    fi
                else
                    echo -e "  ${RED}✗${NC} Automatic install failed."
                    echo "     Install manually: https://docs.docker.com/engine/install/"
                    exit 1
                fi
                ;;
            mac)
                if command -v brew >/dev/null 2>&1; then
                    echo "  Docker Desktop can be installed with Homebrew."
                    read -p "  Install it now (brew install --cask docker)? [Y/n]: " DO_INSTALL
                    if [[ "${DO_INSTALL:-Y}" =~ ^[Nn]$ ]]; then
                        echo "  Download it instead: https://docs.docker.com/desktop/install/mac-install/"
                        exit 1
                    fi
                    if brew install --cask docker; then
                        echo -e "  ${GREEN}✓${NC} Docker Desktop installed — launching it…"
                        open -a Docker 2>/dev/null || true
                    else
                        echo -e "  ${RED}✗${NC} brew install failed."
                        echo "     Download it: https://docs.docker.com/desktop/install/mac-install/"
                        exit 1
                    fi
                else
                    echo "  Install Docker Desktop for Mac, then re-run this script:"
                    echo "    https://docs.docker.com/desktop/install/mac-install/"
                    open_url "https://docs.docker.com/desktop/install/mac-install/" || true
                    exit 1
                fi
                ;;
            wsl)
                echo "  Inside WSL, Docker is provided by Docker Desktop on Windows:"
                echo "    1. Install Docker Desktop: https://docs.docker.com/desktop/install/windows-install/"
                echo "    2. Docker Desktop → Settings → Resources → WSL Integration → enable this distro."
                echo "    3. Make sure Docker Desktop is running."
                echo "  Then re-run this script."
                exit 1
                ;;
            *)
                echo "  Install Docker, then re-run this script: https://docs.docker.com/get-docker/"
                exit 1
                ;;
        esac
    fi

    # ── 2. Is the daemon reachable? (start it / wait for Desktop) ──
    if ! docker info >/dev/null 2>&1; then
        case "$plat" in
            mac)
                echo -e "${YELLOW}!${NC} Docker Desktop isn't running yet — please start it (whale icon)."
                printf "  Waiting for Docker to become ready"
                if wait_for_docker 40; then
                    echo -e "\n  ${GREEN}✓${NC} Docker is running"
                else
                    echo -e "\n  ${RED}✗${NC} Docker is still unreachable. Start Docker Desktop, then re-run: bash setup.sh"
                    exit 1
                fi
                ;;
            wsl)
                echo -e "${YELLOW}!${NC} Can't reach Docker from WSL. Start Docker Desktop on Windows and enable"
                echo "     WSL integration (Settings → Resources → WSL Integration → this distro)."
                printf "  Waiting for Docker to become ready"
                if wait_for_docker 40; then
                    echo -e "\n  ${GREEN}✓${NC} Docker is reachable from WSL"
                else
                    echo -e "\n  ${RED}✗${NC} Still unreachable. Fix WSL integration, then re-run: bash setup.sh"
                    exit 1
                fi
                ;;
            *)
                echo -e "${YELLOW}!${NC} Docker daemon isn't running — trying to start it…"
                $SUDO systemctl start docker >/dev/null 2>&1 \
                    || $SUDO service docker start >/dev/null 2>&1 || true
                if ! docker info >/dev/null 2>&1; then
                    if ! groups 2>/dev/null | grep -q '\bdocker\b'; then
                        echo -e "  ${YELLOW}!${NC} '$USER' isn't in the docker group:  sudo usermod -aG docker $USER"
                        echo "     Then log out/in and re-run: bash setup.sh"
                    else
                        echo -e "  ${RED}✗${NC} Could not start Docker. Check: sudo systemctl status docker"
                    fi
                    exit 1
                fi
                echo -e "  ${GREEN}✓${NC} Docker daemon started"
                ;;
        esac
    fi

    # ── 3. Compose v2 present? ────────────────────────────────
    if ! docker compose version >/dev/null 2>&1; then
        echo -e "${RED}✗${NC} Docker Compose v2 is not available."
        echo "  Linux:        $SUDO apt-get install -y docker-compose-plugin"
        echo "  Mac/Windows:  update Docker Desktop to a recent version."
        exit 1
    fi

    echo -e "${GREEN}✓${NC} Docker is installed, running, and Compose v2 is available"
}

# ── Architecture guard ────────────────────────
# A multi-arch image normally resolves to the host's native arch automatically.
# Two things override that and silently install the wrong arch (then run under
# emulation, e.g. amd64 on an Apple Silicon Mac): DOCKER_DEFAULT_PLATFORM, or a
# stale same-tag image already cached. Detect both and offer to fix so the
# native build is used.
ensure_native_image_arch() {
    local image="borrs/ephem:latest" machine host_arch
    machine=$(uname -m 2>/dev/null || echo unknown)
    case "$machine" in
        arm64|aarch64) host_arch="arm64" ;;
        x86_64|amd64)  host_arch="amd64" ;;
        *) return 0 ;;   # unknown host arch — don't guess
    esac

    # (1) Forced platform env var overrides the manifest for every pull.
    if [ -n "${DOCKER_DEFAULT_PLATFORM:-}" ] \
       && [ "${DOCKER_DEFAULT_PLATFORM##*/}" != "$host_arch" ]; then
        echo -e "${YELLOW}!${NC} DOCKER_DEFAULT_PLATFORM=${DOCKER_DEFAULT_PLATFORM} forces non-native images on this $host_arch machine."
        read -p "  Ignore it for this run so the native $host_arch image is used? [Y/n]: " UNSET_PLAT
        if [[ ! "${UNSET_PLAT:-Y}" =~ ^[Nn]$ ]]; then
            unset DOCKER_DEFAULT_PLATFORM
            echo -e "  ${GREEN}✓${NC} Unset for this run. Make it permanent by removing it from your"
            echo "     shell profile (e.g. ~/.zshrc) and Docker Desktop → Settings → Docker Engine."
        else
            echo "  Keeping it — the app will run under emulation."
        fi
    fi

    # (2) A stale cached image of the wrong arch is not re-selected on its own.
    local img_arch
    img_arch=$(docker image inspect "$image" --format '{{.Architecture}}' 2>/dev/null || echo "")
    if [ -n "$img_arch" ] && [ "$img_arch" != "$host_arch" ]; then
        echo -e "${YELLOW}!${NC} Cached $image is ${BOLD}$img_arch${NC} but this machine is ${BOLD}$host_arch${NC} — Docker won't switch it automatically."
        read -p "  Remove it and re-pull the native $host_arch build? [Y/n]: " REPULL
        if [[ ! "${REPULL:-Y}" =~ ^[Nn]$ ]]; then
            docker rmi "$image" >/dev/null 2>&1 || true
            echo "  Pulling native $host_arch image…"
            docker compose pull odoo 2>/dev/null || docker pull "$image" || true
            echo -e "  ${GREEN}✓${NC} Native image pulled"
        else
            echo "  Keeping the $img_arch image — it will run under emulation."
        fi
    fi
}

# ── Developer pre-flight helpers ───────────────
# Used by the developer-mode menu shown before installation.

dev_cheatsheet() {
    echo -e "${CYAN}${BOLD}Common developer commands${NC} (run from this repo dir)"
    echo ""
    echo "  Logs:"
    echo "    docker compose logs -f odoo            # live tail (Ctrl-C to stop)"
    echo "    docker compose logs --tail=100 odoo    # last 100 lines"
    echo "    docker logs -f ephem-app               # raw odoo lines (no compose prefix)"
    echo "      ↳ PyCharm: add this as a Shell Script run config for colored logs."
    echo "        Colors come from Odoo itself (ODOO_PY_COLORS=1, set in the override) —"
    echo "        no IDE plugin needed; the console just renders the ANSI codes."
    echo "  Service:"
    echo "    bash scripts/dev-logs.sh               # restart Odoo + follow colored logs"
    echo "    bash scripts/dev-logs.sh <name>        # same, for a multi-instance server (e.g. 'a')"
    echo "      ↳ PyCharm: one Shell Script run config per instance (dev-logs.sh a, …) = a green ▶ each"
    echo "    docker compose restart odoo            # restart Odoo only"
    echo "    docker compose up -d                   # start everything"
    echo "    docker compose down                    # stop (keep data)"
    echo "  Image:"
    echo "    docker compose pull                    # fetch a newer app image"
    echo "  Addons (your live git work in custom-addons/):"
    echo "    git -C custom-addons status"
    echo "    git -C custom-addons pull"
    echo "    git -C custom-addons branch --show-current"
    echo "  Update a module after editing:"
    echo "    docker compose exec odoo odoo -u <module> -d <db> --stop-after-init"
}

dev_suggest() {
    echo -e "${CYAN}${BOLD}Suggested next commands${NC} (based on current state)"
    echo ""
    local running=0
    docker compose ps --status=running 2>/dev/null | grep -q odoo && running=1
    if [ "$running" -eq 1 ]; then
        echo "  • Odoo is running. Watch logs:    docker compose logs -f odoo"
        echo "  • After editing addons, restart:  docker compose restart odoo"
    else
        echo "  • Stack is down. Start it:        docker compose up -d"
        echo "  • Then watch startup:             docker compose logs -f odoo"
    fi
    if [ -d custom-addons/.git ]; then
        local cur behind
        cur=$(git -C custom-addons branch --show-current 2>/dev/null || echo "?")
        echo "  • custom-addons branch:           $cur"
        if git -C custom-addons fetch origin >/dev/null 2>&1; then
            behind=$(git -C custom-addons rev-list HEAD..origin/"$cur" --count 2>/dev/null || echo 0)
            [ "${behind:-0}" -gt 0 ] 2>/dev/null && \
                echo "  • $behind commit(s) behind — update:  git -C custom-addons pull"
        fi
    fi
}

dev_readme() {
    echo -e "${CYAN}${BOLD}Documentation${NC}"
    echo ""
    echo "  Deployment / setup (this repo):"
    echo "    https://github.com/borse/ephem_deployment_docker#readme"
    echo "  ePHEM addons:"
    echo "    https://github.com/borse/ePHEM"
    echo ""
    if [ -f README.md ]; then
        read -p "  View the local README.md now? [y/N]: " V
        if [[ "${V:-N}" =~ ^[Yy]$ ]]; then
            ${PAGER:-less} README.md 2>/dev/null || cat README.md
        fi
    fi
    if have_opener; then
        read -p "  Open the deployment README in a browser? [y/N]: " O
        [[ "${O:-N}" =~ ^[Yy]$ ]] && open_url "https://github.com/borse/ephem_deployment_docker#readme" || true
    fi
}

dev_prereq_check() {
    echo -e "${CYAN}${BOLD}Prerequisite check${NC}"
    echo ""
    local ok=1
    if command -v docker >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} docker     $(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')"
    else
        echo -e "${RED}✗${NC} docker not found — install Docker Engine/Desktop"; ok=0
    fi
    if docker compose version >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} compose    $(docker compose version --short 2>/dev/null)"
    else
        echo -e "${RED}✗${NC} docker compose v2 not found"; ok=0
    fi
    if command -v git >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} git        $(git --version 2>/dev/null | awk '{print $3}')"
    else
        echo -e "${RED}✗${NC} git not found"; ok=0
    fi
    if command -v ssh >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} ssh        present"
    else
        echo -e "${RED}✗${NC} ssh not found"; ok=0
    fi
    if ! docker info >/dev/null 2>&1; then
        echo -e "${YELLOW}!${NC} Docker daemon not responding — is Docker running?"; ok=0
    fi
    echo ""
    if [ "$ok" -eq 1 ]; then
        echo -e "${GREEN}✓${NC} All prerequisites present."
    else
        echo -e "${YELLOW}!${NC} Some prerequisites are missing (see above)."
    fi
}

dev_status() {
    echo -e "${CYAN}${BOLD}Container status${NC}"
    echo ""
    docker compose ps 2>/dev/null || echo -e "${YELLOW}!${NC} Could not read compose status (no containers yet?)"
}

dev_doctor() {
    echo -e "${CYAN}${BOLD}Doctor — scanning recent Odoo logs${NC}"
    echo ""
    if ! docker compose ps --status=running 2>/dev/null | grep -q odoo; then
        echo -e "${YELLOW}!${NC} Odoo container isn't running — start it first: docker compose up -d"
        return 0
    fi
    local LOGS found=0 MISSING
    LOGS=$(docker compose logs --tail=300 odoo 2>&1 || true)
    if echo "$LOGS" | grep -q "ModuleNotFoundError"; then
        found=1
        MISSING=$(echo "$LOGS" | sed -n "s/.*ModuleNotFoundError: No module named '\([^']*\)'.*/\1/p" | sort -u | tr '\n' ' ')
        echo -e "${RED}✗${NC} Missing Python module(s): ${BOLD}${MISSING}${NC}"
        echo "   A custom addon imports a package that isn't in the app image."
        echo "   Permanent fix: add it to the image (rebuild & push), then: docker compose pull"
        echo "   Quick local patch:"
        echo "     docker compose exec -u root odoo pip install --break-system-packages ${MISSING}"
        echo "     docker compose restart odoo"
        echo ""
    fi
    if echo "$LOGS" | grep -q "Failed to load registry"; then
        found=1
        echo -e "${RED}✗${NC} Registry failed to load — every page will return 500."
        echo "   Usually a module raising on import (see above) or a bad XML/data file."
        echo ""
    fi
    if echo "$LOGS" | grep -qiE "could not translate host name|connection refused.*5432|database .* does not exist"; then
        found=1
        echo -e "${RED}✗${NC} Database connectivity/availability issue."
        echo "   Check:  docker compose ps   and   docker compose logs db"
        echo ""
    fi
    [ "$found" -eq 0 ] && echo -e "${GREEN}✓${NC} No known error signatures in the last 300 log lines."
}

dev_reset() {
    echo -e "${CYAN}${BOLD}Reset / clean environment${NC}"
    echo ""
    echo -e "${GREEN}Your custom-addons/ is a host folder and is NEVER touched by any option here.${NC}"
    echo ""
    echo "  1) Stop containers, keep data    (docker compose down)"
    echo "  2) Full reset: wipe DB + Odoo filestore volumes, KEEP custom-addons"
    echo "       (docker compose down -v  — removes postgres-data & odoo-data)"
    echo "  3) Cancel"
    echo ""
    read -p "Choose [1-3]: " R
    case "${R:-3}" in
        1) docker compose down && echo -e "${GREEN}✓${NC} Stopped (data preserved)." ;;
        2)
            echo ""
            echo -e "${RED}This deletes the database and Odoo filestore volumes.${NC} custom-addons/ stays."
            read -p "Type RESET to confirm: " CONF
            if [ "$CONF" = "RESET" ]; then
                docker compose down -v && \
                    echo -e "${GREEN}✓${NC} Volumes wiped, custom-addons/ untouched. Start fresh: docker compose up -d"
            else
                echo "  Cancelled."
            fi
            ;;
        *) echo "  Cancelled." ;;
    esac
}

# Pull compose service image(s) and, on failure, explain the ACTUAL cause
# instead of blaming "docker login". Handles the classic WSL breakage where
# ~/.docker/config.json points 'credsStore' at a Windows .exe that can't run in
# Linux — for a public image that's not an auth problem, so it offers to fix it.
# Usage: docker_pull_with_diagnosis <compose pull args…>   (e.g. odoo)
docker_pull_with_diagnosis() {
    local tmp rc out
    tmp="$(mktemp 2>/dev/null || echo "/tmp/ephem-pull.$$")"
    docker compose pull "$@" 2>&1 | tee "$tmp"
    rc=${PIPESTATUS[0]}
    out="$(cat "$tmp" 2>/dev/null)"; rm -f "$tmp"
    [ "$rc" -eq 0 ] && return 0

    echo ""
    # ── Broken credential helper (not an auth problem for a public image) ──
    if printf '%s' "$out" | grep -qiE "error getting credentials|resolve credential|docker-credential-[a-z.]*: (exec format error|not found|no such file|executable file not found)|exec format error"; then
        echo -e "  ${YELLOW}!${NC} This is NOT a login problem — borrs/ephem is public. Docker's"
        echo "    credential helper is misconfigured (common in WSL: ~/.docker/config.json"
        echo "    sets 'credsStore' to a Windows .exe that can't run inside Linux)."
        local cfg="$HOME/.docker/config.json"
        if [ -f "$cfg" ] && grep -qE '"credsStore"|"credHelpers"' "$cfg" 2>/dev/null; then
            read -p "    Fix it now (back up config.json, drop the credential helper, retry)? [Y/n]: " FIXCRED
            if [[ ! "${FIXCRED:-Y}" =~ ^[Nn]$ ]]; then
                cp "$cfg" "$cfg.bak" 2>/dev/null || true
                if command -v python3 >/dev/null 2>&1; then
                    python3 - "$cfg" <<'PY'
import json, sys
p = sys.argv[1]
try:
    d = json.load(open(p))
except Exception:
    d = {}
d.pop('credsStore', None); d.pop('credHelpers', None)
json.dump(d, open(p, 'w'), indent=2)
PY
                else
                    sed -i.sedbak '/"credsStore"/d; /"credHelpers"/d' "$cfg" 2>/dev/null || true
                fi
                echo -e "    ${GREEN}✓${NC} Credential helper removed (backup: $cfg.bak). Retrying…"
                if docker compose pull "$@"; then
                    return 0
                fi
                echo -e "    ${RED}✗${NC} Still failing after the fix — see output above."
                return 1
            fi
        fi
        echo "    Manual fix: remove the \"credsStore\" line from ~/.docker/config.json"
        echo "    (or re-enable WSL interop), then try again."
        return 1
    fi
    # ── Genuine auth failure → THIS is when to log in (private image) ──
    if printf '%s' "$out" | grep -qiE "unauthorized|authentication required|access to the resource is denied|denied: |forbidden|pull access denied"; then
        echo -e "  ${YELLOW}!${NC} The registry denied access. If the image is private, log in first:"
        echo "        docker login"
        echo "    then try again. (The public borrs/ephem image needs no login.)"
        return 1
    fi
    # ── Network / DNS ──
    if printf '%s' "$out" | grep -qiE "no such host|lookup .*: | timeout|temporary failure|connection refused|network is unreachable|TLS handshake|i/o timeout"; then
        echo -e "  ${YELLOW}!${NC} Looks like a network problem reaching Docker Hub — check your"
        echo "    internet connection / proxy / VPN, then try again."
        return 1
    fi
    echo -e "  ${YELLOW}!${NC} Pull failed — see the output above for the cause."
    return 1
}

dev_update_image() {
    echo -e "${CYAN}${BOLD}Update / repair app image${NC}"
    echo ""
    echo "  Fixes a wrong-architecture image (e.g. amd64 pulled on an Apple Silicon"
    echo "  Mac), then pulls the latest borrs/ephem:latest."
    echo ""
    # Detect & offer to fix a forced platform / stale wrong-arch cached image.
    ensure_native_image_arch
    echo ""
    read -p "  Pull the latest app image now? [Y/n]: " PULL_NOW
    if [[ "${PULL_NOW:-Y}" =~ ^[Nn]$ ]]; then
        echo "  Skipped."
        return 0
    fi
    echo "  Pulling borrs/ephem:latest (this may take a few minutes)…"
    if docker_pull_with_diagnosis odoo; then
        echo -e "  ${GREEN}✓${NC} Image up to date. Apply it:  docker compose up -d"
    fi
}

dev_multi_instance() {
    echo -e "${CYAN}${BOLD}Multi-instance dev — run several Odoo servers side by side${NC}"
    echo ""
    echo "  Runs N Odoo containers sharing ONE Postgres, each with its own:"
    echo "    • port            (8010, 8020, 8030, …)"
    echo "    • custom-addons   (odca<name>/)"
    echo "    • config + DB     (odoo-<name>.conf, database ephem_<name>)"
    echo ""
    echo "  This is separate from the single-instance stack. Examples:"
    echo "    bash scripts/dev-instances.sh up 1 2 3"
    echo "    bash scripts/dev-instances.sh up a:18_national_dev b:16_national_dev c"
    echo "    bash scripts/dev-instances.sh status   # ports + URLs"
    echo "    bash scripts/dev-instances.sh down     # stop (keep data)"
    echo ""
    read -p "  Start instances now? Enter names (space-separated) or blank for '1 2 3', or 'n' to skip: " MI
    case "${MI:-}" in
        n|N) echo "  Skipped." ;;
        "")  bash scripts/dev-instances.sh up 1 2 3 ;;
        *)   bash scripts/dev-instances.sh up $MI ;;
    esac
}

dev_fetch_branch() {
    echo -e "${CYAN}${BOLD}Fetch & switch to a remote branch${NC}"
    echo ""
    echo "  Use this when a teammate created a new branch upstream and your"
    echo "  local clone doesn't see it yet (common after a --single-branch clone)."
    echo ""
    read -p "  Repo folder [custom-addons]: " REPO
    REPO="${REPO:-custom-addons}"
    read -p "  Branch name on origin (e.g. 18_national_dev_new): " BR
    if [ -z "${BR:-}" ]; then
        echo "  Cancelled — no branch name given."
        return 0
    fi
    if [ ! -d "$REPO/.git" ]; then
        echo ""
        echo -e "${YELLOW}!${NC} '$REPO' is not a git repository — cloning fresh from origin."
        if [ -e "$REPO" ] && [ -n "$(ls -A "$REPO" 2>/dev/null)" ]; then
            read -p "  '$REPO' exists and is not empty. Delete it and clone fresh? [y/N]: " CONF
            if [[ ! "${CONF:-N}" =~ ^[Yy]$ ]]; then
                echo "  Cancelled."
                return 0
            fi
            rm -rf "$REPO"
        elif [ -e "$REPO" ]; then
            rm -rf "$REPO"
        fi
        echo ""
        echo "  Cloning git@github.com:borse/ePHEM.git (branch: $BR) into $REPO..."
        if git clone git@github.com:borse/ePHEM.git \
               --branch "$BR" \
               --single-branch \
               "$REPO" \
               --progress; then
            echo -e "${GREEN}✓${NC} $REPO cloned (branch: $BR)"
        else
            echo -e "${RED}✗${NC} Clone failed — does branch '$BR' exist on origin, and is your SSH key authorized?"
            return 1
        fi
        return 0
    fi
    echo ""
    echo "  In $REPO, running:"
    echo "    git config remote.origin.fetch \"+refs/heads/*:refs/remotes/origin/*\""
    echo "    git fetch origin $BR"
    echo "    git switch $BR"
    echo ""
    (
        cd "$REPO" || exit 1
        git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
        if ! git fetch origin "$BR"; then
            echo ""
            echo -e "${RED}✗${NC} Fetch failed — does branch '$BR' exist on origin?"
            echo "    git ls-remote --heads origin | grep $BR"
            exit 1
        fi
        git switch "$BR"
    ) && echo -e "${GREEN}✓${NC} $REPO now on branch '$BR'"
}

# Sanitise an instance name into the folder/service-safe form dev-instances.sh uses.
san_name() { printf '%s' "$1" | tr -c 'a-zA-Z0-9_-' '_'; }

multi_switch_branch() {
    # $1 = dir, $2 = branch. Widen the fetch refspec (single-branch clones only
    # track one branch), fetch that branch, then switch/checkout to it.
    local dir="$1" branch="$2"
    (
        cd "$dir" || exit 1
        git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
        git fetch origin "$branch" || exit 1
        git switch "$branch" 2>/dev/null || git checkout "$branch"
    )
}

prepare_multi_addons() {
    # $1 = branch, remaining args = instance names.
    #
    # Downloads ePHEM ONCE into the first instance's odca dir, then copies that
    # folder (including its .git) to the other instances — so the branch is
    # cloned a single time, not once per instance.
    #
    # On a re-run where a dir already has .git, it fetches + switches to the
    # requested branch instead of copying. That's why we keep .git around: the
    # second time you pick a branch it's an incremental fetch, not a full clone.
    local branch="$1"; shift
    local repo="git@github.com:borse/ePHEM.git"
    local first="" first_dir="" name dir

    echo ""
    echo -e "${CYAN}${BOLD}Preparing custom-addons for each instance (branch: $branch)${NC}"
    echo ""

    for raw in "$@"; do
        name=$(san_name "$raw")
        dir="odca$name"

        if [ -z "$first" ]; then
            first="$name"; first_dir="$dir"
            if [ -d "$dir/.git" ]; then
                echo -e "  ${CYAN}↻${NC} $dir exists — fetching & switching to '$branch'…"
                if ! multi_switch_branch "$dir" "$branch"; then
                    echo -e "  ${RED}✗${NC} Could not switch $dir to '$branch'."
                    echo "     Check the branch name and your SSH access to borse/ePHEM."
                    return 1
                fi
            else
                echo -e "  ${CYAN}⬇${NC} Cloning ePHEM ($branch) into $dir (one download for all instances)…"
                rm -rf "$dir"
                if ! git clone "$repo" --branch "$branch" --single-branch "$dir" --progress; then
                    echo -e "  ${RED}✗${NC} Clone failed — does branch '$branch' exist, and is your SSH key authorized?"
                    rm -rf "$dir"
                    return 1
                fi
            fi
            echo -e "  ${GREEN}✓${NC} $dir ready (branch: $branch)"
            continue
        fi

        # Subsequent instances: reuse the first clone.
        if [ -d "$dir/.git" ]; then
            echo -e "  ${CYAN}↻${NC} $dir exists — fetching & switching to '$branch'…"
            if multi_switch_branch "$dir" "$branch"; then
                echo -e "  ${GREEN}✓${NC} $dir ready (branch: $branch)"
            else
                echo -e "  ${YELLOW}!${NC} $dir could not switch to '$branch' — leaving it as-is."
            fi
        else
            echo -e "  ${CYAN}⧉${NC} Copying $first_dir → $dir (no re-download)…"
            rm -rf "$dir"
            cp -a "$first_dir" "$dir"
            echo -e "  ${GREEN}✓${NC} $dir ready (copied from $first_dir, branch: $branch)"
        fi
    done
}

select_instance_layout() {
    # Sets DEV_LAYOUT to "single" or "multi". Auto-detects an existing
    # multi-instance setup so re-running setup doesn't silently clobber it.
    echo ""
    echo -e "${BOLD}Are you running a single Odoo or multiple Odoos side by side?${NC}"
    echo ""
    local default_choice=1 default_label="single-instance"
    if [ -f docker-compose.dev-multi.yml ] && [ -f .dev-instances ] && [ -s .dev-instances ]; then
        default_choice=2
        default_label="multi-instance (detected: $(tr '\n' ' ' < .dev-instances | sed 's/ *$//'))"
    fi
    echo "  1) Single-instance — one Odoo on :8069"
    echo "  2) Multi-instance  — several Odoos on :8010, :8020, …  (scripts/dev-instances.sh)"
    echo ""
    echo "  Detected default: ${default_label}"
    read -p "Choose [1-2] (default: $default_choice): " LAYOUT_CHOICE
    case "${LAYOUT_CHOICE:-$default_choice}" in
        2) DEV_LAYOUT="multi" ;;
        *) DEV_LAYOUT="single" ;;
    esac
}

dev_preflight_menu() {
    read -p "Have you already set up the ePHEM dev environment on this machine before? [y/N]: " ALREADY_SETUP
    echo ""
    if [[ ! "${ALREADY_SETUP:-N}" =~ ^[Yy]$ ]]; then
        echo -e "${CYAN}First-time setup — continuing with installation…${NC}"
        echo "  (Re-run this script later to access the developer menu:"
        echo "   prereq checks, doctor, multi-instance, etc.)"
        return 0
    fi
    echo "Welcome back. Use the menu below, or choose 'Continue' to re-run setup."
    while true; do
        echo ""
        echo -e "${BOLD}Developer pre-flight menu${NC}"
        echo "  1) View relevant commands"
        echo "  2) Suggest commands (based on current state)"
        echo "  3) Open GitHub README / docs"
        echo "  4) Prerequisite check (docker, compose, git, ssh)"
        echo "  5) Container status / health"
        echo "  6) Doctor — scan logs for common errors"
        echo "  7) Reset / clean environment (keeps custom-addons)"
        echo "  8) Multi-instance dev — run several Odoo side by side"
        echo "  9) Fetch & switch to a remote branch (custom-addons or other)"
        echo " 10) Update / repair app image (re-pull latest, fix Mac architecture)"
        echo " 11) Continue with setup"
        echo " 12) Exit"
        echo ""
        read -p "Choose [1-12] (default: 11): " PRE
        echo ""
        case "${PRE:-11}" in
            1) dev_cheatsheet || true ;;
            2) dev_suggest || true ;;
            3) dev_readme || true ;;
            4) dev_prereq_check || true ;;
            5) dev_status || true ;;
            6) dev_doctor || true ;;
            7) dev_reset || true ;;
            8) dev_multi_instance || true ;;
            9) dev_fetch_branch || true ;;
            10) dev_update_image || true ;;
            11) echo -e "${CYAN}Continuing with setup…${NC}"; break ;;
            12) echo "Exiting. Re-run anytime: bash setup.sh"; exit 0 ;;
            *) echo -e "${YELLOW}!${NC} Invalid choice — pick 1-12." ;;
        esac
    done
}

echo ""
echo "========================================="
echo "  ePHEM Setup"
echo "========================================="
echo ""
echo "What are you setting up?"
echo ""
echo -e "  ${BOLD}1)${NC} ${GREEN}Server deploy${NC}     — Production or staging server"
echo -e "  ${BOLD}2)${NC} ${YELLOW}Demo / Evaluate${NC}   — Try ePHEM locally (no development)"
echo -e "  ${BOLD}3)${NC} ${CYAN}Developer${NC}         — I'm a collaborator; I want to edit addons and use PyCharm"
echo ""
read -p "Choose [1-3]: " MODE_CHOICE

case "${MODE_CHOICE:-}" in
    1) MODE="server" ;;
    2) MODE="demo" ;;
    3) MODE="developer" ;;
    *)
        echo -e "${RED}✗${NC} Invalid choice. Run the script again and choose 1, 2, or 3."
        exit 1
        ;;
esac

echo ""
echo "─────────────────────────────────────────"

# ── Prerequisite: make sure Docker is installed, running, and has Compose v2 ──
# (Offers to install it on Linux/Mac; guides + waits on WSL/Windows.) Runs before
# the developer block because multi-instance dev uses Docker inside that block.
ensure_docker_ready

echo "─────────────────────────────────────────"
DEV_MODE=false

# ══════════════════════════════════════════════
# DEVELOPER MODE
# ══════════════════════════════════════════════
if [ "$MODE" = "developer" ]; then
    echo -e "${CYAN}${BOLD}Developer mode${NC}"
    echo ""
    echo "This mode:"
    echo "  • Clones ePHEM addons using YOUR personal GitHub SSH key"
    echo "  • Mounts custom-addons as read-write (live editing)"
    echo "  • Uses debug settings in odoo.conf (workers=0, log_level=debug)"
    echo ""
    echo "Prerequisite: your SSH key must be added to your GitHub account"
    echo "and you must be a collaborator on borse/ePHEM."
    echo ""

    # Pre-flight hub: commands, diagnostics, reset — before any install steps.
    dev_preflight_menu
    echo ""

    # Ask single vs multi BEFORE any single-instance work — so re-running
    # setup against an existing multi-instance stack doesn't clobber it.
    select_instance_layout

    if [ "$DEV_LAYOUT" = "multi" ]; then
        echo ""
        echo -e "${CYAN}${BOLD}Multi-instance mode${NC}"
        echo ""
        echo "  Single-instance steps (override file, odoo.conf, custom-addons/, "
        echo "  single 'docker compose up -d') will be SKIPPED — they would fight"
        echo "  the multi-instance stack. Delegating to scripts/dev-instances.sh."
        echo ""

        # ── Ensure .env exists (self-contained — no single-instance run needed) ──
        # Multi-instance is local dev, so we auto-generate passwords the same way
        # demo/developer single-instance mode does, instead of bailing out.
        if [ ! -f .env ]; then
            echo "  .env not found — creating it from .env.example (local dev passwords)…"
            cp .env.example .env
            AUTO_PG_PASS=$(openssl rand -hex 12 2>/dev/null || echo "ephem-$(date +%s)")
            if sed --version 2>/dev/null | grep -q GNU; then
                sed -i "s/CHANGE_ME/$AUTO_PG_PASS/g" .env
            else
                sed -i '' "s/CHANGE_ME/$AUTO_PG_PASS/g" .env
            fi
            echo -e "  ${GREEN}✓${NC} .env created with auto-generated passwords"
        elif grep -q "CHANGE_ME" .env; then
            echo "  .env has placeholder passwords — auto-filling them for local dev…"
            AUTO_PG_PASS=$(openssl rand -hex 12 2>/dev/null || echo "ephem-$(date +%s)")
            if sed --version 2>/dev/null | grep -q GNU; then
                sed -i "s/CHANGE_ME/$AUTO_PG_PASS/g" .env
            else
                sed -i '' "s/CHANGE_ME/$AUTO_PG_PASS/g" .env
            fi
            echo -e "  ${GREEN}✓${NC} Passwords auto-set (fine for local use)"
        else
            echo -e "  ${GREEN}✓${NC} .env already present"
        fi

        # ── Instance names (default 1 2 3 → odca1, odca2, odca3) ────────────
        echo ""
        if [ -f .dev-instances ] && [ -s .dev-instances ]; then
            INSTANCE_NAMES=$(tr '\n' ' ' < .dev-instances | sed 's/ *$//')
            echo "  Configured instances: ${BOLD}${INSTANCE_NAMES}${NC}"
            read -p "  Use these names? [Y/n]: " USE_EXISTING
            if [[ "${USE_EXISTING:-Y}" =~ ^[Nn]$ ]]; then
                read -p "  Enter instance names (space-separated, default: 1 2 3): " INSTANCE_NAMES
                INSTANCE_NAMES="${INSTANCE_NAMES:-1 2 3}"
            fi
        else
            read -p "  Enter instance names (space-separated, default: 1 2 3): " INSTANCE_NAMES
            INSTANCE_NAMES="${INSTANCE_NAMES:-1 2 3}"
        fi
        # The branch is chosen once below and applied to every instance, so drop
        # any legacy 'name:branch' suffix a user might type.
        CLEAN_NAMES=""
        for _spec in $INSTANCE_NAMES; do
            CLEAN_NAMES="$CLEAN_NAMES ${_spec%%:*}"
        done
        INSTANCE_NAMES="$(echo "$CLEAN_NAMES" | xargs)"

        # ── Verify GitHub SSH access before we try to clone addons ──────────
        echo ""
        echo "  Verifying your GitHub SSH access…"
        SSH_TEST="$(ssh -T git@github.com 2>&1 || true)"
        if echo "$SSH_TEST" | grep -qi "successfully authenticated"; then
            GH_USER=$(printf '%s' "$SSH_TEST" | sed -n 's/.*Hi \([^!]*\)!.*/\1/p' | head -1)
            [ -n "$GH_USER" ] || GH_USER="you"
            echo -e "  ${GREEN}✓${NC} Authenticated as: ${BOLD}$GH_USER${NC}"
        else
            echo -e "  ${RED}✗${NC} Could not authenticate with GitHub via SSH."
            github_ssh_help
            exit 1
        fi

        # ── Choose the branch (downloaded once, shared by all instances) ────
        echo ""
        echo "  Which branch do you want to work on?"
        echo "  It is downloaded once into odca${INSTANCE_NAMES%% *} and copied to the other instances."
        echo ""
        echo "    1) 18_national_dev    — Odoo 18 development (recommended)"
        echo "    2) 18_national_master — Odoo 18 stable"
        echo "    3) 16_national_dev    — Odoo 16 development"
        echo "    4) 16_national_master — Odoo 16 stable"
        echo "    5) Other (type a branch name)"
        echo ""
        read -p "  Choose [1-5] (default: 1): " BRANCH_CHOICE
        case "${BRANCH_CHOICE:-1}" in
            2) BRANCH="18_national_master" ;;
            3) BRANCH="16_national_dev" ;;
            4) BRANCH="16_national_master" ;;
            5) read -p "  Branch name on origin: " BRANCH; BRANCH="${BRANCH:-18_national_dev}" ;;
            *) BRANCH="18_national_dev" ;;
        esac

        # ── Clone once, copy to the rest (or fetch+switch if already cloned) ─
        # shellcheck disable=SC2086  # word-splitting on INSTANCE_NAMES is intentional
        if ! prepare_multi_addons "$BRANCH" $INSTANCE_NAMES; then
            echo -e "${RED}✗${NC} Could not prepare custom-addons — see the error above. Aborting."
            exit 1
        fi

        echo ""
        ensure_native_image_arch
        read -p "  Pull latest Odoo image first? [y/N]: " PULL_IMG
        if [[ "${PULL_IMG:-N}" =~ ^[Yy]$ ]]; then
            echo "  Pulling borrs/ephem:latest (this may take a few minutes)..."
            if [ -f docker-compose.dev-multi.yml ]; then
                docker compose -f docker-compose.yml -f docker-compose.dev-multi.yml pull \
                    || docker compose pull odoo || true
            else
                docker compose pull odoo || true
            fi
        fi

        # ── Sync Postgres 'odoo' password to current .env BEFORE refreshing ──
        # Why this matters: the Postgres data volume persists the password set
        # when 'odoo' was first created. If .env's POSTGRES_PASSWORD has changed
        # since (e.g. via the auto-fix in single-instance mode, or a manual
        # edit), the recreated odoo_<name> containers will hit:
        #   FATAL: password authentication failed for user "odoo"
        # `docker compose exec` uses the unix socket inside the db container,
        # which is `trust` auth — no password needed — so this works even when
        # the cached one is wrong.
        echo ""
        echo "Ensuring Postgres is up so we can sync the 'odoo' password to current .env…"
        docker compose up -d db >/dev/null 2>&1 || true

        echo "Waiting for database…"
        DB_READY=0
        for i in $(seq 1 30); do
            if docker compose exec -T db pg_isready -U odoo -q 2>/dev/null; then
                DB_READY=1
                break
            fi
            sleep 2
        done

        if [ "$DB_READY" -eq 1 ]; then
            ENV_PASSWORD=$(grep "^POSTGRES_PASSWORD=" .env | cut -d'=' -f2- | xargs)
            if [ -n "$ENV_PASSWORD" ]; then
                if docker compose exec -T db psql -U odoo -d postgres \
                       -c "ALTER USER odoo WITH PASSWORD '${ENV_PASSWORD}';" >/dev/null 2>&1; then
                    echo -e "${GREEN}✓${NC} Postgres 'odoo' password synced to current .env"
                else
                    echo -e "${YELLOW}!${NC} Could not sync password automatically. If you still get"
                    echo "    'password authentication failed for user \"odoo\"' after this,"
                    echo "    your db volume was likely initialized with a different POSTGRES_USER."
                    echo "    Last-resort reset (DESTROYS dev databases):  docker compose down -v"
                fi
            else
                echo -e "${YELLOW}!${NC} POSTGRES_PASSWORD is empty in .env — skipping password sync."
            fi
        else
            echo -e "${YELLOW}!${NC} db did not become ready — skipping password sync."
            echo "    Inspect: docker compose logs db"
        fi

        echo ""
        echo "Refreshing multi-instance stack against current .env (recreates containers"
        echo "so they pick up POSTGRES_PASSWORD changes)…"
        echo ""
        # shellcheck disable=SC2086  # word-splitting on INSTANCE_NAMES is intentional
        bash scripts/dev-instances.sh up $INSTANCE_NAMES

        # ── Post-check: catch the auth error if any instance is still broken ──
        echo ""
        echo "Verifying multi-instance database connection…"
        sleep 5
        FIRST_NAME=$(printf '%s' "$INSTANCE_NAMES" | awk '{print $1}' | cut -d':' -f1 | tr -c 'a-zA-Z0-9_-' '_')
        if [ -n "$FIRST_NAME" ]; then
            INST_LOG=$(docker compose -f docker-compose.yml -f docker-compose.dev-multi.yml \
                       logs --tail=20 "odoo_$FIRST_NAME" 2>&1 || true)
            if echo "$INST_LOG" | grep -q "password authentication failed"; then
                echo -e "${YELLOW}! odoo_$FIRST_NAME still reports auth failure. Forcing a recreate of all instances…${NC}"
                # shellcheck disable=SC2086
                for SPEC in $INSTANCE_NAMES; do
                    SAN=$(printf '%s' "$SPEC" | cut -d':' -f1 | tr -c 'a-zA-Z0-9_-' '_')
                    docker compose -f docker-compose.yml -f docker-compose.dev-multi.yml \
                        up -d --force-recreate --no-deps "odoo_$SAN" 2>/dev/null || true
                done
                sleep 3
                INST_LOG=$(docker compose -f docker-compose.yml -f docker-compose.dev-multi.yml \
                           logs --tail=10 "odoo_$FIRST_NAME" 2>&1 || true)
                if echo "$INST_LOG" | grep -q "password authentication failed"; then
                    echo -e "${RED}✗${NC} Auth still failing. Run:"
                    echo "    bash scripts/dev-logs.sh $FIRST_NAME"
                    echo "  Or as a last resort (DESTROYS dev DBs):"
                    echo "    docker compose down -v"
                else
                    echo -e "${GREEN}✓${NC} odoo_$FIRST_NAME is connecting now."
                fi
            else
                echo -e "${GREEN}✓${NC} odoo_$FIRST_NAME is connecting to the database."
            fi
        fi

        echo ""
        echo -e "${GREEN}✓ Multi-instance dev is up.${NC}"
        echo ""
        echo "  Instances created:"
        _pi=0
        for _n in $INSTANCE_NAMES; do
            _port=$(( 8010 + 10 * _pi ))
            echo "    • odca$_n  →  http://localhost:$_port   (db: ephem_$_n, addons: odca$_n/)"
            _pi=$(( _pi + 1 ))
        done
        echo ""
        echo "  Manage the stack:"
        echo "    Status:               bash scripts/dev-instances.sh status"
        echo "    Restart + tail one:   bash scripts/dev-logs.sh <name>"
        echo "    Stop (keep data):     bash scripts/dev-instances.sh down"
        echo ""
        echo -e "  ${CYAN}Fetch a different branch later?${NC} Just re-run this script and choose"
        echo "  multi-instance again — the git history is already on disk, so it's an"
        echo "  incremental fetch, not a fresh download."

        # ── PyCharm handoff — copy/paste-ready run-config guidance ──────────
        # PyCharm runs on the host GUI. Under WSL that's Windows, which reaches
        # WSL files via a \\wsl.localhost UNC path; on macOS/Linux PyCharm sees
        # the same POSIX paths this script already uses.
        _addons_dir="$PWD/odca${INSTANCE_NAMES%% *}"
        if is_wsl; then
            SCRIPT_DISPLAY="\\\\wsl.localhost\\${WSL_DISTRO_NAME:-Ubuntu}$(printf '%s' "$PWD/scripts/dev-logs.sh" | tr '/' '\\')"
            ADDONS_DISPLAY="\\\\wsl.localhost\\${WSL_DISTRO_NAME:-Ubuntu}$(printf '%s' "$_addons_dir" | tr '/' '\\')"
            PYCHARM_HOST="Windows"
        else
            SCRIPT_DISPLAY="$PWD/scripts/dev-logs.sh"
            ADDONS_DISPLAY="$_addons_dir"
            PYCHARM_HOST="this machine"
        fi
        echo ""
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${CYAN}${BOLD}  NEXT: drive each instance from PyCharm${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -e "  ${BOLD}1) Install PyCharm${NC} (Professional recommended) on ${PYCHARM_HOST}:"
        echo "       https://www.jetbrains.com/pycharm/download/"
        echo ""
        echo -e "  ${BOLD}2) Open your addons folder${NC} (File → Open), for example:"
        echo "       $ADDONS_DISPLAY"
        echo ""
        echo -e "  ${BOLD}3) Add one Shell Script run configuration per instance${NC}"
        echo "       Run → Edit Configurations → + → Shell Script → 'Script path'"
        echo ""
        echo "       Use this SAME script path for every configuration:"
        echo ""
        printf '         %b%s%b\n' "$BOLD$GREEN" "$SCRIPT_DISPLAY" "$NC"
        echo ""
        echo "       Set 'Script options' differently per instance. Each one restarts"
        echo "       the instance, updates a module, then tails its colored logs:"
        echo ""
        for _n in $INSTANCE_NAMES; do
            printf "         odca%-4s →  Script options:  ${BOLD}%s -u eoc_signals${NC}\n" "$_n" "$_n"
        done
        echo ""
        echo "       The first word is the instance name; the rest is forwarded to Odoo:"
        echo -e "         • Plain restart + logs:     ${BOLD}${INSTANCE_NAMES%% *}${NC}"
        echo -e "         • Update one module:        ${BOLD}${INSTANCE_NAMES%% *} -u eoc_signals${NC}"
        echo -e "         • Update several modules:   ${BOLD}${INSTANCE_NAMES%% *} -u eoc_base,eoc_incident_management${NC}"
        echo -e "         • Install a new module:     ${BOLD}${INSTANCE_NAMES%% *} -i my_new_module${NC}"
        echo ""
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        exit 0
    fi

    echo "Verifying your GitHub SSH access..."
    SSH_TEST="$(ssh -T git@github.com 2>&1 || true)"

    if echo "$SSH_TEST" | grep -qi "successfully authenticated"; then
        GH_USER=$(printf '%s' "$SSH_TEST" | sed -n 's/.*Hi \([^!]*\)!.*/\1/p' | head -1)
        [ -n "$GH_USER" ] || GH_USER="you"
        echo -e "${GREEN}✓${NC} Authenticated as: ${BOLD}$GH_USER${NC}"
    else
        echo -e "${RED}✗${NC} Could not authenticate with GitHub via SSH."
        github_ssh_help
        exit 1
    fi

    if [ -d "custom-addons/.git" ]; then
        echo -e "${GREEN}✓${NC} custom-addons/ already cloned"
        echo "  Checking for updates..."
        cd custom-addons
        if ! git fetch origin 2>/dev/null; then
            echo -e "${YELLOW}!${NC} Could not reach remote — skipping update check (no internet or SSH issue)"
            ADDONS_BEHIND=0
        else
            ADDONS_BEHIND=$(git rev-list HEAD..origin/$(git branch --show-current) --count 2>/dev/null || echo "0")
        fi
        cd ..

        if [ "$ADDONS_BEHIND" -gt 0 ] 2>/dev/null; then
            echo -e "${YELLOW}!${NC} custom-addons/ is $ADDONS_BEHIND commit(s) behind"
            echo ""
            read -p "  Pull updates now? [y/N]: " PULL_ADDONS
            if [[ "${PULL_ADDONS:-N}" =~ ^[Yy]$ ]]; then
                cd custom-addons && git pull && cd ..
                echo -e "${GREEN}✓${NC} custom-addons/ updated ($ADDONS_BEHIND commit(s))"
                ADDONS_UPDATED=true
            else
                echo "  Skipped — addons not updated"
                ADDONS_UPDATED=false
            fi
        else
            echo -e "${GREEN}✓${NC} custom-addons/ is up to date"
            ADDONS_UPDATED=false
        fi
    else
        echo ""
        echo "Which branch do you want to work on?"
        echo ""
        echo "  1) 18_national_dev    — Odoo 18 development (recommended)"
        echo "  2) 18_national_master — Odoo 18 stable"
        echo "  3) 16_national_dev    — Odoo 16 development"
        echo "  4) 16_national_master — Odoo 16 stable"
        echo ""
        read -p "Choose [1-4] (default: 1): " BRANCH_CHOICE
        case "${BRANCH_CHOICE:-1}" in
            2) BRANCH="18_national_master" ;;
            3) BRANCH="16_national_dev" ;;
            4) BRANCH="16_national_master" ;;
            *) BRANCH="18_national_dev" ;;
        esac

        echo ""
        echo "Cloning ePHEM addons (branch: $BRANCH)..."
        rm -rf custom-addons
        if git clone git@github.com:borse/ePHEM.git \
               --branch "$BRANCH" \
               --single-branch \
               custom-addons \
               --progress; then
            echo -e "${GREEN}✓${NC} custom-addons/ cloned (branch: $BRANCH)"
        else
            echo -e "${RED}✗${NC} Clone failed. Cleaning up..."
            rm -rf custom-addons
            echo ""
            echo "  Things to check:"
            echo "    • Is your SSH key added to GitHub? ssh -T git@github.com"
            echo "    • Do you have collaborator access on borse/ePHEM?"
            echo "    • Is there a network/firewall issue?"
            exit 1
        fi
    fi

    # Write developer docker-compose override
    cat > docker-compose.override.yml << 'OVERRIDE'
# Developer override — generated by setup.sh
# Do NOT commit this file. Add it to .gitignore.
services:
  odoo:
    environment:
      # Force Odoo's colored log formatter even without a TTY, so `docker logs`
      # (and PyCharm's console / a Shell Script run config) shows INFO/WARNING/
      # ERROR in color — no extra IDE plugin needed.
      ODOO_PY_COLORS: "1"
    volumes:
      - odoo-data:/var/lib/odoo
      - ./custom-addons:/mnt/extra-addons:rw
      - ./odoo.conf:/etc/odoo/odoo.conf
    ports:
      - "8069:8069"
      - "8072:8072"

  # Nginx is not needed for local development — Odoo is exposed directly above.
  # Disabling it avoids conflicts with port 80 already in use on the machine.
  nginx:
    profiles:
      - disabled

  # Certbot has nothing to do without nginx
  certbot:
    profiles:
      - disabled
OVERRIDE
    echo -e "${GREEN}✓${NC} docker-compose.override.yml created (nginx disabled, Odoo on :8069)"

    DEV_MODE=true
fi

ERRORS=0
ADDONS_UPDATED=false
IMAGE_UPDATED=false

# ── Docker ────────────────────────────────────
# Already fully verified above by ensure_docker_ready (installed + daemon
# reachable + Compose v2), which exits with platform-specific guidance if not.

# ── Check .env ────────────────────────────────
if [ -f ".env" ]; then
    echo -e "${GREEN}✓${NC} .env file exists"

    if grep -q "CHANGE_ME" .env; then
        if [ "$MODE" = "demo" ] || [ "$MODE" = "developer" ]; then
            echo -e "${YELLOW}!${NC} .env has CHANGE_ME — auto-generating passwords for local use..."
            AUTO_PG_PASS=$(openssl rand -hex 12 2>/dev/null || echo "ephem-$(date +%s)")
            if sed --version 2>/dev/null | grep -q GNU; then
                sed -i "s/CHANGE_ME/$AUTO_PG_PASS/g" .env
            else
                sed -i '' "s/CHANGE_ME/$AUTO_PG_PASS/g" .env
            fi
            echo -e "${GREEN}✓${NC} Passwords auto-set (fine for local use)"
        else
            echo -e "${RED}✗${NC} .env still has CHANGE_ME passwords."
            echo ""
            echo "  Edit your .env file and set real values:"
            echo ""
            echo "    nano .env"
            echo ""
            echo "  Required:"
            echo "    POSTGRES_PASSWORD   — strong password for the database"
            echo "    ODOO_ADMIN_PASSWORD — master password for Odoo"
            echo ""
            echo "  Recommended for production:"
            echo "    DOMAIN    — your domain name  (e.g. ephem.health.gov.xx)"
            echo "    SSL_EMAIL — your email address (e.g. admin@health.gov.xx)"
            echo ""
            echo "  Then run:  bash setup.sh"
            echo ""
            ERRORS=$((ERRORS + 1))
        fi
    else
        echo -e "${GREEN}✓${NC} Passwords have been set"
    fi

    ENV_DOMAIN=$(grep "^DOMAIN=" .env | cut -d'=' -f2- | xargs)
    if [ -n "$ENV_DOMAIN" ]; then
        echo -e "${GREEN}✓${NC} Domain: $ENV_DOMAIN"
    else
        SERVER_IP=$(get_server_ip)
        if [ "$MODE" = "server" ]; then
            echo -e "${YELLOW}!${NC} No domain set — running in IP mode ($SERVER_IP)"
            echo ""
            echo "  For production, set a domain in .env:"
            echo "    DOMAIN=$SERVER_IP   →   DOMAIN=ephem.health.gov.xx"
            echo "    SSL_EMAIL=          →   SSL_EMAIL=admin@health.gov.xx"
            echo ""
            echo "  Then run: bash setup.sh"
            echo "  And after that: bash scripts/ssl-setup.sh ephem.health.gov.xx admin@health.gov.xx"
            echo ""
        else
            echo -e "${GREEN}✓${NC} Local mode — will run on http://localhost"
        fi
    fi
else
    echo -e "${YELLOW}!${NC} .env not found — creating from template..."
    cp .env.example .env

    if [ "$MODE" = "demo" ] || [ "$MODE" = "developer" ]; then
        AUTO_PG_PASS=$(openssl rand -hex 12 2>/dev/null || echo "ephem-$(date +%s)")
        if sed --version 2>/dev/null | grep -q GNU; then
            sed -i "s/CHANGE_ME/$AUTO_PG_PASS/g" .env
        else
            sed -i '' "s/CHANGE_ME/$AUTO_PG_PASS/g" .env
        fi
        echo -e "${GREEN}✓${NC} .env created with auto-generated passwords"
    else
        echo ""
        echo -e "${YELLOW}  .env has been created from the template.${NC}"
        echo "  You must edit it before setup can continue."
        echo ""
        echo "    nano .env"
        echo ""
        echo "  Required:"
        echo "    POSTGRES_PASSWORD   — strong password for the database"
        echo "    ODOO_ADMIN_PASSWORD — master password for Odoo"
        echo ""
        echo "  Recommended for production:"
        echo "    DOMAIN    — your domain name  (e.g. ephem.health.gov.xx)"
        echo "    SSL_EMAIL — your email address (e.g. admin@health.gov.xx)"
        echo ""
        echo "  To generate strong passwords:"
        echo "    openssl rand -base64 24"
        echo ""
        echo "  Once done, run:  bash setup.sh"
        echo ""
        ERRORS=$((ERRORS + 1))
    fi
fi

# ── Nginx config ─────────────────────────────
if [ ! -f "nginx/active.conf" ] && [ -f "nginx/default.conf" ]; then
    cp nginx/default.conf nginx/active.conf
    echo -e "${GREEN}✓${NC} nginx/active.conf created from template"
elif [ -f "nginx/active.conf" ]; then
    echo -e "${GREEN}✓${NC} nginx/active.conf exists"
elif [ ! -f "nginx/default.conf" ] && [ "$MODE" = "server" ]; then
    echo -e "${RED}✗${NC} nginx/default.conf is missing. Re-clone the repo."
    ERRORS=$((ERRORS + 1))
fi

# ── Custom addons (server/demo — deploy key flow) ──
if [ "$MODE" != "developer" ]; then
    if [ -d "custom-addons/.git" ]; then
        echo -e "${GREEN}✓${NC} custom-addons/ has modules (Git repo)"
        echo "  Checking for updates..."
        cd custom-addons
        if ! git fetch origin 2>/dev/null; then
            echo -e "${YELLOW}!${NC} Could not reach remote — skipping update check (no internet or SSH issue)"
            ADDONS_BEHIND=0
        else
            ADDONS_BEHIND=$(git rev-list HEAD..origin/$(git branch --show-current) --count 2>/dev/null || echo "0")
        fi
        cd ..

        if [ "$ADDONS_BEHIND" -gt 0 ] 2>/dev/null; then
            echo -e "${YELLOW}!${NC} custom-addons/ is $ADDONS_BEHIND commit(s) behind"
            echo ""
            read -p "  Pull updates now? [y/N]: " PULL_ADDONS
            if [[ "${PULL_ADDONS:-N}" =~ ^[Yy]$ ]]; then
                cd custom-addons && git pull && cd ..
                echo -e "${GREEN}✓${NC} custom-addons/ updated ($ADDONS_BEHIND commit(s))"
                ADDONS_UPDATED=true
            else
                echo "  Skipped — addons not updated"
                ADDONS_UPDATED=false
            fi
        else
            echo -e "${GREEN}✓${NC} custom-addons/ is up to date"
            ADDONS_UPDATED=false
        fi
    else
        echo -e "${YELLOW}!${NC} Downloading ePHEM modules..."
        rm -rf custom-addons

        DEPLOY_KEY="$HOME/.ssh/ephem_addons_deploy"
        ADDONS_CLONED=false

        if [ -f "$DEPLOY_KEY" ]; then
            echo "  Testing deploy key access..."
            SSH_OUTPUT="$(ssh -T git@github-ephem-addons 2>&1 || true)"

            if echo "$SSH_OUTPUT" | grep -qi "successfully authenticated"; then
                echo -e "  ${GREEN}✓${NC} Access granted"
                echo "  Cloning ePHEM modules..."
                echo ""
                if GIT_SSH_COMMAND="ssh -o ConnectTimeout=30" \
                   git clone git@github-ephem-addons:borse/ePHEM.git \
                       --depth 1 \
                       --branch 18_national_dev \
                       --single-branch \
                       custom-addons \
                       --progress; then
                    echo ""
                    echo -e "${GREEN}✓${NC} ePHEM modules downloaded"
                    ADDONS_CLONED=true
                else
                    echo -e "${RED}✗${NC} Clone failed. Cleaning up partial clone..."
                    rm -rf custom-addons
                    mkdir -p custom-addons
                fi
            else
                echo -e "${YELLOW}!${NC} Deploy key exists but access not yet granted"
                mkdir -p custom-addons
            fi
        fi

        if [ "$ADDONS_CLONED" = false ]; then
            mkdir -p custom-addons
            NEEDS_ADDONS_ACCESS=true

            if [ ! -f "$DEPLOY_KEY" ]; then
                echo -e "${YELLOW}!${NC} Generating deploy key for ePHEM addons..."
                mkdir -p ~/.ssh
                chmod 700 ~/.ssh
                SERVER_NAME=$(hostname 2>/dev/null || echo "unknown")
                ssh-keygen -t ed25519 -f "$DEPLOY_KEY" -C "ephem-addons-${SERVER_NAME}" -N "" -q
                chmod 600 "$DEPLOY_KEY"
                chmod 644 "${DEPLOY_KEY}.pub"

                if ! grep -q "github-ephem-addons" "$HOME/.ssh/config" 2>/dev/null; then
                    cat >> "$HOME/.ssh/config" << SSHEOF

Host github-ephem-addons
    HostName github.com
    User git
    IdentityFile $DEPLOY_KEY
    IdentitiesOnly yes
SSHEOF
                    chmod 600 "$HOME/.ssh/config"
                fi

                if ! grep -q "github.com" ~/.ssh/known_hosts 2>/dev/null; then
                    ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null
                    chmod 644 ~/.ssh/known_hosts
                fi
                echo -e "${GREEN}✓${NC} Deploy key generated"
            else
                echo -e "${YELLOW}!${NC} Deploy key exists — waiting for ePHEM team to grant access"
            fi
        fi
    fi
fi

# ── Scripts ───────────────────────────────────
for script in scripts/backup.sh scripts/ssl-setup.sh scripts/add-domain.sh \
              scripts/duplicate-db.sh scripts/update-modules.sh \
              scripts/request-addons-access.sh scripts/clone-addons.sh \
              scripts/dev-instances.sh scripts/dev-logs.sh; do
    [ -f "$script" ] && chmod +x "$script"
done
echo -e "${GREEN}✓${NC} Scripts are executable"

# ── Generate odoo.conf ────────────────────────
if [ -f ".env" ]; then
    if sed --version 2>/dev/null | grep -q GNU; then
        sed -i 's/\r$//' .env
    else
        sed -i '' 's/\r$//' .env
    fi

    ADMIN_PASS=$(grep "^ODOO_ADMIN_PASSWORD=" .env | cut -d'=' -f2- | xargs)
    DB_FILTER=$(grep "^ODOO_DBFILTER=" .env | cut -d'=' -f2- | xargs)
    LIST_DB=$(grep "^ODOO_LIST_DB=" .env | cut -d'=' -f2- | xargs)

    ADMIN_PASS="${ADMIN_PASS:-}"
    LIST_DB="${LIST_DB:-True}"

    if [ -z "$ADMIN_PASS" ] || [ "$ADMIN_PASS" = "CHANGE_ME" ]; then
        ADMIN_PASS=$(openssl rand -base64 16 2>/dev/null || echo "ephem-$(date +%s)")
        echo -e "${YELLOW}!${NC} Generated admin password: $ADMIN_PASS  (save this!)"
    fi

    if [ "$DEV_MODE" = "true" ]; then
        cat > odoo.conf << ODOOEOF
[options]
; Generated by setup.sh (DEVELOPER MODE)
; Re-run: bash setup.sh to regenerate

admin_passwd = $ADMIN_PASS

addons_path = /mnt/extra-addons,/usr/lib/python3/dist-packages/odoo/addons

proxy_mode = False

; workers=0 uses threading mode — required for dev_mode, simpler for local use
workers = 0
max_cron_threads = 1

xmlrpc_port = 8069
gevent_port = 8072

log_level = debug

; dev_mode enables asset reload, tour snippets, etc.
dev_mode = reload,qweb,werkzeug,xml

list_db = True
ODOOEOF
        echo -e "${GREEN}✓${NC} odoo.conf generated (developer: workers=0, log=debug, dev_mode=reload)"
    else
        cat > odoo.conf << ODOOEOF
[options]
; Generated by setup.sh — do not edit manually.
; Change values in .env and re-run: bash setup.sh

admin_passwd = $ADMIN_PASS

addons_path = /mnt/extra-addons,/usr/lib/python3/dist-packages/odoo/addons

proxy_mode = True

workers = 4
max_cron_threads = 1
limit_memory_hard = 2684354560
limit_memory_soft = 2147483648
limit_request = 8192
limit_time_cpu = 600
limit_time_real = 1200

xmlrpc_port = 8069
gevent_port = 8072

log_level = info

list_db = $LIST_DB
ODOOEOF
        echo -e "${GREEN}✓${NC} odoo.conf generated"
    fi

    if [ -n "${DB_FILTER:-}" ]; then
        echo "dbfilter = $DB_FILTER" >> odoo.conf
    fi
fi

mkdir -p backups
echo -e "${GREEN}✓${NC} backups/ directory exists"

# ── Summary ───────────────────────────────────
echo ""
if [ $ERRORS -gt 0 ]; then
    echo -e "${RED}✗ $ERRORS issue(s) found. Fix them and run this script again.${NC}"
    echo ""
    exit 1
fi

echo -e "${GREEN}✓ Everything looks good!${NC}"
echo ""
echo "Starting ePHEM..."
echo ""

# ── Ensure the native-architecture image is used ──
ensure_native_image_arch

# ── Check for Docker image updates ──────────
echo ""
echo "Checking for Docker image updates..."
CURRENT_IMAGE=$(docker inspect --format='{{.Id}}' borrs/ephem:latest 2>/dev/null || echo "none")

if [ "$CURRENT_IMAGE" = "none" ]; then
    # Image not present at all — will be pulled automatically by docker compose
    echo -e "${GREEN}✓${NC} Image will be downloaded on first run"
    IMAGE_UPDATED=false
else
    read -p "  Check for Odoo image updates? [y/N]: " CHECK_IMAGE
    if [[ "${CHECK_IMAGE:-N}" =~ ^[Yy]$ ]]; then
        echo "  Pulling latest image (this may take a few minutes)..."
        if docker compose pull odoo 2>&1 | grep -q "Downloaded newer image\|Pull complete"; then
            echo -e "${GREEN}✓${NC} Image updated"
            IMAGE_UPDATED=true
        else
            echo -e "${GREEN}✓${NC} Image is already up to date"
            IMAGE_UPDATED=false
        fi
    else
        echo "  Skipped — image not updated"
        IMAGE_UPDATED=false
    fi
fi

# ── Write demo override (no nginx) ───────────
# Demo and developer both run locally — nginx is not needed and conflicts
# with port 80 if another web server is already running on this machine.
if [ "$MODE" = "demo" ]; then
    cat > docker-compose.override.yml << 'OVERRIDE'
# Demo override — generated by setup.sh
# Disables nginx so Odoo is accessible directly on :8069.
services:
  odoo:
    ports:
      - "8069:8069"
      - "8072:8072"

  nginx:
    profiles:
      - disabled

  certbot:
    profiles:
      - disabled
OVERRIDE
    echo -e "${GREEN}✓${NC} docker-compose.override.yml created (nginx disabled, Odoo on :8069)"
fi

docker compose up -d
docker compose restart odoo
echo ""

echo "Waiting for database..."
for i in $(seq 1 30); do
    if docker compose exec -T db pg_isready -U odoo -q 2>/dev/null; then
        echo -e "${GREEN}✓${NC} Database is ready"
        break
    fi
    if [ $i -eq 30 ]; then
        echo -e "${RED}✗${NC} Database did not start in time. Run: docker compose logs db"
        exit 1
    fi
    sleep 2
done

echo "Checking database connection..."
sleep 5

ODOO_LOG=$(docker compose logs --tail=5 odoo 2>&1)
if echo "$ODOO_LOG" | grep -q "password authentication failed"; then
    echo ""
    echo -e "${YELLOW}! Database password mismatch. Fixing automatically...${NC}"
    ENV_PASSWORD=$(grep "^POSTGRES_PASSWORD=" .env | cut -d'=' -f2-)
    docker compose exec -T db psql -U odoo -d postgres -c "ALTER USER odoo WITH PASSWORD '${ENV_PASSWORD}';" 2>/dev/null && {
        echo -e "${GREEN}✓${NC} Password synced. Restarting Odoo..."
        docker compose restart odoo
        sleep 5
    } || {
        echo -e "${RED}✗${NC} Could not fix automatically."
        echo "  To reset: docker compose down -v && docker compose up -d"
        exit 1
    }
fi

echo ""
echo "========================================="
echo ""
docker compose ps
echo ""
echo "========================================="
echo -e "${GREEN}ePHEM is running!${NC}"
echo ""

ENV_DOMAIN=$(grep "^DOMAIN=" .env 2>/dev/null | cut -d'=' -f2- | xargs)
ENV_EMAIL=$(grep "^SSL_EMAIL=" .env 2>/dev/null | cut -d'=' -f2- | xargs)
SERVER_IP=$(get_server_ip)

if [ "$MODE" = "developer" ]; then
    # PyCharm runs on the host GUI. Under WSL that's Windows, which reaches the
    # script via a \\wsl.localhost path; on macOS/Linux it's the POSIX path.
    if is_wsl; then
        SCRIPT_DISPLAY="\\\\wsl.localhost\\${WSL_DISTRO_NAME:-Ubuntu}$(printf '%s' "$PWD/scripts/dev-logs.sh" | tr '/' '\\')"
        ADDONS_DISPLAY="\\\\wsl.localhost\\${WSL_DISTRO_NAME:-Ubuntu}$(printf '%s' "$PWD/custom-addons" | tr '/' '\\')"
        PYCHARM_HOST="Windows"
    else
        SCRIPT_DISPLAY="$PWD/scripts/dev-logs.sh"
        ADDONS_DISPLAY="$PWD/custom-addons"
        PYCHARM_HOST="this machine"
    fi

    echo "ePHEM is ready for development:  http://localhost:8069"
    echo ""
    echo -e "${CYAN}${BOLD}One-click Odoo restart + logs in PyCharm${NC}"
    echo ""
    echo "  scripts/dev-logs.sh restarts Odoo and streams its colored logs. Bind it to a"
    echo "  green ▶ so your edit → restart → test loop becomes one click."
    echo ""
    echo "  One-time PyCharm setup:"
    echo "    1. Install PyCharm on ${PYCHARM_HOST} (Community Edition is free)."
    echo "    2. File → Open → this folder:"
    printf '         %b%s%b\n' "$BOLD" "$ADDONS_DISPLAY" "$NC"
    echo "    3. Run → Edit Configurations → + → Shell Script:"
    echo "         • Name:            Odoo: restart + logs"
    printf '         • Script path:     %b%s%b\n' "$BOLD$GREEN" "$SCRIPT_DISPLAY" "$NC"
    echo "         • Script options:  (leave empty = just restart + tail logs)"
    echo "    4. Apply → OK, then click the green ▶."
    echo ""
    echo "  Put commands in 'Script options' to update/install modules before the restart."
    echo "  Single-instance needs your database name via -d (the DB you created in the browser):"
    echo -e "         ${BOLD}(empty)${NC}                                     restart + tail logs"
    echo -e "         ${BOLD}-u eoc_signals -d yourdb${NC}                    update one module in \"yourdb\""
    echo -e "         ${BOLD}-u eoc_base,eoc_incident_management -d yourdb${NC}   update several at once"
    echo -e "         ${BOLD}-i my_new_module -d yourdb${NC}                  install a new module"
    echo "    Make one run config per scenario so each is its own labelled ▶."
    echo ""
    echo "  Same thing from the terminal:"
    echo "         bash scripts/dev-logs.sh"
    echo "         bash scripts/dev-logs.sh -u eoc_signals -d yourdb"
    echo ""
    echo -e "${CYAN}${BOLD}Need several Odoo servers at once?${NC}"
    echo "  Re-run:  bash setup.sh → 3 (Developer) → y (already set up) → 8 (Multi-instance)"
    echo "  Each instance then gets its own ▶ — same script path, its name as the first option:"
    echo -e "         ${BOLD}1${NC}                                      restart + tail instance 1"
    echo -e "         ${BOLD}1 -u eoc_signals${NC}                       update a module on instance 1"

elif [ "$MODE" = "demo" ]; then
    DEMO_ADMIN_PASS=$(grep "^ODOO_ADMIN_PASSWORD=" .env | cut -d'=' -f2- | xargs)
    echo "Your demo is available at:"
    echo "  http://localhost:8069       (on this machine)"
    if [ -n "$SERVER_IP" ] && [ "$SERVER_IP" != "127.0.0.1" ]; then
        echo "  http://$SERVER_IP:8069   (from other devices on the network)"
    fi
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  First time? Create a database:${NC}"
    echo ""
    echo "  1. Open the URL above in your browser"
    echo "  2. Fill in the database creation form"
    echo "  3. When asked for Master Password, use:"
    echo ""
    echo -e "     ${BOLD}${GREEN}$DEMO_ADMIN_PASS${NC}"
    echo ""
    echo "  (This is your ODOO_ADMIN_PASSWORD from .env)"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "When you're done:"
    echo "  docker compose down      — stop (keep data)"
    echo "  docker compose down -v   — stop and wipe all data"

else
    if grep -v "^#" nginx/active.conf 2>/dev/null | grep -q "ssl_certificate"; then
        DOMAIN=$(grep "server_name" nginx/active.conf | grep -v "#" | head -1 | sed 's/.*server_name//;s/;//' | xargs | awk '{print $1}')
        echo "Your site is available at:"
        echo "  https://$DOMAIN"
        echo ""
        echo "Next steps:"
        echo "  • Go to https://$DOMAIN/web/database/manager to create your database"
        echo "  • Set up automatic backups: crontab -e"
    elif [ -n "$ENV_DOMAIN" ]; then
        echo "Your site is available at:"
        echo "  http://$ENV_DOMAIN  (HTTP only)"
        echo ""
        echo "Next step — enable HTTPS:"
        echo "  bash scripts/ssl-setup.sh $ENV_DOMAIN $ENV_EMAIL"
        echo ""
        echo "Then run setup again to apply any remaining config:"
        echo "  bash setup.sh"
    else
        echo "Your site is available at:"
        echo "  http://$SERVER_IP  (no domain, no SSL)"
        echo ""
        echo -e "${YELLOW}For production, set a domain and SSL:${NC}"
        echo "  1. Edit .env:"
        echo "       DOMAIN=$SERVER_IP   →   DOMAIN=ephem.health.gov.xx"
        echo "       SSL_EMAIL=          →   SSL_EMAIL=admin@health.gov.xx"
        echo ""
        echo "  2. Run setup again:"
        echo "       bash setup.sh"
        echo ""
        echo "  3. Then set up SSL:"
        echo "       bash scripts/ssl-setup.sh ephem.health.gov.xx admin@health.gov.xx"
    fi
fi

echo ""

# ── Deploy key notice (server/demo only) ─────
if [ "${NEEDS_ADDONS_ACCESS:-false}" = true ] && [ -f "$HOME/.ssh/ephem_addons_deploy.pub" ]; then
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  ePHEM CUSTOM MODULES — ACTION REQUIRED${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "  ePHEM is running, but without custom modules."
    echo "  To get the ePHEM modules, send the key below to:"
    echo ""
    echo -e "  ${BOLD}${CYAN}ephem@who.int${NC}"
    echo ""
    echo -e "  ${BOLD}Include your country/server name in the email subject.${NC}"
    echo ""
    echo -e "  ${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${GREEN}║  COPY EVERYTHING BETWEEN THE LINES AND PASTE IN YOUR EMAIL  ║${NC}"
    echo -e "  ${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${CYAN}$(cat $HOME/.ssh/ephem_addons_deploy.pub)${NC}"
    echo ""
    echo -e "  ${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${GREEN}║  END OF KEY                                                 ║${NC}"
    echo -e "  ${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  Once the ePHEM team confirms your key has been added, re-run:"
    echo ""
    echo -e "  ${BOLD}bash setup.sh${NC}"
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
fi
# ── Module update warning ─────────────────────
# Show this if addons were updated — make it impossible to miss
if [ "${ADDONS_UPDATED:-false}" = true ]; then
    echo ""
    echo -e "${RED}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                                                                  ║${NC}"
    echo -e "${RED}║   ⚠  ACTION REQUIRED — ODOO MODULE UPDATE NEEDED                ║${NC}"
    echo -e "${RED}║                                                                  ║${NC}"
    echo -e "${RED}╠══════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${RED}║                                                                  ║${NC}"
    echo -e "${RED}║  The custom addon code was updated, but Odoo's database has      ║${NC}"
    echo -e "${RED}║  not been told about the changes yet.                            ║${NC}"
    echo -e "${RED}║                                                                  ║${NC}"
    echo -e "${RED}║  Without running the module update, you may see:                 ║${NC}"
    echo -e "${RED}║    • Missing fields or buttons                                   ║${NC}"
    echo -e "${RED}║    • Old views not reflecting new changes                        ║${NC}"
    echo -e "${RED}║    • Errors on pages that used to work                           ║${NC}"
    echo -e "${RED}║                                                                  ║${NC}"
    echo -e "${RED}╠══════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${RED}║                                                                  ║${NC}"
    echo -e "${RED}║  Run this now:                                                   ║${NC}"
    echo -e "${RED}║                                                                  ║${NC}"
    echo -e "${RED}║    bash scripts/update-modules.sh                                ║${NC}"
    echo -e "${RED}║                                                                  ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
fi