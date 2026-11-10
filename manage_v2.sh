#!/bin/bash
# ──────────────────────────────────────────────
# ePHEM Menu, version 2. On trial next to manage.sh, which it does not change.
#
#     bash manage_v2.sh        # the home screen
#     bash manage_v2.sh 2      # multi-instance: straight into instance 2
#
# Every screen is a table of what is there and a list of what can be done.
# Choose from the list and it asks where; or type a number from the table
# first; or both on one line once you know them:
#
#     s          switch a branch (asks which repository)
#     3.2        open repository 2 of instance 3
#     s 3.2      switch that repository's branch (3.2 s works too)
#     r 2        restart instance 2 and follow its log
#     p a        pull every repository of every instance
#
# A server, or a developer checkout with one Odoo, has one addons folder, so
# its repositories are simply 1, 2, 3.
#
# Screens read only this machine: what a clone knows about origin is what it
# learned at its last fetch, and the screen says how old that is. Only fetch,
# pull, switch and add go to the network, and an SSH key's passphrase is asked
# right before the first of those that needs it.
#
# This file is the navigation. The work itself (restore, delete, clone, nginx,
# certificates, snapshots) is manage.sh's own code, loaded below, so the two
# menus cannot disagree while both exist.
# ──────────────────────────────────────────────
set -uo pipefail

V2_ROOT="$(cd "$(dirname "$0")" && pwd)"
V2_BASE="$V2_ROOT/manage.sh"
V2_CUT='^# ── Menu loop ─'
V2_ME="bash manage_v2.sh"

if [ ! -f "$V2_BASE" ] || ! grep -q "$V2_CUT" "$V2_BASE"; then
    echo "manage_v2.sh needs manage.sh next to it, with its '# ── Menu loop' line."
    exit 1
fi

# manage.sh's screens are reused as they are, except for the sentences that
# send people to its old menu numbers. A rule that stops matching only leaves
# the old sentence on screen.
V2_TEXTS=$(cat <<'RULES'
s#Re-open anytime:  bash manage\.sh#Re-open anytime:  bash manage_v2.sh#g
s#menu 3 (Addons) moves it into#open its number here to move it into#
s#Addons menu item moves it into#menu offers to move it into#
s#OFFICE_CONVERTER=0, Advanced → Document converter#OFFICE_CONVERTER=0, installed from Maintenance (m)#
s#use menu item 7, and add#use Databases (d), then a, and add#
s#(Advanced → Databases → Backup)#(Databases (d), open one, then s)#
s#Advanced → Databases when you are ready#Databases (d) when you are ready#
s#SSL with main menu → 3 and these#HTTPS with s on this screen and these#
s#from Advanced → Databases if#from Databases (d) if#
s#run menu item 6 next#update the modules next#
s#(update modules across databases)\. To roll back#(Update, then m). To roll back#
s#first (options 4 and 5)#first (open it, then k or n)#
s#come back here (Addons → Add a source) with#come back here (+ again) with#
s#domain (menu item 2) nor the Databases menu next door needs it#domain nor the Databases menu needs it#
s#bash manage\.sh → Stack → Recreate the whole stack#bash manage_v2.sh, Maintenance (m), then c#
s#disable it via Advanced → 3#disable it in Web access (w)#
s#any setting in Advanced → RPC endpoints#any setting in Web access (w)#
s#via Advanced → 4#in Web access (w)#
s#(Restore menu, option 2)#(Databases, then r)#
s#on disk — option 3 removes it#on disk: open it, k, then 3 removes it#
s#Remove them from the Stack menu (6)#Remove them from Maintenance (m)#
s#no whole-server backup yet (menu 10)#no whole-server backup yet (Databases (d), then a)#
s#no per-database snapshots yet (Databases → Backup)#no per-database snapshots yet (Databases (d), open one, then s)#
s#main menu \$(backup_item), or Databases → Backup\.#Databases (d), then a.#
s#Start fresh: Stack → 4, then#Start fresh: Maintenance (m), c, then#
s#run menu 5 next\.#update modules next (u on the instance).#
s#menu item 2 (Manage domains)#a or r on the Web access screen#
s#Menu item 2 → 3 splits#c on the Web access screen splits#
RULES
)

# Everything above manage.sh's menu loop: its preamble (mode, instance, checks)
# and all its functions. Arguments reach its stack_init as they would there.
V2_CODE=$(sed -e "$V2_TEXTS" -e "/$V2_CUT/,\$d" "$V2_BASE") || exit 1
eval "$V2_CODE"
unset V2_CODE V2_TEXTS
if ! declare -f menu_db_restore >/dev/null; then
    echo "manage_v2.sh could not load the functions of manage.sh."
    exit 1
fi

# ── What changes in manage.sh's own helpers ───
services_hint() { if local_mode; then echo "press m, then c"; else echo "press r"; fi; }

# The Y/n before the passphrase goes: the passphrase prompt is the question.
ensure_github_ssh() { v2_ssh_unlock; }

# Remove and rename start by asking which source. Here it is already chosen.
V2_SOURCE=""
pick_source() { PICKED_SOURCE="$V2_SOURCE"; [ -n "$PICKED_SOURCE" ]; }

# Same for a database opened from the list; elsewhere the usual list.
V2_DB=""
eval "$(declare -f pick_db | sed '1s/pick_db/v2_pick_db_listed/')"
pick_db() {
    if [ -n "$V2_DB" ]; then PICKED_DB="$V2_DB"; return 0; fi
    v2_pick_db_listed "$@"
}

# ── Screens, tables, lists ────────────────────
V2_NOTICE=""        # one line for the next screen: a screen clears what came before
V2_NO_PAUSE=0

v2_bye()   { echo "Bye. Re-open anytime:  $V2_ME"; exit 0; }
v2_ask()   { read -r -p "$1" V2_ANS || { echo ""; v2_bye; }; }    # EOF leaves, as in manage.sh
v2_bad()   { V2_NOTICE="${1:-Invalid choice.}"; }
v2_clear() { if [ -t 1 ]; then printf '\033[H\033[2J'; fi; }

v2_cols() {
    local c; c=$(tput cols 2>/dev/null) || c=""
    case "$c" in ""|0|*[!0-9]*) c=100 ;; esac
    echo "$c"
}

v2_title() {  # v2_title TITLE [DETAIL]
    v2_clear
    echo ""
    echo -e "  ${BOLD}$1${NC}"
    if [ -n "${2:-}" ]; then echo -e "  $2"; fi
    echo ""
}

v2_head() { echo ""; echo -e "  ${BOLD}$1${NC}"; }                 # names a group of options
v2_opt()  { printf '    %b%-7s%b %s\n' "$CYAN$BOLD" "$1" "$NC" "$2"; }   # one option, one line
v2_nav()  { echo ""; v2_opt b "Back"; v2_opt x "Exit"; }

v2_prompt() {  # the prompt that ends a screen
    echo ""
    if [ -n "$V2_NOTICE" ]; then
        echo -e "  ${YELLOW}!${NC} $V2_NOTICE"
        echo ""
        V2_NOTICE=""
    fi
    v2_ask "  > "
}

v2_pause() { echo ""; read -r -p "  Press Enter to go back " V2_ANS || v2_bye; }

# One action on a clean screen, its result kept there until Enter. A cancel,
# or backing out of one of manage.sh's own menus, returns at once.
v2_do() {  # v2_do COMMAND...
    CHOICE=""; V2_NO_PAUSE=0
    v2_clear
    "$@" || true
    if [ "$CHOICE" = b ] || [ "$V2_NO_PAUSE" = 1 ]; then return 0; fi
    v2_pause
}

v2_cancel() { V2_NOTICE="${1:-Cancelled.}"; V2_NO_PAUSE=1; }

# Tables. v2_t_begin HEADERS (none for a two-column fact sheet), v2_t_add per
# row, v2_t_draw. Columns fit their contents and the terminal: a column with
# nothing in it is not drawn; if it is still too wide V2_T_DROP goes, then
# V2_T_SHRINK is cut short. A cell can be "$COLOR$V2_CS text", and may start
# with a tree mark. Marks are kept out of the width sums: printf and ${#x}
# count bytes in a C locale, so only plain text may be measured.
V2_FS=$'\x1f'; V2_CS=$'\x1d'
V2_T_HEAD=(); V2_T_ROWS=(); V2_T_DROP=-1; V2_T_SHRINK=-1

v2_t_begin() { V2_T_HEAD=("$@"); V2_T_ROWS=(); V2_T_DROP=-1; V2_T_SHRINK=-1; }
v2_t_add()   { local IFS="$V2_FS"; V2_T_ROWS+=("$*"); }

v2_t_rule() {  # v2_t_rule LEFT MIDDLE RIGHT: reads the caller's keep and w
    local s="" seg k
    for ((k = 0; k < ${#keep[@]}; k++)); do
        printf -v seg '%*s' "$(( w[keep[k]] + 2 ))" ''
        seg="${seg// /─}"
        if [ "$k" -eq 0 ]; then s="$1$seg"; else s="$s$2$seg"; fi
    done
    printf ' %s%s\n' "$s" "$3"
}

v2_t_draw() {
    local ncols=${#V2_T_HEAD[@]} has_head=1 r c k len text rest total cols color glyph width
    local -a w=() used=() cells=() keep=() kept=()
    if [ "${#V2_T_ROWS[@]}" -eq 0 ]; then echo "  (nothing to show)"; return 0; fi
    if [ "$ncols" -eq 0 ]; then
        has_head=0
        for ((r = 0; r < ${#V2_T_ROWS[@]}; r++)); do
            IFS="$V2_FS" read -r -a cells <<< "${V2_T_ROWS[$r]}"
            [ "${#cells[@]}" -gt "$ncols" ] && ncols=${#cells[@]}
        done
    fi
    for ((c = 0; c < ncols; c++)); do
        used[c]=0; w[c]=0
        [ "$has_head" = 1 ] && w[c]=${#V2_T_HEAD[$c]}
    done
    for ((r = 0; r < ${#V2_T_ROWS[@]}; r++)); do
        IFS="$V2_FS" read -r -a cells <<< "${V2_T_ROWS[$r]}"
        for ((c = 0; c < ncols; c++)); do
            text="${cells[$c]:-}"; text="${text#*"$V2_CS"}"
            [ -n "$text" ] && used[c]=1
            rest="${text#├ }"; rest="${rest#└ }"
            if [ "$rest" != "$text" ]; then len=$(( ${#rest} + 2 )); else len=${#text}; fi
            [ "$len" -gt "${w[$c]}" ] && w[c]=$len
        done
    done
    total=2
    for ((c = 0; c < ncols; c++)); do
        if [ "${used[$c]}" = 1 ]; then keep+=("$c"); total=$(( total + w[c] + 3 )); fi
    done
    cols=$(v2_cols)
    if [ "$total" -gt "$cols" ] && [ "$V2_T_DROP" -ge 0 ] && [ "${used[$V2_T_DROP]:-0}" = 1 ]; then
        total=$(( total - w[V2_T_DROP] - 3 ))
        for ((k = 0; k < ${#keep[@]}; k++)); do
            [ "${keep[$k]}" = "$V2_T_DROP" ] || kept+=("${keep[$k]}")
        done
        keep=("${kept[@]}")
    fi
    if [ "$total" -gt "$cols" ] && [ "$V2_T_SHRINK" -ge 0 ]; then
        len=$(( w[V2_T_SHRINK] - (total - cols) ))
        [ "$len" -lt 12 ] && len=12
        w[V2_T_SHRINK]=$len
    fi
    v2_t_rule "┌" "┬" "┐"
    if [ "$has_head" = 1 ]; then
        printf ' │'
        for ((k = 0; k < ${#keep[@]}; k++)); do
            c=${keep[$k]}
            printf ' %b%-*s%b │' "$BOLD" "${w[$c]}" "${V2_T_HEAD[$c]}" "$NC"
        done
        printf '\n'
        v2_t_rule "├" "┼" "┤"
    fi
    for ((r = 0; r < ${#V2_T_ROWS[@]}; r++)); do
        IFS="$V2_FS" read -r -a cells <<< "${V2_T_ROWS[$r]}"
        printf ' │'
        for ((k = 0; k < ${#keep[@]}; k++)); do
            c=${keep[$k]}
            text="${cells[$c]:-}"; color=""
            case "$text" in *"$V2_CS"*) color="${text%%"$V2_CS"*}"; text="${text#*"$V2_CS"}" ;; esac
            glyph=""; width=${w[$c]}
            rest="${text#├ }"
            if [ "$rest" != "$text" ]; then glyph="├ "; text="$rest"; width=$((width - 2)); fi
            rest="${text#└ }"
            if [ "$rest" != "$text" ]; then glyph="└ "; text="$rest"; width=$((width - 2)); fi
            [ "${#text}" -gt "$width" ] && text="${text:0:$((width - 2))}.."
            printf ' %s%b%-*s%b │' "$glyph" "$color" "$width" "$text" "$NC"
        done
        printf '\n'
    done
    v2_t_rule "└" "┴" "┘"
}

# ── Small helpers ─────────────────────────────
v2_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

v2_ago() {  # v2_ago EPOCH
    local d=$(( $(date +%s) - $1 ))
    if   [ "$d" -lt 90 ];     then echo "just now"
    elif [ "$d" -lt 5400 ];   then echo "$(( d / 60 )) min ago"
    elif [ "$d" -lt 129600 ]; then echo "$(( d / 3600 )) h ago"
    else echo "$(( d / 86400 )) d ago"; fi
}

# docker inspect on the fixed container name, because `docker compose ps` per
# instance would make every redraw of the tree take a second or more.
v2_state() {  # v2_state CONTAINER
    local st; st=$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' "$1" 2>/dev/null) || st=""
    case "${st%% *}" in
        running) echo "running" ;;
        "")      echo "not created" ;;
        exited)  echo "exited (${st#* })" ;;
        *)       echo "${st%% *}" ;;
    esac
}

v2_state_colored() {  # v2_state_colored STATE: for a line of text
    case "$1" in
        running)       echo -e "${GREEN}running${NC}" ;;
        "not created") echo -e "${YELLOW}not created${NC}" ;;
        *)             echo -e "${RED}$1${NC}" ;;
    esac
}

v2_state_cell() {  # v2_state_cell STATE: for a table
    case "$1" in
        running)       printf '%s' "$GREEN${V2_CS}running" ;;
        "not created") printf '%s' "$YELLOW${V2_CS}not created" ;;
        *)             printf '%s' "$RED${V2_CS}$1" ;;
    esac
}

# Files with uncommitted changes. No optional locks: the tree is redrawn all
# the time and must never hold the index against an editor or another session.
v2_dirty() {
    local n
    n=$(git --no-optional-locks -C "$1" status --porcelain --untracked-files=no 2>/dev/null | grep -c .) || n=0
    echo "${n:-0}"
}

# Against the last fetched origin. No network.
v2_sync() {  # v2_sync DIR
    local dir="$1" b lr ahead behind
    b=$(git -C "$dir" branch --show-current 2>/dev/null) || b=""
    if [ -z "$b" ]; then echo "detached"; return 0; fi
    if ! git -C "$dir" rev-parse -q --verify "refs/remotes/origin/$b" >/dev/null 2>&1; then
        echo "not on origin"; return 0
    fi
    lr=$(git -C "$dir" rev-list --left-right --count "refs/heads/$b...refs/remotes/origin/$b" 2>/dev/null) || { echo "?"; return 0; }
    ahead=${lr%%[[:space:]]*}; behind=${lr##*[[:space:]]}
    if   [ "$ahead" = 0 ] && [ "$behind" = 0 ]; then echo "up to date"
    elif [ "$ahead" = 0 ];  then echo "$behind behind"
    elif [ "$behind" = 0 ]; then echo "$ahead ahead"
    else echo "$behind behind, $ahead ahead"; fi
}

# ── SSH, asked for when it is needed ──────────
# Called right before a git command that goes to origin, and nowhere else. A
# deploy key alias, HTTPS or a local path never comes this far; a key with no
# passphrase, or one an agent already holds, passes without a word.
V2_SSH_READY=0

v2_ssh_unlock() {
    [ "$V2_SSH_READY" = 1 ] && return 0
    local key rc=0 listed fp
    key=$(ssh_key_file) || key=""
    if [ -z "$key" ] || ! ssh_key_encrypted "$key"; then
        V2_SSH_READY=1
        return 0
    fi
    listed=$(ssh-add -l 2>/dev/null) || rc=$?       # 0 keys, 1 no keys, 2 no agent
    if [ "$rc" -eq 0 ] && [ -f "$key.pub" ]; then
        fp=$(ssh-keygen -lf "$key.pub" 2>/dev/null | awk '{print $2}')
        if [ -n "$fp" ]; then
            case "$listed" in *"$fp"*) V2_SSH_READY=1; return 0 ;; esac
        fi
    fi
    # ssh-add reads the passphrase from stdin when stdin is not a terminal,
    # which is why no loop that reaches this may read from a pipe.
    if [ ! -t 0 ]; then
        echo -e "  ${RED}✗${NC} $key needs its passphrase and there is no terminal to ask on."
        return 1
    fi
    if [ "$rc" -eq 2 ]; then
        eval "$(ssh-agent -s)" >/dev/null 2>&1
        trap 'ssh-agent -k >/dev/null 2>&1' EXIT    # stops with this menu
    fi
    run_interruptible ssh-add "$key" || return 1    # empty passphrase or Ctrl-C cancels
    V2_SSH_READY=1
}

V2_NET_CANCELLED=0
v2_net_ready() {  # v2_net_ready DIR
    local remote; remote=$(git -C "$1" remote get-url origin 2>/dev/null || echo "")
    remote_uses_own_key "$remote" || return 0
    v2_ssh_unlock && return 0
    V2_NET_CANCELLED=1
    return 1
}

# ── The tree ──────────────────────────────────
# One entry per repository: 1.1, 1.2, 2.1 in multi-instance, 1, 2 otherwise.
V2_KEY=(); V2_INST=(); V2_SRC=(); V2_DIR=(); V2_BRANCH=(); V2_CHANGES=(); V2_SYNC=(); V2_LAST=()
V2_OLDEST_FETCH=0

# All-number rosters keep their own numbers (odca3 is 3 even after odca2 goes);
# anything else is numbered by position.
v2_roster_numeric() {
    local n
    for n in "${INSTANCES[@]}"; do [[ "$n" =~ ^[0-9]+$ ]] || return 1; done
    return 0
}
v2_inst_key() {  # v2_inst_key NAME
    if v2_roster_numeric; then echo "$1"; else echo $(( $(inst_index "$1") + 1 )); fi
}
v2_inst_of_key() {  # v2_inst_of_key KEY: 1 when no such instance
    local n
    for n in "${INSTANCES[@]}"; do
        [ "$(v2_inst_key "$n")" = "$1" ] && { echo "$n"; return 0; }
    done
    return 1
}

v2_add_row() {  # v2_add_row KEY INSTANCE SOURCE DIR
    local dir="$4" n t
    V2_KEY+=("$1"); V2_INST+=("$2"); V2_SRC+=("$3"); V2_DIR+=("$dir")
    if [ -d "$dir/.git" ]; then
        V2_BRANCH+=("$(src_branch "$dir")")
        n=$(v2_dirty "$dir")
        if [ "$n" -gt 0 ]; then V2_CHANGES+=("$n file(s)"); else V2_CHANGES+=("clean"); fi
        V2_SYNC+=("$(v2_sync "$dir")")
        V2_LAST+=("$(src_last_commit "$dir")")
        t=$(v2_mtime "$dir/.git/FETCH_HEAD")
        if [ "$t" -gt 0 ] && { [ "$V2_OLDEST_FETCH" -eq 0 ] || [ "$t" -lt "$V2_OLDEST_FETCH" ]; }; then
            V2_OLDEST_FETCH=$t
        fi
    else
        V2_BRANCH+=("(not a git clone)"); V2_CHANGES+=("-"); V2_SYNC+=("-"); V2_LAST+=("-")
    fi
}

v2_load_tree() {
    V2_KEY=(); V2_INST=(); V2_SRC=(); V2_DIR=(); V2_BRANCH=(); V2_CHANGES=(); V2_SYNC=(); V2_LAST=()
    V2_OLDEST_FETCH=0
    local n i s key
    if [ "$EPHEM_MODE" = dev-multi ]; then
        for n in "${INSTANCES[@]}"; do
            key=$(v2_inst_key "$n"); i=1
            while IFS= read -r s; do
                [ -n "$s" ] || continue
                v2_add_row "$key.$i" "$n" "$s" "$EPHEM_ROOT/odca$n/$s"
                i=$((i + 1))
            done < <(addons_sources "$EPHEM_ROOT/odca$n")
        done
    else
        i=1
        while IFS= read -r s; do
            [ -n "$s" ] || continue
            v2_add_row "$i" "" "$s" "$ADDONS_DIR/$s"
            i=$((i + 1))
        done < <(addons_sources "$ADDONS_DIR")
    fi
}

# "as of the fetch 14 min ago", for one clone. A fresh clone has no FETCH_HEAD.
v2_fetch_age() {  # v2_fetch_age DIR
    local t; t=$(v2_mtime "$1/.git/FETCH_HEAD")
    if [ "$t" -gt 0 ]; then echo "as of the fetch $(v2_ago "$t")"; else echo "as of the clone, never fetched"; fi
}

v2_fetched_text() {
    if [ "$V2_OLDEST_FETCH" -eq 0 ]; then echo "not fetched yet"; else echo "fetched $(v2_ago "$V2_OLDEST_FETCH")"; fi
}

# Scanning every manifest takes a moment, so once a run and after code changes.
V2_DUPS=""; V2_DUPS_STALE=1
v2_dups_show() {
    local n d
    if [ "$V2_DUPS_STALE" = 1 ]; then
        V2_DUPS_STALE=0; V2_DUPS=""
        if [ "$EPHEM_MODE" = dev-multi ]; then
            for n in "${INSTANCES[@]}"; do
                d=$(addons_duplicates "$EPHEM_ROOT/odca$n" | sed "s/^/odca$n  /")
                [ -n "$d" ] && V2_DUPS="$V2_DUPS$d"$'\n'
            done
        else
            d=$(addons_duplicates "$ADDONS_DIR")
            [ -n "$d" ] && V2_DUPS="$d"$'\n'
        fi
    fi
    [ -n "$V2_DUPS" ] || return 0
    echo ""
    echo -e "  ${YELLOW}!${NC} The same module exists in more than one repository. Odoo loads the first"
    echo "     one on the addons path and ignores the other silently:"
    printf '%s' "$V2_DUPS" | sed 's/^/       /'
}

v2_t_repo_row() {  # v2_t_repo_row INDEX TREE_MARK
    local i="$1" chg="${V2_CHANGES[$1]}" syn="${V2_SYNC[$1]}"
    [ "$chg" = clean ] || [ "$chg" = "-" ] || chg="$YELLOW$V2_CS$chg"
    case "$syn" in *behind*) syn="$YELLOW$V2_CS$syn" ;; esac
    v2_t_add "${V2_KEY[$i]}" "$2${V2_SRC[$i]}" "${V2_BRANCH[$i]}" "$chg" "$syn" "${V2_LAST[$i]}"
}

# Instances and their repositories in one table, nested 1, 1.1, 1.2, 2, 2.1.
v2_tree_table() {  # v2_tree_table [INSTANCE]: one instance, or all
    local want="${1:-}" n i cnt seen mark dir
    if [ "$EPHEM_MODE" != dev-multi ]; then
        v2_t_begin "No." "Repository" "Branch" "Changes" "Origin" "Last commit"
        V2_T_SHRINK=2; V2_T_DROP=5
        for ((i = 0; i < ${#V2_KEY[@]}; i++)); do v2_t_repo_row "$i" ""; done
        v2_t_draw
        return 0
    fi
    v2_t_begin "No." "Where" "Branch" "State" "Origin" "Last commit"
    V2_T_SHRINK=2; V2_T_DROP=5
    for n in "${INSTANCES[@]}"; do
        [ -z "$want" ] || [ "$n" = "$want" ] || continue
        v2_t_add "$BOLD$V2_CS$(v2_inst_key "$n")" "$BOLD${V2_CS}odca$n  :$(inst_port "$n")" "" \
            "$(v2_state_cell "$(v2_state "ephem-$n")")" "" ""
        dir="$EPHEM_ROOT/odca$n"
        if [ ! -d "$dir" ]; then
            v2_t_add "" "$YELLOW${V2_CS}└ folder does not exist yet" "" "" "" ""
        elif addons_is_legacy "$dir"; then
            v2_t_add "" "$YELLOW${V2_CS}└ old layout: open it to move" "" "" "" ""
        fi
        cnt=0
        for ((i = 0; i < ${#V2_KEY[@]}; i++)); do [ "${V2_INST[$i]}" = "$n" ] && cnt=$((cnt + 1)); done
        seen=0
        for ((i = 0; i < ${#V2_KEY[@]}; i++)); do
            [ "${V2_INST[$i]}" = "$n" ] || continue
            seen=$((seen + 1))
            mark="├ "; [ "$seen" = "$cnt" ] && mark="└ "
            v2_t_repo_row "$i" "$mark"
        done
    done
    v2_t_draw
}

v2_instance_table() {
    local n
    v2_t_begin "No." "Instance" "Database" "Port" "State"
    for n in "${INSTANCES[@]}"; do
        v2_t_add "$(v2_inst_key "$n")" "odca$n" "ephem_$n" "$(inst_port "$n")" "$(v2_state_cell "$(v2_state "ephem-$n")")"
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

v2_find_row() {  # v2_find_row KEY: its index, or 1
    local i
    for ((i = 0; i < ${#V2_KEY[@]}; i++)); do
        [ "${V2_KEY[$i]}" = "$1" ] && { echo "$i"; return 0; }
    done
    return 1
}

# Every action that follows acts on this instance. Nothing is written to .env:
# a number names the instance each time, so there is no "current" one to keep.
v2_use_instance() {  # v2_use_instance NAME
    [ "$EPHEM_MODE" = dev-multi ] || return 0
    [ "$1" = "$EPHEM_INSTANCE" ] && return 0
    stack_use_instance "$1"
    FS_SVC_CACHE=()
}

# Open a place, or do VERB there straight away.
v2_go() {  # v2_go LOC VERB
    local loc="$1" verb="$2" i n
    if [ "$loc" = all ]; then
        case "$verb" in
            p|P) v2_do v2_pull_everywhere ;;
            f|F) v2_do v2_fetch_all ;;
            *)   v2_bad "With a, the actions are p (pull everything) and f (fetch everything)." ;;
        esac
        return 0
    fi
    if i=$(v2_find_row "$loc"); then
        if [ -z "$verb" ]; then
            v2_repo_screen "${V2_INST[$i]}" "${V2_SRC[$i]}"
            return 0
        fi
        v2_repo_verb "$verb" "${V2_INST[$i]}" "${V2_SRC[$i]}" && return 0
        # A Run action given a repository's number means the Odoo it belongs to.
        if [ "$EPHEM_MODE" = server ]; then
            v2_server_verb "$verb" || v2_bad "$verb is not an action here: h lists them."
        else
            v2_instance_verb "$verb" || v2_bad "$verb is not an action here: h lists them."
        fi
        return 0
    fi
    if [ "$EPHEM_MODE" = dev-multi ] && n=$(v2_inst_of_key "$loc"); then
        if [ -z "$verb" ]; then
            v2_instance_screen "$n"
            return 0
        fi
        v2_use_instance "$n"
        v2_layout_offer
        case "$verb" in
            s|S) v2_act_repo s "Switch a branch" "$n" ;;
            c|C) v2_act_repo c "Show local changes" "$n" ;;
            n|N) v2_act_repo n "Rename a repository" "$n" ;;
            k|K) v2_act_repo k "Remove a repository" "$n" ;;
            f|F) v2_do v2_fetch_all "$n" ;;
            *)   v2_instance_verb "$verb" || v2_bad "$verb is not an action here: h lists them." ;;
        esac
        return 0
    fi
    v2_bad "Nothing is numbered $loc."
}

# Asks which repository when there is more than one. Sets V2_PICK_ROW.
V2_PICK_ROW=-1
v2_pick_repo() {  # v2_pick_repo TITLE [INSTANCE]: 1 when backed out
    local title="$1" scope="${2:-}" i cnt=0 only=-1 n first=-1
    v2_load_tree
    for ((i = 0; i < ${#V2_KEY[@]}; i++)); do
        if [ -z "$scope" ] || [ "${V2_INST[$i]}" = "$scope" ]; then
            cnt=$((cnt + 1)); only=$i
            [ "$first" -lt 0 ] && first=$i
        fi
    done
    if [ "$cnt" -eq 0 ]; then v2_bad "No repository here yet: + adds one."; return 1; fi
    if [ "$cnt" -eq 1 ]; then V2_PICK_ROW=$only; return 0; fi
    while true; do
        v2_title "$title"
        v2_tree_table "$scope"
        v2_head "Which repository"
        v2_opt "${V2_KEY[$first]}" "Type its number from the table"
        v2_opt Enter "Back"
        v2_prompt
        case "$V2_ANS" in
            ""|b|B) return 1 ;;
            x|X)    v2_bye ;;
        esac
        if i=$(v2_find_row "$V2_ANS"); then V2_PICK_ROW=$i; return 0; fi
        if [ "$EPHEM_MODE" = dev-multi ] && n=$(v2_inst_of_key "$V2_ANS"); then
            cnt=0
            for ((i = 0; i < ${#V2_KEY[@]}; i++)); do
                if [ "${V2_INST[$i]}" = "$n" ]; then cnt=$((cnt + 1)); only=$i; fi
            done
            if [ "$cnt" -eq 1 ]; then V2_PICK_ROW=$only; return 0; fi
            v2_bad "odca$n has more than one repository: type one of its numbers."
            continue
        fi
        v2_bad "Nothing is numbered $V2_ANS."
    done
}

v2_act_repo() {  # v2_act_repo VERB TITLE [INSTANCE]
    v2_pick_repo "$2" "${3:-}" || return 0
    v2_repo_verb "$1" "${V2_INST[$V2_PICK_ROW]}" "${V2_SRC[$V2_PICK_ROW]}"
}

# Asks which instance when there is more than one.
v2_pick_instance() {  # v2_pick_instance TITLE: 1 when backed out
    [ "$EPHEM_MODE" = dev-multi ] || return 0
    local name
    if [ "${#INSTANCES[@]}" -eq 1 ]; then v2_use_instance "${INSTANCES[0]}"; return 0; fi
    while true; do
        v2_title "$1"
        v2_instance_table
        v2_head "Which instance"
        v2_opt "$(v2_inst_key "${INSTANCES[0]}")" "Type its number from the table"
        v2_opt Enter "Back"
        v2_prompt
        case "$V2_ANS" in
            ""|b|B) return 1 ;;
            x|X)    v2_bye ;;
        esac
        if name=$(v2_inst_of_key "${V2_ANS%%.*}"); then
            v2_use_instance "$name"
            return 0
        fi
        v2_bad "Nothing is numbered $V2_ANS."
    done
}

v2_act_instance() {  # v2_act_instance VERB TITLE
    v2_pick_instance "$2" || return 0
    v2_layout_offer
    v2_instance_verb "$1" || v2_bad
}

# ── Applying new code ─────────────────────────
v2_update_changed() {  # v2_update_changed [DATABASE]
    local -a args=(--auto --changed)
    [ -n "${EPHEM_INSTANCE:-}" ] && args+=(--instance "$EPHEM_INSTANCE")
    [ -n "${1:-}" ] && args+=(--db "$1")
    echo -e "  ${CYAN}→${NC} bash scripts/update-modules.sh ${args[*]}"
    run_interruptible bash scripts/update-modules.sh "${args[@]}" || \
        echo -e "  ${RED}✗${NC} The update did not finish: see the output above."
}

# One question, once, after anything that changed the code on disk.
v2_offer_apply() {
    [ "$ADDONS_CHANGED" -eq 1 ] || return 0
    ADDONS_CHANGED=0
    V2_DUPS_STALE=1
    if [ "$EPHEM_MODE" = server ]; then
        v2_head "The new code is not active yet. Apply it now?"
        v2_opt Enter "Update what changed, then restart"
        v2_opt a "Update all our modules, then restart"
        v2_opt n "Later"
        v2_prompt
        case "$V2_ANS" in
            "")  bash scripts/update-modules.sh --auto --changed --ask-odoo ;;
            a|A) bash scripts/update-modules.sh --auto --ask-odoo ;;
            *)   v2_cancel "Later: Update (u), then m, updates the modules." ;;
        esac
    else
        v2_head "Apply the new code to $ADDONS_NAME?"
        v2_opt Enter "Restart and follow the log"
        v2_opt u "Update what changed"
        v2_opt n "Later"
        v2_prompt
        case "$V2_ANS" in
            "")  v2_clear; menu_restart_logs_local; V2_NO_PAUSE=1 ;;
            u|U) if [ "$EPHEM_MODE" = dev-multi ]; then v2_update_changed
                 elif v2_work_db; then v2_update_changed "$V2_WORK_DB"; fi ;;
            *)   v2_cancel "Later: new Python code needs a restart, new views and data a module update." ;;
        esac
    fi
}

# On a server a pull or a switch is a change to production, chosen by a single
# keystroke here, so it says so and asks.
v2_server_gate() {  # v2_server_gate "Pull x" [Y|N]
    [ "$EPHEM_MODE" = server ] || return 0
    local dflt="${2:-Y}" hint="[Y/n]" C
    [ "$dflt" = N ] && hint="[y/N]"
    echo ""
    echo -e "  ${YELLOW}!${NC} This changes the live code for EVERY database on this server."
    echo "     Take a backup first for anything beyond a routine pull."
    read -r -p "  $1? $hint: " C || return 1
    C="${C:-$dflt}"
    [[ "$C" =~ ^[Yy]$ ]] || { v2_cancel; return 1; }
}

# ── Pull and fetch ────────────────────────────
v2_pull_one() {  # v2_pull_one DIR LABEL: 1 when the pull failed or was cancelled
    local dir="$1" label="$2" before after
    if [ ! -d "$dir/.git" ]; then echo "  · $label: not a git clone, skipped"; return 0; fi
    if ! v2_net_ready "$dir"; then echo "  Cancelled: $label was not pulled."; return 1; fi
    before=$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo "")
    echo -e "  ${CYAN}→${NC} $label: git pull --ff-only   ($(src_branch "$dir"))"
    if ! run_interruptible git -C "$dir" pull --ff-only; then
        echo -e "  ${RED}✗${NC} $label: pull failed (diverged, local changes in the way, or no access)."
        return 1
    fi
    after=$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo "")
    if [ "$before" != "$after" ]; then
        echo -e "  ${GREEN}✓${NC} $label updated"; ADDONS_CHANGED=1
    else
        echo -e "  ${GREEN}✓${NC} $label already up to date"
    fi
}

v2_pull_repo() {  # v2_pull_repo DIR LABEL
    v2_title "Pull: $2"
    v2_server_gate "Pull $2" || return 0
    V2_NET_CANCELLED=0
    v2_pull_one "$1" "$2"
    v2_offer_apply
}

# Every repository of the current instance. An array, not `done < <(...)`:
# inside such a loop stdin is the pipe, and the passphrase could not be asked.
v2_pull_parent() {
    local s i
    local -a srcs=()
    while IFS= read -r s; do [ -n "$s" ] && srcs+=("$s"); done < <(addons_sources "$ADDONS_DIR")
    if [ "${#srcs[@]}" -eq 0 ]; then echo "  (no repository in $ADDONS_NAME/)"; return 0; fi
    # Under "pull everything" the instances share one screen.
    [ "${1:-}" = shared ] || v2_title "Pull: every repository of $ADDONS_NAME/"
    v2_server_gate "Pull every repository of $ADDONS_NAME/" || return 0
    V2_NET_CANCELLED=0
    for ((i = 0; i < ${#srcs[@]}; i++)); do
        v2_pull_one "$ADDONS_DIR/${srcs[$i]}" "$ADDONS_NAME/${srcs[$i]}"
        [ "$V2_NET_CANCELLED" = 1 ] && break
    done
    v2_offer_apply
}

v2_pull_everywhere() {
    if [ "$EPHEM_MODE" != dev-multi ]; then v2_pull_parent; return 0; fi
    local n
    v2_title "Pull: every repository of every instance"
    for n in "${INSTANCES[@]}"; do
        v2_use_instance "$n"
        v2_pull_parent shared
        if [ "$V2_NET_CANCELLED" = 1 ]; then break; fi
        echo ""
    done
    V2_NOTICE=""; V2_NO_PAUSE=0     # keep every instance's result on screen
}

# "p" from the home screen: one repository, one instance, or everything.
v2_act_pull() {
    local i n
    v2_load_tree
    if [ "${#V2_KEY[@]}" -eq 0 ]; then v2_bad "No repository here yet: + adds one."; return 0; fi
    if [ "${#V2_KEY[@]}" -eq 1 ]; then v2_repo_verb p "${V2_INST[0]}" "${V2_SRC[0]}"; return 0; fi
    while true; do
        v2_title "Pull the latest code"
        v2_tree_table
        v2_head "Which one"
        v2_opt "${V2_KEY[0]}" "One repository: type its number from the table"
        [ "$EPHEM_MODE" = dev-multi ] && v2_opt "${V2_KEY[0]%%.*}" "One instance: all its repositories"
        v2_opt a "Everything"
        v2_opt Enter "Back"
        v2_prompt
        case "$V2_ANS" in
            ""|b|B) return 0 ;;
            x|X)    v2_bye ;;
            a|A)    v2_do v2_pull_everywhere; return 0 ;;
        esac
        if i=$(v2_find_row "$V2_ANS"); then
            v2_repo_verb p "${V2_INST[$i]}" "${V2_SRC[$i]}"
            return 0
        fi
        if [ "$EPHEM_MODE" = dev-multi ] && n=$(v2_inst_of_key "$V2_ANS"); then
            v2_use_instance "$n"
            v2_do v2_pull_parent
            return 0
        fi
        v2_bad "Nothing is numbered $V2_ANS."
    done
}

v2_fetch_one() {  # v2_fetch_one DIR
    local dir="$1" cur
    if local_mode; then
        # A developer clone sees every branch of origin.
        git -C "$dir" config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
        run_interruptible git -C "$dir" fetch --quiet --prune origin
    else
        # A server clone follows one branch, and stays that small.
        cur=$(git -C "$dir" branch --show-current 2>/dev/null || echo "")
        [ -n "$cur" ] || return 1
        run_interruptible git -C "$dir" fetch --quiet origin "$cur"
    fi
}

v2_fetch_all() {  # v2_fetch_all [INSTANCE]: everything, or one instance's repositories
    local want="${1:-}" i label bad=0
    v2_load_tree
    v2_title "Fetch from origin"
    V2_NET_CANCELLED=0
    for ((i = 0; i < ${#V2_DIR[@]}; i++)); do
        [ -d "${V2_DIR[$i]}/.git" ] || continue
        [ -z "$want" ] || [ "${V2_INST[$i]}" = "$want" ] || continue
        label="${V2_SRC[$i]}"
        [ -n "${V2_INST[$i]}" ] && label="odca${V2_INST[$i]}/$label"
        if ! v2_net_ready "${V2_DIR[$i]}"; then v2_cancel "Cancelled: nothing more was fetched."; return 0; fi
        echo -e "  ${CYAN}→${NC} $label: git fetch"
        if ! v2_fetch_one "${V2_DIR[$i]}"; then
            echo -e "  ${RED}✗${NC} $label: fetch failed (see above, or no access)."
            bad=1
        fi
    done
    if [ "$bad" = 0 ]; then V2_NOTICE="Fetched: the Origin column is current."; V2_NO_PAUSE=1; fi
}

v2_fetch_repo() {  # v2_fetch_repo DIR LABEL
    v2_title "Fetch: $2"
    V2_NET_CANCELLED=0
    if ! v2_net_ready "$1"; then v2_cancel; return 0; fi
    echo -e "  ${CYAN}→${NC} $2: git fetch"
    if v2_fetch_one "$1"; then
        V2_NOTICE="Fetched $2."; V2_NO_PAUSE=1
    else
        echo -e "  ${RED}✗${NC} $2: fetch failed (see above, or no access)."
    fi
}

# ── Switching a branch ────────────────────────
V2_BR_NAME=(); V2_BR_WHEN=(); V2_BR_NOTE=()
v2_br_add() { V2_BR_NAME+=("$1"); V2_BR_WHEN+=("$2"); V2_BR_NOTE+=("$3"); }

v2_load_branches() {  # v2_load_branches DIR SOURCE CURRENT: 1 when no list could be had
    local dir="$1" src="$2" cur="$3" raw name when note rec=""
    V2_BR_NAME=(); V2_BR_WHEN=(); V2_BR_NOTE=()
    if local_mode; then
        # What the last fetch brought, plus branches only this clone has,
        # newest first. No network, so no passphrase yet.
        raw=$(git -C "$dir" for-each-ref --sort=-committerdate \
                --format='%(refname)%09%(committerdate:relative)' \
                refs/heads refs/remotes/origin 2>/dev/null | awk -F'\t' '
            { if ($1 ~ /^refs\/heads\//) { n = substr($1, 12); here = 1 }
              else                       { n = substr($1, 21); here = 0 }
              if (n == "HEAD") next
              if (!(n in seen)) { seen[n] = $2; order[++c] = n }
              if (!here) origin[n] = 1 }
            END { for (i = 1; i <= c; i++) {
                      n = order[i]
                      print n "\t" seen[n] "\t" ((n in origin) ? "" : "local only") } }')
    else
        # A server clone only knows its one branch: ask origin (names only,
        # nothing is downloaded).
        v2_net_ready "$dir" || { v2_cancel; return 1; }
        raw=$(git -C "$dir" ls-remote --heads origin 2>/dev/null | sed 's|.*refs/heads/||' | sort) || raw=""
        if [ -z "$raw" ]; then
            echo -e "  ${RED}✗${NC} Could not list the branches of origin: is the deploy key or your SSH key authorized?"
            return 1
        fi
    fi
    [ "$src" = "$CORE_NAME" ] && rec="$CORE_BRANCH"
    if [ -n "$rec" ] && [ "$rec" != "$cur" ]; then
        while IFS=$'\t' read -r name when note; do
            [ "$name" = "$rec" ] && v2_br_add "$name" "${when:-}" "recommended"
        done <<< "$raw"
    fi
    while IFS=$'\t' read -r name when note; do
        [ -n "$name" ] || continue
        [ "$name" = "$cur" ] && continue
        [ "$name" = "$rec" ] && continue
        v2_br_add "$name" "${when:-}" "${note:-}"
    done <<< "$raw"
}

# Sets V2_PICK and V2_PICK_NOTE; 1 when cancelled.
V2_PICK=""; V2_PICK_NOTE=""
V2_BR_SHOW=15

v2_pick_branch() {  # v2_pick_branch DIR SOURCE CURRENT LABEL
    local dir="$1" src="$2" cur="$3" label="$4" filter="" i j n detail
    local -a shown=()
    while true; do
        shown=()
        shopt -s nocasematch
        for ((i = 0; i < ${#V2_BR_NAME[@]}; i++)); do
            if [ -z "$filter" ] || [[ "${V2_BR_NAME[$i]}" == *"$filter"* ]]; then shown+=("$i"); fi
        done
        shopt -u nocasematch
        n=${#shown[@]}
        if [ -n "$filter" ] && [ "$n" -eq 0 ]; then
            v2_bad "Nothing matches '$filter'. f gets the newest list from origin."
            filter=""
            continue
        fi
        detail="Now on ${BOLD}$cur${NC}. ${#V2_BR_NAME[@]} other branch(es)"
        if local_mode; then detail="$detail, $(v2_fetch_age "$dir")."; else detail="$detail on origin."; fi
        v2_title "Switch a branch: $label" "$detail"
        [ -n "$filter" ] && { echo -e "  Matching ${BOLD}$filter${NC}"; echo ""; }
        v2_t_begin "No." "Branch" "Last commit" "Note"
        V2_T_SHRINK=1; V2_T_DROP=2
        for ((j = 0; j < n && j < V2_BR_SHOW; j++)); do
            i=${shown[$j]}
            v2_t_add "$((j + 1))" "${V2_BR_NAME[$i]}" "${V2_BR_WHEN[$i]}" "${V2_BR_NOTE[$i]}"
        done
        v2_t_draw
        [ "$n" -gt "$V2_BR_SHOW" ] && echo "  $((n - V2_BR_SHOW)) more not shown: type part of a name to narrow the list."
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
                if v2_net_ready "$dir" && v2_fetch_one "$dir"; then
                    v2_load_branches "$dir" "$src" "$cur" || return 1
                else
                    v2_bad "Not fetched: the list is the one from the last fetch."
                fi
                filter=""
                continue
                ;;
        esac
        # A whole name goes straight through (a pasted branch name).
        for ((i = 0; i < ${#V2_BR_NAME[@]}; i++)); do
            if [ "${V2_BR_NAME[$i]}" = "$V2_ANS" ]; then
                V2_PICK="${V2_BR_NAME[$i]}"; V2_PICK_NOTE="${V2_BR_NOTE[$i]}"
                return 0
            fi
        done
        if [[ "$V2_ANS" =~ ^[0-9]+$ ]] && [ "$V2_ANS" -ge 1 ] && [ "$V2_ANS" -le "$n" ] && [ "$V2_ANS" -le "$V2_BR_SHOW" ]; then
            i=${shown[$((V2_ANS - 1))]}
            V2_PICK="${V2_BR_NAME[$i]}"; V2_PICK_NOTE="${V2_BR_NOTE[$i]}"
            return 0
        fi
        filter="$V2_ANS"
    done
}

# Asking `git switch X` first and falling back to creating it hides why the
# first one failed; a refusal over local changes would read as "already exists".
v2_git_switch() {  # v2_git_switch BRANCH, from inside the clone
    if git show-ref --verify --quiet "refs/heads/$1"; then
        git switch "$1"
    else
        git switch -c "$1" --track "origin/$1"
    fi
}

v2_switch_dev() {  # v2_switch_dev DIR BRANCH
    local dir="$1" br="$2" lr
    v2_net_ready "$dir" || return 1
    echo -e "  ${CYAN}→${NC} git fetch origin $br && git switch $br"
    ( cd "$dir" &&
      git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*" &&
      git fetch origin "$br" &&
      v2_git_switch "$br"
    ) || return 1
    lr=$(git -C "$dir" rev-list --left-right --count "$br...origin/$br" 2>/dev/null || echo "? ?")
    if [ "${lr%%[[:space:]]*}" = "0" ] && [ "${lr##*[[:space:]]}" != "0" ]; then
        git -C "$dir" merge --ff-only "origin/$br" >/dev/null 2>&1 && \
            echo "  fast-forwarded '$br' by ${lr##*[[:space:]]} commit(s)"
    elif [ "${lr%%[[:space:]]*}" != "0" ]; then
        echo "  note: local '$br' is ${lr%%[[:space:]]*} commit(s) ahead of origin, left as is"
    fi
}

# Only the one branch is ever downloaded; a shallow clone stays shallow.
v2_switch_server() {  # v2_switch_server DIR BRANCH
    local dir="$1" br="$2" old depth=""
    v2_net_ready "$dir" || return 1
    old=$(git -C "$dir" config --get remote.origin.fetch 2>/dev/null || echo "")
    [ -f "$dir/.git/shallow" ] && depth="--depth 1"
    # shellcheck disable=SC2086  # $depth is empty or two words
    if ( cd "$dir" &&
         git config remote.origin.fetch "+refs/heads/$br:refs/remotes/origin/$br" &&
         git fetch $depth origin &&
         v2_git_switch "$br" &&
         git merge --ff-only "origin/$br" &&
         git branch --set-upstream-to="origin/$br" "$br"
       ); then
        return 0
    fi
    if [ -n "$old" ] && [ "$(git -C "$dir" branch --show-current 2>/dev/null)" != "$br" ]; then
        git -C "$dir" config remote.origin.fetch "$old"
    fi
    return 1
}

v2_switch() {  # v2_switch DIR SOURCE LABEL
    local dir="$1" src="$2" label="$3" cur dirty C rc=0
    cur=$(git -C "$dir" branch --show-current 2>/dev/null || echo "")
    v2_load_branches "$dir" "$src" "${cur:-(detached)}" || return 0
    if [ "${#V2_BR_NAME[@]}" -eq 0 ]; then
        v2_cancel "No other branch known: Fetch (f) from the home screen first."
        return 0
    fi
    v2_pick_branch "$dir" "$src" "${cur:-(detached)}" "$label" || { v2_cancel; return 0; }
    v2_title "Switch $label to $V2_PICK"
    dirty=$(v2_dirty "$dir")
    if [ "$dirty" -gt 0 ]; then
        echo -e "  ${YELLOW}!${NC} $dirty file(s) have uncommitted changes. They come along if they"
        echo "     do not conflict with '$V2_PICK'; otherwise git refuses and nothing changes."
        read -r -p "  Continue? [y/N]: " C || C=n
        [[ "${C:-N}" =~ ^[Yy]$ ]] || { v2_cancel; return 0; }
    fi
    v2_server_gate "Switch the live code of $label to $V2_PICK" N || return 0
    V2_NET_CANCELLED=0
    if [ "$V2_PICK_NOTE" = "local only" ]; then
        git -C "$dir" switch "$V2_PICK" || rc=1
    elif local_mode; then
        v2_switch_dev "$dir" "$V2_PICK" || rc=1
    else
        v2_switch_server "$dir" "$V2_PICK" || rc=1
    fi
    if [ "$V2_NET_CANCELLED" = 1 ]; then
        v2_cancel "Cancelled: $label stays on ${cur:-its commit}."
        return 0
    fi
    if [ "$rc" -ne 0 ]; then
        echo -e "  ${RED}✗${NC} Not switched: see the git output above. $label stays on ${cur:-its commit}."
        return 0
    fi
    echo -e "  ${GREEN}✓${NC} $label now on '$V2_PICK'"
    ADDONS_CHANGED=1
    v2_offer_apply
}

# ── A repository ──────────────────────────────
v2_show_changes() {  # v2_show_changes DIR LABEL
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

v2_repo_verb() {  # v2_repo_verb VERB INSTANCE SOURCE: 1 when not a repository action
    local verb="$1" dir label
    v2_use_instance "$2"
    dir="$ADDONS_DIR/$3"; label="$ADDONS_NAME / $3"
    case "$verb" in
        n|N) v2_do v2_repo_rename "$3"; return 0 ;;
        k|K)
            if [ "$3" = "$CORE_NAME" ]; then
                v2_bad "$CORE_NAME is the ePHEM clone itself: it cannot be removed here."
            else
                v2_do v2_repo_remove "$3"
            fi
            return 0
            ;;
        s|S|p|P|c|C|f|F) ;;
        *) return 1 ;;
    esac
    if [ ! -d "$dir/.git" ]; then
        v2_bad "$label is not a git clone: nothing to pull or switch."
        return 0
    fi
    case "$verb" in
        s|S) v2_do v2_switch "$dir" "$3" "$label" ;;
        p|P) v2_do v2_pull_repo "$dir" "$label" ;;
        c|C) v2_do v2_show_changes "$dir" "$label" ;;
        f|F) v2_do v2_fetch_repo "$dir" "$label" ;;
    esac
    return 0
}

v2_repo_rename() { V2_SOURCE="$1"; addons_rename_source "$ADDONS_DIR" || true; V2_SOURCE=""; v2_offer_apply; }
v2_repo_remove() { V2_SOURCE="$1"; addons_remove_source "$ADDONS_DIR" || true; V2_SOURCE=""; v2_offer_apply; }

v2_repo_screen() {  # v2_repo_screen INSTANCE SOURCE
    local inst="$1" src="$2" dir label branch dirty is_git=0
    v2_use_instance "$inst"
    dir="$ADDONS_DIR/$src"; label="$ADDONS_NAME / $src"
    [ -d "$dir/.git" ] && is_git=1
    # An earlier version widened a server clone's refspec, so every fetch took
    # all branches, which on a slow link looks like a freeze.
    branch=$(git -C "$dir" branch --show-current 2>/dev/null || echo "")
    if ! local_mode && [ -n "$branch" ] && \
       [ "$(git -C "$dir" config --get remote.origin.fetch 2>/dev/null)" = "+refs/heads/*:refs/remotes/origin/*" ]; then
        git -C "$dir" config remote.origin.fetch "+refs/heads/$branch:refs/remotes/origin/$branch"
        V2_NOTICE="Repaired the fetch config (it was set to fetch every branch)."
    fi
    while true; do
        v2_title "$label"
        v2_t_begin
        V2_T_SHRINK=1
        if [ "$is_git" = 1 ]; then
            dirty=$(v2_dirty "$dir")
            v2_t_add "Branch" "$BOLD$V2_CS$(src_branch "$dir")"
            if [ "$dirty" -gt 0 ]; then v2_t_add "Changes" "$YELLOW$V2_CS$dirty file(s)"; else v2_t_add "Changes" "clean"; fi
            v2_t_add "Origin" "$(v2_sync "$dir"), $(v2_fetch_age "$dir")"
            v2_t_add "Remote" "$(git -C "$dir" remote get-url origin 2>/dev/null)"
            v2_t_add "Last commit" "$(git -C "$dir" log -1 --format='%h %ad %s' --date=short 2>/dev/null)"
        else
            v2_t_add "Git" "$YELLOW${V2_CS}not a git clone: it can only be renamed or removed here"
        fi
        v2_t_add "Modules" "$(src_module_count "$dir")"
        v2_t_draw
        v2_head "This repository"
        if [ "$is_git" = 1 ]; then
            v2_opt s "Switch branch"
            v2_opt p "Pull the latest code"
            v2_opt c "Show local changes"
            v2_opt f "Fetch from origin"
        fi
        v2_opt n "Rename"
        [ "$src" = "$CORE_NAME" ] || v2_opt k "Remove"
        v2_nav
        v2_prompt
        case "$V2_ANS" in
            ""|b|B) return 0 ;;
            x|X)    v2_bye ;;
            *)
                v2_repo_verb "$V2_ANS" "$inst" "$src" || v2_bad
                [ -e "$dir" ] || return 0      # renamed or removed
                ;;
        esac
    done
}

v2_add_repo() {
    if [ ! -d "$ADDONS_DIR" ]; then
        v2_cancel "$ADDONS_NAME/ does not exist yet: bash setup.sh creates it."
        return 0
    fi
    addons_add_source "$ADDONS_DIR" || true
    v2_offer_apply
}

# The layout from before $CORE_NAME/: the clone was the mounted folder itself.
V2_LAYOUT_ASKED=""
v2_layout_offer() {
    local M
    if { [ "$EPHEM_MODE" != dev-multi ] && [ -d "$EPHEM_ROOT/custom-addons" ] && [ ! -d "$ADDONS_DIR/$CORE_NAME" ]; } \
       || addons_is_legacy "$ADDONS_DIR"; then
        case " $V2_LAYOUT_ASKED " in *" $ADDONS_NAME "*) return 0 ;; esac
        V2_LAYOUT_ASKED="$V2_LAYOUT_ASKED $ADDONS_NAME"
        echo -e "  ${YELLOW}!${NC} The ePHEM clone is still the mounted folder itself. It moves one folder"
        echo "     down, into $ADDONS_NAME/$CORE_NAME/, addons_path follows, and the container is recreated."
        echo "     Nothing is deleted; databases and filestores are untouched."
        read -r -p "  Move it now? [Y/n]: " M || M=n
        [[ "${M:-Y}" =~ ^[Nn]$ ]] && return 0
        addons_fix_legacy || true
    fi
    return 0
}

# ── An instance (the developer actions) ───────
v2_follow_log() {
    echo -e "  ${CYAN}→${NC} $(compose_cmd_text) logs -f --tail=100 $ODOO_SVC   (Ctrl-C returns here)"
    run_interruptible compose logs -f --tail=100 "$ODOO_SVC" || true
}

v2_start_stop() {
    if [ "$(svc_state "$ODOO_SVC")" = running ]; then
        echo -e "  ${CYAN}→${NC} $(compose_cmd_text) stop $ODOO_SVC"
        compose stop "$ODOO_SVC" && echo -e "  ${GREEN}✓${NC} $ODOO_SVC stopped"
    else
        svc_start "$ODOO_SVC" && wait_for_odoo
    fi
    return 0
}

# The database to act on: the instance's own, or chosen with one Odoo.
V2_WORK_DB=""
v2_work_db() {
    V2_WORK_DB="$ODOO_DB"
    if [ -z "$V2_WORK_DB" ]; then
        pick_db "Database" || return 1
        V2_WORK_DB="$PICKED_DB"
    fi
}

v2_valid_modules() {
    [[ "$1" =~ ^[A-Za-z0-9_]+(,[A-Za-z0-9_]+)*$ ]] && return 0
    v2_cancel "Module names: letters, digits and underscores, separated by commas."
    return 1
}

# The modules on disk (stack-lib's addons_update_modules), kept to the ones
# this database has installed.
v2_installed_modules() {  # v2_installed_modules DATABASE
    local names
    names=$(addons_update_modules "$ADDONS_DIR" | sort -u | sed "s/.*/'&'/" | paste -sd, -)
    [ -n "$names" ] || return 0
    compose exec -T db psql -U "$DB_USER" -d "$1" -t -A -c \
        "SELECT string_agg(name, ',' ORDER BY name) FROM ir_module_module
          WHERE state = 'installed' AND name IN ($names);" \
        </dev/null 2>/dev/null | tr -d '\r'
}

v2_update_modules() {
    local db MODS
    v2_work_db || { V2_NO_PAUSE=1; return 0; }
    db="$V2_WORK_DB"
    v2_title "Update modules" "Database $db, code from $ADDONS_NAME/"
    v2_head "Which modules"
    v2_opt Enter "Only what changed (with no record yet, every installed module once)"
    v2_opt a "Every module of $ADDONS_NAME/ installed on $db"
    v2_opt names "Type them, comma separated: eoc_signals,eoc_base"
    v2_opt b "Back"
    v2_prompt
    case "$V2_ANS" in
        "")  v2_update_changed "$([ "$EPHEM_MODE" = dev-multi ] || echo "$db")"; return 0 ;;
        b|B) V2_NO_PAUSE=1; return 0 ;;
        x|X) v2_bye ;;
        a|A)
            MODS=$(v2_installed_modules "$db")
            if [ -z "$MODS" ]; then
                echo -e "  ${RED}✗${NC} None of the modules of $ADDONS_NAME/ is installed on '$db', or the database is not reachable."
                return 0
            fi
            echo "  $(printf '%s' "$MODS" | tr ',' '\n' | grep -c .) module(s): $MODS" | fold -s -w 96 | sed '2,$s/^/     /'
            ;;
        *) MODS=$(printf '%s' "$V2_ANS" | tr -d ' ') ;;
    esac
    v2_valid_modules "$MODS" || return 0
    echo -e "  ${CYAN}→${NC} bash scripts/dev-logs.sh ${EPHEM_INSTANCE:-} -u $MODS -d $db   (Ctrl-C ends the log tail)"
    run_interruptible bash scripts/dev-logs.sh ${EPHEM_INSTANCE:+"$EPHEM_INSTANCE"} -u "$MODS" -d "$db" || true
    V2_NO_PAUSE=1
}

v2_install_modules() {
    local db MODS
    v2_work_db || { V2_NO_PAUSE=1; return 0; }
    db="$V2_WORK_DB"
    v2_title "Install a module" "Database $db"
    v2_ask "  Module(s) to install, comma separated (Enter cancels): "
    MODS=$(printf '%s' "$V2_ANS" | tr -d ' ')
    [ -n "$MODS" ] || { v2_cancel; return 0; }
    v2_valid_modules "$MODS" || return 0
    echo -e "  ${CYAN}→${NC} bash scripts/dev-logs.sh ${EPHEM_INSTANCE:-} -i $MODS -d $db   (Ctrl-C ends the log tail)"
    run_interruptible bash scripts/dev-logs.sh ${EPHEM_INSTANCE:+"$EPHEM_INSTANCE"} -i "$MODS" -d "$db" || true
    V2_NO_PAUSE=1
}

v2_restart_quiet() {
    local C
    if [ "$EPHEM_MODE" = server ]; then
        read -r -p "  Restart Odoo now? Every tenant is offline for a moment. [Y/n]: " C || C=n
        [[ "${C:-Y}" =~ ^[Yy]$ ]] || { v2_cancel; return 0; }
    fi
    echo -e "  ${CYAN}→${NC} $(compose_cmd_text) restart $ODOO_SVC"
    svc_restart "$ODOO_SVC" || { echo -e "  ${RED}✗${NC} Restart failed: see the output above."; return 0; }
    wait_for_odoo
}

v2_instance_verb() {  # v2_instance_verb VERB: 1 when not an instance action
    case "$1" in
        r|R) v2_clear; menu_restart_logs_local || true ;;
        o|O) v2_do v2_restart_quiet ;;
        l|L) v2_clear; v2_follow_log ;;
        u|U) v2_do v2_update_modules ;;
        i|I) v2_do v2_install_modules ;;
        t|T) v2_do v2_start_stop ;;
        p|P) v2_do v2_pull_parent ;;
        +)   v2_do v2_add_repo ;;
        *)   return 1 ;;
    esac
    return 0
}

v2_start_stop_label() { if [ "$(v2_state "$ODOO_CTN")" = running ]; then echo "Stop"; else echo "Start"; fi; }

v2_run_options() {  # the same list wherever one Odoo is the subject
    v2_head "Run"
    v2_opt r "Restart and follow the log"
    v2_opt o "Restart only"
    v2_opt l "Follow the log"
    v2_opt t "$(v2_start_stop_label)"
    v2_opt u "Update modules"
    v2_opt i "Install a module"
}

v2_repo_options() {  # the same list wherever repositories are the subject
    v2_head "Repositories and branches"
    v2_opt s "Switch a branch"
    v2_opt p "Pull the latest code"
    v2_opt c "Show local changes"
    v2_opt f "Fetch from origin"
    v2_opt + "Add a repository"
    v2_opt n "Rename a repository"
    v2_opt k "Remove a repository"
}

v2_instance_screen() {  # v2_instance_screen NAME
    local n="$1"
    v2_use_instance "$n"
    v2_layout_offer
    while true; do
        v2_use_instance "$n"     # a jump to another number may have moved it
        v2_load_tree
        v2_title "odca$n" "$ODOO_URL, database $ODOO_DB, $(v2_fetched_text)"
        v2_tree_table "$n"
        v2_dups_show
        v2_repo_options
        v2_run_options
        v2_nav
        echo ""
        echo "  Type a letter from the list, or a number from the table."
        v2_prompt
        [ -n "$V2_ANS" ] || return 0
        v2_parse "$V2_ANS"
        if [ -n "$V2_LOC" ]; then v2_go "$V2_LOC" "$V2_VERB"; continue; fi
        case "$V2_VERB" in
            b|B) return 0 ;;
            x|X) v2_bye ;;
            s|S) v2_act_repo s "Switch a branch" "$n" ;;
            c|C) v2_act_repo c "Show local changes" "$n" ;;
            n|N) v2_act_repo n "Rename a repository" "$n" ;;
            k|K) v2_act_repo k "Remove a repository" "$n" ;;
            f|F) v2_do v2_fetch_all "$n" ;;
            *)   v2_instance_verb "$V2_VERB" || v2_bad ;;
        esac
    done
}

# ── Databases ─────────────────────────────────
V2_DBK=(); V2_DBN=(); V2_DBS=(); V2_DBF=(); V2_DBO=()
V2_STALE_N=(); V2_STALE_S=(); V2_STALE_O=()

v2_db_owner() {  # v2_db_owner NAME: the instance its name points at, else none
    local n
    for n in "${INSTANCES[@]}"; do
        case "$1" in "ephem_$n"|"ephem_${n}_"*) echo "$n"; return 0 ;; esac
    done
    return 0
}

v2_load_dbs() {
    V2_DBK=(); V2_DBN=(); V2_DBS=(); V2_DBF=(); V2_DBO=()
    V2_STALE_N=(); V2_STALE_S=(); V2_STALE_O=()
    local line name size tag i j n key owner found real
    local -a all=() sizes=() owners=() fs_n=() fs_s=() fs_t=()
    while read -r name size tag; do
        [ -n "$name" ] || continue
        size="${size#(}"; size="${size%)}"
        tag="${tag:-}"; tag="${tag#[}"; tag="${tag%]}"
        fs_n+=("$name"); fs_s+=("$size"); fs_t+=("$tag")
    done < <(list_filestores)
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        name="${line%%  (*}"; size="${line##*  (}"; size="${size%)}"
        all+=("$name"); sizes+=("$size")
    done < <(list_dbs_sized)
    for ((i = 0; i < ${#all[@]}; i++)); do
        owner=""
        if [ "$EPHEM_MODE" = dev-multi ]; then
            owner=$(v2_db_owner "${all[$i]}")
            if [ -z "$owner" ]; then
                for ((j = 0; j < ${#fs_n[@]}; j++)); do
                    if [ "${fs_n[$j]}" = "${all[$i]}" ]; then owner="${fs_t[$j]#odca}"; break; fi
                done
            fi
        fi
        owners+=("$owner")
    done
    real=${#all[@]}
    # Files with no database of that name, left behind by a drop: listed, so
    # they can be seen, snapshotted and deleted.
    for ((j = 0; j < ${#fs_n[@]}; j++)); do
        found=0
        for ((i = 0; i < ${#all[@]}; i++)); do [ "${all[$i]}" = "${fs_n[$j]}" ] && found=1; done
        if [ "$found" = 0 ]; then
            all+=("${fs_n[$j]}"); sizes+=("no database"); owners+=("${fs_t[$j]#odca}")
        fi
    done
    # A copy of a database's files on another instance's volume: shown only.
    # Every delete acts on the owner's copy, so offering it would be a trap.
    if [ "$EPHEM_MODE" = dev-multi ]; then
        for ((j = 0; j < ${#fs_n[@]}; j++)); do
            for ((i = 0; i < real; i++)); do
                if [ "${all[$i]}" = "${fs_n[$j]}" ] && [ -n "${owners[$i]}" ] && [ "${fs_t[$j]}" != "odca${owners[$i]}" ]; then
                    V2_STALE_N+=("${fs_n[$j]}"); V2_STALE_S+=("${fs_s[$j]}"); V2_STALE_O+=("${fs_t[$j]#odca}")
                fi
            done
        done
    fi
    # shellcheck disable=SC2329  # called below
    v2_db_add() {  # v2_db_add KEY INDEX
        local k="$1" x="$2" m want_tag="" f="-"
        [ -n "${owners[$x]}" ] && want_tag="odca${owners[$x]}"
        for ((m = 0; m < ${#fs_n[@]}; m++)); do
            [ "${fs_n[$m]}" = "${all[$x]}" ] || continue
            if [ -z "$want_tag" ] || [ "${fs_t[$m]}" = "$want_tag" ]; then f="${fs_s[$m]}"; break; fi
        done
        V2_DBK+=("$k"); V2_DBN+=("${all[$x]}"); V2_DBS+=("${sizes[$x]}"); V2_DBF+=("$f"); V2_DBO+=("${owners[$x]}")
    }
    if [ "$EPHEM_MODE" = dev-multi ]; then
        local last=0
        for n in "${INSTANCES[@]}"; do
            key=$(v2_inst_key "$n"); j=1
            [ "$key" -gt "$last" ] && last=$key
            for ((i = 0; i < ${#all[@]}; i++)); do
                if [ "${owners[$i]}" = "$n" ]; then v2_db_add "$key.$j" "$i"; j=$((j + 1)); fi
            done
        done
        key=$((last + 1)); j=1
        for ((i = 0; i < ${#all[@]}; i++)); do
            if [ -z "${owners[$i]}" ]; then v2_db_add "$key.$j" "$i"; j=$((j + 1)); fi
        done
    else
        for ((i = 0; i < ${#all[@]}; i++)); do v2_db_add "$((i + 1))" "$i"; done
    fi
}

v2_db_size_cell() {  # v2_db_size_cell INDEX
    if [ "${V2_DBS[$1]}" = "no database" ]; then
        printf '%s' "$YELLOW${V2_CS}no database"
    else
        printf '%s' "${V2_DBS[$1]}"
    fi
}

v2_db_table() {
    local i n cnt seen mark shown=""
    if [ "${#V2_DBN[@]}" -eq 0 ]; then echo "  (no databases yet)"; return 0; fi
    v2_t_begin "No." "Database" "Size" "Files"
    V2_T_SHRINK=1
    if [ "$EPHEM_MODE" != dev-multi ]; then
        for ((i = 0; i < ${#V2_DBN[@]}; i++)); do
            v2_t_add "${V2_DBK[$i]}" "${V2_DBN[$i]}" "$(v2_db_size_cell "$i")" "${V2_DBF[$i]}"
        done
        v2_t_draw
        return 0
    fi
    for n in "${INSTANCES[@]}"; do
        v2_t_add "$BOLD$V2_CS$(v2_inst_key "$n")" "$BOLD${V2_CS}odca$n" "" ""
        cnt=0
        for ((i = 0; i < ${#V2_DBN[@]}; i++)); do [ "${V2_DBO[$i]}" = "$n" ] && cnt=$((cnt + 1)); done
        for ((i = 0; i < ${#V2_STALE_N[@]}; i++)); do [ "${V2_STALE_O[$i]}" = "$n" ] && cnt=$((cnt + 1)); done
        seen=0
        for ((i = 0; i < ${#V2_DBN[@]}; i++)); do
            [ "${V2_DBO[$i]}" = "$n" ] || continue
            seen=$((seen + 1))
            mark="├ "; [ "$seen" = "$cnt" ] && mark="└ "
            v2_t_add "${V2_DBK[$i]}" "$mark${V2_DBN[$i]}" "$(v2_db_size_cell "$i")" "${V2_DBF[$i]}"
        done
        for ((i = 0; i < ${#V2_STALE_N[@]}; i++)); do
            [ "${V2_STALE_O[$i]}" = "$n" ] || continue
            seen=$((seen + 1))
            mark="├ "; [ "$seen" = "$cnt" ] && mark="└ "
            v2_t_add "" "$mark${V2_STALE_N[$i]}" "$YELLOW${V2_CS}stale copy" "${V2_STALE_S[$i]}"
        done
    done
    for ((i = 0; i < ${#V2_DBN[@]}; i++)); do
        [ -z "${V2_DBO[$i]}" ] || continue
        if [ -z "$shown" ]; then
            v2_t_add "$BOLD$V2_CS${V2_DBK[$i]%%.*}" "$BOLD${V2_CS}no instance holds its files" "" ""
            shown=1
        fi
        v2_t_add "${V2_DBK[$i]}" "└ ${V2_DBN[$i]}" "$(v2_db_size_cell "$i")" "${V2_DBF[$i]}"
    done
    v2_t_draw
}

v2_db_copy() {  # v2_db_copy SOURCE
    local src="$1" t
    local -a targets=()
    v2_title "Duplicate $src"
    read -r -a targets -p "  New database name(s), separated by spaces (Enter cancels): "
    [ "${#targets[@]}" -eq 0 ] && { v2_cancel; return 0; }
    for t in "${targets[@]}"; do
        if ! valid_db_name "$t"; then
            v2_cancel "'$t' is not a valid database name (letters, digits, . _ -)."
            return 0
        fi
    done
    bash scripts/duplicate-db.sh "$src" "${targets[@]}" || true
}

v2_orphan_delete() {  # v2_orphan_delete NAME: files whose database is already gone
    local db="$1"
    v2_title "Delete the files of $db" "No database has this name: only its files are left."
    echo -e "  ${CYAN}→${NC} Taking a snapshot first..."
    if ! snapshot_create "$db"; then
        echo -e "  ${RED}✗${NC} Snapshot failed: refusing to delete. Nothing was changed."
        return 0
    fi
    echo "  Recoverable from: backups/${SNAPSHOT_DIR##*/}  (Databases, then r)"
    confirm_destructive "$db" filestore || return 0
    delete_filestore "$db" || true
}

v2_db_verb() {  # v2_db_verb VERB INDEX: 1 when not a database action
    local db="${V2_DBN[$2]}" owner="${V2_DBO[$2]}" orphan=0
    [ "${V2_DBS[$2]}" = "no database" ] && orphan=1
    case "$1" in s|S|d|D|k|K) ;; *) return 1 ;; esac
    if ! existing_db_name "$db"; then
        v2_bad "'$db' is not a name this menu can act on (letters, digits, . _ - and ,)."
        return 0
    fi
    [ -n "$owner" ] && v2_use_instance "$owner"
    case "$1" in
        s|S) v2_do snapshot_create "$db" ;;
        d|D)
            if [ "$orphan" = 1 ]; then v2_bad "$db has no database, only files: nothing to duplicate."
            else v2_do v2_db_copy "$db"; fi
            ;;
        k|K)
            if [ "$orphan" = 1 ]; then
                v2_do v2_orphan_delete "$db"
            else
                V2_DB="$db"; v2_do menu_db_delete; V2_DB=""
            fi
            ;;
    esac
    return 0
}

v2_db_screen() {  # v2_db_screen INDEX
    local i="$1" db="${V2_DBN[$1]}" owner="${V2_DBO[$1]}" orphan=0
    [ "${V2_DBS[$i]}" = "no database" ] && orphan=1
    while true; do
        v2_title "$db"
        v2_t_begin
        if [ "$orphan" = 1 ]; then
            v2_t_add "Database" "$YELLOW${V2_CS}none: only its files are left"
        else
            v2_t_add "Size" "${V2_DBS[$i]}"
        fi
        v2_t_add "Files" "${V2_DBF[$i]}"
        [ -n "$owner" ] && v2_t_add "Instance" "odca$owner"
        v2_t_draw
        v2_head "This database"
        v2_opt s "Snapshot: database + files into backups/"
        [ "$orphan" = 1 ] || v2_opt d "Duplicate into new database(s), for example training copies"
        v2_opt k "Delete (takes a snapshot first)"
        v2_nav
        v2_prompt
        case "$V2_ANS" in
            ""|b|B) return 0 ;;
            x|X)    v2_bye ;;
            k|K)
                v2_db_verb k "$i"
                if [ "$orphan" = 1 ] || ! db_exists "$db"; then return 0; fi
                ;;
            *)      v2_db_verb "$V2_ANS" "$i" || v2_bad ;;
        esac
    done
}

# Which database, for an action chosen from the list. Sets V2_PICK_DB.
V2_PICK_DB=-1
v2_pick_db() {  # v2_pick_db TITLE: 1 when backed out
    local j
    if [ "${#V2_DBK[@]}" -eq 0 ]; then v2_bad "No databases yet."; return 1; fi
    while true; do
        v2_title "$1"
        v2_db_table
        v2_head "Which database"
        v2_opt "${V2_DBK[0]}" "Type its number from the table"
        v2_opt Enter "Back"
        v2_prompt
        case "$V2_ANS" in
            ""|b|B) return 1 ;;
            x|X)    v2_bye ;;
        esac
        for ((j = 0; j < ${#V2_DBK[@]}; j++)); do
            if [ "${V2_DBK[$j]}" = "$V2_ANS" ]; then V2_PICK_DB=$j; return 0; fi
        done
        v2_bad "Nothing is numbered $V2_ANS."
    done
}

v2_snapshot_all() {
    local d ok=0 bad=0 dbs
    v2_title "Snapshot every database"
    dbs=$(list_dbs)
    [ -n "$dbs" ] || { v2_cancel "No databases to back up."; return 0; }
    for d in $dbs; do
        echo ""
        if snapshot_create "$d"; then ok=$((ok + 1)); else bad=$((bad + 1)); fi
    done
    echo ""
    echo -e "  ${GREEN}✓${NC} $ok snapshot(s) written to backups/"
    [ "$bad" -gt 0 ] && echo -e "  ${RED}✗${NC} $bad failed: see the output above."
    return 0
}

v2_backup_all() { bash scripts/backup.sh || true; echo ""; ls -lht backups/ 2>/dev/null | head -5; }

v2_databases() {
    local i j reload=1
    if [ "$(svc_state db)" != running ]; then
        v2_bad "The database container is not running: start it first ($(services_hint))."
        return 0
    fi
    while true; do
        if [ "$reload" = 1 ]; then v2_load_dbs; reload=0; fi
        v2_title "Databases and backups" "A tenant is the database plus its files; a snapshot carries both."
        v2_db_table
        v2_head "One database"
        v2_opt s "Snapshot: database + files into backups/"
        v2_opt d "Duplicate into new database(s), for example training copies"
        v2_opt k "Delete (takes a snapshot first)"
        v2_head "All databases"
        v2_opt n "New empty database"
        v2_opt r "Restore a backup"
        v2_opt e "Snapshot every database, one folder each"
        v2_opt a "Back up everything now: whole server, encrypted, the one for cron"
        v2_nav
        echo ""
        echo "  Type a letter from the list, or a number from the table."
        v2_prompt
        [ -n "$V2_ANS" ] || return 0
        v2_parse "$V2_ANS"
        if [ -n "$V2_LOC" ]; then
            i=-1
            for ((j = 0; j < ${#V2_DBK[@]}; j++)); do [ "${V2_DBK[$j]}" = "$V2_LOC" ] && i=$j; done
            if [ "$i" -lt 0 ]; then v2_bad "Nothing is numbered $V2_LOC."; continue; fi
            if [ -z "$V2_VERB" ]; then
                v2_db_screen "$i"; reload=1
            elif v2_db_verb "$V2_VERB" "$i"; then
                reload=1
            else
                v2_bad "For a database: s snapshot, d duplicate, k delete."
            fi
            continue
        fi
        case "$V2_VERB" in
            b|B) return 0 ;;
            x|X) v2_bye ;;
            s|S) if v2_pick_db "Snapshot a database"; then v2_db_verb s "$V2_PICK_DB"; fi ;;
            d|D) if v2_pick_db "Duplicate a database"; then v2_db_verb d "$V2_PICK_DB"; reload=1; fi ;;
            k|K) if v2_pick_db "Delete a database"; then v2_db_verb k "$V2_PICK_DB"; reload=1; fi ;;
            n|N) if v2_pick_instance "New empty database: which instance creates it"; then v2_do menu_db_create; reload=1; fi ;;
            r|R) if v2_pick_instance "Restore a backup: which instance gets its files"; then v2_do menu_db_restore; reload=1; fi ;;
            e|E) v2_do v2_snapshot_all ;;
            a|A) v2_do v2_backup_all ;;
            *)   v2_bad ;;
        esac
    done
}

# ── Maintenance ───────────────────────────────
v2_stack_up() {
    local C
    if [ "$EPHEM_MODE" = dev-multi ]; then
        echo "  Regenerates docker-compose.dev-multi.yml and the odoo-N.conf files, then"
        echo "  recreates every container in the roster (the shared Postgres restarts"
        echo "  too). Databases, filestores and addons folders are kept."
        read -r -p "  Continue? [y/N]: " C || C=n
        [[ "${C:-N}" =~ ^[Yy]$ ]] || { v2_cancel; return 0; }
        bash scripts/dev-instances.sh up "${INSTANCES[@]}" || true
    else
        compose up -d && wait_for_odoo
    fi
    return 0
}

v2_stack_down() {
    local C
    read -r -p "  Stop every container (data is kept)? [y/N]: " C || C=n
    [[ "${C:-N}" =~ ^[Yy]$ ]] || { v2_cancel; return 0; }
    if [ "$EPHEM_MODE" = dev-multi ]; then bash scripts/dev-instances.sh down || true; else compose down || true; fi
}

v2_default_instance() {
    v2_pick_instance "Default instance, now odca$(env_get EPHEM_INSTANCE)" || return 0
    stack_pin_instance "$EPHEM_INSTANCE"
    v2_bad "odca$EPHEM_INSTANCE is the default now (EPHEM_INSTANCE in .env)."
}

v2_maintenance_local() {
    local left
    while true; do
        left=$(stack_leftovers) || true
        v2_title "Maintenance" "$(ephem_mode_label)"
        v2_t_begin
        v2_t_add "Postgres" "$(v2_state_cell "$(v2_state ephem-db)")"
        v2_t_add "App image" "$(stack_image)  $(image_summary)"
        v2_t_draw
        v2_head "Stack"
        if [ "$EPHEM_MODE" = dev-multi ]; then
            v2_opt c "Recreate the whole stack from the roster"
            v2_opt o "Stop the whole stack, keep data"
            v2_opt e "Change the roster: add or remove instances"
            v2_opt d "Default instance: the one scripts use when none is named"
            [ -n "$left" ] && v2_opt l "Clean up leftovers from single-instance mode"
        else
            v2_opt c "Start everything"
            v2_opt o "Stop everything, keep data"
        fi
        v2_head "Software"
        v2_opt i "Pull the latest app image and recreate"
        v2_opt g "Local basemap: the maps draw from a file here, offline too"
        echo ""
        echo -e "  ${RED}${BOLD}Danger${NC}"
        v2_opt z "Full reset: wipe every database and filestore, keep addons"
        v2_nav
        v2_prompt
        case "$V2_ANS" in
            ""|b|B) return 0 ;;
            x|X)    v2_bye ;;
            c|C)    v2_do v2_stack_up ;;
            o|O)    v2_do v2_stack_down ;;
            i|I)    v2_do menu_image_local ;;
            g|G)    v2_do menu_basemap ;;
            z|Z)    v2_do menu_stack_wipe ;;
            e|E)    if [ "$EPHEM_MODE" = dev-multi ]; then v2_do menu_stack_roster; else v2_bad; fi ;;
            d|D)    if [ "$EPHEM_MODE" = dev-multi ]; then v2_default_instance; else v2_bad; fi ;;
            l|L)    if [ "$EPHEM_MODE" = dev-multi ] && [ -n "$left" ]; then v2_do menu_stack_leftovers; else v2_bad; fi ;;
            *)      v2_bad ;;
        esac
    done
}

v2_maintenance_server() {
    while true; do
        v2_title "Maintenance"
        v2_head "Capacity"
        v2_opt w "Workers and scheduled jobs: check the load, change them"
        v2_head "Extras"
        v2_opt o "Document converter (ePHEM AI's reader of old Office files)"
        v2_opt g "Local basemap: the maps draw from a file on this server"
        v2_nav
        v2_prompt
        case "$V2_ANS" in
            ""|b|B) return 0 ;;
            x|X)    v2_bye ;;
            w|W)    v2_do menu_capacity ;;
            o|O)    v2_do menu_office ;;
            g|G)    v2_do menu_basemap ;;
            *)      v2_bad ;;
        esac
    done
}

v2_maintenance() { if local_mode; then v2_maintenance_local; else v2_maintenance_server; fi; }

# ── Web access (server) ───────────────────────
v2_web_certs() {
    local d lin doms hit shared
    if ! ssl_is_configured; then
        echo -e "  ${YELLOW}!${NC} HTTP only: this server answers on any hostname."
        return 0
    fi
    certs_refresh
    v2_t_begin "Domain" "Expires" "Note"
    while IFS= read -r d; do
        [ -n "$d" ] || continue
        hit=""; shared=""
        for lin in $(cert_lineages); do
            doms="$(cert_domains_of "$lin")"
            case " $doms " in
                *" $d "*)
                    hit="$lin"
                    [ "$(printf '%s' "$doms" | wc -w)" -gt 1 ] && shared=1
                    break
                    ;;
            esac
        done
        if [ -z "$hit" ]; then
            v2_t_add "$d" "" "$YELLOW${V2_CS}no certificate found for it"
        elif [ -n "$shared" ]; then
            v2_t_add "$d" "$(cert_expiry_of "$hit")" "$YELLOW${V2_CS}shares $hit: c splits it"
        else
            v2_t_add "$d" "$(cert_expiry_of "$hit")" ""
        fi
    done < <(active_domains)
    if [ "${#V2_T_ROWS[@]}" -eq 0 ]; then
        echo -e "  ${YELLOW}!${NC} nginx serves HTTPS but no domain could be read"
    else
        v2_t_draw
    fi
}

v2_web() {
    local access ssl
    while true; do
        access=$(server_access)
        ssl=0
        v2_title "Web access"
        case "$access" in
            direct) echo "  Odoo is reached directly on port $(direct_port), no nginx. Domains, certificates,"
                    echo "  the upload limit and RPC need nginx: bash setup.sh switches." ;;
            proxy)  echo "  Behind the nginx on $(env_get PROXY_FROM): domains and certificates live there."
                    echo "  The upload limit and RPC rewrite the config file for that machine." ;;
            *)      if ssl_is_configured; then ssl=1; fi
                    v2_web_certs
                    v2_head "Domains and certificates"
                    v2_opt a "Add domain(s): one certificate each, no database created"
                    if [ "$ssl" = 1 ]; then
                        v2_opt r "Remove domain(s): drops nginx block and certificate, keeps the data"
                        v2_opt c "Split a shared certificate into one per domain"
                        v2_opt s "HTTPS details: certificates, renewal, how to redo it"
                    else
                        v2_opt s "Set up HTTPS (Let's Encrypt)"
                    fi ;;
        esac
        v2_head "Settings"
        if [ "$access" != direct ]; then
            v2_opt u "Upload size limit (fixes '413 Request Entity Too Large')"
            v2_opt p "RPC endpoints (/xmlrpc, /jsonrpc): block or allow"
        fi
        v2_opt f "Database routing: which database answers which domain"
        v2_opt m "Web database manager: enable or disable"
        v2_nav
        v2_prompt
        case "$V2_ANS:$access" in
            :*|b:*|B:*)          return 0 ;;
            x:*|X:*)             v2_bye ;;
            a:nginx|A:nginx)     v2_do menu_domain_add ;;
            r:nginx|R:nginx)     if [ "$ssl" = 1 ]; then v2_do menu_domain_remove; else v2_bad; fi ;;
            c:nginx|C:nginx)     if [ "$ssl" = 1 ]; then v2_do bash scripts/split-certs.sh; else v2_bad; fi ;;
            s:nginx|S:nginx)     v2_do menu_ssl ;;
            u:nginx|U:nginx|u:proxy|U:proxy) v2_do menu_upload_limit ;;
            p:nginx|P:nginx|p:proxy|P:proxy) v2_do menu_rpc ;;
            f:*|F:*)             v2_do menu_dbfilter ;;
            m:*|M:*)             v2_do menu_db_manager ;;
            *)                   v2_bad ;;
        esac
    done
}

# ── Update (server) ───────────────────────────
v2_update_guided() {
    local C s i
    local -a srcs=()
    v2_title "Update, step 1 of 3: app image"
    menu_update_app || { v2_cancel "Stopped at the app image: nothing further was done."; return 0; }
    echo ""
    echo -e "  ${BOLD}Step 2 of 3: code${NC}"
    read -r -p "  Pull every repository now? [Y/n]: " C || C=n
    if [[ ! "${C:-Y}" =~ ^[Nn]$ ]]; then
        while IFS= read -r s; do [ -n "$s" ] && srcs+=("$s"); done < <(addons_sources "$ADDONS_DIR")
        V2_NET_CANCELLED=0
        for ((i = 0; i < ${#srcs[@]}; i++)); do
            v2_pull_one "$ADDONS_DIR/${srcs[$i]}" "$ADDONS_NAME/${srcs[$i]}"
            [ "$V2_NET_CANCELLED" = 1 ] && break
        done
    fi
    echo ""
    echo -e "  ${BOLD}Step 3 of 3: modules${NC}"
    ADDONS_CHANGED=1    # a new image can need it even when no repository moved
    v2_offer_apply
}

v2_update_server() {
    while true; do
        v2_load_tree
        v2_title "Update" "App image $(env_get EPHEM_IMAGE_TAG | grep . || echo 'latest (not pinned)'), $(v2_fetched_text)"
        v2_tree_table
        v2_head "Guided"
        v2_opt g "App image, code, modules, in that order"
        v2_head "One step"
        v2_opt i "App image only"
        v2_opt c "Code only: pull every repository"
        v2_opt m "Modules only: choose them per database"
        v2_nav
        v2_prompt
        case "$V2_ANS" in
            ""|b|B) return 0 ;;
            x|X)    v2_bye ;;
            g|G)    v2_do v2_update_guided ;;
            i|I)    v2_do menu_update_app ;;
            c|C)    v2_do v2_pull_parent ;;
            m|M)    v2_do bash scripts/update-modules.sh ;;
            *)      v2_bad ;;
        esac
    done
}

v2_server_verb() {  # v2_server_verb VERB: 1 when not a server action
    case "$1" in
        u|U) v2_update_server ;;
        r|R) v2_do menu_service ;;
        o|O) v2_do v2_restart_quiet ;;
        l|L) v2_clear; v2_follow_log ;;
        w|W) v2_web ;;
        *)   return 1 ;;
    esac
    return 0
}

# ── Status and help ───────────────────────────
v2_last_backup_text() {
    local f; f=$(ls -1t backups/*.age backups/*.gz 2>/dev/null | head -1)
    if [ -n "$f" ]; then echo "${f##*/}, $(v2_ago "$(v2_mtime "$f")")"; else echo "none yet: Databases (d), then a"; fi
}

v2_containers_table() {
    local svc state status
    v2_t_begin "Service" "State" "Detail"
    while IFS='|' read -r svc state status; do
        [ -n "$svc" ] || continue
        v2_t_add "$svc" "$(v2_state_cell "$state")" "$status"
    done < <(compose ps -a --format '{{.Service}}|{{.State}}|{{.Status}}' 2>/dev/null)
    v2_t_draw
}

v2_status_body() {
    local dbs snap left access
    if [ "$EPHEM_MODE" = dev-multi ]; then
        v2_instance_table
    else
        v2_load_tree
        v2_tree_table
    fi
    if [ "$EPHEM_MODE" = server ]; then
        echo ""
        v2_containers_table
    fi
    echo ""
    dbs=$(list_dbs | grep -c .) || dbs=0
    snap=$(snapshot_list | head -1)
    left=$(stack_leftovers) || true
    v2_t_begin
    V2_T_SHRINK=1
    [ "$EPHEM_MODE" = dev-multi ] || v2_t_add "Odoo" "$(v2_state_cell "$(v2_state "$ODOO_CTN")")"
    v2_t_add "Postgres" "$(v2_state_cell "$(v2_state ephem-db)")"
    v2_t_add "Databases" "$dbs, listed under Databases (d)"
    if local_mode; then
        v2_t_add "App image" "$(stack_image)  $(image_summary)"
    else
        access=$(server_access)
        case "$access" in
            direct) v2_t_add "Access" "direct on port $(direct_port), no nginx, no HTTPS here" ;;
            proxy)  v2_t_add "Access" "behind the nginx on $(env_get PROXY_FROM), https://$(env_get PROXY_DOMAIN)" ;;
            *)      v2_t_add "Access" "nginx on this server" ;;
        esac
        v2_t_add "App image" "borrs/ephem:$(env_get EPHEM_IMAGE_TAG | grep . || echo 'latest (not pinned)')"
        if office_converter_on; then
            v2_t_add "Office image" "borrs/ephem-office:$(env_get EPHEM_OFFICE_TAG | grep . || env_get EPHEM_IMAGE_TAG | grep . || echo latest)"
        else
            v2_t_add "Office image" "not installed (Maintenance, o)"
        fi
    fi
    v2_t_add "Disk" "$(df -h / | tail -1 | awk '{printf "%s used of %s (%s)", $3, $2, $5}')"
    v2_t_add "Full backup" "$(v2_last_backup_text)"
    if [ -n "$snap" ]; then
        v2_t_add "Newest snapshot" "${snap##*/}"
    else
        v2_t_add "Newest snapshot" "none yet: open a database, then s"
    fi
    [ -n "$left" ] && v2_t_add "Leftovers" "$YELLOW${V2_CS}from another mode: Maintenance (m) removes them"
    v2_t_draw
    if ! local_mode; then
        if [ "$access" = nginx ]; then
            v2_head "Domains and certificates"
            v2_web_certs
        elif [ "$access" = proxy ]; then
            echo ""
            bash "$SCRIPT_DIR/scripts/proxy-firewall.sh" check || true
        fi
    fi
}

v2_status() {
    while true; do
        v2_title "Status and checks" "$(ephem_mode_label)"
        v2_status_body
        v2_head "Checks"
        v2_opt d "Doctor: prerequisites, then scan the log for known errors"
        [ "$EPHEM_MODE" = server ] && v2_opt c "Security check"
        v2_nav
        v2_prompt
        case "$V2_ANS" in
            ""|b|B) return 0 ;;
            x|X)    v2_bye ;;
            d|D)    if v2_pick_instance "Doctor: scan which instance"; then v2_do menu_doctor_local; fi ;;
            c|C)    if [ "$EPHEM_MODE" = server ]; then v2_do menu_security; else v2_bad; fi ;;
            *)      v2_bad ;;
        esac
    done
}

v2_help() {
    while true; do
        v2_title "How this menu works"
        echo "  Choose from the list and it asks where. Or put the letter and the number"
        echo "  on one line and it goes straight there."
        echo ""
        v2_t_begin "You type" "What happens"
        if [ "$EPHEM_MODE" = dev-multi ]; then
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
        else
            v2_t_add "s" "Switch a branch: asks which repository"
            v2_t_add "s 2" "Switch the branch of repository 2"
            v2_t_add "p 2" "Pull it"
            v2_t_add "p a" "Pull every repository"
            v2_t_add "c 2" "Show its local changes"
            v2_t_add "n 2" "Rename it"
            v2_t_add "k 2" "Remove it"
            v2_t_add "2" "Open repository 2: details and its actions"
        fi
        v2_t_add "Enter or b" "Go back one level"
        v2_t_add "x" "Leave, from anywhere"
        v2_t_draw
        echo ""
        echo "  The Origin column (behind, ahead) is what a clone knew at its last fetch."
        echo "  Your SSH key's passphrase is asked right before the first command that"
        echo "  needs the network, once per run."
        v2_head "Docs"
        echo "    README.md in this folder"
        echo "    https://github.com/borse/ephem_deployment_docker#readme"
        echo "    https://github.com/borse/ePHEM"
        echo ""
        echo "  The old menu is still there: bash manage.sh"
        if local_mode; then
            v2_head "More"
            v2_opt p "PyCharm: paths, Git roots, run configurations"
        fi
        v2_nav
        v2_prompt
        case "$V2_ANS" in
            ""|b|B) return 0 ;;
            x|X)    v2_bye ;;
            p|P)    if local_mode; then v2_do menu_pycharm; else v2_bad; fi ;;
            *)      v2_bad ;;
        esac
    done
}

# ── Home ──────────────────────────────────────
v2_home_title() {
    case "$EPHEM_MODE" in
        dev-multi) v2_title "ePHEM developer menu" "$(ephem_mode_label), $(v2_fetched_text)" ;;
        server)
            v2_title "ePHEM production menu" "$(v2_state_colored "$(v2_state "$ODOO_CTN")"), image $(env_get EPHEM_IMAGE_TAG | grep . || echo latest), $(v2_fetched_text)"
            [ "$(server_access)" = direct ] && { echo "  Odoo on port $(direct_port), no nginx."; echo ""; }
            [ "$(server_access)" = proxy ]  && { echo "  Behind the nginx on $(env_get PROXY_FROM)."; echo ""; }
            ;;
        *) v2_title "ePHEM developer menu" "$(ephem_mode_label), $ODOO_URL, $(v2_state_colored "$(v2_state "$ODOO_CTN")"), $(v2_fetched_text)" ;;
    esac
}

v2_home_options() {
    v2_repo_options
    if [ "$EPHEM_MODE" = server ]; then
        v2_head "Run"
        v2_opt u "Update: guided, or one step"
        v2_opt r "Restart, stop, start: Odoo, nginx, everything"
        v2_opt o "Restart Odoo only"
        v2_opt l "Follow the log"
    elif [ "$EPHEM_MODE" = dev-multi ]; then
        v2_head "Run"
        v2_opt r "Restart and follow the log"
        v2_opt o "Restart only"
        v2_opt l "Follow the log"
        v2_opt t "Start or stop"
        v2_opt u "Update modules"
        v2_opt i "Install a module"
    else
        v2_run_options
    fi
    v2_head "More"
    v2_opt d "Databases and backups: duplicate, restore, create, delete"
    [ "$EPHEM_MODE" = server ] && v2_opt w "Web access: domains, certificates, upload limit, RPC"
    v2_opt m "Maintenance"
    v2_opt v "Status and checks"
    v2_opt h "Help"
    v2_opt x "Exit"
    echo ""
    echo "  Type a letter from the list, or a number from the table."
}

v2_run_verb() {  # v2_run_verb VERB: 1 when not a Run action on this home screen
    case "$EPHEM_MODE" in
        server) v2_server_verb "$1"; return ;;
    esac
    case "$1" in
        r|R) v2_act_instance r "Restart and follow the log" ;;
        o|O) v2_act_instance o "Restart only" ;;
        l|L) v2_act_instance l "Follow the log" ;;
        t|T) v2_act_instance t "Start or stop" ;;
        u|U) v2_act_instance u "Update modules" ;;
        i|I) v2_act_instance i "Install a module" ;;
        *)   return 1 ;;
    esac
}

v2_home() {
    [ "$EPHEM_MODE" = dev-multi ] || v2_layout_offer
    while true; do
        v2_load_tree
        v2_home_title
        v2_tree_table
        v2_dups_show
        v2_home_options
        v2_prompt
        [ -n "$V2_ANS" ] || continue
        v2_parse "$V2_ANS"
        if [ -n "$V2_LOC" ]; then v2_go "$V2_LOC" "$V2_VERB"; continue; fi
        case "$V2_VERB" in
            x|X)     v2_bye ;;
            b|B)     ;;
            s|S)     v2_act_repo s "Switch a branch" ;;
            p|P)     v2_act_pull ;;
            c|C)     v2_act_repo c "Show local changes" ;;
            f|F)     v2_do v2_fetch_all ;;
            +)       v2_act_instance + "Add a repository" ;;
            n|N)     v2_act_repo n "Rename a repository" ;;
            k|K)     v2_act_repo k "Remove a repository" ;;
            d|D)     v2_databases ;;
            m|M)     v2_maintenance ;;
            v|V)     v2_status ;;
            h|H|'?') v2_help ;;
            *)       v2_run_verb "$V2_VERB" || v2_bad ;;
        esac
    done
}

# ── Start ─────────────────────────────────────
# `bash manage_v2.sh 2`: into that instance first; back lands on the tree.
if [ "$EPHEM_MODE" = dev-multi ] && [ -n "${1:-}" ]; then
    v2_instance_screen "$EPHEM_INSTANCE"
fi
v2_home
