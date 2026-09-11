#!/usr/bin/env bash
# run.sh — Start Qwen3.8-Flash-Next llama-server using config.env.
# Runs in the foreground. Use stop.sh from another terminal to stop it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: config.env not found. Run ./setup.sh first." >&2
    exit 1
fi

# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
require_not_root
load_config "$CONFIG_FILE"

# Validate required vars
for var in TOOLBOX_NAME MODEL_PATH BIND_HOST PORT CTX_SIZE PARALLEL_SLOTS GPU_LAYERS FLASH_ATTN LOAD_MODE; do
    if [[ -z "${!var:-}" ]]; then
        echo "Error: $var not set in config.env. Re-run ./setup.sh." >&2
        exit 1
    fi
done

# Numeric vars — a hand-edited config must not pass garbage to llama-server
for var in PORT CTX_SIZE PARALLEL_SLOTS GPU_LAYERS; do
    if [[ ! "${!var}" =~ ^[0-9]+$ ]]; then
        echo "Error: $var must be a number, got '${!var}' in config.env." >&2
        exit 1
    fi
done
if [[ ! "${MTP_DRAFT_N:-0}" =~ ^[0-9]+$ ]]; then
    echo "Error: MTP_DRAFT_N must be a number, got '${MTP_DRAFT_N:-<unset>}' in config.env." >&2
    exit 1
fi

# Check model exists
if [[ ! -f "$MODEL_PATH" ]]; then
    echo "Error: Model not found: $MODEL_PATH" >&2
    echo "Download it first. Re-run ./setup.sh or ./refresh.sh." >&2
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
        echo "Re-download (./setup.sh, ./refresh.sh, or 'hf download') — the model cannot load partially." >&2
        exit 1
    fi
fi

# Locate the container (toolbox only — it must be a toolbox container)
if ! toolbox_has "$TOOLBOX_NAME"; then
    echo "Error: Toolbox '$TOOLBOX_NAME' not found." >&2
    echo "Re-run ./setup.sh or ./refresh.sh, or build it manually: ./toolboxes/refresh-toolboxes.sh $TOOLBOX_NAME" >&2
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

# Host shown in the connection info: the LAN IP when bound to the network,
# the loopback address when bound to localhost.
DISPLAY_HOST="$BIND_HOST"
if [[ "$BIND_HOST" != "127.0.0.1" ]]; then
    DISPLAY_HOST="$(hostname -I 2>/dev/null | awk '{print $1}')"
    if [[ -z "$DISPLAY_HOST" ]]; then
        DISPLAY_HOST="$BIND_HOST"
    fi
fi

# Print connection info
echo ""
echo "============================================"
echo " Qwen3.8-Flash-Next Server"
echo "============================================"
echo ""
echo "  Toolbox:   $TOOLBOX_NAME"
echo "  Model:     $(basename "$MODEL_PATH")"
echo "  Context:   $CTX_SIZE tokens"
echo "  PLE mode:  ${PLE_MODE:-resident}"
echo "  MTP:       ${MTP_ENABLED:-false} (K=${MTP_DRAFT_N:-0})"
echo ""
echo "  Endpoint:  http://$DISPLAY_HOST:$PORT/v1/chat/completions"
echo "  Health:    http://$DISPLAY_HOST:$PORT/health"
if [[ -n "${API_KEY:-}" && "$BIND_HOST" != "127.0.0.1" ]]; then
echo "  API key:   $API_KEY"
echo ""
echo "  NOTE: API key required. Anyone on the network can reach this"
echo "  server. Set this key in your agent/client configuration."
fi
echo ""
echo "  Stop:      ./stop.sh (from another terminal)"
echo ""
echo "============================================"
echo ""

# Run in foreground
exec toolbox run -c "$TOOLBOX_NAME" -- "${CMD[@]}"
