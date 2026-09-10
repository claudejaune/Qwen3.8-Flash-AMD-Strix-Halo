#!/usr/bin/env bash
# refresh.sh — Build a toolbox container image from the Dockerfiles in this
# directory and (re)create the matching toolbox container.
#
# Usage (run from the repo root — the Dockerfiles use toolboxes/ as the build
# context, so the relative path matters):
#
#   ./toolboxes/refresh.sh <toolbox-name> [extra podman build args, e.g. --no-cache]
#
# Available toolboxes:
#   llama-vulkan-laurentz  — LaurentZuijdwijk fork (vulkan/qwen4exp-rocmfpx),
#                            supports ROCmFP4 quants + PLE n-gram streaming
#   llama-vulkan-hanchen   — danielhanchen fork (qwen4exp/mtp), MTP speculative
#                            decoding
#
# Based on the refresh scripts from kyuz0/amd-strix-halo-toolboxes:
#   https://github.com/kyuz0/amd-strix-halo-toolboxes
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
  echo "Usage: $0 <toolbox-name> [extra podman build args, e.g. --no-cache]"
  echo "Available toolboxes:"
  echo "  - llama-vulkan-laurentz"
  echo "  - llama-vulkan-hanchen"
  exit 1
fi

NAME="$1"
shift

declare -A DOCKERFILES
declare -A OPTIONS

DOCKERFILES["llama-vulkan-laurentz"]="toolboxes/Dockerfile.vulkan-laurentz"
OPTIONS["llama-vulkan-laurentz"]=""
DOCKERFILES["llama-vulkan-hanchen"]="toolboxes/Dockerfile.vulkan-hanchen"
OPTIONS["llama-vulkan-hanchen"]="--device /dev/dri --group-add video --security-opt seccomp=unconfined"

if [[ ! -v DOCKERFILES["$NAME"] ]]; then
  echo "Error: Unknown toolbox '$NAME'" >&2
  echo "Available: llama-vulkan-laurentz, llama-vulkan-hanchen" >&2
  exit 1
fi

DOCKERFILE="${DOCKERFILES[$NAME]}"
CREATE_OPTIONS="${OPTIONS[$NAME]}"
IMAGE="$NAME"

# Check OS and pick the toolbox command (Ubuntu/Debian must use distrobox)
TOOLBOX_CMD="toolbox"
if [ -f /etc/os-release ]; then
  . /etc/os-release
  if [ "$ID" = "ubuntu" ] || [ "$ID" = "debian" ]; then
    TOOLBOX_CMD="distrobox"
  fi
fi

# Check dependencies
for cmd in podman "$TOOLBOX_CMD"; do
  if ! command -v "$cmd" > /dev/null 2>&1; then
    if [ "$cmd" = "distrobox" ]; then
      echo "Error: 'distrobox' is not installed. Debian-based distributions (like Ubuntu) must use distrobox instead of toolbox." >&2
      echo "Please install distrobox (e.g., sudo apt install distrobox) and try again." >&2
    else
      echo "Error: '$cmd' is not installed." >&2
    fi
    exit 1
  fi
done

# Match the known-good RDMA setup used by the vLLM Toolbx project.
# Distrobox already manages host device integration and is left unchanged.
if [ "$TOOLBOX_CMD" = "toolbox" ] && [ -d /dev/infiniband ]; then
  echo "🔎 InfiniBand devices detected. Enabling RDMA for Toolbx."
  CREATE_OPTIONS="$CREATE_OPTIONS --device /dev/infiniband --group-add rdma --ulimit memlock=-1"
fi

echo "🔨 Building $IMAGE from $DOCKERFILE…"
echo "   args: ${*-(none, layer-cached)}"
podman build ${1+"$@"} -t "$IMAGE" -f "$DOCKERFILE" toolboxes/

echo "🧪 Smoke test…"
podman run --rm "$IMAGE" llama-server --version

if $TOOLBOX_CMD list 2>/dev/null | grep -q "$NAME"; then
  echo "🧹 Removing existing toolbox: $NAME"
  $TOOLBOX_CMD rm -f "$NAME"
fi

echo "📦 Creating toolbox: $NAME"
if [ -n "$CREATE_OPTIONS" ]; then
  $TOOLBOX_CMD create "$NAME" --image "$IMAGE" -- $CREATE_OPTIONS
else
  $TOOLBOX_CMD create "$NAME" --image "$IMAGE"
fi

echo "✅ $NAME refreshed. Enter with: $TOOLBOX_CMD enter $NAME"
