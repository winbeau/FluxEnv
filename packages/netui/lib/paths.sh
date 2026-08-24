#!/bin/bash

netui_paths_init() {
    local home_dir=${HOME:-}
    local xdg_config_home=${XDG_CONFIG_HOME:-}
    local xdg_data_home=${XDG_DATA_HOME:-}
    local xdg_state_home=${XDG_STATE_HOME:-}
    local configured_config_dir=${NETUI_CONFIG_DIR:-}
    local configured_default_link=${NETUI_DEFAULT_LINK:-}
    local path=''

    [[ -n "$home_dir" ]] || {
        netui_print_error 'HOME is not set'
        return 1
    }

    [[ -n "$xdg_config_home" ]] || xdg_config_home="$home_dir/.config"
    [[ -n "$xdg_data_home" ]] || xdg_data_home="$home_dir/.local/share"
    [[ -n "$xdg_state_home" ]] || xdg_state_home="$home_dir/.local/state"

    for path in "$xdg_config_home" "$xdg_data_home" "$xdg_state_home" "${XDG_BIN_HOME:-$home_dir/.local/bin}"; do
        if [[ "$path" != /* ]]; then
            netui_print_error "XDG path must be absolute: $path"
            return 1
        fi
    done

    NETUI_BIN_DIR=${NETUI_BIN_DIR:-${XDG_BIN_HOME:-$home_dir/.local/bin}}
    NETUI_CONFIG_HOME=${NETUI_CONFIG_HOME:-$xdg_config_home/netui}
    NETUI_DATA_HOME=${NETUI_DATA_HOME:-$xdg_data_home/netui}
    NETUI_STATE_HOME=${NETUI_STATE_HOME:-$xdg_state_home/netui}

    NETUI_CONFIG_DIR=${NETUI_CONFIG_DIR:-$NETUI_CONFIG_HOME/configs}
    NETUI_DEFAULT_LINK=${NETUI_DEFAULT_LINK:-$NETUI_CONFIG_HOME/default.json}
    NETUI_LOG_DIR=${NETUI_LOG_DIR:-$NETUI_STATE_HOME/logs}
    NETUI_RUNTIME_DIR=${NETUI_RUNTIME_DIR:-$NETUI_STATE_HOME/runtime}
    NETUI_LOCK_FILE=${NETUI_LOCK_FILE:-$NETUI_RUNTIME_DIR/lifecycle.lock}
    NETUI_RUNTIME_STATE=${NETUI_RUNTIME_STATE:-$NETUI_RUNTIME_DIR/instance.state}
    NETUI_PROXY_ENDPOINT=${NETUI_PROXY_ENDPOINT:-$NETUI_RUNTIME_DIR/proxy-endpoint}
    NETUI_ENV_GENERATION=${NETUI_ENV_GENERATION:-$NETUI_RUNTIME_DIR/env-generation}
    NETUI_ENV_MODE_FILE=${NETUI_ENV_MODE_FILE:-$NETUI_CONFIG_HOME/env-mode}
    NETUI_LOG_FILE=${NETUI_LOG_FILE:-$NETUI_LOG_DIR/sing-box.log}
    NETUI_NETUI_LOG_FILE=${NETUI_NETUI_LOG_FILE:-$NETUI_LOG_DIR/netui.log}
    NETUI_BACKUP_DIR=${NETUI_BACKUP_DIR:-$NETUI_STATE_HOME/backups}
    NETUI_CONFIG_TRASH_DIR=${NETUI_CONFIG_TRASH_DIR:-$NETUI_BACKUP_DIR/config-trash}
    NETUI_TMUX_SESSION_NAME=${NETUI_TMUX_SESSION_NAME:-netui}
    NETUI_LOCK_TIMEOUT=${NETUI_LOCK_TIMEOUT:-10}

    [[ -z "$configured_config_dir" || "$configured_config_dir" == "$NETUI_CONFIG_HOME/configs" ]] || {
        netui_print_error 'NETUI_CONFIG_DIR must remain below NETUI_CONFIG_HOME'
        return 1
    }
    [[ -z "$configured_default_link" || "$configured_default_link" == "$NETUI_CONFIG_HOME/default.json" ]] || {
        netui_print_error 'NETUI_DEFAULT_LINK must remain in NETUI_CONFIG_HOME'
        return 1
    }

    for path in "$NETUI_BIN_DIR" "$NETUI_CONFIG_HOME" "$NETUI_DATA_HOME" "$NETUI_STATE_HOME" "$NETUI_CONFIG_DIR" "$NETUI_DEFAULT_LINK" "$NETUI_LOG_DIR" "$NETUI_RUNTIME_DIR" "$NETUI_LOCK_FILE" "$NETUI_RUNTIME_STATE" "$NETUI_PROXY_ENDPOINT" "$NETUI_ENV_GENERATION" "$NETUI_ENV_MODE_FILE" "$NETUI_LOG_FILE" "$NETUI_NETUI_LOG_FILE" "$NETUI_BACKUP_DIR" "$NETUI_CONFIG_TRASH_DIR"; do
        if [[ "$path" != /* ]]; then
            netui_print_error "NetUI path must be absolute: $path"
            return 1
        fi
    done
}

netui_ensure_private_dir() {
    local path=$1

    [[ -n "$path" ]] || return 1
    [[ ! -L "$path" ]] || {
        netui_print_error "refusing symlink directory: $path"
        return 1
    }
    mkdir -p -- "$path" || return 1
    chmod 700 -- "$path" || return 1
}

netui_ensure_private_file() {
    local path=$1

    [[ -n "$path" && ! -L "$path" ]] || {
        netui_print_error "refusing symlink runtime or log state: $path"
        return 1
    }
    if [[ -e "$path" ]]; then
        [[ -f "$path" ]] || {
            netui_print_error "refusing non-regular runtime or log state: $path"
            return 1
        }
    else
        touch -- "$path" || return 1
    fi
    chmod 600 -- "$path" || return 1
}

netui_ensure_optional_private_file() {
    local path=$1

    if [[ -e "$path" || -L "$path" ]]; then
        netui_ensure_private_file "$path"
    fi
}

netui_init_dirs() {
    netui_paths_init || return 1

    umask 077
    netui_ensure_private_dir "$NETUI_CONFIG_HOME" || return 1
    netui_ensure_private_dir "$NETUI_CONFIG_DIR" || return 1
    netui_ensure_private_dir "$NETUI_DATA_HOME" || return 1
    netui_ensure_private_dir "$NETUI_STATE_HOME" || return 1
    netui_ensure_private_dir "$NETUI_LOG_DIR" || return 1
    netui_ensure_private_dir "$NETUI_RUNTIME_DIR" || return 1
    netui_ensure_private_dir "$NETUI_BACKUP_DIR" || return 1
    netui_ensure_private_dir "$NETUI_CONFIG_TRASH_DIR" || return 1

    netui_ensure_private_file "$NETUI_LOG_FILE" || return 1
    netui_ensure_private_file "$NETUI_NETUI_LOG_FILE" || return 1
    netui_ensure_private_file "$NETUI_LOCK_FILE" || return 1
    netui_ensure_optional_private_file "$NETUI_RUNTIME_STATE" || return 1
    netui_ensure_optional_private_file "$NETUI_PROXY_ENDPOINT" || return 1
    netui_ensure_optional_private_file "$NETUI_ENV_GENERATION" || return 1
    netui_ensure_optional_private_file "$NETUI_ENV_MODE_FILE" || return 1
}
