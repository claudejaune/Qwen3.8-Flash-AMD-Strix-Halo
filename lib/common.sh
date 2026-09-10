#!/usr/bin/env bash
# lib/common.sh — shared helpers sourced by setup.sh, run.sh, stop.sh and
# toolboxes/refresh.sh.

# Keys that may appear in config.env. load_config refuses anything else, so a
# hand-edited config can never overwrite shell-critical variables (PATH, HOME,
# ...) or trip over readonly ones (UID, ...).
CONFIG_ALLOWED_KEYS=(
    TOOLBOX_NAME MODEL_PATH
    BIND_HOST PORT API_KEY
    CTX_SIZE PARALLEL_SLOTS FLASH_ATTN GPU_LAYERS LOAD_MODE
    CACHE_TYPE_K CACHE_TYPE_V
    PLE_MODE PLE_FLAGS
    VISION_ENABLED MMPROJ_PATH
    MTP_ENABLED MTP_DRAFT_N MTP_DRAFT_MODEL
)

config_key_allowed() {
    local key
    for key in "${CONFIG_ALLOWED_KEYS[@]}"; do
        if [[ "$key" == "$1" ]]; then
            return 0
        fi
    done
    return 1
}

# True if a toolbox container with the given name exists.
#
# Toolbox marks its containers with the podman label
# com.github.containers.toolbox=true, so this query is exact (no substring
# matches) and independent of `toolbox list`'s column layout, which varies
# across toolbox versions. No grep in a pipe → no pipefail/SIGPIPE edge cases.
toolbox_has() {
    local names
    names="$(podman ps -a --filter label=com.github.containers.toolbox=true \
        --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')" || return 1
    [[ " $names " == *" $1 "* ]]
}

# Load KEY=value pairs from a config file into the environment.
#
# The file is treated as pure DATA: values are never evaluated, quoted or
# expanded — a hand-edited config cannot inject commands. Full-line comments
# (#) and blank lines are ignored; CRLF line endings are tolerated. The value
# is everything after the FIRST '=', so values may contain '=' and spaces.
#
# Only the keys in CONFIG_ALLOWED_KEYS are accepted; anything else is an error.
#
# Strict: returns non-zero (and the caller should abort) on malformed lines.
#
# Usage: load_config <file>
load_config() {
    local file="$1" line key value lineno=0
    if [[ ! -r "$file" ]]; then
        echo "Error: config file not found or unreadable: $file" >&2
        return 1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))
        line="${line%$'\r'}"                              # tolerate CRLF
        line="${line#"${line%%[![:space:]]*}"}"           # trim leading ws
        line="${line%"${line##*[![:space:]]}"}"           # trim trailing ws
        if [[ -z "$line" || "$line" == \#* ]]; then
            continue
        fi
        if [[ "$line" != *=* ]]; then
            echo "Error: $file:$lineno — expected KEY=value, got: $line" >&2
            return 1
        fi
        key="${line%%=*}"
        value="${line#*=}"
        if [[ ! "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
            echo "Error: $file:$lineno — invalid variable name: $key" >&2
            return 1
        fi
        if ! config_key_allowed "$key"; then
            echo "Error: $file:$lineno — unknown config key: $key" >&2
            echo "Allowed keys are listed in CONFIG_ALLOWED_KEYS in lib/common.sh." >&2
            return 1
        fi
        printf -v "$key" '%s' "$value"
    done < "$file"
    return 0
}
