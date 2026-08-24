#!/bin/bash

config_store_safe_basename() {
    local basename=$1

    [[ -n "$basename" && "$basename" == *.json ]] || return 1
    [[ "$basename" != */* && "$basename" != *$'\n'* && "$basename" != *$'\r'* ]] || return 1
    if printf '%s' "$basename" | LC_ALL=C grep -q '[[:cntrl:]]'; then
        return 1
    fi

    return 0
}

config_store_config_root() {
    local root=''

    root=$(realpath -e -- "$NETUI_CONFIG_DIR" 2>/dev/null) || return 1
    [[ -d "$root" && ! -L "$NETUI_CONFIG_DIR" ]] || return 1
    printf '%s' "$root"
}

config_store_selection_path() {
    local selection=$1
    local basename=''
    local path=''

    if [[ "$selection" == "$NETUI_CONFIG_DIR/"* ]]; then
        [[ "${selection%/*}" == "$NETUI_CONFIG_DIR" ]] || return 1
        basename=${selection##*/}
    elif [[ "$selection" == /* ]]; then
        return 1
    else
        basename=$selection
    fi

    config_store_safe_basename "$basename" || return 1
    path="$NETUI_CONFIG_DIR/$basename"
    printf '%s' "$path"
}

config_store_validate_file() {
    local path=$1
    local root=''
    local resolved=''

    [[ -n "$path" && "$path" == "$NETUI_CONFIG_DIR/"* ]] || return 5
    [[ "${path%/*}" == "$NETUI_CONFIG_DIR" ]] || return 5
    [[ "$path" != *$'\n'* && "$path" != *$'\r'* ]] || return 5
    [[ ! -L "$path" && -f "$path" ]] || return 5

    root=$(config_store_config_root) || return 5
    resolved=$(realpath -e -- "$path" 2>/dev/null) || return 5
    [[ "$resolved" == "$root/"* && "${resolved%/*}" == "$root" ]] || return 5
    [[ "$resolved" == "$root/"* ]] || return 5

    chmod 600 -- "$path" || return 5
    return 0
}

config_store_discover() {
    local path=''

    while IFS= read -r -d '' path; do
        if config_store_validate_file "$path"; then
            printf '%s\0' "$path"
        fi
    done < <(
        LC_ALL=C find -P "$NETUI_CONFIG_DIR" -mindepth 1 -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null |
            LC_ALL=C sort -z
    )
}

config_store_discover_names() {
    local path=''

    while IFS= read -r -d '' path; do
        printf '%s\n' "${path##*/}"
    done < <(config_store_discover)
}

config_store_resolve_default() {
    local target=''
    local basename=''
    local path=''

    if [[ ! -e "$NETUI_DEFAULT_LINK" && ! -L "$NETUI_DEFAULT_LINK" ]]; then
        return 4
    fi
    [[ -L "$NETUI_DEFAULT_LINK" ]] || return 5

    target=$(readlink -- "$NETUI_DEFAULT_LINK" 2>/dev/null) || return 5
    [[ "$target" == configs/*.json ]] || return 5
    basename=${target#configs/}
    [[ "$target" == "configs/$basename" ]] || return 5
    config_store_safe_basename "$basename" || return 5

    path="$NETUI_CONFIG_DIR/$basename"
    config_store_validate_file "$path" || return 5
    printf '%s' "$path"
}

config_store_validate_external_config() {
    local path=$1
    local core_path=''

    [[ -f "$path" && ! -L "$path" ]] || return 5
    netui_require_command jq || return 3
    jq empty "$path" >/dev/null 2>&1 || return 5
    core_path=$(netui_resolve_core_path) || return 3
    "$core_path" check -c "$path" >/dev/null 2>&1 || return 5
    return 0
}

config_store_validate_config() {
    local path=$1

    config_store_validate_file "$path" || return 5
    config_store_validate_external_config "$path"
}

config_store_default_basename() {
    local target=''
    local basename=''

    [[ -L "$NETUI_DEFAULT_LINK" ]] || return 1
    target=$(readlink -- "$NETUI_DEFAULT_LINK" 2>/dev/null) || return 1
    [[ "$target" == configs/*.json ]] || return 1
    basename=${target#configs/}
    [[ "$target" == "configs/$basename" ]] || return 1
    config_store_safe_basename "$basename" || return 1
    printf '%s' "$basename"
}

config_store_atomic_default_link_unlocked() {
    local basename=$1
    local temporary_link=''
    local attempt=0

    config_store_safe_basename "$basename" || return 5
    if [[ -e "$NETUI_DEFAULT_LINK" && ! -L "$NETUI_DEFAULT_LINK" ]]; then
        netui_print_error 'default.json must be a symlink or absent'
        return 5
    fi

    while ((attempt < 10)); do
        temporary_link="$NETUI_CONFIG_HOME/.default.json.tmp.$$.$RANDOM"
        if [[ ! -e "$temporary_link" && ! -L "$temporary_link" ]]; then
            break
        fi
        attempt=$((attempt + 1))
    done
    ((attempt < 10)) || return 1

    ln -s -- "configs/$basename" "$temporary_link" || return 1
    if ! mv -Tf -- "$temporary_link" "$NETUI_DEFAULT_LINK"; then
        rm -f -- "$temporary_link"
        return 1
    fi
    return 0
}

_config_store_set_default_unlocked() {
    local selection=$1
    local path=''
    local basename=''
    local status=0

    path=$(config_store_selection_path "$selection") || {
        netui_print_error 'configuration must be a direct *.json file in configs'
        return 5
    }
    config_store_validate_config "$path" || {
        netui_print_error "configuration is invalid: ${path##*/}"
        return 5
    }

    basename=${path##*/}
    config_store_atomic_default_link_unlocked "$basename" || {
        netui_print_error 'cannot atomically update default.json'
        return 1
    }

    if ! config_store_resolve_default >/dev/null; then
        netui_print_error 'new default link failed validation'
        status=5
    fi

    return "$status"
}

config_store_set_default() {
    if (($# != 1)); then
        netui_print_error 'usage: config_store_set_default <basename-or-path>'
        return 2
    fi

    netui_with_lock _config_store_set_default_unlocked "$1"
}

_config_store_import_unlocked() {
    local source_path=$1
    local target_basename=$2
    local target_path=''
    local temporary_path=''

    [[ -f "$source_path" && ! -L "$source_path" ]] || {
        netui_print_error 'import source must be a regular file'
        return 5
    }
    config_store_safe_basename "$target_basename" || {
        netui_print_error 'import target must be a safe *.json basename'
        return 5
    }
    target_path="$NETUI_CONFIG_DIR/$target_basename"
    [[ ! -e "$target_path" && ! -L "$target_path" ]] || {
        netui_print_error "configuration already exists: $target_basename"
        return 1
    }

    temporary_path="$NETUI_CONFIG_DIR/.import.$$.$RANDOM.json"
    if ! (
        umask 077
        cp -- "$source_path" "$temporary_path"
        chmod 600 -- "$temporary_path"
    ); then
        rm -f -- "$temporary_path"
        return 1
    fi
    if ! config_store_validate_external_config "$temporary_path"; then
        rm -f -- "$temporary_path"
        netui_print_error 'imported configuration failed validation'
        return 5
    fi
    if ! mv -nT -- "$temporary_path" "$target_path" || [[ -e "$temporary_path" || -L "$temporary_path" ]]; then
        rm -f -- "$temporary_path"
        return 1
    fi
    chmod 600 -- "$target_path"
}

config_store_import() {
    if (($# != 2)); then
        netui_print_error 'usage: config_store_import <source-path> <target-basename>'
        return 2
    fi

    netui_with_lock _config_store_import_unlocked "$1" "$2"
}

config_store_update_runtime_basename_unlocked() {
    local new_basename=$1
    local temporary_state="$NETUI_RUNTIME_DIR/.instance.state.rename.tmp.$$.$RANDOM"
    local key=''
    local value=''

    [[ -f "$NETUI_RUNTIME_STATE" && ! -L "$NETUI_RUNTIME_STATE" ]] || return 1
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        if [[ "$key" == config_basename ]]; then
            printf 'config_basename=%s\n' "$new_basename"
        else
            printf '%s=%s\n' "$key" "$value"
        fi
    done < "$NETUI_RUNTIME_STATE" > "$temporary_state" || {
        rm -f -- "$temporary_state"
        return 1
    }
    chmod 600 -- "$temporary_state" || {
        rm -f -- "$temporary_state"
        return 1
    }
    mv -Tf -- "$temporary_state" "$NETUI_RUNTIME_STATE"
}

_config_store_rename_unlocked() {
    local selection=$1
    local new_basename=$2
    local path=''
    local target_path=''
    local old_basename=''
    local default_basename=''
    local runtime_was_running=0

    path=$(config_store_selection_path "$selection") || return 5
    config_store_validate_file "$path" || return 5
    config_store_safe_basename "$new_basename" || {
        netui_print_error 'new configuration name must be a safe *.json basename'
        return 5
    }
    target_path="$NETUI_CONFIG_DIR/$new_basename"
    [[ "$target_path" != "$path" ]] || return 0
    [[ ! -e "$target_path" && ! -L "$target_path" ]] || {
        netui_print_error "configuration already exists: $new_basename"
        return 1
    }

    old_basename=${path##*/}
    default_basename=$(config_store_default_basename 2>/dev/null) || default_basename=''
    if declare -F runtime_state_load >/dev/null 2>&1 && runtime_state_load &&
        declare -F runtime_session_is_healthy >/dev/null 2>&1 && runtime_session_is_healthy &&
        [[ "$runtime_config_path" == "$path" ]]; then
        runtime_was_running=1
    fi
    if ! mv -nT -- "$path" "$target_path" || [[ -e "$path" || -L "$path" ]]; then
        return 1
    fi

    if [[ "$default_basename" == "$old_basename" ]]; then
        if ! config_store_atomic_default_link_unlocked "$new_basename" ||
            ! config_store_resolve_default >/dev/null; then
            mv -Tf -- "$target_path" "$path" 2>/dev/null || true
            config_store_atomic_default_link_unlocked "$old_basename" >/dev/null 2>&1 || true
            return 1
        fi
    fi

    if ((runtime_was_running)) && ! config_store_update_runtime_basename_unlocked "$new_basename"; then
        mv -Tf -- "$target_path" "$path" 2>/dev/null || true
        if [[ "$default_basename" == "$old_basename" ]]; then
            config_store_atomic_default_link_unlocked "$old_basename" >/dev/null 2>&1 || true
        fi
        return 1
    fi
    chmod 600 -- "$target_path"
}

config_store_rename() {
    if (($# != 2)); then
        netui_print_error 'usage: config_store_rename <basename-or-path> <new-basename>'
        return 2
    fi

    netui_with_lock _config_store_rename_unlocked "$1" "$2"
}

_config_store_archive_unlocked() {
    local selection=$1
    local path=''
    local basename=''
    local default_basename=''
    local archive_dir=''
    local timestamp=''
    local attempt=0

    path=$(config_store_selection_path "$selection") || return 5
    config_store_validate_file "$path" || return 5
    basename=${path##*/}
    default_basename=$(config_store_default_basename 2>/dev/null) || default_basename=''
    if [[ "$default_basename" == "$basename" ]]; then
        netui_print_error 'cannot archive the current default configuration'
        return 5
    fi

    if declare -F runtime_state_load >/dev/null 2>&1 && runtime_state_load &&
        declare -F runtime_session_is_healthy >/dev/null 2>&1 && runtime_session_is_healthy &&
        [[ "$runtime_config_path" == "$path" || "$runtime_config_basename" == "$basename" ]]; then
        netui_print_error 'cannot archive the running configuration'
        return 6
    fi

    timestamp=$(date +%Y%m%d-%H%M%S)
    archive_dir="$NETUI_CONFIG_TRASH_DIR/$timestamp"
    while [[ -e "$archive_dir" || -L "$archive_dir" ]]; do
        attempt=$((attempt + 1))
        archive_dir="$NETUI_CONFIG_TRASH_DIR/$timestamp-$attempt"
    done
    mkdir -p -- "$archive_dir" || return 1
    chmod 700 -- "$archive_dir" || return 1
    if ! mv -nT -- "$path" "$archive_dir/$basename" || [[ -e "$path" || -L "$path" ]]; then
        return 1
    fi
    chmod 600 -- "$archive_dir/$basename"
    NETUI_LAST_ARCHIVE_PATH="$archive_dir/$basename"
    netui_print_info "archived $basename to $NETUI_LAST_ARCHIVE_PATH"
}

config_store_archive() {
    if (($# != 1)); then
        netui_print_error 'usage: config_store_archive <basename-or-path>'
        return 2
    fi

    netui_with_lock _config_store_archive_unlocked "$1"
}

_config_store_restore_unlocked() {
    local archive_path=$1
    local target_basename=$2
    local trash_root=''
    local archive_resolved=''
    local target_path=''

    [[ -f "$archive_path" && ! -L "$archive_path" ]] || return 5
    trash_root=$(realpath -e -- "$NETUI_CONFIG_TRASH_DIR" 2>/dev/null) || return 5
    archive_resolved=$(realpath -e -- "$archive_path" 2>/dev/null) || return 5
    netui_path_is_within "$trash_root" "$archive_resolved" || return 5
    config_store_safe_basename "$target_basename" || return 5
    target_path="$NETUI_CONFIG_DIR/$target_basename"
    [[ ! -e "$target_path" && ! -L "$target_path" ]] || {
        netui_print_error "configuration already exists: $target_basename"
        return 1
    }
    if ! mv -nT -- "$archive_path" "$target_path" || [[ -e "$archive_path" || -L "$archive_path" ]]; then
        return 1
    fi
    chmod 600 -- "$target_path"
    netui_print_info "restored $target_basename"
}

config_store_restore() {
    if (($# != 2)); then
        netui_print_error 'usage: config_store_restore <archive-path> <target-basename>'
        return 2
    fi

    netui_with_lock _config_store_restore_unlocked "$1" "$2"
}
