# Qwen3.8-Flash-Next on AMD Strix Halo

Run Qwen3.8-Flash-Next (180B params, 6B active) on a single Strix Halo machine with 128 GB unified memory.

No prior experience with running local AI models needed. The scripts guide you through every step.

## Quick start

### Prerequisites

- AMD Strix Halo with 128 GB RAM and **100 GB free disk minimum** (120 GB recommended) for the model
- `toolbox` + `podman`:
  - Fedora 42+: `sudo dnf install -y toolbox podman` (preinstalled on Workstation)
  - Ubuntu 24.04/26.04: `sudo add-apt-repository universe && sudo apt install -y podman-toolbox podman` (the toolbox binary is packaged as `podman-toolbox`)
  - Arch: `sudo pacman -S --needed toolbox podman`

### Set up and run

Clone this repo and run `setup.sh`

```bash
git clone https://github.com/claudejaune/Qwen3.8-Flash-AMD-Strix-Halo
cd Qwen3.8-Flash-AMD-Strix-Halo
./setup.sh
```

That's it. The setup script will guide you through the installation and prepare everything for you.

Once everything is set up, start the server:

```bash
./run.sh      # start the server 
```

To stop the server, press Ctrl-c from the same terminal, or run `./stop.sh`.

After `git pull`, update toolboxes / model files if this repo changed them:

```bash
./refresh.sh
```

You can answer No to every prompt. If model paths in `config.env` change, a
timestamped backup is saved under `backups/`.

## Models

| Model | Quant | Size | Container | MTP |
|---|---|---|---|---|
| agentionai | ROCmFP4 | ~92 GB | `llama-vulkan-laurentz` | Yes |
| unsloth | IQ4_XS | ~92 GB (3 shards) | `llama-vulkan-hanchen` | Yes |

Both support MTP speculative decoding and (optionally) vision (images/video).

## What setup.sh asks you

1. Network binding: `localhost` or LAN (auto-generates API key if the latter)
2. Kernel boot params: prints exact commands if yours need changing (reboot required)
3. Model choice: auto downloads if missing
4. Vision on/off
5. PLE table in VRAM or on SSD (slightly slower but saves ~30 GB VRAM)
6. Context size (128k / 180k / 262k)
7. MTP on/off
8. Parallel slots (concurrent requests)

## Documentation

- [docs/how-it-works.md](docs/how-it-works.md) — explanations of the kernel
  params, every llama-server flag, SSD streaming vs RAM, the config file,
  and `refresh.sh`
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
