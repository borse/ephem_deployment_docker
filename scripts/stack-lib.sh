#!/bin/bash
# ──────────────────────────────────────────────
# ePHEM stack helpers (sourced by setup.sh, manage.sh and scripts/, never run)
#
# One checkout of this repo runs in exactly ONE of four modes, recorded in
# .env so every tool agrees on what it is managing:
#
#   EPHEM_MODE=server     production or staging: nginx + certbot + one Odoo
#   EPHEM_MODE=demo       local evaluation: one Odoo on :8069, no nginx
#   EPHEM_MODE=dev        one Odoo on :8069, addons/ mounted read-write
#   EPHEM_MODE=dev-multi  several Odoos (odca1/, odca2/, ...) on one Postgres
#
# setup.sh writes the key at the end of every successful run, and
# scripts/dev-instances.sh writes dev-multi whenever it brings a stack up.
# Installs made before the key existed are recognised from the files they
# left behind (ephem_mode_detect), so nothing has to be re-run.
#
# What the mode changes:
#
#   compose        which compose files are loaded. dev-multi adds the
#                  generated docker-compose.dev-multi.yml; the other modes add
#                  docker-compose.override.yml when it exists, which is what
#                  a plain `docker compose` picks up on its own.
#   ODOO_SVC etc.  the Odoo service, container, addons folder, config file,
#                  database, data volume and URL a tool acts on. In dev-multi
#                  these describe ONE instance (stack_use_instance); in every
#                  other mode they are the single 'odoo' service.
#
# Usage, from a script in the repo root or in scripts/:
#
#     source "$(dirname "$0")/scripts/stack-lib.sh"      # or ../scripts/stack-lib.sh
#     stack_init [instance] || echo "$STACK_ERROR"
#
# Every function here is safe under `set -euo pipefail`: the ones that can
# legitimately fail (inst_index, stack_init, retire_single_override,
# filestore_archive) are meant to be called inside `if` or with `|| ...`.
# ──────────────────────────────────────────────

EPHEM_ROOT="${EPHEM_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Only define colours the sourcing script has not defined already.
RED="${RED:-\033[0;31m}"
GREEN="${GREEN:-\033[0;32m}"
YELLOW="${YELLOW:-\033[1;33m}"
CYAN="${CYAN:-\033[0;36m}"
BOLD="${BOLD:-\033[1m}"
NC="${NC:-\033[0m}"

# ── .env ──────────────────────────────────────
# `|| true`: a key absent from .env must yield "", not kill a set -e script
# (grep exits 1 on no match).
env_get() { grep "^$1=" "$EPHEM_ROOT/.env" 2>/dev/null | cut -d'=' -f2- | xargs || true; }

set_env_key() {  # set_env_key KEY VALUE: update or append KEY=VALUE in .env
    local f="$EPHEM_ROOT/.env"
    [ -f "$f" ] || touch "$f"
    if grep -q "^$1=" "$f"; then
        sed -i "s|^$1=.*|$1=$2|" "$f"
    else
        # A .env whose last line has no newline would otherwise swallow the key.
        [ -s "$f" ] && [ -n "$(tail -c1 "$f")" ] && echo >> "$f"
        printf '%s=%s\n' "$1" "$2" >> "$f"
    fi
}

DB_USER="$(env_get POSTGRES_USER)"; DB_USER="${DB_USER:-odoo}"

# ── Mode ──────────────────────────────────────
EPHEM_MODE="${EPHEM_MODE:-}"
EPHEM_MODE_SOURCE=""          # env | detected

ephem_mode_valid() { case "${1:-}" in server|demo|dev|dev-multi) return 0 ;; esac; return 1; }

# Accept the words people type or older scripts wrote.
ephem_mode_normalise() {
    case "${1:-}" in
        production|prod)                   echo server ;;
        developer|development|single)      echo dev ;;
        multi|multi-instance|dev-multi-instance|developer-multi) echo dev-multi ;;
        *)                                 echo "${1:-}" ;;
    esac
}

ephem_mode_label() {
    case "${1:-$EPHEM_MODE}" in
        server)    echo "server (production or staging)" ;;
        demo)      echo "demo (local evaluation)" ;;
        dev)       echo "developer, single instance" ;;
        dev-multi) echo "developer, multi-instance" ;;
        *)         echo "unknown" ;;
    esac
}

# Recognise an install that predates EPHEM_MODE from the files setup.sh and
# dev-instances.sh leave behind. dev-multi wins when both kinds are present:
# the multi stack is what actually runs, the single-instance override is a
# leftover (see stack_leftovers).
ephem_mode_detect() {
    local ov="$EPHEM_ROOT/docker-compose.override.yml"
    if [ -s "$EPHEM_ROOT/.dev-instances" ] && [ -f "$EPHEM_ROOT/docker-compose.dev-multi.yml" ]; then
        echo dev-multi
    elif [ -f "$ov" ] && grep -q 'Developer override' "$ov"; then
        echo dev
    elif [ -f "$ov" ] && grep -q 'Demo override' "$ov"; then
        echo demo
    else
        echo server
    fi
}

# Sets EPHEM_MODE from .env, else from the files on disk (EPHEM_MODE_SOURCE
# says which). Always succeeds.
ephem_mode() {
    local m; m=$(ephem_mode_normalise "$(env_get EPHEM_MODE)")
    if ephem_mode_valid "$m"; then
        EPHEM_MODE="$m"; EPHEM_MODE_SOURCE=env
    else
        EPHEM_MODE=$(ephem_mode_detect); EPHEM_MODE_SOURCE=detected
    fi
    return 0
}

ephem_mode_save() {  # ephem_mode_save MODE
    local m; m=$(ephem_mode_normalise "$1")
    ephem_mode_valid "$m" || { echo "ephem_mode_save: '$1' is not a mode" >&2; return 1; }
    set_env_key EPHEM_MODE "$m"
    EPHEM_MODE="$m"; EPHEM_MODE_SOURCE=env
}

# ── Compose ───────────────────────────────────
COMPOSE_FILES=()

compose_files_init() {
    COMPOSE_FILES=(-f "$EPHEM_ROOT/docker-compose.yml")
    if [ "$EPHEM_MODE" = dev-multi ]; then
        COMPOSE_FILES+=(-f "$EPHEM_ROOT/docker-compose.dev-multi.yml")
    elif [ -f "$EPHEM_ROOT/docker-compose.override.yml" ]; then
        COMPOSE_FILES+=(-f "$EPHEM_ROOT/docker-compose.override.yml")
    fi
}

# The compose call for this mode. Absolute -f paths make the repo root the
# project directory, so this works from cron and from any cwd.
compose() { docker compose "${COMPOSE_FILES[@]}" "$@"; }

# How to type the same thing by hand (for the commands the menus print).
compose_cmd_text() {
    if [ "$EPHEM_MODE" = dev-multi ]; then
        echo "docker compose -f docker-compose.yml -f docker-compose.dev-multi.yml"
    else
        echo "docker compose"
    fi
}

# Project name compose derived for this checkout: volumes are named
# <project>_<volume>. Read off the db container (present in every mode once
# the stack has run), falling back to compose's own default.
compose_project() {
    docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' ephem-db 2>/dev/null | grep . \
        || basename "$EPHEM_ROOT" | tr '[:upper:]' '[:lower:]'
}

# Container state for one compose service, without parsing `docker compose
# ps` output (its columns move between compose versions).
svc_state() {  # svc_state SERVICE → running | stopped | absent
    local cid; cid=$(compose ps -aq "$1" 2>/dev/null | head -1)
    [ -z "$cid" ] && { echo "absent"; return 0; }
    case "$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null)" in
        running) echo "running" ;;
        "")      echo "absent" ;;
        *)       echo "stopped" ;;
    esac
}

# Same, with the exit code when it is not running: "exited (127)".
svc_detail() {  # svc_detail SERVICE
    local cid st; cid=$(compose ps -aq "$1" 2>/dev/null | head -1)
    [ -z "$cid" ] && { echo "not created"; return 0; }
    st=$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' "$cid" 2>/dev/null)
    case "${st%% *}" in
        running) echo "running" ;;
        "")      echo "not created" ;;
        exited)  echo "exited (${st#* })" ;;
        *)       echo "${st%% *}" ;;
    esac
}

# Docker's own reason a container cannot start ("" when there is none). The
# usual one here: a single-file bind mount (odoo.conf, odoo-N.conf) whose file
# was replaced, so the recorded mount no longer resolves and start fails with
# "not a directory". Recreating the container re-resolves the mount.
svc_start_error() {  # svc_start_error SERVICE
    local cid; cid=$(compose ps -aq "$1" 2>/dev/null | head -1)
    [ -z "$cid" ] && return 0
    docker inspect -f '{{.State.Error}}' "$cid" 2>/dev/null || true
}

# Start one service the way that actually works: create it when it has never
# run, recreate it when docker refuses the old container, plain start else.
svc_start() {  # svc_start SERVICE
    local err
    if [ "$(svc_state "$1")" = absent ]; then
        echo -e "  ${CYAN}→${NC} $(compose_cmd_text) up -d $1"
        compose up -d "$1"
        return
    fi
    err=$(svc_start_error "$1")
    if [ -n "$err" ]; then
        local before; before=$(odoo_cid "$1")
        echo -e "  ${YELLOW}!${NC} The existing container cannot start: ${err:0:140}"
        echo -e "  ${CYAN}→${NC} $(compose_cmd_text) up -d --force-recreate $1   (data volumes are kept)"
        compose up -d --force-recreate "$1" || return 1
        [ "$1" = "$ODOO_SVC" ] && nginx_follow_odoo "$before" "$1"
        return 0
    fi
    echo -e "  ${CYAN}→${NC} $(compose_cmd_text) start $1"
    compose start "$1"
}

# ── nginx after a recreated Odoo ──────────────
# nginx names Odoo in a static upstream block and resolves that name ONCE,
# when it starts. A recreated Odoo container has a new address, so nginx
# keeps sending requests to the old one and every page is a 502 until nginx
# restarts (about a second offline). Take odoo_cid before anything that may
# recreate the container and call nginx_follow_odoo after it; it does
# nothing when the container is the same one, or when nginx is not running
# (every developer mode).
odoo_cid() { compose ps -aq "${1:-$ODOO_SVC}" 2>/dev/null | head -1; }

nginx_follow_odoo() {  # nginx_follow_odoo PREVIOUS-CID [SERVICE]
    local now; now=$(odoo_cid "${2:-$ODOO_SVC}")
    { [ -n "$now" ] && [ "$now" != "${1:-}" ]; } || return 0
    [ "$(svc_state nginx)" = running ] || return 0
    echo -e "  ${CYAN}→${NC} $(compose_cmd_text) restart nginx   (Odoo was recreated, nginx must re-resolve its address)"
    if compose restart nginx >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} nginx restarted"
    else
        echo -e "  ${YELLOW}!${NC} nginx restart failed: run  $(compose_cmd_text) restart nginx  or the site stays on 502"
    fi
}

# Restart, and when the old container cannot come back, recreate it.
svc_restart() {  # svc_restart SERVICE
    echo -e "  ${CYAN}→${NC} $(compose_cmd_text) restart $1"
    compose restart "$1" && return 0
    echo -e "  ${YELLOW}!${NC} Restart failed, trying to recreate the container."
    svc_start "$1"
}

# The app image this mode runs. The generated multi file always tracks latest.
stack_image() {
    local t; t=$(env_get EPHEM_IMAGE_TAG)
    [ "$EPHEM_MODE" = dev-multi ] && t=""
    echo "borrs/ephem:${t:-latest}"
}

# ── App image: architecture and pulls ─────────
# Shared by setup.sh (install) and manage.sh (Update the app image).

# Apple Silicon and other arm64 hosts: a forced DOCKER_DEFAULT_PLATFORM or a
# cached amd64 image makes Docker run the app under emulation, and it never
# re-selects the native build on its own. Asks before changing anything.
ensure_native_image_arch() {
    local image machine host_arch img_arch R
    image=$(stack_image)
    machine=$(uname -m 2>/dev/null || echo unknown)
    case "$machine" in
        arm64|aarch64) host_arch="arm64" ;;
        x86_64|amd64)  host_arch="amd64" ;;
        *) return 0 ;;   # unknown host arch: do not guess
    esac
    if [ -n "${DOCKER_DEFAULT_PLATFORM:-}" ] && [ "${DOCKER_DEFAULT_PLATFORM##*/}" != "$host_arch" ]; then
        echo -e "${YELLOW}!${NC} DOCKER_DEFAULT_PLATFORM=${DOCKER_DEFAULT_PLATFORM} forces non-native images on this $host_arch machine."
        read -r -p "  Ignore it for this run so the native $host_arch image is used? [Y/n]: " R
        if [[ ! "${R:-Y}" =~ ^[Nn]$ ]]; then
            unset DOCKER_DEFAULT_PLATFORM
            echo -e "  ${GREEN}✓${NC} Unset for this run. Make it permanent by removing it from your"
            echo "     shell profile (e.g. ~/.zshrc) and Docker Desktop → Settings → Docker Engine."
        else
            echo "  Keeping it: the app will run under emulation."
        fi
    fi
    img_arch=$(docker image inspect "$image" --format '{{.Architecture}}' 2>/dev/null || echo "")
    if [ -n "$img_arch" ] && [ "$img_arch" != "$host_arch" ]; then
        echo -e "${YELLOW}!${NC} Cached $image is ${BOLD}$img_arch${NC} but this machine is ${BOLD}$host_arch${NC}: Docker will not switch it on its own."
        read -r -p "  Remove it and re-pull the native $host_arch build? [Y/n]: " R
        if [[ ! "${R:-Y}" =~ ^[Nn]$ ]]; then
            docker rmi "$image" >/dev/null 2>&1 || true
            echo "  Pulling the native $host_arch image…"
            docker pull "$image" || true
            echo -e "  ${GREEN}✓${NC} Native image pulled"
        else
            echo "  Keeping the $img_arch image: it will run under emulation."
        fi
    fi
    return 0
}

# Pull compose service image(s) and, on failure, explain the ACTUAL cause
# instead of blaming "docker login". Handles the classic WSL breakage where
# ~/.docker/config.json points 'credsStore' at a Windows .exe that cannot run
# in Linux: for a public image that is not an auth problem, so it offers to
# fix it. Uses the compose files of the current mode when they are set
# (manage.sh) and a plain `docker compose` otherwise (setup.sh).
# Usage: docker_pull_with_diagnosis [service…]   (no argument: every service)
docker_pull_with_diagnosis() {
    local tmp rc=0 out cfg R
    tmp="$(mktemp 2>/dev/null || echo "/tmp/ephem-pull.$$")"
    docker compose ${COMPOSE_FILES[@]+"${COMPOSE_FILES[@]}"} pull "$@" 2>&1 | tee "$tmp" || rc=$?
    out="$(cat "$tmp" 2>/dev/null)"; rm -f "$tmp"
    [ "$rc" -eq 0 ] && return 0

    echo ""
    # Broken credential helper (not an auth problem for a public image).
    if printf '%s' "$out" | grep -qiE "error getting credentials|resolve credential|docker-credential-[a-z.]*: (exec format error|not found|no such file|executable file not found)|exec format error"; then
        echo -e "  ${YELLOW}!${NC} This is NOT a login problem: borrs/ephem is public. Docker's"
        echo "    credential helper is misconfigured (common in WSL: ~/.docker/config.json"
        echo "    sets 'credsStore' to a Windows .exe that cannot run inside Linux)."
        cfg="$HOME/.docker/config.json"
        if [ -f "$cfg" ] && grep -qE '"credsStore"|"credHelpers"' "$cfg" 2>/dev/null; then
            read -r -p "    Fix it now (back up config.json, drop the credential helper, retry)? [Y/n]: " R
            if [[ ! "${R:-Y}" =~ ^[Nn]$ ]]; then
                cp "$cfg" "$cfg.bak" 2>/dev/null || true
                if command -v python3 >/dev/null 2>&1; then
                    python3 - "$cfg" <<'PYFIX'
import json, sys
p = sys.argv[1]
try:
    d = json.load(open(p))
except Exception:
    d = {}
d.pop('credsStore', None); d.pop('credHelpers', None)
json.dump(d, open(p, 'w'), indent=2)
PYFIX
                else
                    sed -i.sedbak '/"credsStore"/d; /"credHelpers"/d' "$cfg" 2>/dev/null || true
                fi
                echo -e "    ${GREEN}✓${NC} Credential helper removed (backup: $cfg.bak). Retrying…"
                if docker compose ${COMPOSE_FILES[@]+"${COMPOSE_FILES[@]}"} pull "$@"; then
                    return 0
                fi
                echo -e "    ${RED}✗${NC} Still failing after the fix: see the output above."
                return 1
            fi
        fi
        echo "    Manual fix: remove the \"credsStore\" line from ~/.docker/config.json"
        echo "    (or re-enable WSL interop), then try again."
        return 1
    fi
    # Genuine auth failure: THIS is when to log in (private image).
    if printf '%s' "$out" | grep -qiE "unauthorized|authentication required|access to the resource is denied|denied: |forbidden|pull access denied"; then
        echo -e "  ${YELLOW}!${NC} The registry denied access. If the image is private, log in first:"
        echo "        docker login"
        echo "    then try again. (The public borrs/ephem image needs no login.)"
        return 1
    fi
    # Network / DNS.
    if printf '%s' "$out" | grep -qiE "no such host|lookup .*: | timeout|temporary failure|connection refused|network is unreachable|TLS handshake|i/o timeout"; then
        echo -e "  ${YELLOW}!${NC} Looks like a network problem reaching Docker Hub: check your"
        echo "    internet connection / proxy / VPN, then try again."
        return 1
    fi
    echo -e "  ${YELLOW}!${NC} Pull failed: see the output above for the cause."
    return 1
}

# ── Addons sources ────────────────────────────
# Every Odoo mounts ONE host folder at /mnt/extra-addons, and that folder is
# a PARENT holding one subfolder per source: the ePHEM clone setup.sh makes
# ($CORE_NAME, ePHEM-core by default) and any repository added later from
# manage.sh → Addons → Add a source. Single modes mount addons/, dev-multi
# mounts odcaN/. The generated odoo config lists every subfolder in its
# addons_path, so a source is nothing more than a subfolder with Odoo modules
# in it; each clone keeps its own remote (and ssh alias), so pull and switch
# work per source with plain git.
#
# Installs made before this layout mounted the ePHEM clone ITSELF
# (custom-addons/, or odcaN/). addons_migrate_legacy moves such a clone one
# level down into <parent>/$CORE_NAME; nothing is deleted. The container
# must then be recreated: its bind mount still shows the moved folder
# (odoo_mount_stale tells).
ADDONS_MOUNT="/mnt/extra-addons"
ODOO_STOCK_ADDONS="/usr/lib/python3/dist-packages/odoo/addons"
CORE_NAME="$(env_get EPHEM_CORE_NAME)"; CORE_NAME="${CORE_NAME:-ePHEM-core}"
CORE_REPO="borse/ePHEM"                    # owner/name, GitHub

# DIR directly holds Odoo modules (name/__manifest__.py).
dir_has_modules() { local m; for m in "$1"/*/__manifest__.py; do [ -f "$m" ] && return 0; done; return 1; }

# The mounted folder is still the clone itself (layout before $CORE_NAME/).
addons_is_legacy() { [ -d "$1/.git" ] || dir_has_modules "$1"; }

# One source name per line: $CORE_NAME first (even while still empty, it is
# the clone target), then every other subfolder that holds modules, sorted.
# Hidden folders and folders without modules are not sources.
addons_sources() {  # addons_sources PARENT
    local p="$1" d n
    [ -d "$p" ] || return 0
    [ -d "$p/$CORE_NAME" ] && echo "$CORE_NAME"
    for d in "$p"/*/; do
        [ -d "$d" ] || continue
        n=$(basename "$d")
        [ "$n" = "$CORE_NAME" ] && continue
        dir_has_modules "$d" && echo "$n"
    done
    return 0
}

addons_source_count() { addons_sources "$1" | grep -c . || true; }

# The folders update-modules.sh and the doctor scan for modules: every
# source, or the parent itself while it is still the legacy clone.
addons_module_dirs() {  # addons_module_dirs PARENT → one host path per line
    local p="$1" s
    if addons_is_legacy "$p"; then echo "$p"; return 0; fi
    while IFS= read -r s; do [ -n "$s" ] && echo "$p/$s"; done < <(addons_sources "$p")
    return 0
}

# The value of the addons_path option inside the container. A parent with no
# source yet (deploy key not granted) lists the mount itself, which exists.
addons_path_value() {  # addons_path_value PARENT
    local s out=""
    while IFS= read -r s; do
        [ -n "$s" ] && out="$out,$ADDONS_MOUNT/$s"
    done < <(addons_sources "$1")
    [ -z "$out" ] && out=",$ADDONS_MOUNT"
    echo "${out#,},$ODOO_STOCK_ADDONS"
}

# Rewrite the addons_path line of a generated odoo config IN PLACE: the file
# is a single-file bind mount, a new inode would leave the container reading
# the old one (see svc_start_error).
odoo_conf_set_addons_path() {  # odoo_conf_set_addons_path CONF PARENT
    local conf="$1" val content
    [ -f "$conf" ] || return 1
    val=$(addons_path_value "$2")
    content=$(awk -v v="$val" '/^addons_path *=/ { print "addons_path = " v; next } { print }' "$conf")
    printf '%s\n' "$content" > "$conf"
}

# Move the legacy clone one level down: PARENT → PARENT/$CORE_NAME. Returns
# 0 when it moved, 1 when the layout was already right, 2 on failure (the
# folder is put back). Prints what it did.
addons_migrate_legacy() {  # addons_migrate_legacy PARENT
    local p="${1%/}" tmp
    addons_is_legacy "$p" || return 1
    tmp="$p.migrating.$$"
    if ! mv "$p" "$tmp"; then
        echo -e "  ${RED}✗${NC} Could not rename $p (permissions?)." >&2
        return 2
    fi
    if ! mkdir "$p" || ! mv "$tmp" "$p/$CORE_NAME"; then
        rmdir "$p" 2>/dev/null || true
        [ -e "$p" ] || mv "$tmp" "$p"
        echo -e "  ${RED}✗${NC} Could not move $p into $p/$CORE_NAME; put back as it was." >&2
        return 2
    fi
    echo -e "  ${GREEN}✓${NC} $(basename "$p")/ was the ePHEM clone itself: moved into $(basename "$p")/$CORE_NAME/ (nothing deleted)"
    return 0
}

# Single modes: the folder used to be custom-addons/. Adopt it as addons/
# (a docker-created empty addons/ gives way), then move the clone down.
# Returns 0 when anything moved.
addons_adopt_single_legacy() {
    local old="$EPHEM_ROOT/custom-addons" new="$EPHEM_ROOT/addons" moved=1
    if [ -d "$old" ] && { [ ! -e "$new" ] || { [ -d "$new" ] && [ -z "$(ls -A "$new" 2>/dev/null)" ]; }; }; then
        [ -d "$new" ] && rmdir "$new"
        mv "$old" "$new" || return 2
        echo -e "  ${GREEN}✓${NC} custom-addons/ renamed to addons/"
        moved=0
    elif [ -d "$old" ] && [ -d "$new" ]; then
        echo -e "  ${YELLOW}!${NC} Both custom-addons/ and addons/ exist. addons/ is the folder in use;"
        echo "     custom-addons/ is ignored from now on (move or delete it yourself)."
    fi
    addons_migrate_legacy "$new" && moved=0
    return $moved
}

# The container still shows the folder that was moved: it runs, the host has
# PARENT/$CORE_NAME, the container does not see it under the mount.
odoo_mount_stale() {  # odoo_mount_stale SERVICE PARENT
    [ "$(svc_state "$1")" = running ] || return 1
    [ -d "$2/$CORE_NAME" ] || return 1
    ! compose exec -T "$1" test -d "$ADDONS_MOUNT/$CORE_NAME" </dev/null >/dev/null 2>&1
}

# Modules present in more than one source: "module: src1 src2" per line.
# Odoo loads the first one in addons_path order (the order of addons_sources).
addons_duplicates() {  # addons_duplicates PARENT
    local p="$1" s m
    while IFS= read -r s; do
        [ -n "$s" ] || continue
        for m in "$p/$s"/*/__manifest__.py; do
            [ -f "$m" ] && printf '%s %s\n' "$(basename "$(dirname "$m")")" "$s"
        done
    done < <(addons_sources "$p") \
    | awk '{ n[$1]++; w[$1] = w[$1] " " $2 } END { for (k in n) if (n[k] > 1) print k ":" w[k] }' | sort
}

addons_warn_duplicates() {  # addons_warn_duplicates PARENT → prints, returns 1 when any
    local d; d=$(addons_duplicates "$1")
    [ -z "$d" ] && return 0
    echo -e "  ${YELLOW}!${NC} The same module exists in more than one source. Odoo loads the FIRST"
    echo "     one in addons path order and ignores the other silently:"
    echo "$d" | sed 's/^/       /'
    return 1
}

# Per-source git facts (DIR = one source folder). Safe on a plain folder.
src_branch() {
    local b
    [ -d "$1/.git" ] || { echo "not a git clone"; return 0; }
    b=$(git -C "$1" branch --show-current 2>/dev/null) || b=""
    echo "${b:-(detached)}"
}
src_last_commit() { git -C "$1" log -1 --format='%h %ad' --date=short 2>/dev/null || echo "-"; }
# grep -c reads to the end, so this is safe under pipefail.
src_dirty_count() {
    local n
    n=$(git -C "$1" status --porcelain --untracked-files=no 2>/dev/null | grep -c .) || n=0
    echo "${n:-0}"
}
src_module_count() { local c=0 m; for m in "$1"/*/__manifest__.py; do [ -f "$m" ] && c=$((c + 1)); done; echo "$c"; }

# A valid source folder name: what a path segment and an Odoo addons_path
# entry both accept, no leading dot.
valid_source_name() { printf '%s' "${1:-}" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$'; }

# ── Git remotes and deploy keys ───────────────
# owner/repo, git@host:owner/repo.git, ssh://git@host/owner/repo.git and
# https://host/owner/repo(.git) name the same repository. Parsed into
# GIT_HOST and GIT_PATH so the access method chosen by the operator decides
# the URL actually used. A local path (/… or ./…) leaves GIT_HOST empty.
GIT_HOST=""; GIT_PATH=""
git_url_parse() {  # git_url_parse URL → 0 and GIT_HOST/GIT_PATH, 1 when unreadable
    local u="${1:-}"
    GIT_HOST=""; GIT_PATH=""
    [ -n "$u" ] || return 1
    case "$u" in
        /*|./*|../*|file://*) GIT_PATH="${u#file://}"; return 0 ;;
    esac
    u="${u%/}"; u="${u%.git}"
    case "$u" in
        ssh://*)   u="${u#ssh://}"; u="${u#*@}"; GIT_HOST="${u%%/*}"; GIT_PATH="${u#*/}" ;;
        https://*|http://*) u="${u#*://}"; GIT_HOST="${u%%/*}"; GIT_PATH="${u#*/}" ;;
        *@*:*)     u="${u#*@}"; GIT_HOST="${u%%:*}"; GIT_PATH="${u#*:}" ;;
        */*)       GIT_HOST="github.com"; GIT_PATH="$u" ;;
        *)         return 1 ;;
    esac
    [ -n "$GIT_HOST" ] && [ -n "$GIT_PATH" ] && [[ "$GIT_PATH" == */* ]]
}
git_url_ssh()   { echo "git@$1:$2.git"; }      # git_url_ssh HOST-OR-ALIAS PATH
git_url_https() { echo "https://$1/$2.git"; }

# Can git reach URL without prompting? (BatchMode: a prompt could not be
# answered under a timeout anyway.)
repo_reachable() {  # repo_reachable URL
    GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=15" GIT_TERMINAL_PROMPT=0 \
        timeout 40 git ls-remote --exit-code -h "$1" >/dev/null 2>&1
}

# A GitHub deploy key opens ONE repository, so every private source gets its
# own key and ssh alias: ~/.ssh/ephem_addons_<name>, reached as
# git@ephem-addons-<name>:owner/repo.git. The core keeps the key and alias
# setup.sh has always used (ephem_addons_deploy, github-ephem-addons).
deploy_slug()      { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-'; }
deploy_key_for()   { if [ "$1" = "$CORE_NAME" ]; then echo "$HOME/.ssh/ephem_addons_deploy"; else echo "$HOME/.ssh/ephem_addons_$(deploy_slug "$1")"; fi; }
deploy_alias_for() { if [ "$1" = "$CORE_NAME" ]; then echo "github-ephem-addons"; else echo "ephem-addons-$(deploy_slug "$1")"; fi; }

# Key file and ssh alias for a source, created when missing. Prints nothing.
ensure_deploy_key() {  # ensure_deploy_key NAME HOST
    local key alias cfg="$HOME/.ssh/config"
    key=$(deploy_key_for "$1"); alias=$(deploy_alias_for "$1")
    mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
    if [ ! -f "$key" ]; then
        ssh-keygen -t ed25519 -f "$key" -C "ephem-addons-$(hostname 2>/dev/null || echo unknown)-$1" -N "" -q
        chmod 600 "$key"; chmod 644 "$key.pub"
    fi
    if ! grep -q "^Host $alias\$" "$cfg" 2>/dev/null; then
        printf '\nHost %s\n    HostName %s\n    User git\n    IdentityFile %s\n    IdentitiesOnly yes\n' "$alias" "$2" "$key" >> "$cfg"
        chmod 600 "$cfg"
    fi
    if ! grep -q "$2" "$HOME/.ssh/known_hosts" 2>/dev/null; then
        ssh-keyscan "$2" >> "$HOME/.ssh/known_hosts" 2>/dev/null || true
        chmod 644 "$HOME/.ssh/known_hosts" 2>/dev/null || true
    fi
}

# The box operators copy into an email or into the repository settings.
print_deploy_key_notice() {  # print_deploy_key_notice NAME PUBKEY-FILE REPO-PATH
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  DEPLOY KEY FOR $3 — ACTION REQUIRED${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "  This key opens only that repository, read-only. Give it access:"
    echo "    • an ePHEM repository:  email the key to ephem@pheoc.com, with your"
    echo "      country or server name and the repository name in the subject"
    echo "    • your own repository:  Settings → Deploy keys → Add deploy key"
    echo ""
    echo -e "  ${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${GREEN}║  COPY EVERYTHING BETWEEN THE LINES                          ║${NC}"
    echo -e "  ${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${CYAN}$(cat "$2")${NC}"
    echo ""
    echo -e "  ${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "  ${GREEN}║  END OF KEY                                                 ║${NC}"
    echo -e "  ${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# ── Instances (dev-multi) ─────────────────────
# The roster is .dev-instances, one name per line, written by
# scripts/dev-instances.sh. A name's position gives its ports: the first
# instance listens on 8010/8012, the next on 8020/8022, and so on.
INSTANCES_FILE="$EPHEM_ROOT/.dev-instances"
INSTANCES=()
INST_WEB_BASE=8010
INST_LONG_BASE=8012
INST_STEP=10

instances_load() {
    local n
    INSTANCES=()
    [ -f "$INSTANCES_FILE" ] || return 0
    while IFS= read -r n; do
        [ -n "$n" ] && INSTANCES+=("$n")
    done < "$INSTANCES_FILE"
    return 0
}

inst_index() {  # inst_index NAME → position, or 1 when unknown
    local i=0 n
    for n in "${INSTANCES[@]}"; do
        [ "$n" = "${1:-}" ] && { echo "$i"; return 0; }
        i=$((i + 1))
    done
    return 1
}

inst_port()      { local i; i=$(inst_index "$1") || return 1; echo $(( INST_WEB_BASE + INST_STEP * i )); }
inst_long_port() { local i; i=$(inst_index "$1") || return 1; echo $(( INST_LONG_BASE + INST_STEP * i )); }
inst_service()   { echo "odoo_$1"; }
inst_container() { echo "ephem-$1"; }
inst_addons()    { echo "odca$1"; }
inst_conf()      { echo "odoo-$1.conf"; }
inst_db()        { echo "ephem_$1"; }
inst_volume()    { echo "odoo-data-$1"; }

# The ePHEM clone of instance N: odcaN/$CORE_NAME, or odcaN itself while it
# is still the legacy layout (so the roster reads right before the move).
inst_core_dir() {
    local p="$EPHEM_ROOT/odca$1"
    if [ -d "$p/$CORE_NAME" ]; then echo "$p/$CORE_NAME"; else echo "$p"; fi
}
inst_branch()       { src_branch "$(inst_core_dir "$1")"; }          # of the core clone
inst_last_commit()  { src_last_commit "$(inst_core_dir "$1")"; }
inst_dirty_count()  { src_dirty_count "$(inst_core_dir "$1")"; }
inst_source_count() { addons_source_count "$EPHEM_ROOT/odca$1"; }
# "18_national_dev +2": the core branch, and how many other sources there are.
inst_branch_label() {
    local n; n=$(inst_source_count "$1")
    if [ "${n:-0}" -gt 1 ]; then echo "$(inst_branch "$1") +$((n - 1))"; else inst_branch "$1"; fi
}

# ── The Odoo a tool acts on ───────────────────
EPHEM_INSTANCE=""
ODOO_SVC=odoo
ODOO_CTN=ephem-app
ADDONS_DIR=""            # the mounted parent folder (host path)
ADDONS_NAME=addons       # its name, for messages
CORE_DIR=""              # the ePHEM clone inside it: $ADDONS_DIR/$CORE_NAME
ODOO_CONF=""
ODOO_DB=""
ODOO_VOL=odoo-data
ODOO_PORT=8069
ODOO_URL=""

stack_use_single() {
    EPHEM_INSTANCE=""
    ODOO_SVC=odoo; ODOO_CTN=ephem-app
    ADDONS_DIR="$EPHEM_ROOT/addons"; ADDONS_NAME=addons
    CORE_DIR="$ADDONS_DIR/$CORE_NAME"
    ODOO_CONF="$EPHEM_ROOT/odoo.conf"
    ODOO_DB=""; ODOO_VOL=odoo-data; ODOO_PORT=8069
    case "$EPHEM_MODE" in
        server) ODOO_URL="" ;;
        *)      ODOO_URL="http://localhost:8069" ;;
    esac
}

stack_use_instance() {  # stack_use_instance NAME (must be in the roster)
    inst_index "$1" >/dev/null || return 1
    EPHEM_INSTANCE="$1"
    ODOO_SVC="odoo_$1"; ODOO_CTN="ephem-$1"
    ADDONS_DIR="$EPHEM_ROOT/odca$1"; ADDONS_NAME="odca$1"
    CORE_DIR="$ADDONS_DIR/$CORE_NAME"
    ODOO_CONF="$EPHEM_ROOT/odoo-$1.conf"
    ODOO_DB="ephem_$1"; ODOO_VOL="odoo-data-$1"
    ODOO_PORT=$(inst_port "$1"); ODOO_URL="http://localhost:$ODOO_PORT"
}

# Remember the instance for the next run (EPHEM_INSTANCE in .env).
stack_pin_instance() { set_env_key EPHEM_INSTANCE "$1"; }

# Mode, compose files, roster, and the Odoo to act on. In dev-multi the
# instance is the argument, else EPHEM_INSTANCE from .env, else the first in
# the roster. Returns 1 with STACK_ERROR set when the request cannot be met;
# the variables are still filled with the best available choice so a caller
# can print the error and carry on.
STACK_ERROR=""
stack_init() {  # stack_init [INSTANCE]
    local want="${1:-}"
    STACK_ERROR=""
    ephem_mode
    compose_files_init
    instances_load
    if [ "$EPHEM_MODE" != dev-multi ]; then
        stack_use_single
        [ -n "$want" ] && STACK_ERROR="This checkout is in $(ephem_mode_label) mode: there are no instances to choose from."
        [ -z "$STACK_ERROR" ]
        return
    fi
    if [ "${#INSTANCES[@]}" -eq 0 ]; then
        stack_use_single
        STACK_ERROR=".dev-instances is empty. Bring the stack up first:  bash scripts/dev-instances.sh up 1 2 3"
        return 1
    fi
    if [ ! -f "$EPHEM_ROOT/docker-compose.dev-multi.yml" ]; then
        STACK_ERROR="docker-compose.dev-multi.yml is missing. Regenerate it:  bash scripts/dev-instances.sh up ${INSTANCES[*]}"
    fi
    if [ -n "$want" ]; then
        if ! inst_index "$want" >/dev/null; then
            STACK_ERROR="No instance named '$want'. Configured: ${INSTANCES[*]}"
            want="${INSTANCES[0]}"
        fi
    else
        want=$(env_get EPHEM_INSTANCE)
        inst_index "$want" >/dev/null 2>&1 || want="${INSTANCES[0]}"
    fi
    stack_use_instance "$want"
    [ -z "$STACK_ERROR" ]
}

# ── Reaching a filestore ──────────────────────
FILESTORE="/var/lib/odoo/.local/share/Odoo/filestore"
FS_PARENT="/var/lib/odoo/.local/share/Odoo"

# Run a shell command against one Odoo service's data volume. Prefers the
# running container; falls back to a throwaway one (same volumes, no
# dependencies started) so the filestore stays reachable while Odoo is
# stopped. stdin is closed: a stray exec must never swallow a menu's own
# keyboard input.
odoo_sh_on() {  # odoo_sh_on SERVICE 'shell command'
    if [ "$(svc_state "$1")" = "running" ]; then
        compose exec -T "$1" sh -c "$2" </dev/null
    else
        compose run --rm -T --no-deps --entrypoint sh "$1" -c "$2" </dev/null
    fi
}

# Same, but stdin IS passed through (a restore streams an archive in). Kept
# separate so no ordinary call can eat menu input by accident.
odoo_pipe_on() {  # odoo_pipe_on SERVICE 'shell command' < file
    if [ "$(svc_state "$1")" = "running" ]; then
        compose exec -T "$1" sh -c "$2"
    else
        compose run --rm -T --no-deps --entrypoint sh "$1" -c "$2"
    fi
}

# The service a filestore operation should go to. A caller sets ODOO_SH_SVC
# (fs_svc_for gives the right one per database); otherwise the pinned Odoo.
odoo_sh()   { odoo_sh_on   "${ODOO_SH_SVC:-$ODOO_SVC}" "$1"; }
odoo_pipe() { odoo_pipe_on "${ODOO_SH_SVC:-$ODOO_SVC}" "$1"; }

# Which instance's volume holds (or should hold) the filestore of a database.
# Postgres is shared in dev-multi, filestores are not: ephem_2's attachments
# live in odoo-data-2 whichever instance the menu is pinned to. Order:
#   1. the instance the name points at (ephem_2, ephem_2_copy → instance 2)
#      when that instance's volume has the folder. A stale copy left in
#      another volume (instance 1 once ran ephem_2) must not win.
#   2. the pinned instance, then any other instance, that has the folder.
#   3. for a folder that does not exist yet: the instance the name points
#      at, else the pinned instance.
declare -A FS_SVC_CACHE=()
fs_svc_for() {  # fs_svc_for DBNAME → service
    [ "$EPHEM_MODE" = dev-multi ] || { echo "$ODOO_SVC"; return 0; }
    local hit="${FS_SVC_CACHE[$1]:-}"
    [ -n "$hit" ] && { echo "$hit"; return 0; }
    local n svc="" named=""
    for n in "${INSTANCES[@]}"; do
        case "$1" in "ephem_$n"|"ephem_${n}_"*) named="odoo_$n"; break ;; esac
    done
    if [ -n "$named" ] && odoo_sh_on "$named" "test -d $FILESTORE/$1" >/dev/null 2>&1; then
        svc="$named"
    elif odoo_sh_on "$ODOO_SVC" "test -d $FILESTORE/$1" >/dev/null 2>&1; then
        svc="$ODOO_SVC"
    else
        for n in "${INSTANCES[@]}"; do
            [ "odoo_$n" = "$ODOO_SVC" ] || [ "odoo_$n" = "$named" ] && continue
            if odoo_sh_on "odoo_$n" "test -d $FILESTORE/$1" >/dev/null 2>&1; then
                svc="odoo_$n"; break
            fi
        done
    fi
    [ -z "$svc" ] && svc="${named:-$ODOO_SVC}"
    FS_SVC_CACHE[$1]="$svc"
    echo "$svc"
}

# The instance name behind a service ("odoo_2" → "2"), "" for the single odoo.
svc_instance() { case "$1" in odoo_*) echo "${1#odoo_}" ;; *) echo "" ;; esac; }

# One tar.gz of every filestore this checkout owns, to stdout: one directory
# per database at the top level, the layout scripts/backup.sh has always
# written and the restore menu reads. Mounts the data volumes directly, so it
# works while Odoo is stopped and, in dev-multi, gathers every instance's
# volume into a single archive. Exit 3 = no filestore exists yet.
filestore_archive() {
    local proj n vol tag
    local -a mounts=()
    proj=$(compose_project)
    if [ "$EPHEM_MODE" = dev-multi ]; then
        for n in "${INSTANCES[@]}"; do
            vol="${proj}_odoo-data-$n"
            if docker volume inspect "$vol" >/dev/null 2>&1; then
                mounts+=(-v "$vol:/fs/$n:ro")
            else
                echo "  note: instance $n has no data volume yet ($vol), nothing to archive" >&2
            fi
        done
    else
        vol="${proj}_odoo-data"
        docker volume inspect "$vol" >/dev/null 2>&1 && mounts+=(-v "$vol:/fs/single:ro")
    fi
    [ "${#mounts[@]}" -eq 0 ] && return 3
    # The sh inside collects only the filestore folders that exist, so an
    # instance that has never created a database cannot fail the whole run.
    docker run --rm "${mounts[@]}" --entrypoint sh "$(stack_image)" -c '
        set --
        for d in /fs/*/.local/share/Odoo/filestore; do
            [ -d "$d" ] && set -- "$@" -C "$d" .
        done
        [ $# -eq 0 ] && exit 3
        exec tar -czf - "$@"'
}

# ── Databases (shared Postgres) ───────────────
list_dbs() {
    compose exec -T db psql -U "$DB_USER" -d postgres -t -A -c \
        "SELECT datname FROM pg_database WHERE datistemplate = false AND datname NOT IN ('postgres') ORDER BY datname;" \
        </dev/null 2>/dev/null | tr -d '\r'
}

# ── Leftovers from another mode ───────────────
# Files and containers a previous mode left behind. One line each on stdout;
# returns 1 when something was found, 0 when clean.
stack_leftovers() {
    local found=0 ov="$EPHEM_ROOT/docker-compose.override.yml" c st
    if [ "$EPHEM_MODE" = dev-multi ]; then
        if [ -f "$ov" ]; then
            echo "docker-compose.override.yml: the single-instance override. The multi stack ignores it, but a plain 'docker compose' command still loads it and would start ephem-app."
            found=1
        fi
        st=$(docker inspect -f '{{.State.Status}}' ephem-app 2>/dev/null) || st=""
        if [ -n "$st" ]; then
            echo "container ephem-app ($st): the single-instance Odoo, not part of the multi stack."
            found=1
        fi
    else
        while IFS= read -r c; do
            case "$c" in
                ""|ephem-app|ephem-db|ephem-nginx|ephem-certbot) continue ;;
            esac
            st=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null) || st="?"
            echo "container $c ($st): from multi-instance mode (scripts/dev-instances.sh)."
            found=1
        done < <(docker ps -a --filter "name=^ephem-" --format '{{.Names}}' 2>/dev/null)
        if [ -f "$EPHEM_ROOT/docker-compose.dev-multi.yml" ]; then
            echo "docker-compose.dev-multi.yml: the multi-instance stack file (unused in $EPHEM_MODE mode)."
            found=1
        fi
    fi
    [ "$found" -eq 0 ]
}

# Remove the single-instance override setup.sh generated. A file without
# that header was written by hand and is left alone (returns 1).
retire_single_override() {
    local ov="$EPHEM_ROOT/docker-compose.override.yml"
    [ -f "$ov" ] || return 0
    if grep -q 'generated by setup.sh' "$ov"; then
        rm -f "$ov"
        echo -e "  ${GREEN}✓${NC} removed docker-compose.override.yml (single-instance override generated by setup.sh)"
        return 0
    fi
    echo -e "  ${YELLOW}!${NC} docker-compose.override.yml was not generated by setup.sh, left in place."
    echo "     A plain 'docker compose up' would use it; move it away if you no longer need it."
    return 1
}

# ── Doctor ────────────────────────────────────
# Scan one Odoo service's recent log for the failures people hit most, and
# print the fix. Reads a stopped container's log too: that is where the
# reason it stopped is.
stack_doctor() {  # stack_doctor SERVICE
    local svc="$1" LOGS found=0 MISSING n
    echo -e "${CYAN}${BOLD}Doctor: scanning the last 300 log lines of $svc${NC}"
    echo ""
    if [ "$(svc_state "$svc")" != running ]; then
        echo -e "${YELLOW}!${NC} $svc is $(svc_detail "$svc")."
        echo ""
    fi
    # Docker refusing to start the container is not in Odoo's log.
    local err; err=$(svc_start_error "$svc")
    if [ -n "$err" ]; then
        found=1
        echo -e "${RED}✗${NC} Docker could not start the container:"
        echo "$err" | fold -s -w 90 | sed 's/^/     /'
        echo "   Usually a stale single-file mount (its config file was replaced)."
        echo "   Recreate it:  $(compose_cmd_text) up -d --force-recreate $svc"
        echo "   (the Stack menu's start does that for you; data volumes are kept)"
        echo ""
    fi
    LOGS=$(compose logs --tail=300 --no-log-prefix "$svc" 2>&1) || LOGS=""
    if [ -z "$LOGS" ]; then
        echo -e "${YELLOW}!${NC} No log output for $svc (never started?)."
        return 0
    fi
    # Here-strings, not `echo | grep -q`: grep quitting early must not
    # SIGPIPE a producer under pipefail.
    if grep -q "ModuleNotFoundError" <<< "$LOGS"; then
        found=1
        MISSING=$(sed -n "s/.*ModuleNotFoundError: No module named '\([^']*\)'.*/\1/p" <<< "$LOGS" | sort -u | tr '\n' ' ')
        echo -e "${RED}✗${NC} Missing Python module(s): ${BOLD}${MISSING}${NC}"
        echo "   A custom addon imports a package that is not in the app image."
        echo "   Permanent fix: add it to the image (rebuild and push), then pull."
        echo "   Quick local patch:"
        echo "     $(compose_cmd_text) exec -u root $svc pip install --break-system-packages ${MISSING}"
        echo "     $(compose_cmd_text) restart $svc"
        echo ""
    fi
    if grep -q "Failed to load registry" <<< "$LOGS"; then
        found=1
        echo -e "${RED}✗${NC} Registry failed to load: every page returns 500."
        echo "   Usually a module raising on import (see above) or a bad XML/data file."
        echo ""
    fi
    if grep -qE "ParseError|XMLSyntaxError|ValidationError.*view" <<< "$LOGS"; then
        found=1
        echo -e "${RED}✗${NC} A view or data file did not load. Last mention:"
        grep -E "ParseError|XMLSyntaxError|ValidationError.*view" <<< "$LOGS" | tail -1 | cut -c1-200 | sed 's/^/     /'
        echo ""
    fi
    if grep -q "password authentication failed" <<< "$LOGS"; then
        found=1
        echo -e "${RED}✗${NC} Postgres rejects the app password: .env and the database disagree."
        echo "   Re-run  bash setup.sh  (it syncs the 'odoo' password to .env)."
        echo ""
    fi
    if grep -qiE "could not translate host name|connection refused.*5432|database .* does not exist" <<< "$LOGS"; then
        found=1
        echo -e "${RED}✗${NC} Database connectivity or availability issue."
        echo "   Check:  $(compose_cmd_text) ps   and   $(compose_cmd_text) logs db"
        echo ""
    fi
    if grep -qE "addons-path: no such directory|addons_path.*(does not exist|no such)" <<< "$LOGS"; then
        found=1
        echo -e "${RED}✗${NC} A folder listed in addons_path is gone (a source was moved, renamed or deleted"
        echo "   by hand). Regenerate the config: manage.sh → Addons, or bash setup.sh."
        echo ""
    fi
    if grep -q "Address already in use" <<< "$LOGS"; then
        found=1
        echo -e "${RED}✗${NC} A port inside the container is already taken: two Odoo processes in one container."
        echo "   Restart it:  $(compose_cmd_text) restart $svc"
        echo ""
    fi
    n=$(grep -c " ERROR " <<< "$LOGS") || n=0
    if [ "$found" -eq 0 ]; then
        if [ "${n:-0}" -gt 0 ]; then
            echo -e "${YELLOW}!${NC} No known signature, but $n ERROR line(s) in the last 300. Newest:"
            grep " ERROR " <<< "$LOGS" | tail -3 | cut -c1-200 | sed 's/^/     /'
        else
            echo -e "${GREEN}✓${NC} No known error signatures in the last 300 log lines."
        fi
    fi
    return 0
}

# ── GitHub SSH access ─────────────────────────
# Developer clones reach borse/ePHEM over SSH with the operator's own key
# (server clones use a deploy key behind an ssh alias and never come here:
# see remote_uses_own_key). A key with a passphrase
# and no agent makes ssh ask for it on EVERY git command; one menu action runs
# several, and a command under `timeout` cannot even show the prompt (it sits
# in a background process group), so it just fails. Before the first git
# command: test access without prompting and, when the only thing missing is
# the passphrase, load the key into an agent once. An agent the shell already
# has (SSH_AUTH_SOCK) is reused, so the key stays loaded after this script
# ends; otherwise one is started for this process and stopped with it.
GITHUB_SSH_STATE=""     # "" (not checked yet) | ok | declined | no-access

# True for a remote that ssh reaches as git@github.com with the default key,
# i.e. one that may need the agent above. Deploy-key aliases and HTTPS do not.
remote_uses_own_key() { case "${1:-}" in git@github.com:*|ssh://git@github.com/*) return 0 ;; esac; return 1; }

github_ssh_ok() {  # never prompts; GitHub answers "successfully authenticated" and exits 1
    local out
    out=$(ssh -o BatchMode=yes -o ConnectTimeout=10 -T git@github.com 2>&1) || true
    grep -q "successfully authenticated" <<< "$out"
}

ssh_key_file() {  # the private key ssh offers by default
    local k
    for k in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_ecdsa" "$HOME/.ssh/id_rsa"; do
        [ -f "$k" ] && { echo "$k"; return 0; }
    done
    return 1
}

ssh_key_encrypted() { ! ssh-keygen -y -P "" -f "$1" >/dev/null 2>&1; }

# Returns 0 when git can reach GitHub without prompting from now on. Asked
# once per run: a declined offer is remembered, so a later action does not
# ask again (git then prompts on its own, as it always did).
ensure_github_ssh() {
    case "$GITHUB_SSH_STATE" in ok) return 0 ;; declined|no-access) return 1 ;; esac
    if github_ssh_ok; then GITHUB_SSH_STATE=ok; return 0; fi
    local key rc=0 A
    key=$(ssh_key_file) || key=""
    if [ -n "$key" ] && ssh_key_encrypted "$key"; then
        echo -e "  ${YELLOW}!${NC} Your SSH key has a passphrase and no agent holds it, so ssh would"
        echo "     ask for it on every git command (and silently fail the quick checks)."
        echo "     Key: $key"
        # EOF (no terminal) counts as no: ssh-add could not ask for the passphrase anyway.
        read -r -p "  Load it into an agent once for this session? [Y/n]: " A || A=n
        if [[ "${A:-Y}" =~ ^[Nn]$ ]]; then
            GITHUB_SSH_STATE=declined
            echo "     Left as is: expect a passphrase prompt per git command."
            return 1
        fi
        # ssh-add -l: 0 = agent with keys, 1 = agent without keys, 2 = no agent
        ssh-add -l >/dev/null 2>&1 || rc=$?
        if [ "$rc" -eq 2 ]; then
            eval "$(ssh-agent -s)" >/dev/null 2>&1
            # Stopped with this process. To keep a key loaded across terminals
            # see README → Developer Mode → Troubleshooting.
            trap 'ssh-agent -k >/dev/null 2>&1' EXIT
            echo "     (started an ssh-agent for this run; it stops when the script exits)"
        fi
        if ! ssh-add "$key"; then
            GITHUB_SSH_STATE=declined
            return 1
        fi
        if github_ssh_ok; then GITHUB_SSH_STATE=ok; return 0; fi
        echo -e "  ${RED}✗${NC} The key is loaded but GitHub refuses it. Is its public key on your"
        echo "     GitHub account, and are you a collaborator on borse/ePHEM?  ssh -T git@github.com"
        GITHUB_SSH_STATE=no-access
        return 1
    fi
    echo -e "  ${RED}✗${NC} No SSH access to GitHub (ssh -o BatchMode=yes -T git@github.com fails)."
    echo "     README → Developer Mode → SSH key setup."
    GITHUB_SSH_STATE=no-access
    return 1
}

# ── Interactive helpers ───────────────────────
# Run a foreground command the operator ends with Ctrl-C (a log tail) and
# come back to the menu instead of dying with it.
run_interruptible() {
    local rc=0
    trap ':' INT
    "$@" || rc=$?
    trap - INT
    return "$rc"
}
