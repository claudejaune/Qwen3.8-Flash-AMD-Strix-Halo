#!/usr/bin/env bash
# run.sh — Start Qwen3.8-Flash-Next llama-server using config.sh.
# Runs in the foreground. Use stop.sh from another terminal to stop it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.sh"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: config.sh not found. Run ./setup.sh first." >&2
    exit 1
fi

# shellcheck source=config.sh
source "$CONFIG_FILE"

have() { command -v "$1" &>/dev/null; }

# Validate required vars
for var in TOOLBOX_NAME MODEL_PATH CTX_SIZE BIND_HOST PORT GPU_LAYERS FLASH_ATTN LOAD_MODE PARALLEL_SLOTS; do
    if [[ -z "${!var:-}" ]]; then
        echo "Error: $var not set in config.sh. Re-run ./setup.sh." >&2
        exit 1
    fi
done

# Check model exists
if [[ ! -f "$MODEL_PATH" ]]; then
    echo "Error: Model not found: $MODEL_PATH" >&2
    echo "Download it first. Re-run ./setup.sh." >&2
    exit 1
fi

# For split GGUFs, verify EVERY shard exists — a partial download passes the
# single-file check above but fails later with a confusing server error.
SHARD_MISSING=()
if [[ "$MODEL_PATH" =~ -([0-9]{5})-of-([0-9]{5})\.gguf$ ]]; then
    FIRST_SHARD="${BASH_REMATCH[1]}"
    TOTAL_SHARDS="${BASH_REMATCH[2]}"
    for ((i = 1; i <= TOTAL_SHARDS; i++)); do
        IDX="$(printf '%05d' "$i")"
        SHARD="${MODEL_PATH/-$FIRST_SHARD-of-/-$IDX-of-}"
        if [[ ! -f "$SHARD" ]]; then
            SHARD_MISSING+=("$(basename "$SHARD")")
        fi
    done
    if ((${#SHARD_MISSING[@]} > 0)); then
        echo "Error: Model is split into $TOTAL_SHARDS shards, but these are missing:" >&2
        for s in "${SHARD_MISSING[@]}"; do
            echo "  $s" >&2
        done
        echo "Re-download (./setup.sh fetch phase or 'hf download') — the model cannot load partially." >&2
        exit 1
    fi
fi

# Locate the container (toolbox preferred, distrobox/podman fallbacks)
toolbox_has() {
    toolbox list -c 2>/dev/null | awk 'NR>1 {print $2}' | grep -qx "$1"
}
distrobox_has() {
    distrobox list 2>/dev/null | awk -F'|' '{gsub(/[ \t]/,"",$1); print $1}' | grep -qx "$1"
}
podman_has() {
    podman ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$1"
}

if ! toolbox_has "$TOOLBOX_NAME" && ! distrobox_has "$TOOLBOX_NAME" && ! podman_has "$TOOLBOX_NAME"; then
    echo "Error: Container '$TOOLBOX_NAME' not found (checked toolbox, distrobox and podman)." >&2
    echo "Re-run ./setup.sh to create it." >&2
    exit 1
fi

if have toolbox && toolbox_has "$TOOLBOX_NAME"; then
    TB_CMD="toolbox"
elif have distrobox && distrobox_has "$TOOLBOX_NAME"; then
    TB_CMD="distrobox"
elif have podman; then
    TB_CMD="podman"
else
    echo "Error: Neither toolbox, distrobox nor podman found." >&2
    exit 1
fi

# Build llama-server command
CMD=(llama-server)
CMD+=(-m "$MODEL_PATH")
CMD+=(-ngl "$GPU_LAYERS")
CMD+=(-fa "$FLASH_ATTN")
CMD+=(-c "$CTX_SIZE")
CMD+=(-lm "$LOAD_MODE")
CMD+=(--host "$BIND_HOST")
CMD+=(--port "$PORT")
CMD+=(-np "$PARALLEL_SLOTS")
CMD+=(-ctk "${CACHE_TYPE_K:-q8_0}")
CMD+=(-ctv "${CACHE_TYPE_V:-q8_0}")

# Multimodal projector (only if vision enabled and file exists)
if [[ "${VISION_ENABLED:-false}" == "true" ]]; then
    if [[ -n "${MMPROJ_PATH:-}" && -f "$MMPROJ_PATH" ]]; then
        CMD+=(-mm "$MMPROJ_PATH")
    else
        echo "WARNING: VISION_ENABLED=true but mmproj not found (${MMPROJ_PATH:-<unset>})." >&2
        echo "         Server will start text-only; image inputs will be silently ignored." >&2
    fi
fi

# PLE storage mode
if [[ "${PLE_MODE:-resident}" == "ssd" && -n "${PLE_FLAGS:-}" ]]; then
    # shellcheck disable=SC2206
    CMD+=($PLE_FLAGS)
fi

# MTP speculative decoding (supported by both laurentz and hanchen forks)
if [[ "${MTP_ENABLED:-false}" == "true" && "${MTP_DRAFT_N:-0}" -gt 0 ]]; then
    CMD+=(--spec-type draft-mtp)
    CMD+=(--spec-draft-n-max "$MTP_DRAFT_N")
    if [[ -n "${MTP_DRAFT_MODEL:-}" && -f "$MTP_DRAFT_MODEL" ]]; then
        CMD+=(-md "$MTP_DRAFT_MODEL")
    else
        echo "WARNING: MTP_ENABLED=true but draft model not found (${MTP_DRAFT_MODEL:-<unset>})." >&2
        echo "         Passing MTP flags without -md; the server may fail to start." >&2
    fi
fi

# API key — only meaningful (and only passed) when bound to the network
if [[ -n "${API_KEY:-}" && "$BIND_HOST" != "127.0.0.1" ]]; then
    CMD+=(--api-key "$API_KEY")
fi

# Get local IP for display
LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")

# Print connection info
echo ""
echo "============================================"
echo " Qwen3.8-Flash-Next Server"
echo "============================================"
echo ""
echo "  Container:  $TOOLBOX_NAME (via $TB_CMD)"
echo "  Model:      $(basename "$MODEL_PATH")"
echo "  Context:    $CTX_SIZE tokens"
echo "  PLE mode:   ${PLE_MODE:-resident}"
echo "  MTP:        ${MTP_ENABLED:-false} (K=${MTP_DRAFT_N:-0})"
echo ""
echo "  Endpoint:   http://${LOCAL_IP}:${PORT}/v1/chat/completions"
echo "  Health:     http://${LOCAL_IP}:${PORT}/health"
if [[ -n "${API_KEY:-}" && "$BIND_HOST" != "127.0.0.1" ]]; then
echo "  API key:    $API_KEY"
echo ""
echo "  NOTE: API key required. Anyone on the network can reach this"
echo "  server. Set this key in your agent/client configuration."
fi
echo ""
echo "  Stop:       ./stop.sh (from another terminal)"
echo ""
echo "============================================"
echo ""

# Run in foreground
case "$TB_CMD" in
    toolbox)
        exec toolbox run -c "$TOOLBOX_NAME" -- "${CMD[@]}"
        ;;
    distrobox)
        exec distrobox enter --name "$TOOLBOX_NAME" -- "${CMD[@]}"
        ;;
    podman)
        # Toolbox/distrobox containers may be stopped; start before exec.
        podman start "$TOOLBOX_NAME" >/dev/null 2>&1 || true
        exec podman exec "$TOOLBOX_NAME" "${CMD[@]}"
        ;;
esac
