#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────
# Bash completion for scripts/dev-logs.sh
# Lists Odoo module names after -u / -i (and --update / --init),
# scoped to the right custom-addons-<name>/ folder based on the
# multi-instance name you typed.
#
# Handles comma-separated values: complete after the last comma,
# e.g.  -u eoc_signals,eoc_<TAB>  →  -u eoc_signals,eoc_incident_management
#
# ── Install (once per user) ────────────────────────────────────
#   echo "source $PWD/scripts/dev-logs-completion.bash" >> ~/.bashrc
#   exec bash    # or open a new terminal
#
# ── Use ───────────────────────────────────────────────────────
#   ./scripts/dev-logs.sh 1 -u eoc_<TAB>           # modules in custom-addons-1/
#   ./scripts/dev-logs.sh 1 -u mod1,mod2,<TAB>     # complete after last comma
#   ./scripts/dev-logs.sh -u <TAB>                 # single-instance → custom-addons/
#
# ── Caveats ───────────────────────────────────────────────────
# • Completion is registered for the command name `dev-logs.sh`, so it
#   triggers when you invoke the script DIRECTLY (e.g. `./scripts/dev-logs.sh`).
#   Calling `bash scripts/dev-logs.sh …` will NOT autocomplete — bash sees
#   `bash` as the command, not `dev-logs.sh`.
# • Make sure the script is executable:  chmod +x scripts/dev-logs.sh
# ──────────────────────────────────────────────────────────────

_dev_logs_list_modules() {
    # $1 = repo root, $2 = instance name (may be empty → single-instance)
    local addons_dir
    if [ -n "$2" ]; then
        addons_dir="$1/custom-addons-$2"
    else
        addons_dir="$1/custom-addons"
    fi
    [ -d "$addons_dir" ] || return 0
    local d
    for d in "$addons_dir"/*/; do
        [ -f "$d/__manifest__.py" ] || [ -f "$d/__openerp__.py" ] || continue
        basename "$d"
    done
}

_dev_logs_complete() {
    local cur prev script_path script_dir repo_root
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    script_path="${COMP_WORDS[0]}"

    # Resolve repo root from the invoked script path.
    if command -v realpath >/dev/null 2>&1; then
        script_path="$(realpath "$script_path" 2>/dev/null || echo "$script_path")"
    fi
    script_dir="$(dirname "$script_path")"
    repo_root="$(cd "$script_dir/.." 2>/dev/null && pwd)" || return 0
    [ -z "$repo_root" ] && return 0

    # First non-flag positional after $0 is the multi-instance name (if any).
    local name="" i w
    for (( i=1; i<COMP_CWORD; i++ )); do
        w="${COMP_WORDS[i]}"
        [ -z "$w" ] && continue
        if [[ "$w" == -* ]]; then break; fi
        name="$w"
        break
    done

    # Only kick in right after -u / -i / --update / --init.
    case "$prev" in
        -u|-i|--update|--init) ;;
        *) return 0 ;;
    esac

    # Gather modules
    local modules=() m
    while IFS= read -r m; do
        [ -n "$m" ] && modules+=("$m")
    done < <(_dev_logs_list_modules "$repo_root" "$name")
    [ ${#modules[@]} -eq 0 ] && return 0

    # Comma-separated: complete the token after the last comma, keep the rest as prefix.
    local prefix="" suffix="$cur"
    if [[ "$cur" == *,* ]]; then
        prefix="${cur%,*},"
        suffix="${cur##*,}"
    fi

    # Substring match (not prefix-only): typing 'incident' matches
    # 'eoc_incident_management'. Empty suffix → list everything.
    local matches=()
    local needle
    needle="$(printf '%s' "$suffix" | tr '[:upper:]' '[:lower:]')"
    for m in "${modules[@]}"; do
        if [ -z "$needle" ] || [[ "$(printf '%s' "$m" | tr '[:upper:]' '[:lower:]')" == *"$needle"* ]]; then
            matches+=("${prefix}${m}")
        fi
    done

    COMPREPLY=("${matches[@]}")
    # 'nospace' lets you keep typing `,nextmodule` right after a completion,
    # without bash inserting a trailing space.
    compopt -o nospace 2>/dev/null || true
}

complete -F _dev_logs_complete dev-logs.sh
