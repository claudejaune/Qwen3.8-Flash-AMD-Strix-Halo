# Troubleshooting

Quick fixes first:

- **Container not found** — create it: `./setup.sh` or `./toolboxes/refresh.sh <name>` (see [toolboxes/README.md](../toolboxes/README.md)).
- **Model not found / incomplete** — download it: `./setup.sh` or `hf download` manually. For split GGUFs, `run.sh` checks every shard and lists exactly which ones are missing.
- **Port in use** — change `PORT` in config.env or stop the existing process: `./stop.sh`.

## mmproj / vision errors

If you get an error about `mmproj` not found or vision not working:

1. **Check `VISION_ENABLED` in config.env.** It must be `true` for vision to work. Re-run `./setup.sh` and enable vision in Step 3b. `run.sh` also warns at startup if vision is enabled but the file is missing.

2. **Check the mmproj file exists.** The paths differ by model:
   ```bash
   # agentionai model
   ls ~/models/agentionai/Qwen3.8-Flash-Next-ROCmFP4-FAST-imatrix-GGUF/mmproj/mmproj-Qwen3.8-Flash-Next-f16.gguf

   # unsloth model
   ls ~/models/unsloth/Qwen3.8-Flash-Next-GGUF/mmproj-Qwen.Qwen3.8-Flash-Next.f16.gguf
   ```

3. **Download it manually** if missing:
   ```bash
   # agentionai
   hf download agentionai/Qwen3.8-Flash-Next-ROCmFP4-FAST-imatrix-GGUF mmproj/mmproj-Qwen3.8-Flash-Next-f16.gguf --local-dir ~/models/agentionai/Qwen3.8-Flash-Next-ROCmFP4-FAST-imatrix-GGUF/

   # unsloth
   hf download unsloth/Qwen3.8-Flash-Next-GGUF mmproj-Qwen.Qwen3.8-Flash-Next.f16.gguf --local-dir ~/models/unsloth/Qwen3.8-Flash-Next-GGUF/
   ```

4. **Check MMPROJ_PATH in config.env** points to the correct file. Edit it manually if needed.

5. **Vision requests return text-only responses** — the server silently ignores images if mmproj wasn't loaded. Check the server startup log for `mmproj` lines.

## Slow prefill with SSD streaming

SSD streaming reads PLE rows on demand. If prefill is slow:
- Ensure the model is on a fast NVMe SSD, not a HDD or SATA SSD.
- For the hanchen toolbox, `--lazy-mode on` uses mmap. The `on-direct` mode (direct reads, bypassing page cache) gives 20-37% faster cold prefill but isn't available in this fork yet.
- For the laurentz toolbox, `--ngram-direct-io` (enabled by default) bypasses page cache.

## OOM / kernel hang

This model is large. If you run out of memory:
- Use SSD streaming (`PLE_MODE=ssd` in config.env) — saves ~30 GB.
- Use a smaller context size (128k instead of 262k).
- Ensure kernel params are set correctly (`amd_iommu=off`, `ttm.pages_limit=32505856`).
- Check `dmesg | grep -i oom` and `journalctl -k | grep NV_ERR`.

## MTP not working

- MTP requires the draft model file. Check `MTP_DRAFT_MODEL` in config.env exists. `run.sh` warns at startup if MTP is enabled but the draft model is missing.
- MTP is supported by both toolboxes (`llama-vulkan-laurentz` and `llama-vulkan-hanchen`).
- Set `MTP_ENABLED=true` and `MTP_DRAFT_N=2` in config.env.
