# Qwen3.8-Flash-Next on AMD Strix Halo

Run Qwen3.8-Flash-Next (180B params, 6B active) on a single Strix Halo machine
with 128 GB unified memory.

## Quick start

```bash
./setup.sh    # interactive onboarding — asks a few questions, downloads what's missing
./run.sh      # start the server (foreground)
./stop.sh     # stop it from another terminal
```

`setup.sh` writes `config.sh`. Re-running it overwrites the config, **but your
existing API key is always kept** — your agents/clients keep working.

## Prerequisites

- AMD Strix Halo with 128 GB RAM and ~90 GB free disk for the model
- `toolbox` + `podman` (or `distrobox` on Ubuntu):
  - Fedora 42+: `sudo dnf install -y toolbox podman` (preinstalled on Workstation)
  - Ubuntu 24.04/26.04: `sudo add-apt-repository universe && sudo apt install -y podman-toolbox podman` (the toolbox binary is packaged as `podman-toolbox`; `distrobox` also works)
  - Arch: `sudo pacman -S --needed toolbox podman`
  - Or just run `./setup.sh` — it detects your distro and offers to install these
- `hf` CLI for model downloads — `setup.sh` offers to install it:
  ```bash
  curl -LsSf https://hf.co/cli/install.sh | bash
  ```
- Internet for the first model download and container build

## Models

| Model | Quant | Size | Container | MTP |
|---|---|---|---|---|
| agentionai | ROCmFP4 | ~88 GB | `llama-vulkan-laurentz` | Yes |
| unsloth | IQ4_XS | ~88 GB (3 shards) | `llama-vulkan-hanchen` | Yes |

Both support vision (images/video) and MTP speculative decoding. The server
runs inside one of two containers built locally from community llama.cpp
forks — `setup.sh` builds it for you (~20 min, once).

## What setup.sh asks you

1. Network binding (localhost or LAN, with API key)
2. Kernel boot params — it prints exact commands if yours need changing (reboot required, never touches your bootloader itself)
3. Model choice — and downloads it if missing
4. Vision on/off
5. PLE table on SSD or in RAM
6. Context size (128k / 180k / 262k)
7. MTP on/off
8. Parallel slots

## Want the details?

- [docs/how-it-works.md](docs/how-it-works.md) — explanations of the kernel
  params, every llama-server flag, SSD streaming vs RAM, and the config file
- [docs/troubleshooting.md](docs/troubleshooting.md) — vision, OOM, slow prefill, and other problems
- [toolboxes/](toolboxes/README.md) — the container images and how they're built

## Credits

- Container design and base Dockerfiles:
  [kyuz0/amd-strix-halo-toolboxes](https://github.com/kyuz0/amd-strix-halo-toolboxes)
- llama.cpp forks: [LaurentZuijdwijk](https://github.com/LaurentZuijdwijk/llama.cpp),
  [danielhanchen](https://github.com/danielhanchen/llama.cpp)
- Model quants by [agentionai](https://huggingface.co/agentionai) and
  [unsloth](https://huggingface.co/unsloth)

## License

MIT — see [LICENSE](LICENSE).
