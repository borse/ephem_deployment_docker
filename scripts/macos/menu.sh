#!/bin/bash
# ──────────────────────────────────────────────────────────────
# menu.sh — the menu `bash manage.sh` opens on a native Mac setup: the same
# screens, keys, tables and colors as the Docker developer menu (manage.sh),
# acting on the native instances through dev.sh.
#
#   bash manage.sh          (on a Mac with .macos-native)
#   bash manage.sh 3        straight into instance 3
#   bash scripts/macos/dev.sh menu-plain    the older, plain text menu
#
# Every action runs `bash dev.sh …` as its own process, so a command that
# fails stops by itself and the menu comes back. Ctrl+C stops the command
# (a log that is being followed, an update), not the menu.
#
# Runs on macOS's own bash 3.2.
# ──────────────────────────────────────────────────────────────
set -o pipefail

# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

DEV="$MAC_DIR/dev.sh"
V2_ME="bash manage.sh"
native_installed || die "No native setup found in $NATIVE_HOME. Run: bash setup.sh  (Developer → Native)"
native_env || die "Homebrew is not installed. Run: bash scripts/macos/install.sh"

# ── Screens, tables ───────────────────────────
# ui.sh: copied from manage.sh (the Docker menu), so both menus look the same.
# shellcheck source=ui.sh
source "$MAC_DIR/ui.sh"

v2_mtime() { stat -f %m "$1" 2>/dev/null || echo 0; }

v2_ago() {  # v2_ago EPOCH
    local d=$(( $(date +%s) - $1 ))
    if   [ "$d" -lt 90 ];     then echo "just now"
    elif [ "$d" -lt 5400 ];   then echo "$(( d / 60 )) min ago"
    elif [ "$d" -lt 129600 ]; then echo "$(( d / 3600 )) h ago"
    else echo "$(( d / 86400 )) d ago"; fi
}

# ── Running dev.sh ────────────────────────────
# A handler (not "ignore") for Ctrl+C while a command runs: the command gets
# the signal and stops, the menu's handler does nothing and the menu goes on.
dev() {
    local rc
    trap 'true' INT
    bash "$DEV" "$@"; rc=$?
    trap - INT
    return "$rc"
}

# ── Instances and their state ─────────────────
INSTANCES=()
m_load_instances() {
    local n
    INSTANCES=()
    while IFS= read -r n; do [ -n "$n" ] && INSTANCES+=("$n"); done < <(instances)
}
m_is_instance() { local n; for n in "${INSTANCES[@]}"; do [ "$n" = "$1" ] && return 0; done; return 1; }

# running | starting | running in PyCharm | port taken | stopped
m_state() {  # m_state N
    local pid owner opid parent
    pid="$(inst_pid "$1")"
    if [ -n "$pid" ]; then
        if curl -fsS -o /dev/null --max-time 1 "http://127.0.0.1:$(inst_port "$1")/web/health" 2>/dev/null; then
            echo "running"
        else
            echo "starting"
        fi
        return 0
    fi
    owner="$(port_owner "$(inst_port "$1")")"
    if [ -n "$owner" ]; then
        opid="${owner%% *}"
        parent="$(ps -o comm= -p "$(ps -o ppid= -p "$opid" 2>/dev/null | tr -d ' ')" 2>/dev/null || true)"
        case "$parent" in *[Pp]y[Cc]harm*) echo "running in PyCharm" ;; *) echo "port taken" ;; esac
        return 0
    fi
    echo "stopped"
}

m_state_cell() {  # m_state_cell STATE: for a table
    case "$1" in
        running|"running in PyCharm") printf '%s' "$GREEN$V2_CS$1" ;;
        starting)                     printf '%s' "$YELLOW$V2_CS$1" ;;
        *)                            printf '%s' "$RED$V2_CS$1" ;;
    esac
}

m_state_colored() {  # m_state_colored STATE: for a line of text
    case "$1" in
        running|"running in PyCharm") echo -e "${GREEN}$1${NC}" ;;
        starting)                     echo -e "${YELLOW}$1${NC}" ;;
        *)                            echo -e "${RED}$1${NC}" ;;
    esac
}

m_pg_text() { if pg_ready; then echo -e "Postgres ${GREEN}running${NC}"; else echo -e "Postgres ${RED}not answering${NC} (brew services start $PG_FORMULA)"; fi; }

# ── Git, read only and without the network ────
m_dirty() {
    local n
    n=$(git --no-optional-locks -C "$1" status --porcelain --untracked-files=no 2>/dev/null | grep -c .) || n=0
    echo "${n:-0}"
}
m_branch() { local b; b=$(git -C "$1" branch --show-current 2>/dev/null) || b=""; echo "${b:-(detached)}"; }
m_last_commit() { git -C "$1" log -1 --format='%h %ad' --date=short 2>/dev/null || echo "-"; }

# Against the branch it tracks, as of the last fetch (ePHEM-core's local
# branch odcaN/X tracks origin/X).
m_sync() {  # m_sync DIR
    local lr ahead behind
    git -C "$1" rev-parse -q --verify '@{upstream}' >/dev/null 2>&1 || { echo "no upstream"; return 0; }
    lr=$(git -C "$1" rev-list --left-right --count 'HEAD...@{upstream}' 2>/dev/null) || { echo "?"; return 0; }
    ahead=${lr%%[[:space:]]*}; behind=${lr##*[[:space:]]}
    if   [ "$ahead" = 0 ] && [ "$behind" = 0 ]; then echo "up to date"
    elif [ "$ahead" = 0 ];  then echo "$behind behind"
    elif [ "$behind" = 0 ]; then echo "$ahead ahead"
    else echo "$behind behind, $ahead ahead"; fi
}

# When this repository last fetched: the clone's FETCH_HEAD (the ePHEM
# worktrees share the one of ePHEM/).
m_fetch_time() {  # m_fetch_time DIR → epoch, 0 when never
    local g; g=$(git -C "$1" rev-parse --git-common-dir 2>/dev/null) || { echo 0; return 0; }
    case "$g" in /*) ;; *) g="$1/$g" ;; esac
    v2_mtime "$g/FETCH_HEAD"
}
m_fetch_age() {  # m_fetch_age DIR
    local t; t=$(m_fetch_time "$1")
    if [ "$t" -gt 0 ]; then echo "as of the fetch $(v2_ago "$t")"; else echo "as of the clone, never fetched"; fi
}

# ── The tree: 1, 1.1, 1.2, 2, 2.1 … ───────────
# One row per repository: N.1 is ePHEM-core, N.2… the instance's others.
M_KEY=(); M_INST=(); M_NAME=(); M_DIR=(); M_BRANCH=(); M_CHANGES=(); M_SYNC=(); M_LAST=()
M_OLDEST_FETCH=0

m_add_row() {  # m_add_row KEY N NAME DIR
    local dir="$4" c t
    M_KEY+=("$1"); M_INST+=("$2"); M_NAME+=("$3"); M_DIR+=("$dir")
    if [ -e "$dir/.git" ]; then
        M_BRANCH+=("$(m_branch "$dir")")
        c=$(m_dirty "$dir")
        if [ "$c" -gt 0 ]; then M_CHANGES+=("$c file(s)"); else M_CHANGES+=("clean"); fi
        M_SYNC+=("$(m_sync "$dir")")
        M_LAST+=("$(m_last_commit "$dir")")
        t=$(m_fetch_time "$dir")
        if [ "$t" -gt 0 ] && { [ "$M_OLDEST_FETCH" -eq 0 ] || [ "$t" -lt "$M_OLDEST_FETCH" ]; }; then M_OLDEST_FETCH=$t; fi
    else
        M_BRANCH+=("(not a git clone)"); M_CHANGES+=("-"); M_SYNC+=("-"); M_LAST+=("-")
    fi
}

m_load_tree() {
    local n i r
    M_KEY=(); M_INST=(); M_NAME=(); M_DIR=(); M_BRANCH=(); M_CHANGES=(); M_SYNC=(); M_LAST=()
    M_OLDEST_FETCH=0
    m_load_instances
    for n in "${INSTANCES[@]}"; do
        if inst_old_layout "$n"; then
            m_add_row "$n.1" "$n" "$CORE_NAME" "$(inst_dir "$n")"
            continue
        fi
        [ -d "$(inst_core "$n")" ] && m_add_row "$n.1" "$n" "$CORE_NAME" "$(inst_core "$n")"
        i=2
        while IFS= read -r r; do
            [ -n "$r" ] || continue
            m_add_row "$n.$i" "$n" "$r" "$(inst_dir "$n")/$r"
            i=$((i + 1))
        done < <(inst_repos "$n")
    done
}

m_fetched_text() {
    if [ "$M_OLDEST_FETCH" -eq 0 ]; then echo "not fetched yet"; else echo "fetched $(v2_ago "$M_OLDEST_FETCH")"; fi
}

m_t_repo_row() {  # m_t_repo_row INDEX TREE_MARK
    local i="$1" chg="${M_CHANGES[$1]}" syn="${M_SYNC[$1]}"
    [ "$chg" = clean ] || [ "$chg" = "-" ] || chg="$YELLOW$V2_CS$chg"
    case "$syn" in *behind*) syn="$YELLOW$V2_CS$syn" ;; esac
    v2_t_add "${M_KEY[$i]}" "$2${M_NAME[$i]}" "${M_BRANCH[$i]}" "$chg" "$syn" "${M_LAST[$i]}"
}

m_tree_table() {  # m_tree_table [N]: one instance, or all
    local want="${1:-}" n i cnt seen mark
    v2_t_begin "No." "Where" "Branch" "State" "Origin" "Last commit"
    V2_T_SHRINK=2; V2_T_DROP=5
    for n in "${INSTANCES[@]}"; do
        [ -z "$want" ] || [ "$n" = "$want" ] || continue
        v2_t_add "$BOLD$V2_CS$n" "$BOLD${V2_CS}odca$n  :$(inst_port "$n")" "" "$(m_state_cell "$(m_state "$n")")" "" ""
        if inst_old_layout "$n"; then
            v2_t_add "" "$YELLOW${V2_CS}└ old layout: open it to move" "" "" "" ""
            continue
        fi
        cnt=0
        for ((i = 0; i < ${#M_KEY[@]}; i++)); do [ "${M_INST[$i]}" = "$n" ] && cnt=$((cnt + 1)); done
        seen=0
        for ((i = 0; i < ${#M_KEY[@]}; i++)); do
            [ "${M_INST[$i]}" = "$n" ] || continue
            seen=$((seen + 1))
            mark="├ "; [ "$seen" = "$cnt" ] && mark="└ "
            m_t_repo_row "$i" "$mark"
        done
    done
    if [ "${#INSTANCES[@]}" -eq 0 ]; then
        echo "  No instance yet: m (Maintenance), then a, adds one."
        return 0
    fi
    v2_t_draw
}

m_instance_table() {
    local n
    v2_t_begin "No." "Instance" "Database" "Port" "State"
    for n in "${INSTANCES[@]}"; do
        v2_t_add "$n" "odca$n" "$(inst_db "$n")" "$(inst_port "$n")" "$(m_state_cell "$(m_state "$n")")"
    done
    v2_t_draw
}

# ── Choosing what a number means ──────────────
V2_LOC=""; V2_VERB=""
V2_RE_LOC='^([0-9]+(\.[0-9]+)?)(.*)$'
V2_RE_NUM='^[0-9]+(\.[0-9]+)?$'

v2_parse() {  # "3.2 s", "3.2s", "s 3.2", "2 r", "r 2", "a p", "p a", "d"
    local first rest
    read -r first rest <<< "$1"
    V2_LOC=""; V2_VERB=""
    if [[ "${first:-}" =~ $V2_RE_LOC ]]; then
        V2_LOC="${BASH_REMATCH[1]}"; V2_VERB="${BASH_REMATCH[3]}${rest:-}"
    elif { [ "${first:-}" = a ] || [ "${first:-}" = A ]; } && [ -n "${rest:-}" ]; then
        V2_LOC=all; V2_VERB="$rest"
    elif [ "${rest:-}" = a ] || [ "${rest:-}" = A ]; then
        V2_LOC=all; V2_VERB="$first"
    elif [[ "${rest:-}" =~ $V2_RE_NUM ]]; then
        V2_LOC="$rest"; V2_VERB="$first"
    else
        V2_VERB="${first:-}${rest:+ $rest}"
    fi
}

m_find_row() {  # m_find_row KEY: its index, or 1
    local i
    for ((i = 0; i < ${#M_KEY[@]}; i++)); do
        [ "${M_KEY[$i]}" = "$1" ] && { echo "$i"; return 0; }
    done
    return 1
}

# Open a place, or do VERB there straight away.
m_go() {  # m_go LOC VERB
    local loc="$1" verb="$2" i n
    if [ "$loc" = all ]; then
        case "$verb" in
            p|P) v2_do m_pull_everywhere ;;
            f|F) v2_do dev fetch ;;
            *)   v2_bad "With a, the actions are p (pull everything) and f (fetch everything)." ;;
        esac
        return 0
    fi
    if i=$(m_find_row "$loc"); then
        if [ -z "$verb" ]; then m_repo_screen "$i"; return 0; fi
        m_repo_verb "$verb" "$i" && return 0
        # A Run action given a repository's number means the Odoo it belongs to.
        m_instance_verb "$verb" "${M_INST[$i]}" || v2_bad "$verb is not an action here: h lists them."
        return 0
    fi
    n="${loc%%.*}"
    if [ "$n" = "$loc" ] && m_is_instance "$n"; then
        if [ -z "$verb" ]; then m_instance_screen "$n"; return 0; fi
        case "$verb" in
            s|S) m_act_repo s "Switch a branch" "$n" ;;
            c|C) m_act_repo c "Show local changes" "$n" ;;
            n|N) m_act_repo n "Rename a repository" "$n" ;;
            k|K) m_act_repo k "Remove a repository" "$n" ;;
            *)   m_instance_verb "$verb" "$n" || v2_bad "$verb is not an action here: h lists them." ;;
        esac
        return 0
    fi
    v2_bad "Nothing is numbered $loc."
}

# Asks which repository when there is more than one. Sets M_PICK_ROW.
M_PICK_ROW=-1
m_pick_repo() {  # m_pick_repo TITLE [N]: 1 when backed out
    local title="$1" scope="${2:-}" i cnt=0 only=-1 first=-1 n
    m_load_tree
    for ((i = 0; i < ${#M_KEY[@]}; i++)); do
        if [ -z "$scope" ] || [ "${M_INST[$i]}" = "$scope" ]; then
            cnt=$((cnt + 1)); only=$i
            [ "$first" -lt 0 ] && first=$i
        fi
    done
    if [ "$cnt" -eq 0 ]; then v2_bad "No repository here yet: + adds one."; return 1; fi
    if [ "$cnt" -eq 1 ]; then M_PICK_ROW=$only; return 0; fi
    while true; do
        v2_title "$title"
        m_tree_table "$scope"
        v2_head "Which repository"
        v2_opt "${M_KEY[$first]}" "Type its number from the table"
        v2_opt Enter "Back"
        v2_prompt
        case "$V2_ANS" in
            ""|b|B) return 1 ;;
            x|X)    v2_bye ;;
        esac
        if i=$(m_find_row "$V2_ANS"); then M_PICK_ROW=$i; return 0; fi
        if m_is_instance "$V2_ANS"; then
            cnt=0
            for ((i = 0; i < ${#M_KEY[@]}; i++)); do
                if [ "${M_INST[$i]}" = "$V2_ANS" ]; then cnt=$((cnt + 1)); only=$i; fi
            done
            if [ "$cnt" -eq 1 ]; then M_PICK_ROW=$only; return 0; fi
            v2_bad "odca$V2_ANS has more than one repository: type one of its numbers."
            continue
        fi
        v2_bad "Nothing is numbered $V2_ANS."
    done
}

m_act_repo() {  # m_act_repo VERB TITLE [N]
    m_pick_repo "$2" "${3:-}" || return 0
    m_repo_verb "$1" "$M_PICK_ROW"
}

# Asks which instance when there is more than one. Sets M_PICK_N.
M_PICK_N=""
m_pick_instance() {  # m_pick_instance TITLE: 1 when backed out
    m_load_instances
    if [ "${#INSTANCES[@]}" -eq 0 ]; then v2_bad "No instance yet: m (Maintenance), then a, adds one."; return 1; fi
    if [ "${#INSTANCES[@]}" -eq 1 ]; then M_PICK_N="${INSTANCES[0]}"; return 0; fi
    while true; do
        v2_title "$1"
        m_instance_table
        v2_head "Which instance"
        v2_opt "${INSTANCES[0]}" "Type its number from the table"
        v2_opt Enter "Back"
        v2_prompt
        case "$V2_ANS" in
            ""|b|B) return 1 ;;
            x|X)    v2_bye ;;
        esac
        if m_is_instance "${V2_ANS%%.*}"; then M_PICK_N="${V2_ANS%%.*}"; return 0; fi
        v2_bad "Nothing is numbered $V2_ANS."
    done
}

m_act_instance() {  # m_act_instance VERB TITLE
    m_pick_instance "$2" || return 0
    m_instance_verb "$1" "$M_PICK_N" || v2_bad
}

# ── Old layout ────────────────────────────────
m_old_instances() {
    local n out=""
    m_load_instances
    for n in "${INSTANCES[@]}"; do inst_old_layout "$n" && out="$out $n"; done
    echo "${out# }"
}

m_migrate() {  # m_migrate N…
    v2_title "Move into odcaN/$CORE_NAME/" "The layout of the Docker developer stack: other repositories can then go next to ePHEM."
    echo "  Branches, commits and uncommitted changes move with the worktree; a running"
    echo "  instance is restarted. Stop an instance that PyCharm runs first."
    echo ""
    # shellcheck disable=SC2068  # one word per instance number
    dev migrate $@
    echo ""
    echo "  Editors and coding agents opened in odcaN/ before: reopen them."
    echo "  PyCharm: the git roots are now odcaN/$CORE_NAME (Settings → Version Control → Directory Mappings)."
}

m_layout_blocked() {  # m_layout_blocked N: 0 (and a notice) when it has the old layout
    if inst_old_layout "$1"; then
        v2_bad "odca$1 still has the old layout: open it ($1), then w moves it."
        return 0
    fi
    return 1
}

# ── Pull, fetch ───────────────────────────────
m_pull_everywhere() {
    local n
    m_load_instances
    for n in "${INSTANCES[@]}"; do
        inst_old_layout "$n" && { echo -e "  ${YELLOW}!${NC} odca$n: old layout, skipped"; continue; }
        echo -e "  ${BOLD}odca$n${NC}"
        dev repo pull "$n" || true
        echo ""
    done
}

m_fetch_repo() {  # m_fetch_repo DIR LABEL
    echo -e "  ${CYAN}→${NC} $2: git fetch --prune origin"
    if GIT_TERMINAL_PROMPT=0 git -C "$1" fetch --prune origin; then
        echo -e "  ${GREEN}✓${NC} fetched: $(m_branch "$1") is $(m_sync "$1")"
    else
        echo -e "  ${RED}✗${NC} fetch failed: see git's message above (network, or your SSH key)."
    fi
}

# ── A repository ──────────────────────────────
m_show_changes() {  # m_show_changes DIR LABEL
    local out n=0 line
    out=$(git --no-optional-locks -C "$1" status --short 2>/dev/null) || out=""
    v2_title "Local changes: $2"
    if [ -z "$out" ]; then echo "  Clean: nothing to show."; return 0; fi
    v2_t_begin "State" "File"
    V2_T_SHRINK=1
    while IFS= read -r line; do
        n=$((n + 1))
        [ "$n" -le 60 ] && v2_t_add "${line:0:2}" "${line:3}"
    done <<< "$out"
    v2_t_draw
    [ "$n" -gt 60 ] && echo "  and $((n - 60)) more"
    return 0
}

# The branches to choose from: for ePHEM-core the branches of origin (its own
# local branch is odcaN/<that>), for another repository origin's plus its
# local ones. Newest first, from the last fetch: no network.
M_BR_NAME=(); M_BR_WHEN=(); M_BR_NOTE=()
m_load_branches() {  # m_load_branches DIR IS_CORE CURRENT_BASE
    local dir="$1" core="$2" cur="$3" raw name when note
    M_BR_NAME=(); M_BR_WHEN=(); M_BR_NOTE=()
    if [ "$core" = 1 ]; then
        raw=$(git -C "$dir" for-each-ref --sort=-committerdate \
                --format='%(refname:strip=3)%09%(committerdate:relative)' refs/remotes/origin 2>/dev/null | grep -v '^HEAD	')
    else
        raw=$(git -C "$dir" for-each-ref --sort=-committerdate \
                --format='%(refname)%09%(committerdate:relative)' refs/heads refs/remotes/origin 2>/dev/null | awk -F'\t' '
            { if ($1 ~ /^refs\/heads\//) { n = substr($1, 12); here = 1 }
              else                       { n = substr($1, 21); here = 0 }
              if (n == "HEAD") next
              if (!(n in seen)) { seen[n] = $2; order[++c] = n }
              if (!here) origin[n] = 1 }
            END { for (i = 1; i <= c; i++) {
                      n = order[i]
                      print n "\t" seen[n] "\t" ((n in origin) ? "" : "local only") } }')
    fi
    if [ "$core" = 1 ] && [ "$DEFAULT_BRANCH" != "$cur" ]; then
        while IFS=$'\t' read -r name when note; do
            if [ "$name" = "$DEFAULT_BRANCH" ]; then M_BR_NAME+=("$name"); M_BR_WHEN+=("${when:-}"); M_BR_NOTE+=("recommended"); fi
        done <<< "$raw"
    fi
    while IFS=$'\t' read -r name when note; do
        [ -n "$name" ] || continue
        [ "$name" = "$cur" ] && continue
        [ "$core" = 1 ] && [ "$name" = "$DEFAULT_BRANCH" ] && continue
        M_BR_NAME+=("$name"); M_BR_WHEN+=("${when:-}"); M_BR_NOTE+=("${note:-}")
    done <<< "$raw"
    [ "${#M_BR_NAME[@]}" -gt 0 ]
}

# Sets M_PICK; 1 when cancelled.
M_PICK=""; M_BR_SHOW=15
m_pick_branch() {  # m_pick_branch DIR IS_CORE CURRENT_BASE LABEL
    local dir="$1" core="$2" cur="$3" label="$4" filter="" i j n
    local -a shown=()
    m_load_branches "$dir" "$core" "$cur" || { v2_bad "No other branch known: f in the repository fetches the list."; return 1; }
    while true; do
        shown=()
        shopt -s nocasematch
        for ((i = 0; i < ${#M_BR_NAME[@]}; i++)); do
            if [ -z "$filter" ] || [[ "${M_BR_NAME[$i]}" == *"$filter"* ]]; then shown+=("$i"); fi
        done
        shopt -u nocasematch
        n=${#shown[@]}
        if [ -n "$filter" ] && [ "$n" -eq 0 ]; then
            v2_bad "Nothing matches '$filter'. f gets the newest list from origin."
            filter=""
            continue
        fi
        v2_title "Switch a branch: $label" "Now on ${BOLD}$cur${NC}. ${#M_BR_NAME[@]} other branch(es), $(m_fetch_age "$dir")."
        [ -n "$filter" ] && { echo -e "  Matching ${BOLD}$filter${NC}"; echo ""; }
        v2_t_begin "No." "Branch" "Last commit" "Note"
        V2_T_SHRINK=1; V2_T_DROP=2
        for ((j = 0; j < n && j < M_BR_SHOW; j++)); do
            i=${shown[$j]}
            v2_t_add "$((j + 1))" "${M_BR_NAME[$i]}" "${M_BR_WHEN[$i]}" "${M_BR_NOTE[$i]}"
        done
        v2_t_draw
        [ "$n" -gt "$M_BR_SHOW" ] && echo "  $((n - M_BR_SHOW)) more not shown: type part of a name to narrow the list."
        v2_head "Choose"
        if [ -n "$filter" ] && [ "$n" -eq 1 ]; then
            v2_opt Enter "Switch to this branch"
            v2_opt text "Type another part of a name"
            v2_opt b "Back"
        elif [ -n "$filter" ]; then
            v2_opt number "Switch to that branch"
            v2_opt text "Type more of the name"
            v2_opt Enter "Show the whole list"
            v2_opt b "Back"
        else
            v2_opt number "Switch to that branch"
            v2_opt text "Type part of a name to filter the list"
            v2_opt f "Fetch from origin first"
            v2_opt Enter "Back"
        fi
        v2_prompt
        case "$V2_ANS" in
            "")
                if [ -z "$filter" ]; then return 1; fi
                if [ "$n" -eq 1 ]; then V2_ANS=1; else filter=""; continue; fi
                ;;
            b|B) return 1 ;;
            x|X) v2_bye ;;
            f|F)
                v2_clear
                m_fetch_repo "$dir" "$label"
                m_load_branches "$dir" "$core" "$cur" || return 1
                filter=""
                continue
                ;;
        esac
        for ((i = 0; i < ${#M_BR_NAME[@]}; i++)); do
            if [ "${M_BR_NAME[$i]}" = "$V2_ANS" ]; then M_PICK="$V2_ANS"; return 0; fi
        done
        if [[ "$V2_ANS" =~ ^[0-9]+$ ]] && [ "$V2_ANS" -ge 1 ] && [ "$V2_ANS" -le "$n" ] && [ "$V2_ANS" -le "$M_BR_SHOW" ]; then
            M_PICK="${M_BR_NAME[${shown[$((V2_ANS - 1))]}]}"
            return 0
        fi
        filter="$V2_ANS"
    done
}

m_switch() {  # m_switch INDEX
    local i="$1" n="${M_INST[$1]}" name="${M_NAME[$1]}" dir="${M_DIR[$1]}" cur core=0
    cur="$(m_branch "$dir")"
    if [ "$name" = "$CORE_NAME" ]; then core=1; cur="${cur#odca$n/}"; fi
    m_pick_branch "$dir" "$core" "$cur" "odca$n / $name" || return 0
    v2_clear
    if [ "$core" = 1 ]; then
        dev switch "$n" "$M_PICK" || true
    else
        dev repo switch "$n" "$name" "$M_PICK" || true
    fi
    v2_pause
}

m_repo_verb() {  # m_repo_verb VERB INDEX: 1 when not a repository action
    local verb="$1" i="$2" n name dir label new
    n="${M_INST[$i]}"; name="${M_NAME[$i]}"; dir="${M_DIR[$i]}"; label="odca$n / $name"
    case "$verb" in
        s|S|p|P|n|N|k|K) m_layout_blocked "$n" && return 0 ;;
        c|C|f|F) ;;
        *) return 1 ;;
    esac
    case "$verb" in
        s|S) m_switch "$i" ;;
        p|P) v2_do dev repo pull "$n" "$name" ;;
        c|C) v2_do m_show_changes "$dir" "$label" ;;
        f|F) v2_do m_fetch_repo "$dir" "$label" ;;
        n|N)
            if [ "$name" = "$CORE_NAME" ]; then v2_bad "$CORE_NAME is the ePHEM worktree: its name is the same everywhere."; return 0; fi
            v2_title "Rename $label"
            read -r -p "  New folder name (Enter cancels): " new || v2_bye
            [ -n "$new" ] || { v2_bad "Cancelled."; return 0; }
            v2_do dev repo rename "$n" "$name" "$new"
            ;;
        k|K)
            if [ "$name" = "$CORE_NAME" ]; then v2_bad "$CORE_NAME is the ePHEM worktree: remove the instance instead (m, then k)."; return 0; fi
            v2_do dev repo remove "$n" "$name"
            ;;
    esac
    return 0
}

m_repo_screen() {  # m_repo_screen INDEX
    local i="$1" n name dir label dirty url
    n="${M_INST[$i]}"; name="${M_NAME[$i]}"; dir="${M_DIR[$i]}"; label="odca$n / $name"
    while true; do
        [ -e "$dir" ] || return 0      # renamed or removed
        v2_title "$label"
        v2_t_begin
        V2_T_SHRINK=1
        if [ -e "$dir/.git" ]; then
            dirty=$(m_dirty "$dir")
            v2_t_add "Branch" "$BOLD$V2_CS$(m_branch "$dir")"
            if [ "$dirty" -gt 0 ]; then v2_t_add "Changes" "$YELLOW$V2_CS$dirty file(s)"; else v2_t_add "Changes" "clean"; fi
            v2_t_add "Origin" "$(m_sync "$dir"), $(m_fetch_age "$dir")"
            url="$(git -C "$dir" remote get-url origin 2>/dev/null || true)"
            v2_t_add "Remote" "${url:-none}"
            v2_t_add "Last commit" "$(git -C "$dir" log -1 --format='%h %ad %s' --date=short 2>/dev/null)"
        else
            v2_t_add "Git" "$YELLOW${V2_CS}not a git clone"
        fi
        v2_t_add "Folder" "$dir"
        v2_t_add "Modules" "$(module_count_dir "$dir")"
        v2_t_draw
        v2_head "This repository"
        v2_opt s "Switch branch"
        v2_opt p "Pull the latest code"
        v2_opt c "Show local changes"
        v2_opt f "Fetch from origin"
        if [ "$name" != "$CORE_NAME" ]; then
            v2_opt n "Rename"
            v2_opt k "Remove"
        fi
        v2_nav
        v2_prompt
        case "$V2_ANS" in
            ""|b|B) return 0 ;;
            x|X)    v2_bye ;;
            *)      m_repo_verb "$V2_ANS" "$i" || v2_bad ;;
        esac
        m_load_tree
    done
}

module_count_dir() { local m c=0; for m in "$1"/*/__manifest__.py; do [ -f "$m" ] && c=$((c + 1)); done; echo "$c"; }

# ── An instance ───────────────────────────────
m_add_repo() {  # m_add_repo N
    local n="$1" spec br name dflt
    m_layout_blocked "$n" && { V2_NO_PAUSE=1; return 0; }
    v2_title "Add a repository to odca$n" "It is cloned into odca$n/<name>/ next to $CORE_NAME and put on this instance's addons path after it."
    echo "  A repository whose top level holds Odoo modules (<module>/__manifest__.py)."
    echo "  owner/name means GitHub over SSH, with the key the ePHEM clone uses."
    echo ""
    read -r -p "  Repository (owner/name, git@…, https://…; Enter cancels): " spec || v2_bye
    [ -n "$spec" ] || { v2_cancel; return 0; }
    dflt="$(basename "${spec%/}")"; dflt="${dflt%.git}"
    read -r -p "  Folder name [$dflt]: " name || v2_bye
    read -r -p "  Branch (Enter: the one $CORE_NAME follows if it has it, else its default): " br || v2_bye
    echo ""
    dev repo add "$n" "$spec" ${br:+"$br"} --name "${name:-$dflt}"
}

m_update() {  # m_update N
    local n="$1" mods
    v2_title "Update modules: odca$n" "Database $(inst_db "$n"). The instance stops for it and starts again if it was running."
    dev changed "$n" 2>/dev/null || true
    v2_head "Which modules"
    v2_opt Enter "Only what changed (with no record yet, every installed module once)"
    v2_opt a "Every module of odca$n's repositories (Odoo skips the ones not installed)"
    v2_opt names "Type them, comma separated: eoc_signals,eoc_base"
    v2_opt b "Back"
    v2_prompt
    case "$V2_ANS" in
        b|B) V2_NO_PAUSE=1; return 0 ;;
        x|X) v2_bye ;;
        "")  v2_clear; dev update "$n" --changed; return ;;
        a|A) mods="" ;;
        *)
            if ! [[ "$V2_ANS" =~ ^[A-Za-z0-9_]+(,[A-Za-z0-9_]+)*$ ]]; then
                v2_cancel "Module names: letters, digits and underscores, separated by commas."; return 0
            fi
            mods="$V2_ANS"
            ;;
    esac
    v2_clear
    dev update "$n" ${mods:+"$mods"}
}

m_install() {  # m_install N
    local n="$1"
    v2_title "Install modules: odca$n" "Database $(inst_db "$n")."
    read -r -p "  Module names, comma separated (Enter cancels): " V2_ANS || v2_bye
    [ -n "$V2_ANS" ] || { v2_cancel; return 0; }
    if ! [[ "$V2_ANS" =~ ^[A-Za-z0-9_]+(,[A-Za-z0-9_]+)*$ ]]; then
        v2_cancel "Module names: letters, digits and underscores, separated by commas."; return 0
    fi
    dev install "$n" "$V2_ANS"
}

m_start_stop() {  # m_start_stop N
    case "$(m_state "$1")" in
        running|starting)     dev stop "$1" ;;
        "running in PyCharm") echo -e "  ${YELLOW}!${NC} odca$1 runs in PyCharm: stop it there (the red square)." ;;
        "port taken")         echo -e "  ${RED}✗${NC} Port $(inst_port "$1") is taken by another program: $(port_owner "$(inst_port "$1")")" ;;
        *)                    dev start "$1" ;;
    esac
}

m_start_stop_label() { case "$(m_state "$1")" in running|starting) echo "Stop" ;; *) echo "Start" ;; esac; }

m_instance_verb() {  # m_instance_verb VERB N: 1 when not an instance action
    local n="$2"
    case "$1" in
        r|R) v2_clear; dev restart "$n" && dev logs "$n" ;;
        o|O) v2_do dev restart "$n" ;;
        l|L) v2_clear; echo "  Ctrl+C returns to the menu."; dev logs "$n" ;;
        t|T) v2_do m_start_stop "$n" ;;
        u|U) v2_do m_update "$n" ;;
        i|I) v2_do m_install "$n" ;;
        p|P) m_layout_blocked "$n" || v2_do dev repo pull "$n" ;;
        f|F) v2_do dev fetch ;;
        +)   v2_do m_add_repo "$n" ;;
        w|W) if inst_old_layout "$n"; then v2_do m_migrate "$n"; else v2_bad "odca$n already has the $CORE_NAME/ layout."; fi ;;
        *)   return 1 ;;
    esac
    return 0
}

m_repo_options() {  # the same list wherever repositories are the subject
    v2_head "Repositories and branches"
    v2_opt s "Switch a branch"
    v2_opt p "Pull the latest code"
    v2_opt c "Show local changes"
    v2_opt f "Fetch from origin"
    v2_opt + "Add a repository"
    v2_opt n "Rename a repository"
    v2_opt k "Remove a repository"
}

m_run_options() {  # m_run_options [N]
    v2_head "Run"
    v2_opt r "Restart and follow the log"
    v2_opt o "Restart only"
    v2_opt l "Follow the log"
    if [ -n "${1:-}" ]; then v2_opt t "$(m_start_stop_label "$1")"; else v2_opt t "Start or stop"; fi
    v2_opt u "Update modules"
    v2_opt i "Install a module"
}

m_instance_screen() {  # m_instance_screen N
    local n="$1"
    while true; do
        m_load_tree
        m_is_instance "$n" || return 0       # removed meanwhile
        v2_title "odca$n" "$(inst_url "$n"), database $(inst_db "$n"), $(m_state_colored "$(m_state "$n")"), $(m_fetched_text)"
        m_tree_table "$n"
        if inst_old_layout "$n"; then
            echo ""
            echo -e "  ${YELLOW}!${NC} Old layout: odca$n/ itself is the ePHEM worktree. w moves it into odca$n/$CORE_NAME/,"
            echo "     so other repositories can go next to it."
            v2_head "Layout"
            v2_opt w "Move it into odca$n/$CORE_NAME/"
        fi
        m_repo_options
        m_run_options "$n"
        v2_nav
        echo ""
        echo "  Type a letter from the list, or a number from the table."
        v2_prompt
        [ -n "$V2_ANS" ] || return 0
        v2_parse "$V2_ANS"
        if [ -n "$V2_LOC" ]; then m_go "$V2_LOC" "$V2_VERB"; continue; fi
        case "$V2_VERB" in
            b|B) return 0 ;;
            x|X) v2_bye ;;
            s|S) m_act_repo s "Switch a branch" "$n" ;;
            c|C) m_act_repo c "Show local changes" "$n" ;;
            n|N) m_act_repo n "Rename a repository" "$n" ;;
            k|K) m_act_repo k "Remove a repository" "$n" ;;
            *)   m_instance_verb "$V2_VERB" "$n" || v2_bad ;;
        esac
    done
}

# ── Databases ─────────────────────────────────
m_db_size() {  # m_db_size DB
    "$PG_BIN/psql" -X -d postgres -Atc "SELECT pg_size_pretty(pg_database_size('$1'))" 2>/dev/null || echo "?"
}
m_db_exists() { [ "$("$PG_BIN/psql" -X -d postgres -Atc "SELECT 1 FROM pg_database WHERE datname = '$1'" 2>/dev/null)" = 1 ]; }

m_db_table() {
    local n db cnt latest t
    v2_t_begin "No." "Database" "Instance" "Size" "Snapshots" "Latest"
    for n in "${INSTANCES[@]}"; do
        db="$(inst_db "$n")"
        cnt=$(ls -1d "$BACKUP_DIR/${db}"_* 2>/dev/null | grep -c . || true)
        latest=$(ls -1d "$BACKUP_DIR/${db}"_* 2>/dev/null | sort | tail -1 || true)
        if [ -n "$latest" ]; then t="$(v2_ago "$(v2_mtime "$latest")")"; else t="-"; fi
        if m_db_exists "$db"; then
            v2_t_add "$n" "$db" "odca$n" "$(m_db_size "$db")" "${cnt:-0}" "$t"
        else
            v2_t_add "$n" "$db" "odca$n" "$YELLOW${V2_CS}not created" "${cnt:-0}" "$t"
        fi
    done
    v2_t_draw
}

m_restore() {  # m_restore N
    local n="$1" db list i cnt src neu=""
    db="$(inst_db "$n")"
    v2_title "Restore into $db" "It REPLACES the database and its files. A snapshot, a .zip from Odoo's database manager or from Windows, or a .dump / .sql file."
    list=$(ls -1d "$BACKUP_DIR/${db}"_* 2>/dev/null | sort -r || true)
    cnt=$(printf '%s\n' "$list" | grep -c . || true)
    if [ "$cnt" -gt 0 ]; then
        v2_t_begin "No." "Snapshot" "Taken"
        i=0
        while IFS= read -r src; do
            [ -n "$src" ] || continue
            i=$((i + 1)); [ "$i" -le 15 ] || break
            v2_t_add "$i" "$(basename "$src")" "$(v2_ago "$(v2_mtime "$src")")"
        done <<< "$list"
        v2_t_draw
    else
        echo "  No snapshot of $db yet in $BACKUP_DIR."
    fi
    echo ""
    read -r -p "  A number from the table, or the path of a file or folder (Enter cancels): " V2_ANS || v2_bye
    [ -n "$V2_ANS" ] || { v2_cancel; return 0; }
    if [[ "$V2_ANS" =~ ^[0-9]+$ ]] && [ "$V2_ANS" -ge 1 ] && [ "$V2_ANS" -le "$cnt" ]; then
        src=$(printf '%s\n' "$list" | sed -n "${V2_ANS}p")
    else
        src="${V2_ANS/#\~/$HOME}"
    fi
    confirm "  Neutralize it (mail servers and scheduled actions off: for a copy of production)?" N && neu="--neutralize"
    echo ""
    dev restore "$n" "$src" $neu
}

m_snapshot_all() {
    local n
    for n in "${INSTANCES[@]}"; do
        m_db_exists "$(inst_db "$n")" || { echo "  $(inst_db "$n"): not created, skipped"; continue; }
        dev backup "$n" || true
        echo ""
    done
}

m_databases() {
    while true; do
        m_load_instances
        v2_title "Databases and backups" "A database plus its files (filestore); a snapshot carries both, into $BACKUP_DIR."
        m_db_table
        v2_head "One database"
        v2_opt s "Snapshot: database + files into backups/"
        v2_opt r "Restore a snapshot or a file into it"
        v2_opt n "Create it empty (module base, admin / admin)"
        v2_head "All databases"
        v2_opt e "Snapshot every database, one folder each"
        v2_nav
        echo ""
        echo "  Type a letter, optionally with the number: s 2"
        v2_prompt
        v2_parse "$V2_ANS"
        if [ -n "$V2_LOC" ] && [ "$V2_LOC" != all ]; then
            m_is_instance "${V2_LOC%%.*}" || { v2_bad "Nothing is numbered $V2_LOC."; continue; }
            M_PICK_N="${V2_LOC%%.*}"
        else
            M_PICK_N=""
        fi
        case "$V2_VERB" in
            ""|b|B) return 0 ;;
            x|X) v2_bye ;;
            s|S) [ -n "$M_PICK_N" ] || m_pick_instance "Snapshot a database" || continue; v2_do dev backup "$M_PICK_N" ;;
            r|R) [ -n "$M_PICK_N" ] || m_pick_instance "Restore into which database" || continue; v2_do m_restore "$M_PICK_N" ;;
            n|N) [ -n "$M_PICK_N" ] || m_pick_instance "Create which database" || continue; v2_do dev initdb "$M_PICK_N" ;;
            e|E) v2_do m_snapshot_all ;;
            *)   v2_bad ;;
        esac
    done
}

# ── Maintenance ───────────────────────────────
m_wkhtml_version() { "$TOOLS/wkhtmltox/bin/wkhtmltopdf" --version 2>/dev/null | head -1 || echo "missing"; }

m_conf_all() {
    local n
    for n in "${INSTANCES[@]}"; do dev conf "$n" || true; done
}

m_maintenance() {
    local old office
    while true; do
        m_load_instances
        old="$(m_old_instances)"
        if [ "$(nenv_get OFFICE)" = 1 ]; then office="on"; else office="off"; fi
        v2_title "Maintenance" "native macOS, $NATIVE_HOME"
        v2_t_begin
        V2_T_SHRINK=1
        v2_t_add "Odoo source" "$ODOO_BRANCH, $(git -C "$ODOO_SRC" log -1 --format='%h %ad' --date=short 2>/dev/null)"
        v2_t_add "Python" "$("$PY" -V 2>&1 | awk '{print $2}') ($VENV)"
        v2_t_add "Postgres" "$("$PG_BIN/postgres" --version 2>/dev/null | awk '{print $3}'), $(pg_ready && echo running || echo 'not answering')"
        v2_t_add "wkhtmltopdf" "$(m_wkhtml_version)"
        v2_t_add "Office converter" "$office"
        v2_t_draw
        v2_head "Instances"
        v2_opt a "Add an instance: number, branch, database"
        v2_opt k "Remove an instance: database, files, folder (asks first)"
        [ -n "$old" ] && v2_opt g "Move old-layout instances into odcaN/$CORE_NAME/ ($old)"
        v2_opt c "Write every instance's config again (conf/odoo-N.conf)"
        v2_head "Software"
        v2_opt o "Office converter: $( [ "$office" = on ] && echo stop || echo start ) it (a Docker container, for ePHEM AI)"
        v2_opt i "Run the installer again: checks the tools, Postgres and the packages"
        v2_opt u "Update the Odoo source and its packages"
        v2_nav
        v2_prompt
        case "$V2_ANS" in
            ""|b|B) return 0 ;;
            x|X) v2_bye ;;
            a|A) v2_do dev new ;;
            k|K) m_pick_instance "Remove an instance" && v2_do dev remove "$M_PICK_N" ;;
            g|G) if [ -n "$old" ]; then v2_do m_migrate $old; else v2_bad; fi ;;
            c|C) v2_do m_conf_all ;;
            o|O) if [ "$office" = on ]; then v2_do dev office stop; else v2_do dev office start; fi ;;
            i|I) v2_do bash "$MAC_DIR/install.sh" --no-instances ;;
            u|U) v2_do bash "$MAC_DIR/install.sh" --no-instances --update-odoo ;;
            *)   v2_bad ;;
        esac
    done
}

# ── Status and checks ─────────────────────────
m_errors() {  # m_errors N: the last errors in its log
    local log; log="$(inst_log "$1")"
    v2_title "Errors in the log of odca$1" "$log"
    [ -f "$log" ] || { echo "  No log yet: the instance has never been started."; return 0; }
    if ! grep -a -E ' (ERROR|CRITICAL) ' "$log" | tail -n 25 | sed 's/\x1b\[[0-9;]*m//g' | cut -c1-200 | grep .; then
        echo -e "  ${GREEN}✓${NC} no ERROR or CRITICAL line in it."
    fi
}

m_status() {
    while true; do
        m_load_instances
        v2_title "Status and checks" "native macOS, $NATIVE_HOME"
        dev status | tail -n +2
        v2_head "Checks"
        v2_t_begin
        V2_T_SHRINK=1
        if pg_ready; then v2_t_add "Postgres" "$GREEN${V2_CS}answering on 127.0.0.1:$(db_port)"; else v2_t_add "Postgres" "$RED${V2_CS}not answering: brew services start $PG_FORMULA"; fi
        case "$(m_wkhtml_version)" in
            *"patched qt"*) v2_t_add "wkhtmltopdf" "$GREEN${V2_CS}$(m_wkhtml_version)" ;;
            *)              v2_t_add "wkhtmltopdf" "$RED${V2_CS}$(m_wkhtml_version): PDF reports need the patched one (install.sh)" ;;
        esac
        if [ -x "$TOOLS/node/node_modules/.bin/rtlcss" ]; then v2_t_add "rtlcss" "present (Arabic pages)"; else v2_t_add "rtlcss" "$RED${V2_CS}missing: run the installer again"; fi
        v2_t_add "Disk" "$(df -h "$NATIVE_HOME" 2>/dev/null | awk 'NR == 2 { print $4 " free" }'), the native home uses $(du -sh "$NATIVE_HOME" 2>/dev/null | awk '{print $1}')"
        v2_t_draw
        v2_head "Logs"
        v2_opt e "The last errors in an instance's log"
        v2_opt l "Follow an instance's log"
        v2_nav
        v2_prompt
        v2_parse "$V2_ANS"
        M_PICK_N=""
        if [ -n "$V2_LOC" ] && [ "$V2_LOC" != all ]; then M_PICK_N="${V2_LOC%%.*}"; fi
        case "$V2_VERB" in
            ""|b|B) return 0 ;;
            x|X) v2_bye ;;
            e|E) [ -n "$M_PICK_N" ] || m_pick_instance "Errors in which log" || continue; v2_do m_errors "$M_PICK_N" ;;
            l|L) [ -n "$M_PICK_N" ] || m_pick_instance "Follow which log" || continue; m_instance_verb l "$M_PICK_N" ;;
            *)   v2_bad ;;
        esac
    done
}

# ── Help ──────────────────────────────────────
m_pycharm() {
    v2_title "PyCharm" "One window on $NATIVE_HOME shows every instance."
    v2_t_begin
    V2_T_SHRINK=1
    v2_t_add "Open" "$NATIVE_HOME (File → Open)"
    v2_t_add "Interpreter" "$PY"
    v2_t_add "Source root" "$ODOO_SRC (Mark Directory as → Sources Root)"
    v2_t_add "Exclude" "backups, data, logs, run, tools, venv, ePHEM"
    v2_t_add "Git roots" "odcaN/$CORE_NAME and each other repository (Settings → Version Control → Directory Mappings)"
    v2_t_add "Debug" "script $ODOO_SRC/odoo-bin, parameters -c $CONF_DIR/odoo-N.conf --dev=xml --logfile=, after stopping that instance here"
    v2_t_draw
    echo ""
    echo "  docs/macos-native-dev.md, section PyCharm, has the rest."
}

m_help() {
    while true; do
        v2_title "How this menu works"
        echo "  Choose from the list and it asks where. Or put the letter and the number"
        echo "  on one line and it goes straight there."
        echo ""
        v2_t_begin "You type" "What happens"
        v2_t_add "s" "Switch a branch: asks which repository"
        v2_t_add "s 3.2" "Switch the branch of repository 3.2"
        v2_t_add "p 3.2" "Pull that repository"
        v2_t_add "p 2" "Pull every repository of instance 2"
        v2_t_add "p a" "Pull every repository of every instance"
        v2_t_add "c 3.2" "Show its local changes"
        v2_t_add "f 3.2" "Fetch that repository (f a: everything)"
        v2_t_add "+ 3" "Add a repository to instance 3"
        v2_t_add "n 3.2" "Rename that repository"
        v2_t_add "k 3.2" "Remove that repository"
        v2_t_add "r 2" "Restart instance 2 and follow its log"
        v2_t_add "u 2" "Update modules on instance 2"
        v2_t_add "3" "Open instance 3"
        v2_t_add "3.2" "Open repository 3.2: details and its actions"
        v2_t_add "Enter or b" "Go back one level"
        v2_t_add "x" "Leave, from anywhere"
        v2_t_draw
        echo ""
        echo "  The Origin column (behind, ahead) is what a clone knew at its last fetch."
        echo "  Ctrl+C stops what is running (a log, an update) and comes back here."
        v2_head "Docs"
        echo "    docs/macos-native-dev.md in this folder"
        echo "    https://github.com/borse/ephem_deployment_docker#readme"
        echo ""
        echo "  The same actions as commands: bash scripts/macos/dev.sh help"
        echo "  The older plain menu: bash scripts/macos/dev.sh menu-plain"
        v2_head "More"
        v2_opt p "PyCharm: paths, Git roots, debugging"
        v2_nav
        v2_prompt
        case "$V2_ANS" in
            ""|b|B) return 0 ;;
            x|X)    v2_bye ;;
            p|P)    v2_do m_pycharm ;;
            *)      v2_bad ;;
        esac
    done
}

# ── Home ──────────────────────────────────────
m_home_options() {
    m_repo_options
    m_run_options
    v2_head "More"
    v2_opt d "Databases and backups: snapshot, restore, create"
    v2_opt m "Maintenance: add or remove an instance, office converter, installer"
    v2_opt v "Status and checks"
    v2_opt h "Help"
    v2_opt x "Exit"
    echo ""
    echo "  Type a letter from the list, or a number from the table."
}

# Instances made before the ePHEM-core/ layout: offered once per start.
m_offer_migrate() {
    local old; old="$(m_old_instances)"
    [ -n "$old" ] || return 0
    v2_title "ePHEM developer menu"
    echo -e "  ${YELLOW}!${NC} Instance(s) $old still have the old layout: odcaN/ itself is the ePHEM worktree."
    echo "     They move into odcaN/$CORE_NAME/, the layout of the Docker developer stack, so other"
    echo "     repositories can go next to ePHEM. Branches, commits and uncommitted changes move"
    echo "     with them; a running instance is restarted."
    echo ""
    if confirm "  Move them now?" Y; then
        # shellcheck disable=SC2086  # one word per instance number
        v2_do m_migrate $old
    fi
}

m_home() {
    while true; do
        m_load_tree
        v2_title "ePHEM developer menu" "native macOS ($NATIVE_HOME), $(m_pg_text), $(m_fetched_text)"
        m_tree_table
        m_home_options
        v2_prompt
        [ -n "$V2_ANS" ] || continue
        v2_parse "$V2_ANS"
        if [ -n "$V2_LOC" ]; then m_go "$V2_LOC" "$V2_VERB"; continue; fi
        case "$V2_VERB" in
            x|X)     v2_bye ;;
            b|B)     ;;
            s|S)     m_act_repo s "Switch a branch" ;;
            p|P)     m_pick_instance "Pull the latest code: which instance" && { m_layout_blocked "$M_PICK_N" || v2_do dev repo pull "$M_PICK_N"; } ;;
            c|C)     m_act_repo c "Show local changes" ;;
            f|F)     v2_do dev fetch ;;
            +)       m_act_instance + "Add a repository" ;;
            n|N)     m_act_repo n "Rename a repository" ;;
            k|K)     m_act_repo k "Remove a repository" ;;
            r|R)     m_act_instance r "Restart and follow the log" ;;
            o|O)     m_act_instance o "Restart only" ;;
            l|L)     m_act_instance l "Follow the log" ;;
            t|T)     m_act_instance t "Start or stop" ;;
            u|U)     m_act_instance u "Update modules" ;;
            i|I)     m_act_instance i "Install a module" ;;
            d|D)     m_databases ;;
            m|M)     m_maintenance ;;
            v|V)     m_status ;;
            h|H|'?') m_help ;;
            *)       v2_bad ;;
        esac
    done
}

# ── Start ─────────────────────────────────────
# `bash manage.sh 2`: into that instance first; back lands on the home screen.
m_offer_migrate
m_load_instances
if [ -n "${1:-}" ] && m_is_instance "$1"; then
    m_instance_screen "$1"
fi
m_home
