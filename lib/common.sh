#!/usr/bin/env bash
# lib/common.sh — shared helpers sourced by setup.sh, run.sh, stop.sh,
# refresh.sh and toolboxes/refresh-toolboxes.sh.

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CATALOG_DIR="$_LIB_DIR/catalog"

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

# Keys that may appear in lib/catalog/*.conf (data, never sourced).
CATALOG_ALLOWED_KEYS=(
    ID LABEL ORDER DEFAULT
    TOOLBOX_NAME TOOLBOX_NOTE
    HF_REPO MODEL_SUBDIR MODEL_FILE MMPROJ_FILE MTP_FILE
    DOWNLOAD_FILES
    SSD_FLAG SSD_EXTRA_FLAGS
    VISION_AVAILABLE SIZE_GIB SIZE_NOTE PRO CON
)

config_key_allowed() {
    _key_in_list "$1" CONFIG_ALLOWED_KEYS
}

catalog_key_allowed() {
    _key_in_list "$1" CATALOG_ALLOWED_KEYS
}

_key_in_list() {
    local needle="$1"
    local -n _keys="$2"
    local key
    for key in "${_keys[@]}"; do
        if [[ "$key" == "$needle" ]]; then
            return 0
        fi
    done
    return 1
}

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
err()   { echo -e "\033[1;31m[ERR ]\033[0m  $*" >&2; exit 1; }

have() { command -v "$1" &>/dev/null; }

# Regular user only — sudo would write models to /root/models and root-own config.env.
require_not_root() {
    if [[ "$(id -u)" -eq 0 ]]; then
        err "Don't run this as root (sudo). Model files would land in /root/models and config.env would get the wrong paths. Run as your normal user."
    fi
}

# True if path exists, is a regular file, and is not empty (0-byte leftovers
# from an interrupted download must not count as complete).
file_usable() {
    [[ -f "$1" && -s "$1" ]]
}

# All prompts tolerate EOF (Ctrl-D): read fails, the default is used instead
# of the script dying with a cryptic set -e failure.
ask() {
    local varname="$1" prompt="$2" default="$3" val
    read -rp "$prompt [$default]: " val || val=""
    val="${val:-$default}"
    printf -v "$varname" '%s' "$val"
}

ask_number() {
    local varname="$1" prompt="$2" default="$3" val
    while true; do
        read -rp "$prompt [$default]: " val || val=""
        val="${val:-$default}"
        if [[ "$val" =~ ^[0-9]+$ ]]; then break; fi
        echo "  Please enter a number." >&2
    done
    printf -v "$varname" '%s' "$val"
}

# ask_yes_no <prompt> [y|n] — returns 0 on yes
ask_yes_no() {
    local prompt="$1" default="${2:-y}" reply
    if [[ "$default" == "y" ]]; then
        read -rp "$prompt [Y/n]: " reply || reply=""
        [[ ! "$reply" =~ ^[Nn] ]]
    else
        read -rp "$prompt [y/N]: " reply || reply=""
        [[ "$reply" =~ ^[Yy] ]]
    fi
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

container_running() {
    local running
    running="$(podman ps --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')" || return 1
    [[ " $running " == *" $1 "* ]]
}

# Load KEY=value pairs from a data file into the environment.
#
# The file is treated as pure DATA: values are never evaluated, quoted or
# expanded — a hand-edited file cannot inject commands. Full-line comments
# (#) and blank lines are ignored; CRLF line endings are tolerated. The value
# is everything after the FIRST '=', so values may contain '=' and spaces.
#
# prefix: prepended to each key ("" for config.env, "CATALOG_" for catalogs).
# allowed_array: name of an array of permitted keys (unprefixed).
#
# Strict: returns non-zero (and the caller should abort) on malformed lines.
_load_kv_file() {
    local file="$1" prefix="$2" allowed_array="$3"
    local line key value lineno=0
    if [[ ! -r "$file" ]]; then
        echo "Error: config file not found or unreadable: $file" >&2
        return 1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno + 1))
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
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
        if ! _key_in_list "$key" "$allowed_array"; then
            echo "Error: $file:$lineno — unknown config key: $key" >&2
            echo "Allowed keys are listed in $allowed_array in lib/common.sh." >&2
            return 1
        fi
        printf -v "${prefix}${key}" '%s' "$value"
    done < "$file"
    return 0
}

# Usage: load_config <file>
load_config() {
    _load_kv_file "$1" "" CONFIG_ALLOWED_KEYS
}

# Usage: load_catalog <file>
# Sets CATALOG_* from the file after clearing any previous catalog values.
load_catalog() {
    local key
    for key in "${CATALOG_ALLOWED_KEYS[@]}"; do
        unset "CATALOG_${key}" || true
    done
    _load_kv_file "$1" "CATALOG_" CATALOG_ALLOWED_KEYS
}

# Print catalog .conf paths, one per line, sorted by ORDER.
catalog_sorted_files() {
    local f order
    for f in "$CATALOG_DIR"/*.conf; do
        [[ -f "$f" ]] || continue
        order="$(grep -E '^ORDER=' "$f" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
        printf '%s\t%s\n' "${order:-99}" "$f"
    done | sort -n | cut -f2-
}

# Load the catalog whose TOOLBOX_NAME matches $1. Returns 1 if none match.
catalog_load_by_toolbox() {
    local tb="$1" f
    local files
    mapfile -t files < <(catalog_sorted_files)
    for f in "${files[@]}"; do
        load_catalog "$f" || return 1
        if [[ "${CATALOG_TOOLBOX_NAME:-}" == "$tb" ]]; then
            return 0
        fi
    done
    return 1
}

# Set MODEL_DIR / MODEL_PATH / … from the currently loaded CATALOG_* values.
# Requires MODELS_DIR (typically $HOME/models).
catalog_apply_paths() {
    MODEL_DIR="$MODELS_DIR/$CATALOG_MODEL_SUBDIR"
    MODEL_PATH="$MODEL_DIR/$CATALOG_MODEL_FILE"
    MMPROJ_PATH="$MODEL_DIR/$CATALOG_MMPROJ_FILE"
    MTP_DRAFT_MODEL="$MODEL_DIR/$CATALOG_MTP_FILE"
    TOOLBOX_NAME="$CATALOG_TOOLBOX_NAME"
    DOWNLOAD_REPO="$CATALOG_HF_REPO"
    DOWNLOAD_FILES="$CATALOG_DOWNLOAD_FILES"
    MMPROJ_DOWNLOAD_FILE="$CATALOG_MMPROJ_FILE"
    SSD_FLAG="$CATALOG_SSD_FLAG"
    SSD_EXTRA_FLAGS="${CATALOG_SSD_EXTRA_FLAGS:-}"
    VISION_AVAILABLE="${CATALOG_VISION_AVAILABLE:-false}"
}

# Print every shard path for a (possibly split) GGUF, one per line.
model_shard_paths() {
    local model_path="$1"
    local first total i idx shard
    if [[ "$model_path" =~ -([0-9]{5})-of-([0-9]{5})\.gguf$ ]]; then
        first="${BASH_REMATCH[1]}"
        total="${BASH_REMATCH[2]}"
        for ((i = 1; i <= total; i++)); do
            idx="$(printf '%05d' "$i")"
            shard="${model_path/-$first-of-/-$idx-of-}"
            printf '%s\n' "$shard"
        done
    else
        printf '%s\n' "$model_path"
    fi
}

# GiB free on the filesystem that contains $1 (walks up if the path does not
# exist yet). Prints an integer. Returns 1 if df fails.
disk_avail_gib() {
    local path="$1"
    local avail
    while [[ -n "$path" && "$path" != "/" && ! -e "$path" ]]; do
        path="$(dirname "$path")"
    done
    [[ -e "$path" ]] || path="/"
    avail="$(df -B1G --output=avail "$path" 2>/dev/null | awk 'NR==2 {print $1}')"
    avail="${avail%G}"
    avail="${avail%g}"
    if [[ ! "$avail" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    printf '%s\n' "$avail"
}

# Bytes used by the given paths that exist. Prints an integer.
disk_files_bytes() {
    local total=0 sz f
    for f in "$@"; do
        if [[ -f "$f" ]]; then
            sz="$(stat -c '%s' "$f" 2>/dev/null || echo 0)"
            total=$((total + sz))
        fi
    done
    printf '%s\n' "$total"
}

ensure_hf_cli() {
    if have hf || have uvx; then
        HF_OK=true
        return 0
    fi
    warn "Neither 'hf' nor 'uvx' found. The HF CLI is required to download models."
    echo ""
    echo "  Install it with:"
    echo ""
    echo "    curl -LsSf https://hf.co/cli/install.sh | bash"
    echo ""
    if ask_yes_no "  Install now?" y; then
        if curl -LsSf https://hf.co/cli/install.sh | bash; then
            export PATH="$HOME/.local/bin:$PATH"
            hash -r 2>/dev/null || true
            if have hf; then
                ok "HF CLI installed."
                HF_OK=true
                return 0
            fi
            warn "'hf' installed but not on this shell's PATH yet."
            echo "  Restart your shell and re-run this script to download models."
        else
            warn "HF CLI installation failed."
        fi
    else
        echo "  Skipped. Install it later with: curl -LsSf https://hf.co/cli/install.sh | bash"
    fi
    HF_OK=false
    return 1
}

hf_download() {
    local repo="$1" file="$2" dir="$3"
    if [[ "${HF_OK:-false}" != "true" ]]; then
        warn "Skipped: $file (HF CLI unavailable)"
        return 1
    fi
    if have hf; then
        hf download "$repo" "$file" --local-dir "$dir"
    else
        uvx --from huggingface-hub hf download "$repo" "$file" --local-dir "$dir"
    fi
}

# Usage: download_if_missing <repo> <relative-file> <local-dir> [ask|always]
# ask (default): prompt before downloading a missing file.
# always: download without prompting (caller already confirmed).
download_if_missing() {
    local repo="$1" file="$2" dir="$3" mode="${4:-ask}"
    local fpath="$dir/$file"
    if file_usable "$fpath"; then
        ok "Already downloaded: $file ($(du -sh "$fpath" | cut -f1))"
        return 0
    fi
    if [[ -f "$fpath" && ! -s "$fpath" ]]; then
        warn "Empty file (interrupted download?), re-downloading: $file"
        rm -f "$fpath"
    fi
    warn "Missing: $file"
    if [[ "$mode" == "ask" ]]; then
        if ! ask_yes_no "  Download now?" y; then
            return 1
        fi
    fi
    mkdir -p "$(dirname "$fpath")"
    if hf_download "$repo" "$file" "$dir"; then
        ok "Downloaded: $file"
        return 0
    fi
    warn "Download failed: $file"
    return 1
}
