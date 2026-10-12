# 482b evidence: the llama-server slot on lenovinha (2026-10-12)

Host: lenovinha, Fedora 44, kernel 7.2.7, podman rootless. GPUs: AMD Cezanne iGPU at
renderD128 (RADV RENOIR, Mesa 26.2.3 in the image) and NVIDIA RTX 3070 at renderD129.
These smoke runs passed devices to podman directly and never passed the NVIDIA CDI device, so llama-server saw only the iGPU. (CORRECTION: this host DOES have a CDI spec, ~/.config/cdi/nvidia.yaml and /var/run/cdi/nvidia.yaml, and the live tillandsias-inference has the RTX 3070. An earlier version of this file said there was none.) The image
was built from this branch as `localhost/482b-inference:test`. The operator's enclave
images and model cache were not touched; every run used a scratch models dir under /tmp.

| File | What it shows |
|---|---|
| `vulkan-cold-install-and-kill.txt` | Cold slot run, vulkan lane (see below). |
| `cpu-cold-install.txt` | Cold slot run, cpu lane (see below). |
| `vulkan-warm-healthy-then-kill.txt` | Warm vulkan run on the final tree: healthy case, then the supervision proof (see below). |
| `lane-fixtures.txt` | Every selection, closure, pin and digest verdict against fixtures. The same rules are pinned in litmus:inference-llama-server-lane-shape (5/5). |

**Cold vulkan run** (`vulkan-cold-install-and-kill.txt`): `TILLANDSIAS_INFERENCE_ENGINE=llama-server`, with renderD128 passed in.
- The payload was downloaded and its pin verified. Only core+vulkan was extracted out of cuda_v12, cuda_v13 and vulkan.
- `.engine-set` = `core+vulkan v0.34.0 sha256:cf958867…`, and the closure check passed with `GGML_BACKEND_PATH` naming `vulkan/libggml-vulkan.so`.
- The T0 GGUF was downloaded and verified against the pin (sha256 74a4da8c…, 491400032 bytes).
- `/api/version` returned 200 in 0.8 ms with `{"version":"llama-server 0.3.0-dev (build 1, commit 0f3a71be1)"}`. `/v1/models` and `/v1/chat/completions` answered through :11434.
- `kill -9` of llama-server: the container stopped in 164 ms with exit 137.

**Cold cpu run** (`cpu-cold-install.txt`): no render node passed, so `backend=cpu reason=no-render-node`.
- The payload installed the core set only (`backends=[core-only]`).
- Closure ok with no pin (`GGML_BACKEND_PATH` unset in llama-server's environment).
- `/api/version` 200 in 0.9 ms, and a completion was served.

**Warm vulkan run** (`vulkan-warm-healthy-then-kill.txt`):
- Ready in 2 s, with the cached GGUF re-verified.
- HEALTHY: `/api/version` 200 in 0.85 ms.
- The iGPU's VRAM use rose from 828 to 1286 MiB while serving (amdgpu `mem_info_vram_used`), i.e. the 491 MB Q4 model and its KV cache sit on the Radeon.
- KILL: `kill -9` of llama-server, then the container stopped in 105 ms with exit 137. No /api/version probe answered 200 after the kill. VRAM returned to 828 MiB.

STATED BOUND: once llama-server dies, /api/version stops answering 200 within 1 s. Measured: 105 ms and 164 ms. The supervisor stops caddy as soon as `wait -n` returns.

CONTROL for the kill run: an earlier run of the same script found no `pgrep` in the image, so it killed nothing. /api/version then answered 200 continuously for over 5 s, which is the healthy case with no kill. That run's script was fixed to scan /proc for the pid; its output is not kept as a separate file.

Throughput on this hardware, T0 at 0.5B, single request, outside the slot via the plain llama-server image: Vulkan on the iGPU 48.9 tok/s, CPU 77.1 tok/s. For a 0.5B model the 16-thread CPU beats the integrated GPU. Larger rows need 482-igky's pins first.

Not exercised here:
- CUDA through the slot was NOT exercised live. The runs never requested `TILLANDSIAS_INFERENCE_LLAMA_BACKEND=cuda` or passed the CDI device. The fixtures cover both refusals and the delivered-lane selection. A live cuda run on this host's RTX 3070 belongs to 482c. (Corrected: an earlier version wrongly said this host had no CDI spec.)
- Promotion of llama-server to the default: that is 482c.
