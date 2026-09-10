#!/usr/bin/env bash
# stop.sh — Stop the running Qwen3.8-Flash-Next llama-server.
#
# Prefers killing inside the configured toolbox container: pgrep run *inside*
# the container only sees that container's processes, so an unrelated
# llama-server elsewhere on the host can never be touched. If the container
# path is unavailable, falls back to a host-wide search WITH a confirmation
# prompt before killing anything.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"

if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=lib/common.sh
    . "$SCRIPT_DIR/lib/common.sh"
    load_config "$CONFIG_FILE"
fi

have() { command -v "$1" &>/dev/null; }

CONTAINER="${TOOLBOX_NAME:-}"
TIMEOUT=10

# True if the container is currently running. (A stopped container would be
# *started* by `toolbox run`, which we don't want just to check for a server.)
container_running() {
    local running
    running="$(podman ps --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')" || return 1
    [[ " $running " == *" $1 "* ]]
}

# ── Container-scoped stop ─────────────────────────────────────────────────────
if [[ -n "$CONTAINER" ]] && have toolbox && toolbox_has "$CONTAINER" && \
   have podman && container_running "$CONTAINER"; then
    TBX=(toolbox run -c "$CONTAINER" --)

    C_PIDS=$("${TBX[@]}" pgrep -f llama-server 2>/dev/null || true)

    # Keep only processes whose command line *starts with* llama-server.
    # This excludes transient wrappers (the host-side `toolbox run` process
    # itself, shells, etc.) without fragile substring matches.
    REAL_PIDS=""
    for pid in $C_PIDS; do
        C_CMD=$("${TBX[@]}" cat "/proc/$pid/cmdline" 2>/dev/null | tr '\0' ' ' || true)
        case "$C_CMD" in
            llama-server*) REAL_PIDS+="$pid " ;;
        esac
    done

    if [[ -n "$REAL_PIDS" ]]; then
        echo "Found llama-server in container '$CONTAINER': PIDs $REAL_PIDS"
        echo "Sending SIGTERM ..."
        # shellcheck disable=SC2086
        "${TBX[@]}" kill $REAL_PIDS 2>/dev/null || true

        for ((i = 0; i < TIMEOUT; i++)); do
            STILL_ALIVE=false
            for pid in $REAL_PIDS; do
                if "${TBX[@]}" kill -0 "$pid" 2>/dev/null; then
                    STILL_ALIVE=true
                    break
                fi
            done
            if [[ "$STILL_ALIVE" != "true" ]]; then
                echo "Stopped."
                exit 0
            fi
            sleep 1
        done

        echo "Force killing ..."
        # shellcheck disable=SC2086
        "${TBX[@]}" kill -9 $REAL_PIDS 2>/dev/null || true
        echo "Stopped."
        exit 0
    fi
fi

# ── Host fallback (confirmation required) ────────────────────────────────────
PIDS=$(pgrep -f "llama-server" 2>/dev/null || true)

if [[ -z "$PIDS" ]]; then
    echo "No llama-server process found."
    exit 0
fi

echo "Found llama-server processes (host-wide):"
# shellcheck disable=SC2086
ps -p $PIDS -o pid,cmd --no-headers 2>/dev/null || true
echo ""
echo "WARNING: this will kill ALL of the processes listed above, not just the"
echo "server from this project's config (container-scoped stop was unavailable)."
read -rp "Kill them? [y/N]: " reply || reply=""
if [[ ! "$reply" =~ ^[Yy] ]]; then
    echo "Aborted."
    exit 1
fi

echo "Sending SIGTERM ..."
# shellcheck disable=SC2086
kill $PIDS 2>/dev/null || true

for ((i = 0; i < TIMEOUT; i++)); do
    STILL_ALIVE=false
    for pid in $PIDS; do
        if kill -0 "$pid" 2>/dev/null; then
            STILL_ALIVE=true
            break
        fi
    done
    if [[ "$STILL_ALIVE" != "true" ]]; then
        echo "Stopped."
        exit 0
    fi
    sleep 1
done

echo "Force killing ..."
# shellcheck disable=SC2086
kill -9 $PIDS 2>/dev/null || true

echo "Stopped."
