#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════
# dev-autostart.sh: on Windows (WSL), bring ePHEM back after Docker Desktop
# starts. Every mode: developer, demo and a server or training laptop.
#
# Why: when Docker Desktop starts (Windows sign in, opened by hand, or its
# own restart) it starts the containers that were running before, about two
# seconds BEFORE its link into Ubuntu is up. The files they mount from Ubuntu
# are not there yet. A container that mounts a single file (odoo.conf for
# Odoo, active.conf for nginx) then fails before it even runs ("not a
# directory ... odoo.conf", exit 127), and Docker never retries that kind of
# failure. ePHEM stays down although nothing is broken. (Postgres survives:
# its failure happens inside the container, which the restart policy retries.)
#
# What it does: as a service it waits for Docker to answer, and each time it
# comes back starts every container of this stack that Docker failed to
# start and that should be running (restart policy unless-stopped or always),
# retrying for up to a minute. Containers you stopped yourself, or that are
# running, are left alone. It never removes, recreates or updates anything.
#
#   bash scripts/dev-autostart.sh              # check once now
#   bash scripts/dev-autostart.sh --install    # as a service from now on (asks for sudo)
#   bash scripts/dev-autostart.sh --uninstall  # remove the service
#   bash scripts/dev-autostart.sh --status     # is it installed, what did it do
#   journalctl -u ephem-autostart              # the whole log
#
# The service is a system one (runs without anyone logged in, which is how
# Docker Desktop starts Ubuntu) under your own user, so it needs systemd in
# WSL: [boot] systemd=true in /etc/wsl.conf, then wsl --shutdown once.
# ════════════════════════════════════════════════════════════════
set -uo pipefail

UNIT=ephem-autostart.service
UNIT_FILE=/etc/systemd/system/$UNIT
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
ROOT="$(cd "$(dirname "$SELF")/.." && pwd)"
POLL=10          # seconds between "does Docker answer"
WINDOW=60        # seconds of retries once it does
ONCE_WAIT=${EPHEM_AUTOSTART_WAIT:-60}

is_wsl() { grep -qiE "microsoft|wsl" /proc/version 2>/dev/null || [ -n "${WSL_DISTRO_NAME:-}" ]; }
has_systemd() { [ "$(cat /proc/1/comm 2>/dev/null)" = systemd ]; }
docker_up() { timeout 15 docker version --format '{{.Server.Version}}' >/dev/null 2>&1; }

# installed | missing | stale (points at another folder) | no-systemd | not-wsl
state() {
    is_wsl || { echo not-wsl; return; }
    has_systemd || { echo no-systemd; return; }
    if [ ! -f "$UNIT_FILE" ] || ! systemctl is-enabled --quiet "$UNIT" 2>/dev/null; then
        echo missing; return
    fi
    if grep -qF -- "$SELF --watch" "$UNIT_FILE"; then echo installed; else echo stale; fi
}

# Containers of this stack Docker failed to start that should be running.
stuck() {
    docker ps -a --filter "label=com.docker.compose.project.working_dir=$ROOT" \
        --format '{{.Names}}' 2>/dev/null | while read -r c; do
        [ -n "$c" ] || continue
        docker inspect "$c" --format '{{.Name}} {{.State.Status}} {{.HostConfig.RestartPolicy.Name}} {{if .State.Error}}failed{{end}}' 2>/dev/null
    done | awk '$2 != "running" && ($3 == "unless-stopped" || $3 == "always") && $4 == "failed" { sub("^/", "", $1); print $1 }'
}

# Start what is stuck, every 5 seconds: for at least MIN seconds (Docker may
# still be starting the rest of the stack), and while something still refuses
# to start, up to WINDOW seconds.
recover() {  # recover MIN
    local min="${1:-0}" t=0 c started=0 left found
    while true; do
        left=""; found=0
        for c in $(stuck); do
            found=1
            if docker start "$c" >/dev/null 2>&1; then
                echo "✓ $c started (Docker had tried before Ubuntu was ready)"
                started=$((started + 1))
            else
                left="$left $c"
            fi
        done
        { [ "$found" = 0 ] && [ "$t" -ge "$min" ]; } && break
        [ "$t" -ge "$WINDOW" ] && break
        sleep 5; t=$((t + 5))
    done
    for c in $left; do
        echo "✗ $c still does not start. Its mounted file was probably replaced, so it must be"
        echo "  recreated: bash manage.sh (start it from its screen), or bash scripts/dev-logs.sh N"
    done
    [ "$started" -gt 0 ] || [ -n "$left" ] || echo "Nothing to start: every container of $ROOT is as it should be."
}

case "${1:-}" in
  --install)
    if ! is_wsl; then
        echo "Not WSL: the containers here see their files from the start, nothing to install."
        exit 0
    fi
    if ! has_systemd; then
        echo "✗ systemd is not running in this WSL distro, and the service needs it."
        echo "  1. sudo nano /etc/wsl.conf and add:"
        echo "       [boot]"
        echo "       systemd=true"
        echo "  2. In PowerShell: wsl --shutdown   (then open Ubuntu again)"
        echo "  3. bash scripts/dev-autostart.sh --install"
        echo "  Until then, after Windows starts run: bash scripts/dev-autostart.sh"
        exit 1
    fi
    SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO=sudo
    RUN_AS="${SUDO_USER:-$(id -un)}"
    # The first version was a user unit, which runs only while someone is
    # logged in. Replace it.
    if [ -f "$HOME/.config/systemd/user/$UNIT" ]; then
        systemctl --user disable "$UNIT" >/dev/null 2>&1 || true
        rm -f "$HOME/.config/systemd/user/$UNIT"
        systemctl --user daemon-reload >/dev/null 2>&1 || true
    fi
    $SUDO tee "$UNIT_FILE" >/dev/null <<EOF || { echo "✗ Could not write $UNIT_FILE"; exit 1; }
[Unit]
Description=ePHEM: start the containers Docker Desktop started before Ubuntu was ready
After=network.target

[Service]
Type=simple
User=$RUN_AS
ExecStart=/usr/bin/env bash $SELF --watch
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable "$UNIT" >/dev/null 2>&1
    if ! $SUDO systemctl restart "$UNIT"; then
        echo "✗ The service did not start: systemctl status $UNIT"
        exit 1
    fi
    echo "✓ Installed: ePHEM comes back by itself each time Docker Desktop starts."
    echo "  Log: journalctl -u ${UNIT%.service}"
    exit 0 ;;

  --uninstall)
    SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO=sudo
    if [ -f "$UNIT_FILE" ]; then
        $SUDO systemctl disable --now "$UNIT" >/dev/null 2>&1 || true
        $SUDO rm -f "$UNIT_FILE"
        $SUDO systemctl daemon-reload
    fi
    rm -f "$HOME/.config/systemd/user/$UNIT"
    echo "✓ Removed."
    exit 0 ;;

  --state)
    state
    exit 0 ;;

  --status)
    case "$(state)" in
        installed)  echo "✓ Installed and $(systemctl is-active "$UNIT" 2>/dev/null)." ;;
        stale)      echo "! Installed for another folder ($(sed -n 's/^ExecStart=.* bash //p' "$UNIT_FILE")). Run: bash scripts/dev-autostart.sh --install" ;;
        missing)    echo "✗ Not installed. Run: bash scripts/dev-autostart.sh --install" ;;
        no-systemd) echo "✗ systemd is off in this WSL distro: bash scripts/dev-autostart.sh --install says how to turn it on." ;;
        not-wsl)    echo "Not WSL: not needed here." ;;
    esac
    if [ -f "$UNIT_FILE" ]; then
        echo "Last lines of its log:"
        journalctl -u "$UNIT" -n 8 --no-pager -o short 2>/dev/null | sed 's/^/  /' \
            || echo "  (reading the log needs: sudo journalctl -u ${UNIT%.service})"
    fi
    exit 0 ;;

  --watch)
    # The service. Each time Docker comes back (it was not answering), recover.
    echo "Watching for Docker (stack in $ROOT)."
    up=0
    while true; do
        if docker_up; then
            if [ "$up" = 0 ]; then
                up=1
                echo "Docker answers: checking the stack."
                recover 20
            fi
        elif [ "$up" = 1 ]; then
            up=0
            echo "Docker stopped answering: waiting for it to come back."
        fi
        sleep "$POLL"
    done ;;

  "")
    waited=0
    until docker_up; do
        if [ "$waited" -ge "$ONCE_WAIT" ]; then
            echo "✗ Docker did not answer within ${ONCE_WAIT}s: open Docker Desktop, then run this again."
            exit 1
        fi
        sleep 5; waited=$((waited + 5))
    done
    recover 0
    exit 0 ;;

  *)
    echo "usage: $0 [--install|--uninstall|--status|--state]" >&2
    exit 2 ;;
esac
