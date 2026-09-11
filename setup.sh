#!/usr/bin/env bash
# setup.sh — Interactive onboarding for Qwen3.8-Flash-Next on AMD Strix Halo.
# Writes config.env (plain KEY=value data) which run.sh reads. Re-running
# setup.sh overwrites config.env, but an existing API key is always preserved
# so clients keep working.
# All downloads and the toolbox build happen in a final fetch phase, *after*
# config.env is written — a failed download never throws away your answers.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"

# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

require_not_root

MISSING=()
note_missing() { MISSING+=("$1"); }

generate_api_key() {
    # od reads a fixed byte count, so no pipe is closed early (SIGPIPE/pipefail safe).
    echo "sk-lm-$(od -An -N18 -tx1 /dev/urandom | tr -d ' \n' | cut -c1-24)"
}

# Preserve an existing API key so repeated setup runs never rotate it
# (extracted by grep — we deliberately do NOT execute the old config here).
PRESERVED_API_KEY=""
if [[ -f "$CONFIG_FILE" ]]; then
    PRESERVED_API_KEY="$(grep -E '^API_KEY=' "$CONFIG_FILE" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
fi

# ── Detect OS ────────────────────────────────────────────────────────────────
OS_ID="unknown"
OS_VERSION=""
if [[ -r /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-}"
fi
case "$OS_ID" in
    fedora)        OS_LABEL="Fedora ${OS_VERSION:-}" ;;
    ubuntu|debian) OS_LABEL="${OS_ID^} ${OS_VERSION:-}" ;;
    arch)          OS_LABEL="Arch Linux" ;;
    *)             OS_LABEL="${PRETTY_NAME:-$OS_ID}" ;;
esac

# ── Container tooling (toolbox + podman) ─────────────────────────────────────
install_container_tooling() {
    echo "  This project runs llama-server inside a toolbox container."
    echo "  Preferred tool: toolbox (package name varies by distro)."
    echo ""
    case "$OS_ID" in
        fedora)
            echo "  Will run: sudo dnf install -y toolbox podman" ;;
        ubuntu|debian)
            echo "  Will run:"
            echo "    sudo add-apt-repository universe   # toolbox/podman live in universe"
            echo "    sudo apt update"
            echo "    sudo apt install -y podman-toolbox podman" ;;
        arch)
            echo "  Will run: sudo pacman -S --needed toolbox podman" ;;
        *)
            echo "  No automatic install for '$OS_ID'. Install 'toolbox' plus 'podman'"
            echo "  with your distro's package manager, then re-run setup.sh." ;;
    esac
    if ! ask_yes_no "  Install now?" y; then
        warn "Skipped. Install toolbox + podman before running run.sh."
        return 1
    fi
    case "$OS_ID" in
        fedora)
            sudo dnf install -y toolbox podman || return 1 ;;
        ubuntu|debian)
            sudo add-apt-repository universe 2>/dev/null || true
            sudo apt update && sudo apt install -y podman-toolbox podman || return 1 ;;
        arch)
            sudo pacman -S --needed toolbox podman || return 1 ;;
        *)
            return 1 ;;
    esac
    ok "Container tooling installed."
}

echo ""
info "=== Container tooling (detected: $OS_LABEL) ==="
if ! have toolbox || ! have podman; then
    if ! have toolbox; then
        warn "'toolbox' not found."
    else
        warn "'toolbox' found but 'podman' (its runtime) is missing."
    fi
    if install_container_tooling; then
        hash -r 2>/dev/null || true
    fi
fi

if have toolbox && have podman; then
    ok "Using: toolbox + podman"
else
    warn "Toolbox tooling incomplete. run.sh will not work until both are installed."
fi

# ── Detect hardware ──────────────────────────────────────────────────────────
echo ""
echo "============================================"
echo " Qwen3.8-Flash-Next on AMD Strix Halo"
echo " Interactive Setup"
echo "============================================"
echo ""

MEM_TOTAL_GIB=$(awk '/MemTotal/ {printf "%.0f", $2/1048576}' /proc/meminfo)
MEM_AVAIL_GIB=$(awk '/MemAvailable/ {printf "%.0f", $2/1048576}' /proc/meminfo)
info "Total RAM: ${MEM_TOTAL_GIB} GiB  Available: ${MEM_AVAIL_GIB} GiB"

CMDLINE=$(cat /proc/cmdline 2>/dev/null || echo "")
IOMMU_OK=false
if echo "$CMDLINE" | grep -q "amd_iommu=off"; then IOMMU_OK=true; fi

# Sanitize: unset, '-1' (auto) or garbage all mean "not set" — never do math on it.
CURRENT_TTM=$(cat /sys/module/ttm/parameters/pages_limit 2>/dev/null | tr -d '[:space:]' || echo "")
if ! [[ "$CURRENT_TTM" =~ ^[0-9]+$ ]]; then
    CURRENT_TTM="0"
fi
if (( CURRENT_TTM > 0 )); then
    CURRENT_TTM_GIB=$((CURRENT_TTM * 4096 / 1073741824))
    TTM_DISPLAY="$CURRENT_TTM ($CURRENT_TTM_GIB GiB)"
else
    TTM_DISPLAY="not set / auto"
fi

IOMMU_LABEL="on (not recommended)"
if [[ "$IOMMU_OK" == "true" ]]; then
    IOMMU_LABEL="off (optimal)"
fi

info "amd_iommu: $IOMMU_LABEL"
info "ttm.pages_limit: $TTM_DISPLAY"
echo ""

# ── HF CLI availability ──────────────────────────────────────────────────────
ensure_hf_cli || true
echo ""

# ── Step 1: Network binding ──────────────────────────────────────────────────
info "=== Step 1: Network binding ==="
echo "  1) localhost — only accessible on this machine"
echo "  2) 0.0.0.0  — accessible over the network (API key required)"
read -rp "Choice [1]: " net_choice || net_choice=""
net_choice="${net_choice:-1}"

if [[ "$net_choice" == "2" ]]; then
    BIND_HOST="0.0.0.0"
    if [[ -n "$PRESERVED_API_KEY" ]]; then
        API_KEY="$PRESERVED_API_KEY"
        ok "Network access enabled. Keeping your existing API key (your agents keep working)."
    else
        API_KEY=$(generate_api_key)
        ok "Network access enabled. API key generated."
    fi
else
    BIND_HOST="127.0.0.1"
    # Keep any existing key so a later switch back to LAN never rotates it.
    API_KEY="$PRESERVED_API_KEY"
    ok "Localhost only. No API key needed."
fi

ask_number PORT "Port" "1235"
if (( 10#$PORT < 1 || 10#$PORT > 65535 )); then
    err "Port must be between 1 and 65535."
fi
echo ""

# ── Step 2: Host memory reservation ──────────────────────────────────────────
info "=== Step 2: Host memory reservation ==="
echo "  This model is large (~90-95 GB on disk). Kernel params control how much"
echo "  system RAM the GPU can use as unified memory."
echo ""
echo "  All changes require a reboot. setup.sh will NOT modify your bootloader."
echo "  It will print the required commands at the end."
echo ""
echo "  Current state:"
echo "    amd_iommu:       $IOMMU_LABEL"
echo "    ttm.pages_limit: $TTM_DISPLAY"
echo ""
echo "  1) ~120 GiB — keep GUI desktop (safe for daily use)"
echo "  2) ~124 GiB — pure inference machine (max VRAM, best to disable desktop)"
echo "  3) Skip — my kernel params are already set"
read -rp "Choice [1]: " mem_choice || mem_choice=""
mem_choice="${mem_choice:-1}"

case "$mem_choice" in
    1)
        TARGET_TTM=31457280
        TARGET_TTM_LABEL="120 GiB (GUI desktop)"
        ;;
    2)
        TARGET_TTM=32505856
        TARGET_TTM_LABEL="124 GiB (pure inference)"
        ;;
    3)
        TARGET_TTM=0
        TARGET_TTM_LABEL="skip"
        ;;
    *)
        TARGET_TTM=31457280
        TARGET_TTM_LABEL="120 GiB (GUI desktop)"
        ;;
esac

# Reboot needed if the TTM value differs OR amd_iommu is still enabled.
NEEDS_REBOOT=false
BOOT_INSTRUCTIONS=""
if [[ "$TARGET_TTM" != "0" && ( "$CURRENT_TTM" != "$TARGET_TTM" || "$IOMMU_OK" != "true" ) ]]; then
    NEEDS_REBOOT=true
    KERNEL_ARGS="amd_iommu=off"
    if [[ "$CURRENT_TTM" != "$TARGET_TTM" ]]; then
        KERNEL_ARGS="$KERNEL_ARGS ttm.pages_limit=$TARGET_TTM"
    fi
    # Prefer grubby (Fedora/RHEL family): the recommended tool, works with BLS
    # entries where grub2-mkconfig alone does not propagate kernel args.
    if have grubby; then
        BOOT_INSTRUCTIONS="  # Fedora/RHEL-family: grubby updates all entries (BLS + /etc/kernel/cmdline + grub.cfg)
  sudo grubby --update-kernel=ALL --args='$KERNEL_ARGS'
  sudo reboot"
    elif [[ -d /boot/loader/entries || -f /etc/kernel/cmdline ]]; then
        BOOT_INSTRUCTIONS="  # systemd-boot: add to /etc/kernel/cmdline:
  #   $KERNEL_ARGS
  #
  # Then rebuild and reboot:
  sudo kernel-install add \"\$(uname -r)\" \"/boot/vmlinuz-\$(uname -r)\" \"/boot/initramfs-\$(uname -r).img\"
  sudo reboot"
    elif [[ -f /etc/default/grub ]]; then
        BOOT_INSTRUCTIONS="  # Add to GRUB_CMDLINE_LINUX in /etc/default/grub:
  #   $KERNEL_ARGS
  #
  # Then rebuild and reboot:
  sudo update-grub 2>/dev/null || sudo grub2-mkconfig -o /boot/grub2/grub.cfg
  sudo reboot"
    else
        BOOT_INSTRUCTIONS="  # Add these kernel boot params (method depends on your distro):
  #   $KERNEL_ARGS
  sudo reboot"
    fi
fi

# Offer tuned profile (can be changed at runtime, no reboot needed)
if have tuned-adm; then
    CURRENT_PROFILE=$(tuned-adm active 2>/dev/null | grep -oP 'Current active profile: \K.*' || echo "unknown")
    if [[ "$CURRENT_PROFILE" != "accelerator-performance" ]]; then
        if ask_yes_no "Set tuned profile to accelerator-performance?" y; then
            if sudo tuned-adm profile accelerator-performance 2>/dev/null; then
                ok "tuned profile set (no reboot needed)."
            else
                warn "Failed to set tuned profile."
            fi
        fi
    else
        ok "tuned profile already accelerator-performance."
    fi
fi

# Offer desktop disable
if [[ "$mem_choice" == "2" ]]; then
    CURRENT_TARGET=$(systemctl get-default 2>/dev/null || echo "unknown")
    if [[ "$CURRENT_TARGET" == "graphical.target" ]] && ask_yes_no "Disable desktop (switch to multi-user.target)?" n; then
        if sudo systemctl set-default multi-user.target 2>/dev/null; then
            ok "Desktop disabled on next boot."
            NEEDS_REBOOT=true
        else
            warn "Failed to disable desktop."
        fi
    fi
fi
echo ""

# ── Step 3: Model selection ──────────────────────────────────────────────────
info "=== Step 3: Model selection ==="
MODELS_DIR="$HOME/models"

if [[ ! -d "$MODELS_DIR" ]]; then
    warn "Models directory not found: $MODELS_DIR"
    if ask_yes_no "Create it?" y; then
        mkdir -p "$MODELS_DIR"
        ok "Created $MODELS_DIR"
    else
        err "Cannot proceed without a models directory."
    fi
fi

mapfile -t CATALOG_FILES < <(catalog_sorted_files)
if ((${#CATALOG_FILES[@]} == 0)); then
    err "No model catalog files found in $CATALOG_DIR"
fi

echo ""
default_choice=1
i=1
for f in "${CATALOG_FILES[@]}"; do
    load_catalog "$f" || err "Failed to read catalog: $f"
    echo "  $i) $CATALOG_LABEL — $CATALOG_SIZE_NOTE"
    echo "     Toolbox: $CATALOG_TOOLBOX_NOTE"
    echo "     Pro: $CATALOG_PRO"
    echo "     Con: $CATALOG_CON"
    echo ""
    if [[ "${CATALOG_DEFAULT:-}" == "true" ]]; then
        default_choice=$i
    fi
    i=$((i + 1))
done
read -rp "Choice [$default_choice]: " model_choice || model_choice=""
model_choice="${model_choice:-$default_choice}"
if [[ ! "$model_choice" =~ ^[0-9]+$ ]] || \
   (( model_choice < 1 || model_choice > ${#CATALOG_FILES[@]} )); then
    err "Invalid choice."
fi
load_catalog "${CATALOG_FILES[$((model_choice - 1))]}" || err "Failed to read catalog."
catalog_apply_paths

# ── Step 3b: Vision (multimodal) ─────────────────────────────────────────────
VISION_ENABLED=false
if [[ "$VISION_AVAILABLE" == "true" ]]; then
    info "=== Step 3b: Vision (multimodal) ==="
    echo "  This model supports images and video via a multimodal projector (~863 MB)."
    echo "  1) Enable vision — downloads mmproj if missing"
    echo "  2) Disable vision — text only"
    read -rp "Choice [1]: " vision_choice || vision_choice=""
    vision_choice="${vision_choice:-1}"
    if [[ "$vision_choice" == "1" ]]; then
        VISION_ENABLED=true
        ok "Vision enabled. mmproj is downloaded in the fetch phase (if missing)."
    else
        ok "Vision disabled. Text only."
        MMPROJ_PATH=""
    fi
else
    info "=== Step 3b: Vision ==="
    info "No mmproj available for this model. Skipping."
fi
echo ""

# ── Step 4: PLE/ngram storage ────────────────────────────────────────────────
info "=== Step 4: PLE n-gram table storage ==="
echo "  The model has a ~27-51 GB n-gram lookup table (PLE). It can be:"
echo ""
echo "  1) SSD streaming — reads rows from disk on demand (saves ~30 GB VRAM)"
echo "     Decode: -2-3 tok/s slower  Prefill: depends on SSD speed"
echo ""
echo "  2) Resident in RAM — loads the full table into memory"
echo "     Faster decode/prefill but needs ~30 GB more RAM"
echo ""
read -rp "Choice [1]: " ple_choice || ple_choice=""
ple_choice="${ple_choice:-1}"

if [[ "$ple_choice" == "2" ]]; then
    PLE_MODE="resident"
    PLE_FLAGS=""
    ok "PLE table will be loaded into RAM."
else
    PLE_MODE="ssd"
    PLE_FLAGS="$SSD_FLAG $SSD_EXTRA_FLAGS"
    ok "PLE table will stream from SSD."
fi
echo ""

# ── Step 5: Context size ─────────────────────────────────────────────────────
info "=== Step 5: Context size ==="
echo "  1) 128k — short sessions, lowest VRAM usage"
echo "  2) 180k — balanced (recommended)"
echo "  3) 262k — very long sessions, highest VRAM usage"
read -rp "Choice [2]: " ctx_choice || ctx_choice=""
ctx_choice="${ctx_choice:-2}"

case "$ctx_choice" in
    1) CTX_SIZE=131072 ;;
    2) CTX_SIZE=180000 ;;
    3) CTX_SIZE=262144 ;;
    *) CTX_SIZE=180000 ;;
esac
ok "Context size: $CTX_SIZE tokens"
echo ""

# ── Step 6: MTP speculative decoding ─────────────────────────────────────────
MTP_ENABLED=false
MTP_DRAFT_N=0
info "=== Step 6: MTP speculative decoding ==="
echo "  MTP (Multi-Token Prediction) drafts extra tokens for faster generation."
echo "  Supported by both toolboxes (laurentz and hanchen forks)."
echo "  Requires the MTP draft model file (downloaded in the fetch phase if missing)."
echo ""
echo "  1) No MTP — standard autoregressive decoding"
echo "  2) MTP 2 — draft 2 extra tokens per step"
read -rp "Choice [1]: " mtp_choice || mtp_choice=""
mtp_choice="${mtp_choice:-1}"

if [[ "$mtp_choice" == "2" ]]; then
    MTP_ENABLED=true
    MTP_DRAFT_N=2
    ok "MTP enabled with K=2."
else
    ok "MTP disabled."
fi
echo ""

# ── Step 7: Parallel slots ───────────────────────────────────────────────────
info "=== Step 7: Parallel slots ==="
echo "  Number of concurrent request slots. 1 = single user, higher = more throughput"
echo "  but uses more VRAM."
ask_number PARALLEL_SLOTS "Slots" "1"
echo ""

# ── Write config (BEFORE any downloads/builds — answers are never lost) ─────
info "=== Writing config ==="

cat > "$CONFIG_FILE" <<CONFIG_EOF
# config.env — Generated by setup.sh on $(date -Iseconds)
# Plain KEY=value data — safe to edit by hand, never executed as code.
# Full-line comments only. Re-running setup.sh overwrites this file
# (your API key is preserved).

# Model
TOOLBOX_NAME=$TOOLBOX_NAME
MODEL_PATH=$MODEL_PATH

# Server
BIND_HOST=$BIND_HOST
PORT=$PORT
API_KEY=$API_KEY

# Context & performance
CTX_SIZE=$CTX_SIZE
PARALLEL_SLOTS=$PARALLEL_SLOTS
FLASH_ATTN=on
GPU_LAYERS=999
LOAD_MODE=auto
CACHE_TYPE_K=q8_0
CACHE_TYPE_V=q8_0

# PLE n-gram table storage
PLE_MODE=$PLE_MODE
PLE_FLAGS=$PLE_FLAGS

# Vision (multimodal)
VISION_ENABLED=$VISION_ENABLED
MMPROJ_PATH=$MMPROJ_PATH

# MTP speculative decoding
MTP_ENABLED=$MTP_ENABLED
MTP_DRAFT_N=$MTP_DRAFT_N
MTP_DRAFT_MODEL=$MTP_DRAFT_MODEL
CONFIG_EOF

ok "Config written to: $CONFIG_FILE"
echo ""

# ── Fetch phase: downloads + toolbox build (config is safe on disk) ──────────
download_missing() {
    if download_if_missing "$1" "$2" "$3" ask; then
        return 0
    fi
    note_missing "$2"
    return 1
}

info "=== Fetch phase: model files ==="
avail="$(disk_avail_gib "$MODELS_DIR")" || avail=""
size_gib="${CATALOG_SIZE_GIB:-95}"
disk_min_gib=100
disk_rec_gib=120
if [[ -z "$avail" ]]; then
    warn "Could not check free disk space for $MODELS_DIR."
elif (( avail < disk_min_gib )); then
    err "Only ${avail} GiB free on the disk that holds $MODELS_DIR. Need at least ${disk_min_gib} GiB (this model uses ~${size_gib} GB on disk; ${disk_rec_gib} GiB free is recommended so the disk isn't packed full)."
elif (( avail < disk_rec_gib )); then
    warn "Only ${avail} GiB free on the disk that holds $MODELS_DIR."
    echo "  This model uses ~${size_gib} GB on disk. ${disk_rec_gib} GiB free is recommended so about 30 GB stays unused."
    if ! ask_yes_no "  Continue anyway?" n; then
        err "Stopped before downloading. config.env was saved — free some space, then re-run ./setup.sh or ./refresh.sh."
    fi
fi
mkdir -p "$MODEL_DIR"

if [[ "$VISION_ENABLED" == "true" && -n "$MMPROJ_PATH" && ! -f "$MMPROJ_PATH" ]]; then
    mkdir -p "$(dirname "$MMPROJ_PATH")"
    download_missing "$DOWNLOAD_REPO" "$MMPROJ_DOWNLOAD_FILE" "$MODEL_DIR" || true
fi

# shellcheck disable=SC2086
for f in $DOWNLOAD_FILES; do
    download_missing "$DOWNLOAD_REPO" "$f" "$MODEL_DIR" || true
done
echo ""

info "=== Fetch phase: toolbox ==="
if toolbox_has "$TOOLBOX_NAME"; then
    ok "Toolbox '$TOOLBOX_NAME' already exists."
else
    warn "Toolbox '$TOOLBOX_NAME' not found."
    info "Building it compiles a llama.cpp fork inside a container image. This may take ~20 minutes."
    if ask_yes_no "Build toolbox now?" n; then
        if bash "$SCRIPT_DIR/toolboxes/refresh-toolboxes.sh" "$TOOLBOX_NAME"; then
            ok "Toolbox built."
        else
            warn "Toolbox build failed."
            note_missing "toolbox '$TOOLBOX_NAME'"
        fi
    else
        echo "  Build it manually before running run.sh:"
        echo "    ./toolboxes/refresh-toolboxes.sh $TOOLBOX_NAME"
        note_missing "toolbox '$TOOLBOX_NAME'"
    fi
fi
echo ""

# ── Summary ──────────────────────────────────────────────────────────────────
echo "============================================"
echo " Setup complete!"
echo "============================================"
echo ""
echo "  Toolbox:    $TOOLBOX_NAME"
echo "  Model:      $MODEL_PATH"
echo "  Context:    $CTX_SIZE tokens"
echo "  PLE mode:   $PLE_MODE"
echo "  MTP:        $MTP_ENABLED (K=$MTP_DRAFT_N)"
echo "  Bind:       $BIND_HOST:$PORT"
if [[ -n "$API_KEY" ]]; then
echo "  API key:    $API_KEY"
fi
echo ""
echo "  Start:      ./run.sh"
echo "  Stop:       ./stop.sh"
echo "  Update:     ./refresh.sh   (after git pull)"
echo ""

if ((${#MISSING[@]} > 0)); then
    warn "Items still missing (run.sh will refuse to start until resolved):"
    for item in "${MISSING[@]}"; do
        echo "  - $item"
    done
    echo ""
fi

if [[ "$NEEDS_REBOOT" == "true" ]]; then
    echo ""
    echo "============================================"
    warn "KERNEL PARAMS NOT YET APPLIED — REBOOT REQUIRED"
    echo "============================================"
    echo ""
    echo "  setup.sh does NOT modify your bootloader."
    echo "  Run these commands manually, then reboot:"
    echo ""
    echo "$BOOT_INSTRUCTIONS"
    echo ""
    echo "  After reboot, verify with:"
    echo "    cat /proc/cmdline | tr ' ' '\\n' | grep -E 'iommu|ttm'"
    echo "    cat /sys/module/ttm/parameters/pages_limit"
    echo ""
fi
