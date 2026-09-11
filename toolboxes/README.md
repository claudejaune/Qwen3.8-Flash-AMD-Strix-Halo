# Toolboxes

`llama-server` in this project runs inside one of two containers, built locally
from community llama.cpp forks:

| Container | llama.cpp source | What it enables |
|---|---|---|
| `llama-vulkan-laurentz` | [LaurentZuijdwijk/llama.cpp](https://github.com/LaurentZuijdwijk/llama.cpp) (`vulkan/qwen4exp-rocmfpx`) | ROCmFP4 GGUFs + PLE n-gram streaming. MTP is supported. |
| `llama-vulkan-hanchen` | [danielhanchen/llama.cpp](https://github.com/danielhanchen/llama.cpp) (`qwen4exp/mtp`) | Unsloth IQ4_XS GGUFs + PLE streaming. MTP is supported. |

Build one (~20 min first build, needs internet — the build clones the llama.cpp
fork):

```bash
./toolboxes/refresh-toolboxes.sh llama-vulkan-laurentz
./toolboxes/refresh-toolboxes.sh llama-vulkan-hanchen
```

After `git pull`, `./refresh.sh` at the repo root offers to run this for you
(and checks whether the recommended model files changed).

Pass `--no-cache` to force a full rebuild (fresh git clone + recompile);
without it, podman layer caching makes rebuilds fast but reuses the same code.

`setup.sh` offers to run this for you and only does so if the container
doesn't already exist.

## Credits

- Container design, base images and the original Dockerfiles:
  [kyuz0/amd-strix-halo-toolboxes](https://github.com/kyuz0/amd-strix-halo-toolboxes)
  (the `gguf-vram-estimator.py` helper from the originals is not included here)
- llama.cpp forks: [LaurentZuijdwijk](https://github.com/LaurentZuijdwijk/llama.cpp),
  [danielhanchen](https://github.com/danielhanchen/llama.cpp)
