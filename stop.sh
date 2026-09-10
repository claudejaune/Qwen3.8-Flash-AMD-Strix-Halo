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
CONFIG_FILE="$SCRIPT_DIR/config.sh"

if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=config.sh
    source "$CONFIG_FILE"
fi

have() { command -v "$1" &>/dev/null; }

CONTAINER="${TOOLBOX_NAME:-}"
TIMEOUT=10

# ── Container-scoped stop ─────────────────────────────────────────────────────
# The container must actually be running; don't start it just to check.
CONTAINER_RUNNING=true
if have podman && ! podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"; then
    CONTAINER_RUNNING=false
fi

if [[ -n "$CONTAINER" && "$CONTAINER_RUNNING" == "true" ]]; then
    if have toolbox; then
        TBX=(toolbox run -c "$CONTAINER" --)
    elif have podman; then
        TBX=(podman exec "$CONTAINER")
    else
        TBX=()
    fi

    if ((${#TBX[@]} > 0)); then
        C_PIDS=$("${TBX[@]}" pgrep -f llama-server 2>/dev/null || true)

        # Filter out transient wrappers (pgrep itself, toolbox plumbing) by
        # checking each candidate's cmdline inside the container.
        REAL_PIDS=""
        for pid in $C_PIDS; do
            C_CMD=$("${TBX[@]}" cat "/proc/$pid/cmdline" 2>/dev/null | tr '\0' ' ' || true)
            case "$C_CMD" in
                *pgrep*|*toolbox*) continue ;;
                *) REAL_PIDS+="$pid " ;;
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
                if ! $STILL_ALIVE; then
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
    if ! $STILL_ALIVE; then
        echo "Stopped."
        exit 0
    fi
    sleep 1
done

echo "Force killing ..."
# shellcheck disable=SC2086
kill -9 $PIDS 2>/dev/null || true

echo "Stopped."
