#!/bin/bash

# Terminal lifecycle and bounded key decoding for the fullscreen NetUI UI.

tui_terminal_active=0
tui_terminal_saved_stty=''
tui_terminal_alt_screen=0
tui_terminal_key=''
tui_terminal_hidden_value=''

tui_terminal_get_size() {
    local rows=''
    local cols=''

    if [[ "${NETUI_TUI_FIXED_ROWS:-}" =~ ^[0-9]+$ && "${NETUI_TUI_FIXED_COLS:-}" =~ ^[0-9]+$ ]]; then
        printf '%s|%s' "$NETUI_TUI_FIXED_ROWS" "$NETUI_TUI_FIXED_COLS"
        return 0
    fi
    if read -r rows cols < <(stty size 2>/dev/null); then
        [[ "$rows" =~ ^[0-9]+$ && "$cols" =~ ^[0-9]+$ ]] || return 1
        printf '%s|%s' "$rows" "$cols"
        return 0
    fi
    rows=${LINES:-24}
    cols=${COLUMNS:-80}
    [[ "$rows" =~ ^[0-9]+$ && "$cols" =~ ^[0-9]+$ ]] || return 1
    printf '%s|%s' "$rows" "$cols"
}

tui_terminal_restore() {
    if ((tui_terminal_active)); then
        if ((tui_terminal_alt_screen)); then
            printf '\033[?2004l\033[?25h\033[?1049l' >&1
        else
            printf '\033[?2004l\033[?25h' >&1
        fi
        if [[ -n "$tui_terminal_saved_stty" ]]; then
            stty "$tui_terminal_saved_stty" 2>/dev/null || true
        fi
        tui_terminal_active=0
        tui_terminal_saved_stty=''
        tui_terminal_alt_screen=0
    fi
}

tui_terminal_enter() {
    [[ -t 0 && -t 1 ]] || return 1
    tui_terminal_saved_stty=$(stty -g 2>/dev/null) || return 1
    stty -icanon -echo min 0 time 0 2>/dev/null || {
        tui_terminal_saved_stty=''
        return 1
    }
    tui_terminal_active=1
    if [[ "${NETUI_TUI_DISABLE_ALT_SCREEN:-0}" != 1 ]]; then
        printf '\033[?1049h\033[?25l\033[?2004h' >&1
        tui_terminal_alt_screen=1
    else
        printf '\033[?25l\033[?2004h' >&1
    fi
}

tui_terminal_read_key() {
    local timeout=${1:-0.2}
    local esc_timeout=${NETUI_TUI_ESC_TIMEOUT_MS:-50}
    local esc_seconds='0.050'
    local first=''
    local next=''
    local sequence=''
    local byte=''

    if [[ "$esc_timeout" =~ ^[0-9]+$ ]]; then
        esc_seconds=$(awk -v ms="$esc_timeout" 'BEGIN {printf "%.3f", ms / 1000}')
    fi
    tui_terminal_key=''
    IFS= read -r -N 1 -t "$timeout" first || return 1
    case "$first" in
        $'\r'|$'\n') tui_terminal_key=ENTER ;;
        $'\x12') tui_terminal_key=CTRL_R ;;
        $'\x14') tui_terminal_key=CTRL_T ;;
        $'\x7f'|$'\b') tui_terminal_key=BACKSPACE ;;
        $'\x1b')
            if ! IFS= read -r -N 1 -t "$esc_seconds" next; then
                tui_terminal_key=ESC
            elif [[ "$next" == '[' || "$next" == 'O' ]]; then
                sequence=''
                if [[ "$next" == 'O' ]]; then
                    IFS= read -r -N 1 -t "$esc_seconds" byte || byte=''
                    case "$byte" in
                        A) tui_terminal_key=UP ;;
                        B) tui_terminal_key=DOWN ;;
                        *) tui_terminal_key=UNKNOWN ;;
                    esac
                else
                    while ((${#sequence} < 12)); do
                        IFS= read -r -N 1 -t "$esc_seconds" byte || {
                            tui_terminal_key=UNKNOWN
                            break
                        }
                        sequence+=$byte
                        if [[ "$byte" =~ [A-Za-z~] ]]; then
                            case "$sequence" in
                                A) tui_terminal_key=UP ;;
                                B) tui_terminal_key=DOWN ;;
                                '1;5A'|'5A') tui_terminal_key=CTRL_UP ;;
                                '1;5B'|'5B') tui_terminal_key=CTRL_DOWN ;;
                                '200~') tui_terminal_key=PASTE_START ;;
                                '201~') tui_terminal_key=PASTE_END ;;
                                *) tui_terminal_key=UNKNOWN ;;
                            esac
                            break
                        fi
                    done
                fi
            else
                tui_terminal_key=UNKNOWN
            fi
            ;;
        i|I) tui_terminal_key=IMPORT ;;
        l|L) tui_terminal_key=LOG_SOURCE ;;
        r|R) tui_terminal_key=REFRESH ;;
        o|O) tui_terminal_key=MODE_OFF ;;
        g|G) tui_terminal_key=MODE_GLOBAL ;;
        w|W) tui_terminal_key=MODE_WHITELIST ;;
        q|Q) tui_terminal_key=QUIT ;;
        '?') tui_terminal_key=HELP ;;
        *)
            if [[ "$first" =~ [[:cntrl:]] ]]; then
                tui_terminal_key=UNKNOWN
            else
                tui_terminal_key="TEXT:$first"
            fi
            ;;
    esac
    [[ -n "$tui_terminal_key" ]] || tui_terminal_key=UNKNOWN
    return 0
}

tui_terminal_read_hidden_line() {
    local max_bytes=${1:-16384}
    local value=''
    local byte=''
    local next=''
    local sequence=''
    local paste_mode=0

    tui_terminal_hidden_value=''
    while :; do
        IFS= read -r -N 1 -t 0.25 byte || continue
        case "$byte" in
            $'\r'|$'\n')
                break
                ;;
            $'\x7f'|$'\b')
                value=${value%?}
                ;;
            $'\x1b')
                sequence=''
                if ! IFS= read -r -N 1 -t 0.05 next; then
                    tui_terminal_hidden_value=''
                    return 1
                fi
                if [[ "$next" == '[' ]]; then
                    while ((${#sequence} < 8)); do
                        IFS= read -r -N 1 -t 0.05 next || break
                        sequence+=$next
                        [[ "$next" =~ [A-Za-z~] ]] && break
                    done
                    case "$sequence" in
                        '200~') paste_mode=1 ;;
                        '201~') paste_mode=0 ;;
                    esac
                fi
                ;;
            *)
                if [[ ! "$byte" =~ [[:cntrl:]] ]]; then
                    value+=$byte
                    ((${#value} <= max_bytes)) || return 2
                elif ((paste_mode)); then
                    return 2
                fi
                ;;
        esac
    done
    tui_terminal_hidden_value=$value
}

tui_terminal_confirm() {
    local answer=''

    while :; do
        tui_terminal_read_key 30 || return 1
        answer=$tui_terminal_key
        case "$answer" in
            TEXT:y|TEXT:Y|ENTER) return 0 ;;
            TEXT:n|TEXT:N|ESC|QUIT) return 1 ;;
        esac
    done
}
