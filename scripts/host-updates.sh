#!/bin/bash
# ──────────────────────────────────────────────
# ePHEM: the server installs its own security updates and comes back by itself
#
# The app image is updated by the ePHEM team. The operating system under it
# is the server's own: without this, a security update waits until someone
# logs in and runs apt, and a new kernel is not in use until someone restarts
# the machine. This turns on the system's own updater (unattended-upgrades,
# Debian and Ubuntu) with two settings of ours:
#
#   • updates install every night, one hour before the restart time;
#   • when one of them needs a restart (a new kernel, a new libc), the server
#     restarts at HOST_REBOOT_TIME (.env, 04:00 when empty, on the server's
#     own clock). Nights with nothing that needs it: no restart.
#
# A restart takes ePHEM down for about two minutes. Docker starts with the
# server and starts every container whose restart policy says so, which is
# all of them (docker-compose.yml); `check` below verifies both, because a
# container without the policy stays down after the first restart. That was
# the certbot container until November 2026: nothing looked broken, and the
# certificates would have run out some weeks later.
#
# Only the distribution's own security updates are installed, as it ships
# them. Docker Engine installed from Docker's repository is not among them:
# a new Docker restarts every container, so that one stays a decision of the
# administrator (sudo apt update && sudo apt upgrade, at a chosen moment).
#
# Two root-owned files, nothing else is edited:
#   /etc/apt/apt.conf.d/90ephem-host-updates
#   /etc/systemd/system/apt-daily-upgrade.timer.d/ephem.conf
# `remove` deletes both and the system is back to its own defaults.
#
# Usage:
#   bash scripts/host-updates.sh apply      turn it on, restart time from .env (sudo)
#   bash scripts/host-updates.sh remove     take our two files out again (sudo)
#   bash scripts/host-updates.sh status     what is in force, next run, last runs
#   bash scripts/host-updates.sh check      lines for the security check, no sudo;
#                                           exit 0 only when nothing needs attention
#   bash scripts/host-updates.sh supported  exit 0 when this machine can use it
#   bash scripts/host-updates.sh in-force   exit 0 when on and matching .env (quiet)
# ──────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EPHEM_ROOT="$SCRIPT_DIR"
# shellcheck source=stack-lib.sh
source "$SCRIPT_DIR/scripts/stack-lib.sh"

APT_CONF=/etc/apt/apt.conf.d/90ephem-host-updates
TIMER=apt-daily-upgrade.timer
TIMER_DROPIN=/etc/systemd/system/$TIMER.d/ephem.conf
DEFAULT_TIME=04:00

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 && SUDO=sudo
fi

valid_time() { [[ "${1:-}" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; }

# 04:00 → 03:00, 00:30 → 23:30. 10# because 08 and 09 are not octal numbers.
hour_before() { printf '%02d:%s' $(( (10#${1%%:*} + 23) % 24 )) "${1##*:}"; }

# The restart time .env asks for.
wanted_time() {
    local t; t="$(env_get HOST_REBOOT_TIME)"
    [ -n "$t" ] || t=$DEFAULT_TIME
    if ! valid_time "$t"; then
        echo -e "${RED}✗${NC} HOST_REBOOT_TIME in .env is '$t': a time like 04:00 is needed (24 hour clock)." >&2
        return 1
    fi
    printf '%s' "$t"
}

# A Debian or Ubuntu server with systemd. Not WSL: there the machine is
# Windows, which updates and restarts on its own terms.
supported() {
    [ "$(uname -s)" = Linux ] || return 1
    is_wsl && return 1
    command -v apt-get >/dev/null 2>&1 && command -v apt-config >/dev/null 2>&1 || return 1
    command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] || return 1
}

need_root_tools() {
    if ! supported; then
        echo -e "${RED}✗${NC} This needs a Debian or Ubuntu server with systemd. Elsewhere, turn on the"
        echo "     system's own automatic updates: HARDENING.md, Automatic security updates."
        exit 1
    fi
    if [ "$(id -u)" -ne 0 ] && [ -z "$SUDO" ]; then
        echo -e "${RED}✗${NC} Run as root, or install sudo."
        exit 1
    fi
}

# What apt has in force for one setting, whichever file set it. apt-config
# shell is apt's interface for scripts: it prints V='value', nothing when
# the setting is absent.
apt_value() {  # apt_value KEY
    local V=""
    eval "$(apt-config shell V "$1" 2>/dev/null || true)"
    printf '%s' "$V"
}

apt_true() {
    case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
        true|1|yes|on|with|enable) return 0 ;;
    esac
    return 1
}

updates_on() {
    command -v unattended-upgrade >/dev/null 2>&1 || return 1
    case "$(apt_value APT::Periodic::Unattended-Upgrade)" in ""|0) return 1 ;; esac
    systemctl is-enabled --quiet "$TIMER" 2>/dev/null
}

# On, and restarting at TIME, through our two files.
in_force() {  # in_force TIME
    updates_on || return 1
    [ -f "$APT_CONF" ] && [ -f "$TIMER_DROPIN" ] || return 1
    apt_true "$(apt_value Unattended-Upgrade::Automatic-Reboot)" || return 1
    [ "$(apt_value Unattended-Upgrade::Automatic-Reboot-Time)" = "$1" ] || return 1
    grep -qx "OnCalendar=\*-\*-\* $(hour_before "$1")" "$TIMER_DROPIN"
}

# Numbered 90 so it is read after the distribution's own files
# (20auto-upgrades, 50unattended-upgrades): the last value wins.
write_apt_conf() {  # write_apt_conf TIME OUT
    cat > "$2" <<EOF
// Generated by ephem-deploy (scripts/host-updates.sh apply), $(date '+%Y-%m-%d %H:%M').
// The server installs its security updates every night and restarts at $1
// (its own clock) when one of them needs it. Change HOST_REBOOT_TIME in that
// checkout's .env and run apply again: an edit here is overwritten.
// scripts/host-updates.sh remove deletes this file.
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "$1";
EOF
}

# The system's timer runs the updates at 06:00 plus up to an hour: in the
# working day wherever the server's clock is UTC and the country is east of
# it, and a day before the restart they ask for. One hour before the restart
# instead, so both happen in the same night. The empty OnCalendar= drops the
# stock time; without it systemd would keep both.
write_timer_dropin() {  # write_timer_dropin TIME OUT
    cat > "$2" <<EOF
# Generated by ephem-deploy (scripts/host-updates.sh apply).
# Updates install one hour before the restart time ($1). An edit here is
# overwritten by apply; scripts/host-updates.sh remove deletes this file.
[Timer]
OnCalendar=
OnCalendar=*-*-* $(hour_before "$1")
RandomizedDelaySec=15m
EOF
}

# Containers of this stack that would stay down after a restart of the
# server. One-off containers (docker compose run) are left out. Prints one
# name per line.
containers_without_restart() {
    local project name
    docker info >/dev/null 2>&1 || return 0
    project="$(compose_project)"
    docker ps -a --filter "label=com.docker.compose.project=$project" \
                 --filter "label=com.docker.compose.oneoff=False" --format '{{.Names}}' 2>/dev/null \
    | while read -r name; do
          [ -n "$name" ] || continue
          case "$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$name" 2>/dev/null)" in
              no) echo "$name" ;;
          esac
      done
}

# Docker itself at boot, then the containers. Returns 1 when something
# would stay down.
check_comes_back() {
    local rc=0 down
    if command -v systemctl >/dev/null 2>&1 && systemctl cat docker.service >/dev/null 2>&1; then
        if systemctl is-enabled --quiet docker 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} Docker starts with the server"
        else
            echo -e "  ${YELLOW}!${NC} Docker does not start with the server, so nothing comes back after a restart: sudo systemctl enable docker"
            rc=1
        fi
    fi
    down="$(containers_without_restart | tr '\n' ' ' || true)"
    if [ -n "${down% }" ]; then
        echo -e "  ${YELLOW}!${NC} not started again after a restart of the server: ${down% }"
        echo "     Their restart policy is missing (an older docker-compose.yml): git pull, then docker compose up -d"
        rc=1
    elif docker info >/dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} every container starts again after a restart of the server"
    fi
    return $rc
}

cmd_check() {
    local rc=0 want rtime
    if ! supported; then
        echo -e "  ${CYAN}→${NC} updates of this machine are not set from here (Debian or Ubuntu with systemd only): HARDENING.md"
        check_comes_back || rc=1
        return $rc
    fi
    if updates_on; then
        echo -e "  ${GREEN}✓${NC} the server installs its security updates by itself every night (unattended-upgrades)"
        rtime="$(apt_value Unattended-Upgrade::Automatic-Reboot-Time)"
        if apt_true "$(apt_value Unattended-Upgrade::Automatic-Reboot)"; then
            if [ -n "$rtime" ]; then
                echo -e "  ${GREEN}✓${NC} it restarts at $rtime when an update needs it (server clock: now $(date '+%H:%M %Z'))"
            else
                echo -e "  ${YELLOW}!${NC} it restarts as soon as an update needs it, at any hour (no restart time set): bash scripts/host-updates.sh apply"
                rc=1
            fi
        else
            echo -e "  ${YELLOW}!${NC} no automatic restart: a new kernel is not in use until someone restarts the server (bash scripts/host-updates.sh apply)"
            rc=1
        fi
        if [ "$(env_get HOST_AUTO_UPDATES)" = 1 ] && want="$(wanted_time 2>/dev/null)" && ! in_force "$want"; then
            echo -e "  ${YELLOW}!${NC} .env asks for a restart time of $want (HOST_REBOOT_TIME), the server is set differently: bash scripts/host-updates.sh apply"
            rc=1
        fi
    else
        echo -e "  ${YELLOW}!${NC} the server does not install its security updates by itself: bash scripts/host-updates.sh apply"
        rc=1
    fi
    if [ -f /var/run/reboot-required ]; then
        echo -e "  ${CYAN}→${NC} an installed update is waiting for a restart of the server$( [ -r /var/run/reboot-required.pkgs ] && printf ' (%s)' "$(sort -u /var/run/reboot-required.pkgs | tr '\n' ' ' | sed 's/ $//')" )"
    fi
    check_comes_back || rc=1
    return $rc
}

cmd_apply() {
    need_root_tools
    local t tmp
    t="$(wanted_time)" || exit 1
    if ! command -v unattended-upgrade >/dev/null 2>&1; then
        echo "  Installing unattended-upgrades…"
        $SUDO apt-get update -qq || true
        if ! $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unattended-upgrades >/dev/null; then
            echo -e "${RED}✗${NC} Could not install it: sudo apt-get install unattended-upgrades"
            exit 1
        fi
    fi
    tmp="$(mktemp -d)"
    write_apt_conf "$t" "$tmp/apt"
    write_timer_dropin "$t" "$tmp/timer"
    $SUDO install -m 0644 -o root -g root "$tmp/apt" "$APT_CONF"
    $SUDO install -D -m 0644 -o root -g root "$tmp/timer" "$TIMER_DROPIN"
    rm -rf "$tmp"
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable apt-daily.timer "$TIMER" >/dev/null 2>&1 || true
    # restart, not start: a running timer keeps the time it was started with.
    $SUDO systemctl restart "$TIMER" >/dev/null 2>&1 || true
    if systemctl cat docker.service >/dev/null 2>&1 && ! systemctl is-enabled --quiet docker 2>/dev/null; then
        $SUDO systemctl enable docker >/dev/null 2>&1 || true
    fi
    if ! in_force "$t"; then
        echo -e "${RED}✗${NC} Written, but the system does not report it in force. Look at:"
        echo "     apt-config dump | grep -i -e periodic -e unattended ; systemctl status $TIMER"
        exit 1
    fi
    echo -e "${GREEN}✓${NC} This server installs its security updates every night at about $(hour_before "$t")"
    echo "     and restarts at $t when one of them needs it (server clock: now $(date '+%H:%M %Z'))."
    echo "     ePHEM is down for about two minutes on those nights and comes back by itself."
    [ -f /var/run/reboot-required ] && echo "     A restart is already waiting: expect the first one at the next $t."
    check_comes_back || true
}

cmd_remove() {
    need_root_tools
    $SUDO rm -f "$APT_CONF" "$TIMER_DROPIN"
    $SUDO rmdir "$(dirname "$TIMER_DROPIN")" 2>/dev/null || true
    $SUDO systemctl daemon-reload
    $SUDO systemctl restart "$TIMER" >/dev/null 2>&1 || true
    echo -e "${GREEN}✓${NC} Removed: updates and restarts of this server follow the system's own settings again"
    if updates_on; then
        echo "     (unattended-upgrades stays installed and on, without a restart of ours)"
    fi
}

cmd_status() {
    cmd_check || true
    supported || return 0
    echo ""
    echo "  Our settings: $([ -f "$APT_CONF" ] && echo "$APT_CONF" || echo "not installed (bash scripts/host-updates.sh apply)")"
    echo "  Next run of the updates:"
    { systemctl list-timers "$TIMER" --no-pager 2>/dev/null || true; } | sed -n '1,2p' | sed 's/^/    /'
    if [ -r /var/log/unattended-upgrades/unattended-upgrades.log ]; then
        echo "  Last lines of its log (/var/log/unattended-upgrades/unattended-upgrades.log):"
        tail -n 6 /var/log/unattended-upgrades/unattended-upgrades.log | sed 's/^/    /'
    else
        echo "  Its log: sudo tail /var/log/unattended-upgrades/unattended-upgrades.log"
    fi
}

case "${1:-}" in
    apply)     cmd_apply ;;
    remove)    cmd_remove ;;
    status)    cmd_status ;;
    check)     cmd_check ;;
    supported) supported ;;
    in-force)  supported && t="$(wanted_time 2>/dev/null)" && in_force "$t" ;;
    *)         sed -n '2,41p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
