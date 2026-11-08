#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════
# dev-autostart.sh: bring the ePHEM dev containers back after Windows starts.
#
# Why: Docker Desktop starts its containers as soon as Windows logs in,
# often BEFORE Ubuntu (WSL) has shared the project folder. The container then
# fails to mount its files ("not a directory ... odoo.conf"), exits with code
# 127, and Docker does not try again, so ePHEM is down although nothing is
# broken.
#
# What it does: waits until Docker answers, then starts every ephem-N container
# that failed at start-up (Docker recorded a start error). Containers that you
# stopped yourself, or that are running, are left alone. It never removes,
# recreates or updates anything.
#
#   bash scripts/dev-autostart.sh              # run once now
#   bash scripts/dev-autostart.sh --install    # run it each time Ubuntu starts
#   bash scripts/dev-autostart.sh --uninstall  # stop doing that
#   journalctl --user -u ephem-autostart       # what it did
# ════════════════════════════════════════════════════════════════
set -uo pipefail

UNIT=ephem-autostart.service
UNIT_DIR="$HOME/.config/systemd/user"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
WAIT_SECONDS=${EPHEM_AUTOSTART_WAIT:-900}

case "${1:-}" in
  --install)
    mkdir -p "$UNIT_DIR"
    cat > "$UNIT_DIR/$UNIT" <<EOF
[Unit]
Description=Start ePHEM dev containers that failed while Ubuntu was not ready

[Service]
Type=oneshot
ExecStart=/usr/bin/env bash $SELF

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable "$UNIT"
    echo "✓ Installed: runs each time Ubuntu starts. Log: journalctl --user -u ${UNIT%.service}"
    exit 0 ;;
  --uninstall)
    systemctl --user disable "$UNIT" 2>/dev/null
    rm -f "$UNIT_DIR/$UNIT"
    systemctl --user daemon-reload
    echo "✓ Removed."
    exit 0 ;;
  "") ;;
  *) echo "usage: $0 [--install|--uninstall]" >&2; exit 2 ;;
esac

# 1. Wait for Docker Desktop (it may still be starting, or not opened yet).
waited=0
until docker info >/dev/null 2>&1; do
  if (( waited >= WAIT_SECONDS )); then
    echo "✗ Docker did not answer within ${WAIT_SECONDS}s: open Docker Desktop, then run: bash $SELF"
    exit 1
  fi
  sleep 5; waited=$((waited + 5))
done
echo "Docker is up (waited ${waited}s)."

# 2. Start the ePHEM containers whose last start failed.
started=0
for c in $(docker ps -a --filter 'name=^ephem-[0-9]+$' --format '{{.Names}}'); do
  read -r status err <<<"$(docker inspect "$c" --format '{{.State.Status}} {{if .State.Error}}failed{{else}}-{{end}}')"
  if [[ "$status" != "running" && "$err" == "failed" ]]; then
    echo "→ $c failed at start-up: starting it again"
    if docker start "$c" >/dev/null; then started=$((started + 1)); else echo "✗ $c still does not start: see docker logs $c"; fi
  fi
done
echo "Done: $started container(s) started."
