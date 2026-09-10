#!/usr/bin/env bash
# refresh.sh — Build a toolbox container image from the Dockerfiles in this
# directory and (re)create the matching toolbox container.
#
# Usage (can be run from anywhere):
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

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
DOCKERFILES["llama-vulkan-laurentz"]="Dockerfile.vulkan-laurentz"
DOCKERFILES["llama-vulkan-hanchen"]="Dockerfile.vulkan-hanchen"

if [[ ! -v DOCKERFILES[$NAME] ]]; then
  echo "Error: Unknown toolbox '$NAME'" >&2
  echo "Available: llama-vulkan-laurentz, llama-vulkan-hanchen" >&2
  exit 1
fi

DOCKERFILE="$SCRIPT_DIR/toolboxes/${DOCKERFILES[$NAME]}"
IMAGE="$NAME"

# Check dependencies (toolbox requires podman as its runtime)
for cmd in podman toolbox; do
  if ! command -v "$cmd" > /dev/null 2>&1; then
    echo "Error: '$cmd' is not installed." >&2
    echo "  Install it with your distro's package manager" >&2
    echo "  (Fedora/Arch: 'toolbox', Ubuntu/Debian: 'podman-toolbox')." >&2
    exit 1
  fi
done

echo "🔨 Building $IMAGE from $DOCKERFILE…"
echo "   args: ${*-(none, layer-cached)}"
podman build ${1+"$@"} -t "$IMAGE" -f "$DOCKERFILE" "$SCRIPT_DIR/toolboxes/"

echo "🧪 Smoke test…"
podman run --rm "$IMAGE" llama-server --version

if toolbox_has "$NAME"; then
  echo "🧹 Removing existing toolbox: $NAME"
  toolbox rm -f "$NAME"
fi

# toolbox create has no flag passthrough — and needs none: toolbox containers
# natively share the host's /dev, the udev database and the user's groups,
# which is what the --device/--group-add/--security-opt args used to provide
# for plain podman containers.
echo "📦 Creating toolbox: $NAME"
toolbox create "$NAME" --image "$IMAGE"

# Sanity check: the GPU must be visible inside the container
if toolbox run -c "$NAME" -- ls /dev/dri > /dev/null 2>&1; then
  echo "✅ GPU device nodes visible in /dev/dri"
else
  echo "⚠️  /dev/dri is not visible inside the container — the GPU may not work." >&2
fi

echo "✅ $NAME refreshed. Enter with: toolbox enter $NAME"
