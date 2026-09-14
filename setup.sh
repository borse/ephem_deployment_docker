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

# Shared with manage.sh and the scripts/ tools: the mode record (EPHEM_MODE in
# .env), compose files per mode, the instance roster. scripts/stack-lib.sh
EPHEM_ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/stack-lib.sh
source "$EPHEM_ROOT/scripts/stack-lib.sh"
ephem_mode    # what this checkout is now (from .env, else from the files)

# Single modes mount addons/ and the ePHEM clone lives inside it as
# addons/$CORE_NAME (ePHEM-core). Repositories added later from manage.sh →
# Addons sit next to it. dev-multi uses odcaN/ the same way.
ADDONS_PARENT="$EPHEM_ROOT/addons"
CORE_TARGET="$ADDONS_PARENT/$CORE_NAME"
MIGRATED_SINGLE=false      # the old custom-addons/ layout was moved this run

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

# Developer mode: make sure .env says where the dev Odoo ports listen.
# 0.0.0.0 (every interface) by default so a phone or a colleague on the LAN
# can open the instance; a developer who wants it local sets 127.0.0.1.
ensure_dev_bind_host() {
    [ -f .env ] || return 0
    if ! grep -q "^DEV_BIND_HOST=" .env; then
        printf '\n# Developer mode: where the dev Odoo ports listen. 0.0.0.0 = every interface\n# (phones and colleagues on the LAN can open it), 127.0.0.1 = this machine only.\nDEV_BIND_HOST=0.0.0.0\n' >> .env
        echo -e "  ${GREEN}✓${NC} DEV_BIND_HOST=0.0.0.0 added to .env (dev ports open on the LAN; set 127.0.0.1 to keep them local)"
    fi
}

# The address other devices on the LAN use. Under WSL2 the ports are published
# by Docker Desktop on the Windows host, so its adapter address is the right one.
get_lan_ip() {
    local ip=""
    if command -v ipconfig.exe >/dev/null 2>&1; then
        ip=$(ipconfig.exe 2>/dev/null | tr -d '\r' | awk '/IPv4/ {print $NF}' \
             | grep -vE '^(127\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[01])\.)' | head -n1) || true
    fi
    [ -n "$ip" ] || ip=$(get_server_ip)
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

# Every git source inside PARENT (addons/): fetch, say how far behind each
# is, offer ONE pull for all of them. Sets ADDONS_UPDATED=true when anything
# was pulled (the module update warning at the end depends on it).
check_addons_updates() {  # check_addons_updates PARENT
    local parent="$1" s dir cur behind
    local -a behind_dirs=()
    ADDONS_UPDATED=false
    while IFS= read -r s; do
        [ -n "$s" ] || continue
        dir="$parent/$s"
        if [ ! -d "$dir/.git" ]; then
            echo -e "${GREEN}✓${NC} addons/$s (a folder, not a git clone: nothing to fetch)"
            continue
        fi
        cur=$(git -C "$dir" branch --show-current 2>/dev/null) || cur=""
        if [ -z "$cur" ] || ! git -C "$dir" fetch origin 2>/dev/null; then
            echo -e "${YELLOW}!${NC} addons/$s: could not reach origin — skipping the update check (no internet or SSH issue)"
            continue
        fi
        behind=$(git -C "$dir" rev-list HEAD..origin/"$cur" --count 2>/dev/null) || behind=0
        if [ "${behind:-0}" -gt 0 ] 2>/dev/null; then
            echo -e "${YELLOW}!${NC} addons/$s is $behind commit(s) behind on '$cur'"
            behind_dirs+=("$dir")
        else
            echo -e "${GREEN}✓${NC} addons/$s is up to date ('$cur')"
        fi
    done < <(addons_sources "$parent")
    [ "${#behind_dirs[@]}" -eq 0 ] && return 0
    echo ""
    read -p "  Pull updates now? [y/N]: " PULL_ADDONS
    if [[ "${PULL_ADDONS:-N}" =~ ^[Yy]$ ]]; then
        for dir in "${behind_dirs[@]}"; do
            if git -C "$dir" pull --ff-only; then
                echo -e "${GREEN}✓${NC} addons/$(basename "$dir") updated"
                ADDONS_UPDATED=true
            else
                echo -e "${RED}✗${NC} addons/$(basename "$dir"): pull failed (diverged or local changes): resolve it in manage.sh → Addons"
            fi
        done
    else
        echo "  Skipped — addons not updated"
    fi
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

# ── Multi-instance addons folders ─────────────
# (The architecture guard and the pull diagnosis live in scripts/stack-lib.sh,
# shared with manage.sh.)

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

# "1 2" → "odca1 odca2"
odca_names() { local n out=""; for n in $1; do out="$out odca$n"; done; printf '%s' "${out# }"; }

prepare_multi_addons() {
    # $1 = branch, remaining args = every instance name.
    #
    # odcaN/ is the mounted parent; the ePHEM clone goes to odcaN/$CORE_NAME.
    # An instance with no clone yet gets one: the first by a single git
    # clone, the rest by copying that clone (.git included) and switching
    # the copy, so the branch is downloaded once. A clone that is already
    # there is never touched here: it may be on its own branch on purpose,
    # and switching is manage.sh → Addons, per instance.
    local branch="$1"; shift
    local repo; repo=$(git_url_ssh github.com "$CORE_REPO")
    local source_core="" name dir core cur

    echo ""
    echo -e "${CYAN}${BOLD}Preparing $CORE_NAME per instance (branch: $branch)${NC}"
    echo ""

    for raw in "$@"; do
        name=$(san_name "$raw")
        dir="odca$name"; core="$dir/$CORE_NAME"

        if [ -d "$core/.git" ]; then
            [ -z "$source_core" ] && source_core="$core"
            cur=$(git -C "$core" branch --show-current 2>/dev/null) || cur=""
            echo -e "  ${GREEN}·${NC} $core kept as it is (branch: ${cur:-(detached)})"
            continue
        fi

        # No clone here. A folder with files but no .git is someone's work,
        # not ours to replace.
        if [ -n "$(ls -A "$core" 2>/dev/null)" ]; then
            echo -e "  ${YELLOW}!${NC} $core has files but is not a git clone — left as it is."
            continue
        fi
        mkdir -p "$dir"
        if [ -z "$source_core" ]; then
            echo -e "  ${CYAN}⬇${NC} Cloning ePHEM ($branch) into $core (one download for all instances)…"
            rm -rf "$core"
            if ! git clone "$repo" --branch "$branch" --single-branch "$core" --progress; then
                echo -e "  ${RED}✗${NC} Clone failed — does branch '$branch' exist, and is your SSH key authorized?"
                rm -rf "$core"
                return 1
            fi
            source_core="$core"
        else
            echo -e "  ${CYAN}⧉${NC} Copying $source_core → $core (no re-download)…"
            rm -rf "$core"
            cp -a "$source_core" "$core"
            cur=$(git -C "$core" branch --show-current 2>/dev/null) || cur=""
            if [ "$cur" != "$branch" ] && ! multi_switch_branch "$core" "$branch"; then
                echo -e "  ${YELLOW}!${NC} $core copied, but could not switch it to '$branch' — left on '${cur:-(detached)}'."
                continue
            fi
        fi
        echo -e "  ${GREEN}✓${NC} $core ready (branch: $branch)"
    done
}

select_instance_layout() {
    # Sets DEV_LAYOUT to "single" or "multi". Auto-detects an existing
    # multi-instance setup so re-running setup doesn't silently clobber it.
    echo ""
    echo -e "${BOLD}Are you running a single Odoo or multiple Odoos side by side?${NC}"
    echo ""
    local default_choice=1 default_label="single-instance"
    if [ "$EPHEM_MODE" = dev-multi ] || \
       { [ -f docker-compose.dev-multi.yml ] && [ -f .dev-instances ] && [ -s .dev-instances ]; }; then
        default_choice=2
        default_label="multi-instance (instances: $(tr '\n' ' ' < .dev-instances 2>/dev/null | sed 's/ *$//'))"
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

# Returning developers: day-to-day work is manage.sh's job, so offer it
# before the install steps run again. Continuing is safe (every step keeps
# data), it is just the long way round for a status check or a branch switch.
dev_returning_gate() {
    read -p "Have you already set up the ePHEM dev environment on this machine before? [y/N]: " ALREADY_SETUP
    echo ""
    if [[ ! "${ALREADY_SETUP:-N}" =~ ^[Yy]$ ]]; then
        echo -e "${CYAN}First-time setup — continuing with installation…${NC}"
        return 0
    fi
    echo "Welcome back. Day-to-day work lives in the management menu: status, addons"
    echo "and branches, restart + logs, module updates, doctor, databases, stack, app image."
    echo ""
    echo "  1) Open the management menu now          (bash manage.sh)"
    echo "  2) Re-run setup: refresh containers, add instances, change the layout"
    echo "  3) Exit"
    echo ""
    read -p "Choose [1-3] (default: 1): " R
    case "${R:-1}" in
        2) echo -e "${CYAN}Continuing with setup…${NC}" ;;
        3) echo "Exiting. Re-run anytime: bash setup.sh"; exit 0 ;;
        *) exec bash manage.sh ;;
    esac
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
# A checkout that has been set up before defaults to what it already is.
DEFAULT_MODE_CHOICE=""
if [ -f .env ]; then
    case "$EPHEM_MODE" in
        server)        DEFAULT_MODE_CHOICE=1 ;;
        demo)          DEFAULT_MODE_CHOICE=2 ;;
        dev|dev-multi) DEFAULT_MODE_CHOICE=3 ;;
    esac
fi
if [ -n "$DEFAULT_MODE_CHOICE" ]; then
    if [ "$EPHEM_MODE_SOURCE" = env ]; then
        echo -e "  This checkout is set up as: ${BOLD}$(ephem_mode_label)${NC}  (EPHEM_MODE in .env)"
    else
        echo -e "  From the files here this checkout looks like: ${BOLD}$(ephem_mode_label)${NC}"
    fi
    read -p "Choose [1-3] (Enter keeps $DEFAULT_MODE_CHOICE): " MODE_CHOICE
    MODE_CHOICE="${MODE_CHOICE:-$DEFAULT_MODE_CHOICE}"
else
    read -p "Choose [1-3]: " MODE_CHOICE
fi

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
    echo "  • Clones ePHEM into addons/$CORE_NAME using YOUR personal GitHub SSH key"
    echo "  • Mounts addons/ read-write (live editing); other repositories can be"
    echo "    added next to $CORE_NAME later from manage.sh → Addons"
    echo "  • Uses debug settings in odoo.conf (workers=0, log_level=debug)"
    echo ""
    echo "Prerequisite: your SSH key must be added to your GitHub account"
    echo "and you must be a collaborator on borse/ePHEM."
    echo ""

    # Returning developers get sent to manage.sh before any install step runs.
    dev_returning_gate
    echo ""

    # Ask single vs multi BEFORE any single-instance work — so re-running
    # setup against an existing multi-instance stack doesn't clobber it.
    select_instance_layout

    if [ "$DEV_LAYOUT" = "multi" ]; then
        echo ""
        echo -e "${CYAN}${BOLD}Multi-instance mode${NC}"
        echo ""
        echo "  Single-instance steps (override file, odoo.conf, addons/, "
        echo "  single 'docker compose up -d') will be SKIPPED — they would fight"
        echo "  the multi-instance stack. Delegating to scripts/dev-instances.sh."
        echo ""
        # The single-instance override must not linger: a plain `docker compose`
        # would still load it and start ephem-app next to the instances.
        retire_single_override || true

        # ── Ensure .env exists (self-contained — no single-instance run needed) ──
        # Multi-instance is local dev, so we auto-generate passwords the same way
        # demo/developer single-instance mode does, instead of bailing out.
        # The Postgres password stays random; the Odoo master password is pinned
        # to a memorable dev value because you type it every time Odoo asks.
        DEV_ADMIN_PASSWORD="9090"
        if [ ! -f .env ]; then
            echo "  .env not found — creating it from .env.example (local dev passwords)…"
            cp .env.example .env
            AUTO_PG_PASS=$(openssl rand -hex 12 2>/dev/null || echo "ephem-$(date +%s)")
            if sed --version 2>/dev/null | grep -q GNU; then
                sed -i "s/CHANGE_ME/$AUTO_PG_PASS/g" .env
                sed -i "s/^ODOO_ADMIN_PASSWORD=.*/ODOO_ADMIN_PASSWORD=$DEV_ADMIN_PASSWORD/" .env
            else
                sed -i '' "s/CHANGE_ME/$AUTO_PG_PASS/g" .env
                sed -i '' "s/^ODOO_ADMIN_PASSWORD=.*/ODOO_ADMIN_PASSWORD=$DEV_ADMIN_PASSWORD/" .env
            fi
            echo -e "  ${GREEN}✓${NC} .env created (Odoo master password: ${BOLD}$DEV_ADMIN_PASSWORD${NC})"
        elif grep -q "CHANGE_ME" .env; then
            echo "  .env has placeholder passwords — auto-filling them for local dev…"
            AUTO_PG_PASS=$(openssl rand -hex 12 2>/dev/null || echo "ephem-$(date +%s)")
            if sed --version 2>/dev/null | grep -q GNU; then
                sed -i "s/CHANGE_ME/$AUTO_PG_PASS/g" .env
                sed -i "s/^ODOO_ADMIN_PASSWORD=.*/ODOO_ADMIN_PASSWORD=$DEV_ADMIN_PASSWORD/" .env
            else
                sed -i '' "s/CHANGE_ME/$AUTO_PG_PASS/g" .env
                sed -i '' "s/^ODOO_ADMIN_PASSWORD=.*/ODOO_ADMIN_PASSWORD=$DEV_ADMIN_PASSWORD/" .env
            fi
            echo -e "  ${GREEN}✓${NC} Passwords auto-set (Odoo master password: ${BOLD}$DEV_ADMIN_PASSWORD${NC})"
        else
            # .env exists with real passwords — still pin the Odoo master
            # password to the dev default, otherwise a password generated by an
            # earlier demo/single-instance run would end up in every regenerated
            # odoo-<name>.conf. Local-only stacks: memorable beats random.
            CUR_ADMIN=$(grep "^ODOO_ADMIN_PASSWORD=" .env | cut -d'=' -f2- | xargs || true)
            if [ "$CUR_ADMIN" = "$DEV_ADMIN_PASSWORD" ]; then
                echo -e "  ${GREEN}✓${NC} .env already present (Odoo master password: ${BOLD}$DEV_ADMIN_PASSWORD${NC})"
            else
                if sed --version 2>/dev/null | grep -q GNU; then
                    sed -i "s/^ODOO_ADMIN_PASSWORD=.*/ODOO_ADMIN_PASSWORD=$DEV_ADMIN_PASSWORD/" .env
                else
                    sed -i '' "s/^ODOO_ADMIN_PASSWORD=.*/ODOO_ADMIN_PASSWORD=$DEV_ADMIN_PASSWORD/" .env
                fi
                echo -e "  ${GREEN}✓${NC} .env updated — Odoo master password pinned to dev default: ${BOLD}$DEV_ADMIN_PASSWORD${NC}"
            fi
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
        ensure_github_ssh || true    # loads a passphrase-protected key once, so clone/fetch below do not ask
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

        # ── Addons folders ──────────────────────────────────────────────────
        # odcaN/ is the mounted folder and the ePHEM clone is odcaN/$CORE_NAME.
        # A folder from before that layout (odcaN/ was the clone itself) is
        # moved down first; the stack refresh below recreates its container.
        # First run: every odcaN/ is empty and all of them get the clone.
        # Re-run: a clone that is already there is left exactly as it is
        # (pull and branch switching are manage.sh → Addons, per instance);
        # only an instance with no clone yet gets one.
        echo ""
        for _n in $INSTANCE_NAMES; do
            _n=$(san_name "$_n")
            addons_migrate_legacy "odca$_n" || true
        done
        MISSING=""
        for _n in $INSTANCE_NAMES; do
            _n=$(san_name "$_n")
            [ -d "odca$_n/$CORE_NAME/.git" ] || MISSING="$MISSING $_n"
        done
        MISSING="${MISSING# }"
        if [ -z "$MISSING" ]; then
            echo -e "  ${GREEN}✓${NC} Every instance already has ePHEM checked out (odcaN/$CORE_NAME); the folders are left as they are."
            echo "     Pull, switch a branch or add a repository per instance:  bash manage.sh → Addons"
        else
            echo ""
            echo "  Which branch do you want to work on?"
            if [ "$(printf '%s\n' $MISSING | wc -l)" -eq "$(printf '%s\n' $INSTANCE_NAMES | wc -l)" ]; then
                echo "  It is downloaded once into odca${MISSING%% *}/$CORE_NAME and copied to the other instances."
            else
                echo "  It goes to $(odca_names "$MISSING"), copied from an existing clone (no re-download)."
            fi
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

            # ── Clone once, copy to the rest ────────────────────────────────
            # shellcheck disable=SC2086  # word-splitting on INSTANCE_NAMES is intentional
            if ! prepare_multi_addons "$BRANCH" $INSTANCE_NAMES; then
                echo -e "${RED}✗${NC} Could not prepare $CORE_NAME — see the error above. Aborting."
                exit 1
            fi
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
            if docker compose exec -T db pg_isready -U odoo -q </dev/null 2>/dev/null; then
                DB_READY=1
                break
            fi
            sleep 2
        done

        if [ "$DB_READY" -eq 1 ]; then
            ENV_PASSWORD=$(grep "^POSTGRES_PASSWORD=" .env | cut -d'=' -f2- | xargs)
            if [ -n "$ENV_PASSWORD" ]; then
                if docker compose exec -T db psql -U odoo -d postgres \
                       -c "ALTER USER odoo WITH PASSWORD '${ENV_PASSWORD}';" </dev/null >/dev/null 2>&1; then
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
        ensure_dev_bind_host
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

        # Recorded by dev-instances.sh as well; stated here so it cannot be missed.
        ephem_mode_save dev-multi
        echo ""
        echo -e "${GREEN}✓ Multi-instance dev is up.${NC}   (EPHEM_MODE=dev-multi in .env)"
        echo ""
        echo "  Instances created:"
        _pi=0
        for _n in $INSTANCE_NAMES; do
            _port=$(( 8010 + 10 * _pi ))
            echo "    • odca$_n  →  http://localhost:$_port   (db: ephem_$_n, ePHEM code: odca$_n/$CORE_NAME/)"
            _pi=$(( _pi + 1 ))
        done
        echo ""
        echo "  Manage the stack:"
        echo "    Everything, per instance:  bash manage.sh <name>     (status, addons, restart + logs, modules, doctor)"
        echo "    Status:               bash scripts/dev-instances.sh status"
        echo "    Restart + tail one:   bash scripts/dev-logs.sh <name>"
        echo "    Stop (keep data):     bash scripts/dev-instances.sh down"
        echo ""
        echo -e "  ${CYAN}Everything from here on is bash manage.sh:${NC} it asks which instance,"
        echo "  then pulls or switches that instance's sources alone, adds another"
        echo "  repository next to $CORE_NAME, restarts, updates modules, and changes the"
        echo "  roster. Re-running this script never touches an existing clone."

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
        echo "       (the ePHEM clone is $CORE_NAME/ inside it; repositories added later sit next to it)"
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
    ensure_github_ssh || true    # loads a passphrase-protected key once, so clone/fetch below do not ask
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

    # Installs from before the addons/$CORE_NAME layout: custom-addons/ becomes
    # addons/ and the clone moves into it. The container is recreated below.
    if addons_adopt_single_legacy; then MIGRATED_SINGLE=true; fi

    if [ -d "$CORE_TARGET/.git" ]; then
        echo -e "${GREEN}✓${NC} addons/$CORE_NAME already cloned"
        echo "  Checking for updates..."
        check_addons_updates "$ADDONS_PARENT"
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
        echo "Cloning ePHEM addons (branch: $BRANCH) into addons/$CORE_NAME..."
        mkdir -p "$ADDONS_PARENT"
        rm -rf "$CORE_TARGET"
        if git clone "$(git_url_ssh github.com "$CORE_REPO")" \
               --branch "$BRANCH" \
               --single-branch \
               "$CORE_TARGET" \
               --progress; then
            echo -e "${GREEN}✓${NC} addons/$CORE_NAME cloned (branch: $BRANCH)"
        else
            echo -e "${RED}✗${NC} Clone failed. Cleaning up..."
            rm -rf "$CORE_TARGET"
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
      # addons/ holds ePHEM-core plus any repository added from manage.sh;
      # odoo.conf lists each subfolder in its addons_path.
      - ./addons:/mnt/extra-addons:rw
      - ./odoo.conf:/etc/odoo/odoo.conf
    # Every interface by default (DEV_BIND_HOST in .env), so a phone or a
    # colleague on the same LAN can open the instance. Docker-published ports
    # bypass ufw, so this is raw Odoo (dev config, open db manager) on the
    # network: set DEV_BIND_HOST=127.0.0.1 to keep it on this machine only.
    ports:
      - "${DEV_BIND_HOST:-0.0.0.0}:8069:8069"
      - "${DEV_BIND_HOST:-0.0.0.0}:8072:8072"

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
# addons/ is the mounted folder; the ePHEM clone is addons/$CORE_NAME. Other
# repositories are added next to it later (manage.sh → Addons → Add a
# source, each with its own deploy key). Installs from before that layout
# (custom-addons/ was the clone) are moved; the container is recreated below.
if [ "$MODE" != "developer" ]; then
    if addons_adopt_single_legacy; then MIGRATED_SINGLE=true; fi
    if [ -d "$CORE_TARGET/.git" ]; then
        echo -e "${GREEN}✓${NC} addons/$CORE_NAME has the ePHEM modules (Git repo)"
        echo "  Checking for updates..."
        check_addons_updates "$ADDONS_PARENT"
    else
        echo -e "${YELLOW}!${NC} Downloading ePHEM modules into addons/$CORE_NAME..."
        mkdir -p "$ADDONS_PARENT"
        rm -rf "$CORE_TARGET"

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
                   git clone "$(git_url_ssh github-ephem-addons "$CORE_REPO")" \
                       --depth 1 \
                       --branch 18_national_dev \
                       --single-branch \
                       "$CORE_TARGET" \
                       --progress; then
                    echo ""
                    echo -e "${GREEN}✓${NC} ePHEM modules downloaded"
                    ADDONS_CLONED=true
                else
                    echo -e "${RED}✗${NC} Clone failed. Cleaning up partial clone..."
                    rm -rf "$CORE_TARGET"
                    mkdir -p "$CORE_TARGET"
                fi
            else
                echo -e "${YELLOW}!${NC} Deploy key exists but access not yet granted"
                mkdir -p "$CORE_TARGET"
            fi
        fi

        if [ "$ADDONS_CLONED" = false ]; then
            mkdir -p "$CORE_TARGET"
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
              scripts/remove-domain.sh scripts/split-certs.sh scripts/nginx-lib.sh \
              scripts/duplicate-db.sh scripts/update-modules.sh \
              scripts/request-addons-access.sh scripts/clone-addons.sh \
              scripts/dev-instances.sh scripts/dev-logs.sh; do
    [ -f "$script" ] && chmod +x "$script"
done
echo -e "${GREEN}✓${NC} Scripts are executable"

# ── Generate odoo.conf ────────────────────────
# addons/ must exist before odoo.conf lists what is inside it (and before
# compose mounts it: docker would otherwise create it as root).
mkdir -p "$ADDONS_PARENT"
ADDONS_PATH_LINE=$(addons_path_value "$ADDONS_PARENT")
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

    if [ "$DEV_MODE" = "true" ]; then
        # Local dev: pin the master password to the memorable dev default —
        # the same value dev-instances.sh uses — and keep .env in sync so
        # every tool that reads ODOO_ADMIN_PASSWORD agrees.
        ADMIN_PASS="9090"
        if [ "$(grep "^ODOO_ADMIN_PASSWORD=" .env | cut -d'=' -f2- | xargs)" != "$ADMIN_PASS" ]; then
            if sed --version 2>/dev/null | grep -q GNU; then
                sed -i "s/^ODOO_ADMIN_PASSWORD=.*/ODOO_ADMIN_PASSWORD=$ADMIN_PASS/" .env
            else
                sed -i '' "s/^ODOO_ADMIN_PASSWORD=.*/ODOO_ADMIN_PASSWORD=$ADMIN_PASS/" .env
            fi
        fi
        echo -e "${GREEN}✓${NC} Odoo master password pinned to local dev default: ${BOLD}$ADMIN_PASS${NC}"
        ensure_dev_bind_host
    elif [ -z "$ADMIN_PASS" ] || [ "$ADMIN_PASS" = "CHANGE_ME" ]; then
        ADMIN_PASS=$(openssl rand -base64 16 2>/dev/null || echo "ephem-$(date +%s)")
        echo -e "${YELLOW}!${NC} Generated admin password: $ADMIN_PASS  (save this!)"
    fi

    if [ "$DEV_MODE" = "true" ]; then
        cat > odoo.conf << ODOOEOF
[options]
; Generated by setup.sh (DEVELOPER MODE)
; Re-run: bash setup.sh to regenerate

admin_passwd = $ADMIN_PASS

; One entry per source folder inside addons/ ($CORE_NAME first). Regenerated by
; setup.sh and by manage.sh → Addons whenever a source is added, removed or renamed.
addons_path = $ADDONS_PATH_LINE

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

; One entry per source folder inside addons/ ($CORE_NAME first). Regenerated by
; setup.sh and by manage.sh → Addons whenever a source is added, removed or renamed.
addons_path = $ADDONS_PATH_LINE

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
# Note: on some Docker CLI versions, `docker inspect --format=...` on a
# missing image writes a blank line to stdout before erroring — so
# `$(cmd 2>/dev/null || echo none)` can capture "\nnone" instead of a clean
# "none", failing the equality check below and routing a genuinely fresh
# install into the interactive "check for updates?" prompt. Use `|| true`
# (not `|| echo none`) so the substitution still exits 0 under `set -e`
# without polluting stdout, then fall back with a parameter default — a
# missing image reliably resolves to a clean "none".
echo ""
echo "Checking for Docker image updates..."
CURRENT_IMAGE=$(docker inspect --format='{{.Id}}' "$(stack_image)" 2>/dev/null || true)
CURRENT_IMAGE="${CURRENT_IMAGE:-none}"

if [ "$CURRENT_IMAGE" = "none" ]; then
    # Image not present at all — will be pulled automatically by docker compose
    echo -e "${GREEN}✓${NC} Image will be downloaded on first run"
    IMAGE_UPDATED=false
else
    read -p "  Check for Odoo image updates? [y/N]: " CHECK_IMAGE
    if [[ "${CHECK_IMAGE:-N}" =~ ^[Yy]$ ]]; then
        echo "  Pulling latest image (this may take a few minutes)..."
        # Compared by image id: the pull output is not a stable API, and a
        # failed pull is explained by the helper instead of read as "no update".
        IMAGE_UPDATED=false
        if docker_pull_with_diagnosis odoo; then
            NEW_IMAGE=$(docker inspect --format='{{.Id}}' "$(stack_image)" 2>/dev/null || true)
            if [ "${NEW_IMAGE:-none}" != "$CURRENT_IMAGE" ]; then
                echo -e "${GREEN}✓${NC} Image updated"
                IMAGE_UPDATED=true
            else
                echo -e "${GREEN}✓${NC} Image is already up to date"
            fi
        else
            echo -e "${YELLOW}!${NC} Pull failed (see above); continuing with the image already here."
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

echo "Starting database…"
docker compose up -d db
echo ""

echo "Waiting for database..."
for i in $(seq 1 30); do
    if docker compose exec -T db pg_isready -U odoo -q </dev/null 2>/dev/null; then
        echo -e "${GREEN}✓${NC} Database is ready"
        break
    fi
    if [ $i -eq 30 ]; then
        echo -e "${RED}✗${NC} Database did not start in time. Run: docker compose logs db"
        exit 1
    fi
    sleep 2
done

# ── Sync Postgres 'odoo' password to current .env BEFORE starting odoo ──
# Why this matters: the Postgres data volume persists the password set when
# 'odoo' was first created. If .env's POSTGRES_PASSWORD has changed since
# (regenerated .env, re-cloned repo, switched from/to multi-instance mode),
# odoo will hit "password authentication failed" even though .env looks
# correct. Sync unconditionally, before odoo ever attempts to connect,
# instead of waiting for the failure and grepping logs for it — that races
# against odoo's own retry/backoff and can miss a fast crash loop.
# `docker compose exec` uses the unix socket inside the db container, which
# is `trust` auth — no password needed — so this works even when the
# currently-set password is wrong.
ENV_PASSWORD=$(grep "^POSTGRES_PASSWORD=" .env | cut -d'=' -f2- | xargs)
if [ -n "$ENV_PASSWORD" ]; then
    if docker compose exec -T db psql -U odoo -d postgres \
           -c "ALTER USER odoo WITH PASSWORD '${ENV_PASSWORD}';" </dev/null >/dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} Postgres 'odoo' password synced to current .env"
    else
        echo -e "${YELLOW}!${NC} Could not sync password automatically."
    fi
else
    echo -e "${YELLOW}!${NC} POSTGRES_PASSWORD is empty in .env — skipping password sync."
fi

# ── Least-privilege database role ────────────
# Installs made before August 2026 bootstrapped Postgres with the app's
# 'odoo' role as the cluster SUPERUSER, so a compromised addon could read
# or drop every database. Fresh volumes get an unprivileged role from
# db-init/; existing volumes are migrated here (idempotent, data untouched).
if ! bash scripts/harden-db-role.sh; then
    echo -e "${YELLOW}!${NC} Could not harden the database role automatically."
    echo "   Run it manually later:  bash scripts/harden-db-role.sh"
fi

docker compose up -d
# After the move from custom-addons/ the old container's bind mount still
# shows the folder that was moved (a mount follows the inode, not the path);
# recreate it so /mnt/extra-addons is addons/ and the new addons_path resolves.
if [ "$MIGRATED_SINGLE" = true ] && odoo_mount_stale odoo "$ADDONS_PARENT"; then
    echo "Recreating the Odoo container so it sees addons/$CORE_NAME…"
    docker compose up -d --force-recreate --no-deps odoo
fi
docker compose restart odoo

echo "Checking database connection..."
sleep 5

ODOO_LOG=$(docker compose logs --tail=20 odoo 2>&1)
if echo "$ODOO_LOG" | grep -q "password authentication failed"; then
    echo ""
    echo -e "${RED}✗${NC} Database password mismatch persists after sync."
    echo "  Your db volume was likely initialized with a different POSTGRES_USER."
    echo "  Last-resort reset (DESTROYS dev databases):  docker compose down -v && bash setup.sh"
    exit 1
fi

# ── Server mode: lock down the database manager once databases exist ──
# /web/database/manager can create, drop and download databases and is
# protected only by the master password. Once the site's databases have been
# created there is no reason to leave it enabled.
if [ "$MODE" = "server" ]; then
    LIST_DB_NOW=$(grep "^ODOO_LIST_DB=" .env | cut -d'=' -f2- | xargs)
    DB_COUNT=$(docker compose exec -T db psql -U odoo -d postgres -t -A -c \
        "SELECT count(*) FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres');" \
        </dev/null 2>/dev/null | tr -d '\r')
    if [ "${LIST_DB_NOW:-True}" != "False" ] && [ "${DB_COUNT:-0}" -gt 0 ] 2>/dev/null; then
        echo ""
        echo -e "${YELLOW}!${NC} The Odoo database manager (/web/database/manager) is publicly reachable"
        echo "   and can create, drop and download databases — the master password is its"
        echo "   only protection. Your database(s) already exist, so it can be disabled."
        read -p "  Disable the database manager now (sets ODOO_LIST_DB=False)? [Y/n]: " LOCK_DB
        if [[ ! "${LOCK_DB:-Y}" =~ ^[Nn]$ ]]; then
            if sed --version 2>/dev/null | grep -q GNU; then
                sed -i "s/^ODOO_LIST_DB=.*/ODOO_LIST_DB=False/" .env
                sed -i "s/^list_db = .*/list_db = False/" odoo.conf
            else
                sed -i '' "s/^ODOO_LIST_DB=.*/ODOO_LIST_DB=False/" .env
                sed -i '' "s/^list_db = .*/list_db = False/" odoo.conf
            fi
            docker compose restart odoo >/dev/null 2>&1 || true
            echo -e "  ${GREEN}✓${NC} Database manager disabled. To create a new database later,"
            echo "     set ODOO_LIST_DB=True in .env, re-run setup, then disable it again."
        else
            echo "  Left enabled — disable it later by setting ODOO_LIST_DB=False in .env"
            echo "  and re-running: bash setup.sh"
        fi
    fi
fi

echo ""
echo "========================================="
echo ""
docker compose ps
# Record the mode for manage.sh and the scripts/ tools.
case "$MODE" in
    server)    ephem_mode_save server ;;
    demo)      ephem_mode_save demo ;;
    developer) ephem_mode_save dev ;;
esac
compose_files_init
if [ "$MODE" != server ]; then
    LEFT=$(stack_leftovers) || true
    if [ -n "$LEFT" ]; then
        echo ""
        echo -e "${YELLOW}!${NC} Left over from multi-instance mode (still running or on disk):"
        echo "$LEFT" | sed 's/^/    /'
        echo "    Stop and remove the instances with:  bash scripts/dev-instances.sh down"
    fi
fi

echo ""
echo "========================================="
echo -e "${GREEN}ePHEM is running!${NC}   (EPHEM_MODE=$EPHEM_MODE in .env)"
echo ""

ENV_DOMAIN=$(grep "^DOMAIN=" .env 2>/dev/null | cut -d'=' -f2- | xargs)
ENV_EMAIL=$(grep "^SSL_EMAIL=" .env 2>/dev/null | cut -d'=' -f2- | xargs)
SERVER_IP=$(get_server_ip)

if [ "$MODE" = "developer" ]; then
    # PyCharm runs on the host GUI. Under WSL that's Windows, which reaches the
    # script via a \\wsl.localhost path; on macOS/Linux it's the POSIX path.
    if is_wsl; then
        SCRIPT_DISPLAY="\\\\wsl.localhost\\${WSL_DISTRO_NAME:-Ubuntu}$(printf '%s' "$PWD/scripts/dev-logs.sh" | tr '/' '\\')"
        ADDONS_DISPLAY="\\\\wsl.localhost\\${WSL_DISTRO_NAME:-Ubuntu}$(printf '%s' "$PWD/addons" | tr '/' '\\')"
        PYCHARM_HOST="Windows"
    else
        SCRIPT_DISPLAY="$PWD/scripts/dev-logs.sh"
        ADDONS_DISPLAY="$PWD/addons"
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
    echo "    2. File → Open → this folder (the ePHEM clone is $CORE_NAME/ inside it):"
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
    echo -e "${CYAN}${BOLD}Day-to-day menu${NC}"
    echo "  bash manage.sh    (status, addons: pull/switch/add a repository, restart + logs, module updates, doctor, databases)"
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
    if grep -Eq '^[^#]*ssl_certificate' nginx/active.conf 2>/dev/null; then
        DOMAIN=$(grep "server_name" nginx/active.conf | grep -v "#" \
                 | sed 's/.*server_name//;s/;//' | tr ' ' '\n' \
                 | grep -Ev '^(_)?$' | head -1)
        echo "Your site is available at:"
        echo "  https://$DOMAIN"
        echo ""
        echo "Next steps:"
        echo "  • Add your domains:         bash manage.sh   → 2) Manage domains"
        echo "  • Create/restore databases: bash manage.sh   → 11) Advanced → 2) Databases"
        echo "  • Set up automatic backups: crontab -e   (README → Backups)"
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

    echo ""
    echo -e "${BOLD}Day-to-day management — the production menu:${NC}"
    echo "  bash manage.sh"
    echo "  (status & health, domains, SSL, app/addon updates, backups,"
    echo "   database manager lock, RPC endpoint switch, security check)"
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
    echo -e "  ${BOLD}${CYAN}ephem@pheoc.com${NC}"
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