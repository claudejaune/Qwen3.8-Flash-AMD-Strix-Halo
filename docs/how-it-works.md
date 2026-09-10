# How it works

Details for people who want to know what's actually going on. For the short
version, see the [main README](../README.md).

## What setup.sh does

1. **Container tooling check** — detects your distro (Fedora/Ubuntu/Arch) and offers to install `toolbox` + `podman` (or `distrobox`) if missing
2. **Network binding** — localhost or 0.0.0.0 (with API key, preserved across setup runs)
3. **Kernel config check** — prints the `amd_iommu=off` / `ttm.pages_limit` commands for your bootloader; never modifies the bootloader itself
4. **Model selection** — ROCmFP4 (agentionai) or IQ4_XS (unsloth)
5. **Vision on/off** — multimodal projector (mmproj)
6. **PLE storage** — SSD streaming or resident in RAM
7. **Context size** — 128k / 180k / 262k
8. **MTP** — optional 2-token speculative decoding
9. **Parallel slots** — concurrent request slots

After all questions are answered, `config.sh` is written and a final **fetch
phase** downloads any missing model files and offers to build the toolbox
container (~20 min first time). Downloads/builds happen *after* the config is
saved, so a failed download never throws away your answers.

`stop.sh` only kills llama-server processes inside the container named in
`config.sh` — it never touches unrelated llama-server processes on the host.

## Host configuration (kernel params)

This model needs most of your system's 128 GB unified memory. Two kernel boot parameters control how much the GPU can use:

| Parameter | What it does |
|---|---|
| `amd_iommu=off` | Disables AMD IOMMU. 5-12% performance gain. **Breaks NPU and DMA isolation.** |
| `ttm.pages_limit=<N>` | Max 4 KiB pages the GPU can pin. Controls unified memory size. |

Both **require a reboot** — they're read once at boot. `setup.sh` checks your current values and prints the commands to run; it does not modify your bootloader.

### Values

| Target | `ttm.pages_limit` | Use case |
|---|---|---|
| ~121 GiB | `31457280` | GUI desktop, safe for daily use |
| ~124 GiB | `32505856` | Pure inference, max VRAM |

### Fedora

Prefer `grubby` (Fedora's recommended tool — it works with the BLS boot
entries that modern Fedora uses, where `grub2-mkconfig` alone does not
propagate kernel args):

```bash
sudo grubby --update-kernel=ALL --args='amd_iommu=off ttm.pages_limit=31457280'
sudo reboot
```

Alternatively, edit `GRUB_CMDLINE_LINUX` in `/etc/default/grub` and run
`sudo grub2-mkconfig -o /boot/grub2/grub.cfg`.

### Ubuntu / Debian (GRUB)

```bash
# Add to GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub:
#   amd_iommu=off ttm.pages_limit=31457280

sudo update-grub
sudo reboot
```

### systemd-boot (e.g. Ryzen AI Halo images)

```bash
# Add to /etc/kernel/cmdline:
#   amd_iommu=off ttm.pages_limit=31457280

sudo kernel-install add "$(uname -r)" \
  "/boot/vmlinuz-$(uname -r)" \
  "/boot/initrd.img-$(uname -r)"
sudo reboot
```

Or use `amd-ttm` (ships with Ryzen AI Halo):

```bash
sudo amd-ttm --set 124
sudo reboot
```

### Verify after reboot

```bash
# Check params are active
cat /proc/cmdline | tr ' ' '\n' | grep -E 'iommu|ttm'

# Check memory allocated to GPU
cat /sys/module/ttm/parameters/pages_limit
sudo dmesg | grep "amdgpu.*memory"
```

### Power tuning (no reboot needed)

Set the `tuned` profile for maximum throughput:

```bash
sudo dnf install tuned       # or: sudo apt install tuned
sudo systemctl enable --now tuned
sudo tuned-adm profile accelerator-performance
```

### Desktop disable (optional, reboot needed)

Switch to text-only mode to free RAM for inference:

```bash
sudo systemctl set-default multi-user.target
sudo reboot

# Restore desktop later:
# sudo systemctl set-default graphical.target && sudo reboot
```

### Notes

- `amdgpu.gttsize` is **deprecated** on kernels 6.1+ — use `ttm.pages_limit` instead.
- `amd_iommu=off` prevents the NPU from working and removes DMA attack protection. Leave IOMMU enabled if you need the NPU.
- On the Framework Desktop, 121 GiB (`ttm.pages_limit=31457280`) is enough for this model with SSD streaming. 124 GiB only matters if you want to load the PLE table into RAM.

## Config file reference

`config.sh` is a shell-sourceable file that `run.sh` reads. `setup.sh` generates it; you can also edit it by hand. Example:

```bash
TOOLBOX_NAME="llama-vulkan-hanchen"
MODEL_PATH="$HOME/models/unsloth/Qwen3.8-Flash-Next-GGUF/Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf"
MMPROJ_PATH="$HOME/models/unsloth/Qwen3.8-Flash-Next-GGUF/mmproj-Qwen.Qwen3.8-Flash-Next.f16.gguf"
BIND_HOST="0.0.0.0"
PORT="1235"
API_KEY="sk-lm-..."
CTX_SIZE="180000"
PARALLEL_SLOTS="1"
FLASH_ATTN="on"
GPU_LAYERS="999"
LOAD_MODE="auto"
CACHE_TYPE_K="q8_0"
CACHE_TYPE_V="q8_0"
PLE_MODE="ssd"
PLE_FLAGS="--lazy-mode on"
MTP_ENABLED="true"
MTP_DRAFT_N="2"
MTP_DRAFT_MODEL="$HOME/models/unsloth/Qwen3.8-Flash-Next-GGUF/mtp-Qwen3.8-Flash-Next-Q4_K_M.gguf"
```

| Variable | Meaning |
|---|---|
| `TOOLBOX_NAME` | Container the server runs in (`llama-vulkan-laurentz` or `llama-vulkan-hanchen`) |
| `MODEL_PATH` | Main GGUF file (first shard for split models) |
| `MMPROJ_PATH` | Multimodal projector file, used when `VISION_ENABLED=true` |
| `BIND_HOST` / `PORT` / `API_KEY` | Where the server listens; `API_KEY` only applies when not on localhost |
| `CTX_SIZE` / `PARALLEL_SLOTS` | Context window and concurrent request slots |
| `FLASH_ATTN` / `GPU_LAYERS` / `LOAD_MODE` | Advanced: flash attention, layer offload, load mode |
| `CACHE_TYPE_K/V` | KV cache quantization (`q8_0` halves cache memory) |
| `PLE_MODE` / `PLE_FLAGS` | PLE table storage: `ssd` streams from disk, `resident` loads to RAM |
| `MTP_ENABLED` / `MTP_DRAFT_N` / `MTP_DRAFT_MODEL` | MTP speculative decoding |

## SSD streaming vs resident

The model's PLE n-gram table (~27-51 GB) is only looked up, never multiplied. It can live on SSD instead of RAM.

| Mode | Flag (hanchen) | Flag (laurentz) | VRAM savings | Decode impact |
|---|---|---|---|---|
| SSD streaming | `--lazy-mode on` | `--ngram-on-disk` | ~30 GB | -2-3 tok/s |
| Resident | (default) | (default) | 0 | baseline |

## llama-server flags

`run.sh` builds the llama-server command from config.sh. Here's what each flag does:

### Always set

| Flag | Config variable | What it does |
|---|---|---|
| `-m <path>` | `MODEL_PATH` | Path to the main GGUF model file |
| `-ngl 999` | `GPU_LAYERS` | Offload all layers to GPU (unified memory, so everything is "GPU") |
| `-fa on` | `FLASH_ATTN` | Flash attention — reduces KV cache memory, faster attention kernels |
| `-c <N>` | `CTX_SIZE` | Context window in tokens. 131072 (128k), 180000, or 262144 (262k) |
| `-lm auto` | `LOAD_MODE` | Model loading mode. `auto` = mmap where supported, falls back to eager |
| `--host <ip>` | `BIND_HOST` | `127.0.0.1` (localhost) or `0.0.0.0` (all interfaces) |
| `--port <N>` | `PORT` | TCP port to listen on (default 1235) |
| `-np <N>` | `PARALLEL_SLOTS` | Number of concurrent request slots. 1 = single user |
| `-ctk q8_0` | `CACHE_TYPE_K` | KV cache key dtype. Q8_0 halves cache memory vs f16 with negligible quality loss |
| `-ctv q8_0` | `CACHE_TYPE_V` | KV cache value dtype. Same as above |

### Conditional flags

| Flag | When | What it does |
|---|---|---|
| `-mm <path>` | `VISION_ENABLED=true` and mmproj file exists | Multimodal projector — enables image/video input |
| `--lazy-mode on` | `PLE_MODE=ssd` and toolbox is hanchen | Streams PLE n-gram rows from SSD on demand instead of loading into RAM |
| `--ngram-on-disk` | `PLE_MODE=ssd` and toolbox is laurentz | Same as above, laurentz fork's equivalent flag |
| `--ngram-direct-io` | PLE is ssd and toolbox is laurentz | Bypasses OS page cache for PLE reads (enabled by default in the fork) |
| `--ngram-io-threads 64` | PLE is ssd and toolbox is laurentz | Number of threads for reading PLE rows from disk |
| `--spec-type draft-mtp` | `MTP_ENABLED=true` | Enables MTP speculative decoding — drafts extra tokens per step |
| `--spec-draft-n-max <N>` | `MTP_ENABLED=true` | Number of tokens to draft per step (2 recommended) |
| `-md <path>` | `MTP_ENABLED=true` and draft model exists | Path to the MTP draft model GGUF |
| `--api-key <key>` | `API_KEY` set and bound off-localhost | Requires this key in all API requests |

### Example command (fully assembled)

```bash
# Unsloth model, SSD streaming, vision enabled, MTP K=2, network access
llama-server \
  -m ~/models/unsloth/Qwen3.8-Flash-Next-GGUF/Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf \
  -ngl 999 \
  -fa on \
  -c 180000 \
  -lm auto \
  --host 0.0.0.0 \
  --port 1235 \
  -np 1 \
  -ctk q8_0 \
  -ctv q8_0 \
  -mm ~/models/unsloth/Qwen3.8-Flash-Next-GGUF/mmproj-Qwen.Qwen3.8-Flash-Next.f16.gguf \
  --lazy-mode on \
  --spec-type draft-mtp \
  --spec-draft-n-max 2 \
  -md ~/models/unsloth/Qwen3.8-Flash-Next-GGUF/mtp-Qwen3.8-Flash-Next-Q4_K_M.gguf \
  --api-key sk-lm-xxxxxxxxxxxxxxxx
```
