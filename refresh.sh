#!/usr/bin/env bash
# refresh.sh — After git pull: offer toolbox rebuilds and download a new
# quant if the catalog in this repo changed.
#
# Cancel-safe: config.env is only rewritten after a new-model download
# finishes. Ctrl-C before that leaves config.env and model files as they were
# (unless you confirmed a low-disk delete-first).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"
MODELS_DIR="$HOME/models"
KEEP_BOTH_MIN_GIB=120

# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

require_not_root

CONFIG_UPDATED=false
DELETED_OLD=false

on_interrupt() {
    echo ""
    if [[ "$CONFIG_UPDATED" == "true" ]]; then
        warn "Interrupted after config.env was updated. A backup is in backups/."
    elif [[ "$DELETED_OLD" == "true" ]]; then
        warn "Interrupted. The old model files were deleted (you confirmed that)."
        warn "config.env was NOT changed — it still points at the old (now missing) files."
        warn "Re-run ./refresh.sh to finish the download, or ./setup.sh to choose again."
    else
        warn "Interrupted. config.env was not changed."
        warn "If a download was in progress, a partial file may be in $HOME/models — re-run ./refresh.sh to resume."
    fi
    exit 130
}
trap on_interrupt INT

if [[ ! -f "$CONFIG_FILE" ]]; then
    err "config.env not found. Run ./setup.sh first (one-time), then ./refresh.sh after git pull."
fi

load_config "$CONFIG_FILE"

echo ""
echo "============================================"
echo " Qwen3.8-Flash-Next — refresh"
echo "============================================"
echo ""
echo "  Run this after:  git pull"
echo "  This script can update your toolbox container and, if this repo"
echo "  changed the recommended model files, download the new ones."
echo ""
echo "  You can answer No to any step."
echo "  Ctrl-C leaves config.env alone unless a download already finished."
echo "  Exception: if you already confirmed deleting the old model to free"
echo "  disk, those files stay gone. A toolbox rebuild cannot be undone."
echo ""

llama_server_running() {
    if [[ -n "${TOOLBOX_NAME:-}" ]] && have toolbox && have podman \
       && toolbox_has "$TOOLBOX_NAME" && container_running "$TOOLBOX_NAME"; then
        if toolbox run -c "$TOOLBOX_NAME" -- pgrep -f llama-server >/dev/null 2>&1; then
            return 0
        fi
    fi
    if pgrep -x llama-server >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

stop_server() {
    info "Stopping the running server (it has model files open)..."
    bash "$SCRIPT_DIR/stop.sh"
}

rebuild_toolbox() {
    local name="$1"
    if [[ "$name" == "${TOOLBOX_NAME:-}" ]] && llama_server_running; then
        warn "The server is running inside this toolbox. Rebuilding replaces the container and will stop it."
        if ! ask_yes_no "  Stop the server and rebuild?" n; then
            warn "Skipped toolbox rebuild."
            return 0
        fi
        stop_server || err "Could not stop the server; toolbox not rebuilt. config.env was not changed."
    fi
    info "Building toolbox '$name' (this can take ~20 minutes)..."
    if bash "$SCRIPT_DIR/toolboxes/refresh-toolboxes.sh" "$name"; then
        ok "Toolbox '$name' rebuilt."
    else
        warn "Toolbox build failed for '$name'. Your existing container (if any) was left as-is unless the build finished and replace started."
        return 1
    fi
}

offer_toolbox() {
    local name="$1" note="$2"
    if ! have toolbox || ! have podman; then
        warn "toolbox/podman not installed — skipping toolbox updates."
        return 0
    fi
    if toolbox_has "$name"; then
        echo "  $note"
        if ask_yes_no "  Rebuild/update '$name'?" n; then
            rebuild_toolbox "$name" || true
        else
            echo "  Skipped."
        fi
    elif [[ "$name" == "${TOOLBOX_NAME:-}" ]]; then
        warn "Toolbox '$name' is not installed (run.sh needs it)."
        if ask_yes_no "  Build it now? (~20 min)" n; then
            rebuild_toolbox "$name" || true
        else
            echo "  Build later with: ./toolboxes/refresh-toolboxes.sh $name"
        fi
    fi
}

# ── Current combo ────────────────────────────────────────────────────────────
info "=== Your current setup ==="
HAS_CATALOG=false
if catalog_load_by_toolbox "${TOOLBOX_NAME:-}"; then
    HAS_CATALOG=true
    echo "  Quant:    $CATALOG_LABEL"
else
    echo "  Quant:    (no catalog entry for toolbox '${TOOLBOX_NAME:-unset}')"
fi
echo "  Toolbox:  ${TOOLBOX_NAME:-unset}"
echo "  Model:    ${MODEL_PATH:-unset}"
echo "  Vision:   ${VISION_ENABLED:-false}"
echo "  MTP:      ${MTP_ENABLED:-false} (K=${MTP_DRAFT_N:-0})"
echo ""

# ── Toolboxes ────────────────────────────────────────────────────────────────
info "=== Toolboxes ==="
echo "  Rebuilding compiles a llama.cpp fork inside a container (~20 min,"
echo "  needs internet). Say No if you just want to check the model files."
echo ""
offer_toolbox "${TOOLBOX_NAME:-}" "This is the toolbox your config.env uses."

if [[ "$HAS_CATALOG" == "true" ]]; then
    USER_TOOLBOX="$TOOLBOX_NAME"
    mapfile -t _cat_files < <(catalog_sorted_files)
    for _cf in "${_cat_files[@]}"; do
        load_catalog "$_cf" || continue
        if [[ "$CATALOG_TOOLBOX_NAME" != "$USER_TOOLBOX" ]] && toolbox_has "$CATALOG_TOOLBOX_NAME"; then
            echo ""
            offer_toolbox "$CATALOG_TOOLBOX_NAME" "Also installed (not currently selected in config.env)."
        fi
    done
    catalog_load_by_toolbox "$USER_TOOLBOX" || err "Failed to reload catalog for $USER_TOOLBOX"
fi
echo ""

# ── Models ───────────────────────────────────────────────────────────────────
info "=== Model files ==="

if [[ "$HAS_CATALOG" != "true" ]]; then
    warn "This repo has no catalog for toolbox '${TOOLBOX_NAME:-unset}'."
    echo "  Skipping model update. Re-run ./setup.sh if you want to switch models."
    echo ""
    echo "============================================"
    echo " Refresh finished."
    echo "============================================"
    exit 0
fi

EXPECTED_MODEL="$MODELS_DIR/$CATALOG_MODEL_SUBDIR/$CATALOG_MODEL_FILE"
EXPECTED_MTP="$MODELS_DIR/$CATALOG_MODEL_SUBDIR/$CATALOG_MTP_FILE"
EXPECTED_MMPROJ="$MODELS_DIR/$CATALOG_MODEL_SUBDIR/$CATALOG_MMPROJ_FILE"
SIZE_GIB="${CATALOG_SIZE_GIB:-95}"

needs_update=false
if [[ "${MODEL_PATH:-}" != "$EXPECTED_MODEL" ]]; then
    needs_update=true
fi
if [[ "${MTP_ENABLED:-false}" == "true" && "${MTP_DRAFT_MODEL:-}" != "$EXPECTED_MTP" ]]; then
    needs_update=true
fi
if [[ "${VISION_ENABLED:-false}" == "true" && "${MMPROJ_PATH:-}" != "$EXPECTED_MMPROJ" ]]; then
    needs_update=true
fi

if [[ "$needs_update" != "true" ]]; then
    ok "Recommended files for $CATALOG_LABEL have not changed. No download needed."
    echo ""
    echo "============================================"
    echo " Refresh finished."
    echo "============================================"
    echo ""
    echo "  Start / restart:  ./run.sh"
    exit 0
fi

echo "  This repo now recommends different model files for your toolbox."
echo ""
echo "  Current model file:"
echo "    ${MODEL_PATH:-<unset>}"
echo "  Recommended now ($CATALOG_LABEL):"
echo "    $EXPECTED_MODEL"
echo ""

if ! ask_yes_no "  Download the new model files? (up to ~${SIZE_GIB} GB if the main files changed)" y; then
    echo "  Skipped. config.env was not changed."
    echo ""
    echo "============================================"
    echo " Refresh finished."
    echo "============================================"
    exit 0
fi

collect_old_files() {
    local f
    if [[ -n "${MODEL_PATH:-}" ]]; then
        while IFS= read -r f; do
            file_usable "$f" && printf '%s\n' "$f"
        done < <(model_shard_paths "$MODEL_PATH")
    fi
    if [[ -n "${MTP_DRAFT_MODEL:-}" ]] && file_usable "$MTP_DRAFT_MODEL"; then
        printf '%s\n' "$MTP_DRAFT_MODEL"
    fi
    if [[ -n "${MMPROJ_PATH:-}" ]] && file_usable "$MMPROJ_PATH"; then
        printf '%s\n' "$MMPROJ_PATH"
    fi
    return 0
}

collect_new_files() {
    local f
    # shellcheck disable=SC2086
    for f in $CATALOG_DOWNLOAD_FILES; do
        printf '%s\n' "$MODELS_DIR/$CATALOG_MODEL_SUBDIR/$f"
    done
    if [[ "${VISION_ENABLED:-false}" == "true" ]]; then
        printf '%s\n' "$EXPECTED_MMPROJ"
    fi
    return 0
}

file_is_new() {
    local needle="$1" n
    for n in "${NEW_FILES[@]+"${NEW_FILES[@]}"}"; do
        [[ "$n" == "$needle" ]] && return 0
    done
    return 1
}

mapfile -t OLD_FILES < <(collect_old_files)
mapfile -t NEW_FILES < <(collect_new_files)
OBSOLETE=()
for f in "${OLD_FILES[@]+"${OLD_FILES[@]}"}"; do
    if ! file_is_new "$f"; then
        OBSOLETE+=("$f")
    fi
done

old_bytes="$(disk_files_bytes "${OLD_FILES[@]+"${OLD_FILES[@]}"}")"
old_gib=$((old_bytes / 1073741824))

MISSING_NEW=()
MAIN_MISSING=false
for f in "${NEW_FILES[@]+"${NEW_FILES[@]}"}"; do
    if ! file_usable "$f"; then
        MISSING_NEW+=("$f")
        if [[ "$f" != "$EXPECTED_MTP" && "$f" != "$EXPECTED_MMPROJ" ]]; then
            MAIN_MISSING=true
        fi
    fi
done

if [[ "$MAIN_MISSING" == "true" ]]; then
    DOWNLOAD_NEED_GIB=$((SIZE_GIB + 20))
    KEEP_BOTH_NEED_GIB=$KEEP_BOTH_MIN_GIB
elif ((${#MISSING_NEW[@]} > 0)); then
    DOWNLOAD_NEED_GIB=15
    KEEP_BOTH_NEED_GIB=15
else
    DOWNLOAD_NEED_GIB=0
    KEEP_BOTH_NEED_GIB=0
fi

space_path="$MODELS_DIR"
if [[ ! -e "$space_path" && -n "${MODEL_PATH:-}" ]]; then
    space_path="$(dirname "$MODEL_PATH")"
fi
avail="$(disk_avail_gib "$space_path")" || err "Could not check free disk space for $space_path"

echo ""
if (( DOWNLOAD_NEED_GIB == 0 )); then
    ok "The new model files are already on disk. config.env will be pointed at them."
elif [[ "$MAIN_MISSING" == "true" ]]; then
    echo "  Free space on the disk that holds $MODELS_DIR: ${avail} GiB"
    echo "  The main model files (~${SIZE_GIB} GB) are not on disk yet."
    echo "  Need ${KEEP_BOTH_NEED_GIB} GiB free to download next to the old files."
else
    echo "  Free space on the disk that holds $MODELS_DIR: ${avail} GiB"
    echo "  Only extra files (MTP/vision) are missing, not the full ~${SIZE_GIB} GB model."
    echo "  Need about ${DOWNLOAD_NEED_GIB} GiB free."
fi
echo ""

delete_files() {
    local f
    for f in "$@"; do
        if [[ -f "$f" ]]; then
            info "Deleting $(basename "$f") ($(du -sh "$f" | cut -f1))"
            rm -f "$f"
        fi
    done
}

download_new_quant() {
    local failed=0 f
    local dest="$MODELS_DIR/$CATALOG_MODEL_SUBDIR"
    mkdir -p "$dest"
    if [[ "${VISION_ENABLED:-false}" == "true" && -n "$CATALOG_MMPROJ_FILE" ]]; then
        download_if_missing "$CATALOG_HF_REPO" "$CATALOG_MMPROJ_FILE" "$dest" always || failed=1
    fi
    # shellcheck disable=SC2086
    for f in $CATALOG_DOWNLOAD_FILES; do
        download_if_missing "$CATALOG_HF_REPO" "$f" "$dest" always || failed=1
    done
    return "$failed"
}

backup_config() {
    mkdir -p "$SCRIPT_DIR/backups"
    local ts dest
    ts="$(date +%Y-%m-%d-%H-%M)"
    dest="$SCRIPT_DIR/backups/config.env-$ts"
    if [[ -e "$dest" ]]; then
        dest="$SCRIPT_DIR/backups/config.env-$ts-$(date +%S)"
    fi
    cp -a "$CONFIG_FILE" "$dest"
    printf '%s\n' "$dest"
}

write_config_paths() {
    local tmp new_model new_mtp new_mmproj
    local seen_model=0 seen_mmproj=0 seen_mtp=0
    new_model="$EXPECTED_MODEL"
    new_mtp="$EXPECTED_MTP"
    if [[ "${VISION_ENABLED:-false}" == "true" ]]; then
        new_mmproj="$EXPECTED_MMPROJ"
    else
        new_mmproj="${MMPROJ_PATH:-}"
    fi
    tmp="$(mktemp "$SCRIPT_DIR/.config.env.tmp.XXXXXX")"
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            MODEL_PATH=*)      seen_model=1; printf 'MODEL_PATH=%s\n' "$new_model" ;;
            MMPROJ_PATH=*)     seen_mmproj=1; printf 'MMPROJ_PATH=%s\n' "$new_mmproj" ;;
            MTP_DRAFT_MODEL=*) seen_mtp=1; printf 'MTP_DRAFT_MODEL=%s\n' "$new_mtp" ;;
            *)                 printf '%s\n' "$line" ;;
        esac
    done < "$CONFIG_FILE" > "$tmp"
    (( seen_model ))  || printf 'MODEL_PATH=%s\n' "$new_model" >> "$tmp"
    (( seen_mmproj )) || printf 'MMPROJ_PATH=%s\n' "$new_mmproj" >> "$tmp"
    (( seen_mtp ))    || printf 'MTP_DRAFT_MODEL=%s\n' "$new_mtp" >> "$tmp"
    mv -f "$tmp" "$CONFIG_FILE"
}

if (( DOWNLOAD_NEED_GIB > 0 && avail < KEEP_BOTH_NEED_GIB )); then
    warn "Not enough free space to download next to the existing files."
    echo "  Need ${KEEP_BOTH_NEED_GIB} GiB free, you have ${avail} GiB."
    if [[ "$MAIN_MISSING" == "true" && ${#OBSOLETE[@]} -gt 0 ]]; then
        echo "  Your current model files use ~${old_gib} GiB."
        echo "  Stopping the server and deleting ONLY those files would free it"
        echo "  (about $((avail + old_gib)) GiB afterwards). Other models on disk are left alone."
        echo ""
        if ! ask_yes_no "  Stop the server and delete the current model files first, then download?" n; then
            err "Not enough disk space. Nothing was changed. Free some space (or agree to replace the old model files) and re-run ./refresh.sh."
        fi
        if llama_server_running; then
            stop_server || err "Could not stop the server. Nothing was deleted."
        fi
        DELETED_OLD=true
        delete_files "${OBSOLETE[@]}"
        ok "Old model files removed."
        avail="$(disk_avail_gib "$space_path")" || err "Could not re-check free disk space."
        echo "  Free space now: ${avail} GiB"
        if (( avail < DOWNLOAD_NEED_GIB )); then
            err "Still not enough space (${avail} GiB free, need ~${DOWNLOAD_NEED_GIB} GiB). config.env was not changed."
        fi
    else
        err "Not enough disk space (${avail} GiB free, need ~${KEEP_BOTH_NEED_GIB} GiB). Nothing was changed. Free some space and re-run ./refresh.sh."
    fi
fi

if (( DOWNLOAD_NEED_GIB > 0 )); then
    ensure_hf_cli || err "Cannot download without the Hugging Face CLI. config.env was not changed."
    info "Downloading new files into $MODELS_DIR/$CATALOG_MODEL_SUBDIR"
    if ! download_new_quant; then
        if [[ "$DELETED_OLD" == "true" ]]; then
            err "Download failed after the old files were deleted. config.env still points at the old paths. Re-run ./refresh.sh to retry, or ./setup.sh to choose again."
        fi
        err "Download failed. config.env and your previous model files were not changed."
    fi
fi

backup_path="$(backup_config)"
write_config_paths
CONFIG_UPDATED=true
ok "config.env updated to the new files."
ok "Backup saved as: $backup_path"

if [[ "$DELETED_OLD" != "true" && ${#OBSOLETE[@]} -gt 0 ]]; then
    echo ""
    echo "  The previous model files are still on disk (~${old_gib} GiB)."
    if ! ask_yes_no "  Delete the previous model files now?" n; then
        echo "  Kept. You can delete them later by hand if you need the space."
    else
        if llama_server_running; then
            warn "The server is still running with the old files open."
            if ! ask_yes_no "  Stop it so the old files can be deleted?" y; then
                echo "  Left the old files in place (cannot delete while in use)."
            else
                stop_server || warn "Could not stop the server; old files not deleted."
                if ! llama_server_running; then
                    DELETED_OLD=true
                    delete_files "${OBSOLETE[@]}"
                    ok "Old model files removed."
                fi
            fi
        else
            DELETED_OLD=true
            delete_files "${OBSOLETE[@]}"
            ok "Old model files removed."
        fi
    fi
fi

echo ""
echo "============================================"
echo " Refresh finished."
echo "============================================"
echo ""
echo "  Quant:     $CATALOG_LABEL"
echo "  Model:     $EXPECTED_MODEL"
echo "  Backup:    $backup_path"
echo ""
echo "  Restart the server to use the new files:"
echo "    ./stop.sh && ./run.sh"
echo ""
