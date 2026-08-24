#!/bin/bash

# Model, frame rendering, and actions for the fullscreen NetUI interface.

tui_v2_selected_index=0
tui_v2_selected_basename=''
tui_v2_model_ready=0
tui_v2_running=1
tui_v2_status_message=''
tui_v2_status_level='info'
tui_v2_modal_message=''
tui_v2_cols=80
tui_v2_rows=24
declare -a tui_v2_names=()
declare -a tui_v2_protocols=()
declare -a tui_v2_servers=()
declare -a tui_v2_ports=()
declare -a tui_v2_transports=()
declare -a tui_v2_security=()
declare -a tui_v2_locals=()
declare -a tui_v2_checks=()
declare -a tui_v2_paths=()
declare -a tui_v2_latencies=()
declare -a tui_v2_speeds=()
declare -a tui_v2_logs=()

tui_v2_clean_text() {
    local input=${1:-}
    local output=''
    local char=''
    local ordinal=0
    local index=0

    LC_ALL=C
    for ((index = 0; index < ${#input}; index++)); do
        char=${input:index:1}
        printf -v ordinal '%d' "'$char"
        if ((ordinal >= 32 && ordinal != 127)); then
            output+=$char
        fi
    done
    printf '%s' "$output"
}

tui_v2_clip() {
    local value=''
    local width=$2

    [[ "$width" =~ ^[0-9]+$ ]] || width=1
    value=$(tui_v2_clean_text "${1:-}")
    if ((${#value} > width)); then
        if ((width > 3)); then
            value="${value:0:$((width - 3))}..."
        else
            value=${value:0:width}
        fi
    fi
    printf '%s' "$value"
}

tui_v2_field() {
    local value=''
    local width=$2

    value=$(tui_v2_clip "${1:-}" "$width")
    printf "%-${width}s" "$value"
}

tui_v2_repeat() {
    local count=$1
    local char=${2:-─}
    local output=''

    ((count > 0)) || return 0
    printf -v output '%*s' "$count" ''
    output=${output// /$char}
    printf '%s' "$output"
}

tui_v2_line() {
    local text
    local inner_width=$((tui_v2_cols - 2))

    text=$(tui_v2_clip "${1:-}" "$inner_width")
    printf '│%-*s│\n' "$inner_width" "$text"
}

tui_v2_set_status() {
    tui_v2_status_level=${1:-info}
    tui_v2_status_message=$(tui_v2_clean_text "${2:-}")
    tui_v2_modal_message=''
}

tui_v2_collect_logs() {
    local line=''

    tui_v2_logs=()
    if [[ -f "$NETUI_LOG_FILE" && ! -L "$NETUI_LOG_FILE" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            tui_v2_logs+=("$(tui_v2_clean_text "$line")")
        done < <(tail -n 8 -- "$NETUI_LOG_FILE")
    fi
    if ((${#tui_v2_logs[@]} == 0)); then
        tui_v2_logs=('No recent NetUI log entries.')
    fi
}

tui_v2_model_refresh() {
    local previous_basename=${tui_v2_selected_basename:-}
    local path=''
    local basename=''
    local metadata=''
    local fields=''
    local name=''
    local protocol=''
    local server=''
    local port=''
    local transport=''
    local security=''
    local local_endpoint=''
    local metadata_status=''
    local index=0

    tui_refresh_configs
    tui_running_state
    tui_v2_paths=()
    tui_v2_names=()
    tui_v2_protocols=()
    tui_v2_servers=()
    tui_v2_ports=()
    tui_v2_transports=()
    tui_v2_security=()
    tui_v2_locals=()
    tui_v2_checks=()
    tui_v2_latencies=()
    tui_v2_speeds=()

    for path in "${tui_config_paths[@]}"; do
        basename=${path##*/}
        metadata=$(config_meta_extract "$path" 2>/dev/null || printf '{}')
        fields=$(jq -r '[
            (.name // ""),
            (.display_protocol // "unknown"),
            (.server // "—"),
            ((.server_port // "") | tostring),
            (.transport // "—"),
            (.security // "—"),
            (if .local_type == null then "—" else "\(.local_type) \(.local_listen):\(.local_port)" end),
            (.metadata_status // "unknown")
        ] | @tsv' <<< "$metadata" 2>/dev/null || printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$basename" unknown '—' '' '—' '—' '—' invalid)
        IFS=$'\t' read -r name protocol server port transport security local_endpoint metadata_status <<< "$fields"
        tui_v2_paths[$index]=$path
        tui_v2_names+=("$basename")
        tui_v2_protocols+=("${protocol:-unknown}")
        tui_v2_servers+=("${server:-—}")
        tui_v2_ports+=("${port:-—}")
        tui_v2_transports+=("${transport:-—}")
        tui_v2_security+=("${security:-—}")
        tui_v2_locals+=("${local_endpoint:-—}")
        tui_v2_checks+=("$(tui_check_for_config "$path")")
        tui_v2_latencies+=('—')
        tui_v2_speeds+=('—')
        index=$((index + 1))
    done

    if ((${#tui_v2_paths[@]} == 0)); then
        tui_v2_selected_index=0
        tui_v2_selected_basename=''
    else
        if [[ -n "$previous_basename" ]]; then
            for index in "${!tui_v2_paths[@]}"; do
                if [[ "${tui_v2_names[$index]}" == "$previous_basename" || "${tui_v2_paths[$index]##*/}" == "$previous_basename" ]]; then
                    tui_v2_selected_index=$index
                    break
                fi
            done
        fi
        ((tui_v2_selected_index < ${#tui_v2_paths[@]})) || tui_v2_selected_index=$((${#tui_v2_paths[@]} - 1))
        ((tui_v2_selected_index >= 0)) || tui_v2_selected_index=0
        tui_v2_selected_basename=${tui_v2_paths[$tui_v2_selected_index]##*/}
        tui_selected_path=${tui_v2_paths[$tui_v2_selected_index]}
    fi
    tui_v2_collect_logs
    tui_v2_model_ready=1
}

tui_v2_render_frame() {
    local size=''
    local version=''
    local default_basename=''
    local selected_name=''
    local selected_endpoint='—'
    local environment=''
    local env_mode='off'
    local env_effective='off'
    local env_bytes='0'
    local title=''
    local row=''
    local marker=''
    local index=0
    local visible_rows=0
    local log_rows=0
    local line_index=0
    local status_prefix=''
    local inner_width=0

    size=$(tui_terminal_get_size 2>/dev/null || printf '24|80')
    IFS='|' read -r tui_v2_rows tui_v2_cols <<< "$size"
    ((tui_v2_rows >= 12)) || tui_v2_rows=12
    ((tui_v2_cols >= 60)) || tui_v2_cols=60
    inner_width=$((tui_v2_cols - 2))
    if [[ -f "${NETUI_PACKAGE_ROOT:-.}/VERSION" ]]; then
        IFS= read -r version < "${NETUI_PACKAGE_ROOT:-.}/VERSION" || version='?'
    else
        version='?'
    fi
    default_basename=$(tui_default_basename)
    environment=$(tui_environment_summary)
    IFS='|' read -r env_mode env_effective env_bytes <<< "$environment"
    if ((${#tui_v2_paths[@]} > 0)); then
        selected_name=${tui_v2_names[$tui_v2_selected_index]}
        selected_endpoint=${tui_v2_locals[$tui_v2_selected_index]}
    else
        selected_name='—'
    fi
    if [[ -n "$tui_v2_status_message" ]]; then
        status_prefix='STATUS: '
    fi

    if ((tui_terminal_active)); then
        printf '\033[H\033[2J'
    fi
    printf '╭%s╮\n' "$(tui_v2_repeat "$inner_width" '─')"
    title=" NetUI v$version | running: ${tui_running_status:-stopped} ${tui_running_basename:-—}"
    tui_v2_line "$title"
    tui_v2_line ' ↑↓ select   Enter default   Ctrl+↑ global   Ctrl+↓ cn-direct   Ctrl+R restart'
    tui_v2_line ' i import   r refresh   l logs   o off   ? help   q quit'
    printf '├%s┤\n' "$(tui_v2_repeat "$inner_width" '─')"
    tui_v2_line ' CONFIGURATIONS'
    if ((tui_v2_cols >= 100)); then
        tui_v2_line "$(printf '%-5s %-20s %-22s %5s %-11s %-10s %-18s %-4s' MARK CONFIG SERVER PORT PROTOCOL SECURITY LOCAL CHECK)"
    else
        tui_v2_line "$(printf '%-5s %-18s %-12s %-18s %-4s' MARK CONFIG PROTOCOL LOCAL CHECK)"
    fi
    visible_rows=$((tui_v2_rows - 16))
    ((visible_rows >= 1)) || visible_rows=1
    if ((${#tui_v2_paths[@]} == 0)); then
        tui_v2_line '      no JSON configurations found; press i to import'
    else
        for index in "${!tui_v2_paths[@]}"; do
            ((index < visible_rows)) || break
            marker=' '
            ((index == tui_v2_selected_index)) && marker='▶'
            [[ "${tui_v2_paths[$index]##*/}" == "$default_basename" ]] && marker+="★"
            [[ "${tui_v2_paths[$index]##*/}" == "$tui_running_basename" ]] && marker+="●"
            [[ "${tui_v2_checks[$index]}" == bad ]] && marker+='!'
            if ((tui_v2_cols >= 100)); then
                printf -v row '%-5s %-20s %-22s %5s %-11s %-10s %-18s %-4s' \
                    "$marker" "${tui_v2_names[$index]}" "${tui_v2_servers[$index]}" "${tui_v2_ports[$index]}" \
                    "${tui_v2_protocols[$index]}" "${tui_v2_security[$index]}" "${tui_v2_locals[$index]}" "${tui_v2_checks[$index]}"
            else
                printf -v row '%-5s %-18s %-12s %-18s %-4s' \
                    "$marker" "${tui_v2_names[$index]}" "${tui_v2_protocols[$index]}" "${tui_v2_locals[$index]}" "${tui_v2_checks[$index]}"
            fi
            tui_v2_line "$row"
        done
        if ((${#tui_v2_paths[@]} > visible_rows)); then
            tui_v2_line "      ... ${#tui_v2_paths[@]} configurations; use ↑/↓ to move"
        fi
    fi
    printf '├%s┤\n' "$(tui_v2_repeat "$inner_width" '─')"
    tui_v2_line ' LOGS'
    log_rows=$((tui_v2_rows - 15))
    ((log_rows >= 2)) || log_rows=2
    for ((line_index = 0; line_index < log_rows; line_index++)); do
        if ((line_index < ${#tui_v2_logs[@]})); then
            tui_v2_line "  ${tui_v2_logs[$line_index]}"
        else
            tui_v2_line ''
        fi
    done
    printf '├%s┤\n' "$(tui_v2_repeat "$inner_width" '─')"
    tui_v2_line "Default: ${default_basename:-—}  Running: ${tui_running_basename:-—}  Selected: $selected_name"
    tui_v2_line "Env: $env_mode effective:$env_effective no_proxy:${env_bytes}B  Local: $selected_endpoint"
    if [[ -n "$tui_v2_status_message" ]]; then
        tui_v2_line "$status_prefix$tui_v2_status_message"
    else
        tui_v2_line 'Ready. Press ? for help.'
    fi
    if [[ -n "$tui_v2_modal_message" ]]; then
        tui_v2_line "╭─ $tui_v2_modal_message"
    fi
    printf '╰%s╯\n' "$(tui_v2_repeat "$inner_width" '─')"
}

tui_v2_run_business() {
    local label=$1
    shift
    local output_file=''
    local output=''
    local status=0

    output_file=$(mktemp "${TMPDIR:-/tmp}/netui-tui-action.XXXXXX") || {
        tui_v2_set_status error "$label failed: temporary file unavailable"
        return 1
    }
    "$@" >"$output_file" 2>&1 || status=$?
    output=$(tail -n 1 -- "$output_file" 2>/dev/null || true)
    rm -f -- "$output_file"
    if ((status == 0)); then
        tui_v2_set_status info "${label}: ${output:-ok}"
    else
        tui_v2_set_status error "${label} failed (exit $status)"
    fi
    tui_v2_model_refresh
    return "$status"
}

tui_v2_modal_help() {
    tui_v2_modal_message='↑↓ move | Enter default | Ctrl↑ global | Ctrl↓ cn-direct | CtrlR restart | i import | o off | q quit'
    tui_v2_render_frame
    tui_terminal_read_key 30 || true
    tui_v2_modal_message=''
}

tui_v2_modal_import() {
    local uri=''
    local preview=''
    local fields=''
    local protocol=''
    local server=''
    local port=''
    local warning=''
    local status=0

    tui_v2_set_status info 'Paste one share URI; input is hidden. Press Enter to parse or Esc to cancel.'
    tui_v2_render_frame
    tui_terminal_read_hidden_line 16384 || {
        tui_v2_set_status info 'Import cancelled'
        return 0
    }
    uri=$tui_terminal_hidden_value
    [[ -n "$uri" ]] || {
        tui_v2_set_status error 'Import failed: empty URI'
        return 1
    }
    if ! share_uri_parse "$uri" >/dev/null 2>&1; then
        tui_v2_set_status error "Import failed: $(share_uri_last_error_code)"
        return 1
    fi
    preview=$(share_uri_preview_json 2>/dev/null) || {
        tui_v2_set_status error 'Import failed: preview unavailable'
        return 1
    }
    fields=$(jq -r '[.protocol, (.server // "—"), ((.port // "") | tostring), (.warning // "")] | @tsv' <<< "$preview")
    IFS=$'\t' read -r protocol server port warning <<< "$fields"
    tui_v2_modal_message="Preview $protocol $server:$port${warning:+ [$warning]} | Enter import, Esc cancel"
    tui_v2_render_frame
    tui_terminal_read_key 30 || status=1
    if [[ "$tui_terminal_key" != ENTER ]]; then
        tui_v2_modal_message=''
        tui_v2_set_status info 'Import cancelled'
        return 0
    fi
    if ! share_uri_import "$uri" >/dev/null 2>&1; then
        tui_v2_set_status error "Import failed: $(share_uri_last_error_code)"
        return 1
    fi
    tui_v2_set_status info "Imported ${share_uri_last_path##*/}"
    tui_v2_model_refresh
}

tui_v2_modal_rename() {
    local new_basename=''

    tui_v2_set_status info 'Type a new *.json basename; input is hidden. Press Enter to commit or Esc to cancel.'
    tui_v2_render_frame
    tui_terminal_read_hidden_line 255 || {
        tui_v2_set_status info 'Rename cancelled'
        return 0
    }
    new_basename=$tui_terminal_hidden_value
    [[ -n "$new_basename" ]] || return 1
    if config_store_rename "${tui_v2_paths[$tui_v2_selected_index]}" "$new_basename" >/dev/null 2>&1; then
        tui_v2_set_status info "Renamed to $new_basename"
        tui_v2_model_refresh
    else
        tui_v2_set_status error 'Rename failed'
        return 1
    fi
}

tui_v2_modal_detail() {
    local index=$tui_v2_selected_index

    tui_v2_modal_message="${tui_v2_names[$index]} | ${tui_v2_protocols[$index]} | ${tui_v2_servers[$index]}:${tui_v2_ports[$index]} | credentials hidden | press any key"
    tui_v2_render_frame
    tui_terminal_read_key 30 || true
    tui_v2_modal_message=''
}

tui_v2_restore_for_shell_hook() {
    local status=0

    tui_terminal_restore
    shell_integration_install || status=$?
    tui_terminal_enter || return 1
    if ((status == 0)); then
        tui_v2_set_status info 'Shell hook installed'
    else
        tui_v2_set_status error 'Shell hook installation failed'
    fi
    return "$status"
}

tui_v2_dispatch_key() {
    local key=$1
    local count=${#tui_v2_paths[@]}
    local status=0

    case "$key" in
        UP)
            ((count > 0)) && ((tui_v2_selected_index > 0)) && tui_v2_selected_index=$((tui_v2_selected_index - 1))
            ;;
        DOWN)
            ((count > 0)) && ((tui_v2_selected_index < count - 1)) && tui_v2_selected_index=$((tui_v2_selected_index + 1))
            ;;
        ENTER)
            ((count > 0)) || return 0
            tui_selected_path=${tui_v2_paths[$tui_v2_selected_index]}
            tui_v2_run_business 'set default' config_store_set_default "$tui_selected_path" || status=$?
            ;;
        CTRL_UP|MODE_GLOBAL)
            tui_v2_run_business 'global mode' env_profiles_set_mode global || status=$?
            ;;
        CTRL_DOWN|MODE_WHITELIST)
            tui_v2_run_business 'cn-direct mode' env_profiles_set_mode cn-direct || status=$?
            ;;
        MODE_OFF)
            tui_v2_run_business 'off mode' env_profiles_set_mode off || status=$?
            ;;
        CTRL_R)
            if tui_terminal_confirm; then
                tui_v2_run_business 'restart' tui_action_restart || status=$?
            else
                tui_v2_set_status info 'Restart cancelled'
            fi
            ;;
        CTRL_T)
            tui_v2_set_status info 'Speed probe is not enabled in this build'
            ;;
        IMPORT)
            tui_v2_modal_import || status=$?
            ;;
        LOG_SOURCE)
            tui_v2_set_status info 'Showing the latest NetUI log entries'
            tui_v2_collect_logs
            ;;
        REFRESH)
            tui_v2_set_status info 'Configuration list refreshed'
            tui_v2_model_refresh
            ;;
        HELP)
            tui_v2_modal_help
            ;;
        TEXT:v|TEXT:V)
            ((count > 0)) || return 0
            tui_selected_path=${tui_v2_paths[$tui_v2_selected_index]}
            tui_v2_run_business 'validate' tui_action_validate || status=$?
            ;;
        TEXT:u|TEXT:U)
            tui_v2_run_business 'start' tui_action_start || status=$?
            ;;
        TEXT:x|TEXT:X)
            if tui_terminal_confirm; then
                tui_v2_run_business 'stop' tui_action_stop || status=$?
            else
                tui_v2_set_status info 'Stop cancelled'
            fi
            ;;
        TEXT:n|TEXT:N)
            ((count > 0)) && tui_v2_modal_rename || status=$?
            ;;
        TEXT:a|TEXT:A)
            if ((count > 0)) && tui_terminal_confirm; then
                tui_v2_run_business 'archive' config_store_archive "${tui_v2_paths[$tui_v2_selected_index]}" || status=$?
                tui_v2_model_refresh
            else
                tui_v2_set_status info 'Archive cancelled'
            fi
            ;;
        TEXT:e|TEXT:E)
            ((count > 0)) && tui_v2_modal_detail
            ;;
        TEXT:h|TEXT:H)
            tui_v2_restore_for_shell_hook || status=$?
            ;;
        QUIT)
            tui_v2_running=0
            ;;
    esac
    return "$status"
}

tui_v2_run() {
    local key=''
    local status=0

    tui_v2_model_refresh
    tui_terminal_enter || return 1
    tui_v2_running=1
    trap 'tui_terminal_restore; exit 130' INT TERM HUP
    while ((tui_v2_running)); do
        tui_v2_render_frame
        if ! tui_terminal_read_key 0.2; then
            continue
        fi
        key=$tui_terminal_key
        tui_v2_dispatch_key "$key" || status=$?
        if ((status != 0)); then
            tui_v2_set_status error "Action failed (exit $status)"
            status=0
        fi
    done
    tui_terminal_restore
    trap - INT TERM HUP
}

tui_v2_render_dashboard() {
    tui_v2_model_refresh
    tui_v2_render_frame
}
