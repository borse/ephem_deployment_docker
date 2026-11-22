#!/bin/bash
# ──────────────────────────────────────────────────────────────
# ui.sh — the screens and boxed tables of the native menu (menu.sh) and of
# the move from Docker (from-docker.sh). Sourced, never run. Runs on macOS's
# own bash 3.2; uses the colors of lib.sh, so source that first.
# ──────────────────────────────────────────────────────────────

# ── Screens, tables ───────────────────────────
# Copied from manage.sh (the Docker menu), so both menus look the same: keep
# the two in step when one of them changes.
V2_NOTICE=""        # one line for the next screen: a screen clears what came before
V2_NO_PAUSE=0

v2_bye()   { echo "Bye. Re-open anytime:  $V2_ME"; exit 0; }
v2_ask()   { read -r -p "$1" V2_ANS || { echo ""; v2_bye; }; }
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

# One action on a clean screen, its result kept there until Enter.
v2_do() {  # v2_do COMMAND...
    V2_NO_PAUSE=0
    v2_clear
    "$@" || true
    if [ "$V2_NO_PAUSE" = 1 ]; then return 0; fi
    v2_pause
}

v2_cancel() { V2_NOTICE="${1:-Cancelled.}"; V2_NO_PAUSE=1; }

# Tables. v2_t_begin HEADERS (none for a two-column fact sheet), v2_t_add per
# row, v2_t_draw. Columns fit their contents and the terminal: a column with
# nothing in it is not drawn; if it is still too wide V2_T_DROP goes, then
# V2_T_SHRINK is cut short. A cell can be "$COLOR$V2_CS text", and may start
# with a tree mark.
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
