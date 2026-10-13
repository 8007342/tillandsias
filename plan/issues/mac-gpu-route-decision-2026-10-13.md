# Mac GPU route decision record — Venus Vulkan in a VM vs Metal on the host

Order 1653-77bt, filed 2026-10-13. This is the first step of the operator-approved direction "confined host helpers for Metal and the Neural Engine": SLOT-6 of `openspec/specs/inference-engine-slots`, and packet 483 (`host-native-sidecar-endpoints`).

The question: before building a host helper, is the in-VM route good enough? That route is libkrun/krunkit's virtio-gpu Venus, which is Vulkan forwarded to MoltenVK on the host and needs no host-side inference process at all.

## Recommendation

**Build the Metal host helper (packet 483). Do not adopt Venus as the Mac route.**

1. **Prefill is 2.7x faster on Metal** (1,308 vs 477 t/s). Prefill is the cost an agent pays on every turn, because each turn resubmits a long prompt. An 8,000-token prompt takes about 6 s on Metal and about 17 s through Venus.
2. **The Venus route holds about twice the RAM** for the same model: 4.4 GiB resident for the VMM, against 2.3 GiB for the host server. The weights live once in the guest and again as host-side GPU buffers. On a 16 GiB Mac that is the difference between fitting a second model and not.
3. **Venus needs a VMM switch.** The Tillandsias guest runs on Apple's Virtualization.framework (`crates/tillandsias-vm-layer/src/vz.rs`), not on libkrun. Venus is a libkrun/krunkit device. Taking this route means re-platforming the macOS VM, plus a third-party Homebrew tap that the operator has to trust.
4. **Decode is close to parity** (51.5 vs 55.0 t/s, 94%). Venus is a credible fallback if the VMM ever moves to libkrun for other reasons. It is not a reason to move it.

This record does not cover the Neural Engine: llama.cpp does not use the ANE, and an ANE path (Core ML) is a separate measurement.

## Numbers

Host: tlatoanis-macbook-air, Apple M5, 16 GiB, 10 cores, macOS (Darwin 27.0). Model: qwen2.5:3b, Q4_K_M, the same GGUF file on every route (ollama blob `sha256-5ee4f07c…`, 1.93 GB).

The workload is one ~1,030-token prompt (a varied prefix, prompt cache off) followed by exactly 128 decoded tokens (EOS ignored), at temperature 0 with seed 42. One warm-up request precedes 5 measured runs; CPU controls ran 3 times. The figures come from llama-server's own `/completion` timings.

| Route | Engine | Prefill t/s, median (min–max) | Decode t/s, median (min–max) |
|---|---|---|---|
| **Metal, host** | ollama 0.40.1's bundled llama-server (build 11351), `-ngl 99` | **1307.9** (1220.1–1314.8) | **55.0** (54.9–55.2) |
| **Venus, krunkit guest** | RamaLama image `quay.io/ramalama/ramalama@sha256:d60dfda3…` llama-server, Vulkan0 = "Virtio-GPU Venus (Apple M5)", `-ngl 99` | **477.2** (461.1–489.1) | **51.5** (50.7–51.9) |
| CPU control, host | same as Metal, `-ngl 0` | 78.0 (76.8–81.2) | 28.4 (27.5–29.1) |
| CPU control, guest (4 vCPU) | same image, `-ngl 0` | 84.1 (82.7–87.7) | 30.9 (30.3–31.4) |
| ollama API, host (Metal) | ollama 0.40.1 `/api/generate`, decode until EOS (~90 tok) | 1283.5 (1233.7–1284.9) | 55.7 (55.7–56.0) |

Both GPU routes are confirmed to be on the GPU by their own controls: prefill is 17x faster than the host's CPU-only run on Metal, and 5.7x faster than the guest's on Venus. The ollama API row agrees with the bare llama-server row, so the helper can wrap either one without paying a speed cost.

### Memory, with the model loaded

| Route | Measure |
|---|---|
| Metal (host llama-server) | RSS 2,341 MiB (the model is mmapped); `phys_footprint` 433 MB (peak 469) |
| Venus | krunkit RSS 4,487 MiB (`phys_footprint` reports 10 GB, which counts the 8 GiB guest reservation); gvproxy 38 MiB; guest `free`: 836 MiB used plus 3,236 MiB page cache; the container 317 MB |

### Setup cost

| | Metal host helper | Venus guest |
|---|---|---|
| Install | none beyond the engine (ollama is already installed on this host) | `brew trust libkrun/krun` plus krunkit 1.3.2 with gvproxy, libepoxy, libkrunfw, molten-vk (83 MB), virglrenderer-krun and libkrun: about 140 MB |
| Download | the model (1.8 GB; 103 s here) | the model, plus the machine image (65 s `machine init`, 7.9 GB on disk), plus the 1.02 GB image (27 s) |
| Cold start to serving | 0.55 s model load (ollama `load_duration`) | 10 s machine start, then 4 s to llama-server ready |
| Isolation work still owed | the Seatbelt profile, a loopback/unix-socket-only bind, and the SLOT-6 proxy registration | the VM is the sandbox, but this is a new VMM for Tillandsias |

## Caveats

- The llama.cpp builds differ: ollama's bundled build against RamaLama's image build. Both use the same model file and flags, and the CPU controls (78 vs 84 t/s prefill) show the builds are comparable on CPU. The GPU gap is the backend, not the build.
- One host, one model size. A larger model would raise the RAM-duplication cost in absolute terms. The prefill ratio should be re-measured for a 7B model before it is quoted as general.
- The Venus device advertises Vulkan 1.2 through MoltenVK. llama.cpp's Vulkan backend may close part of the prefill gap as it matures. That is worth re-running on a krunkit or llama.cpp upgrade, not waiting for.

## Reproduce

All state lives under `./target/work/1653-77bt` (gitignored). The operator's VM, the installed app and the default podman machine were not touched; the podman config and data dirs are redirected.

```bash
W=$PWD/target/work/1653-77bt
# Metal
OLLAMA_HOST=127.0.0.1:11500 OLLAMA_MODELS=$W/ollama-models ollama serve &   # then: ollama pull qwen2.5:3b
/opt/homebrew/Cellar/ollama/0.40.1/libexec/lib/ollama/llama-server -m $W/qwen2.5-3b-q4_k_m.gguf -ngl 99 -c 4096 --host 127.0.0.1 --port 11510 &
tillandsias-plan script run plan/evidence/mac-gpu-route-20261013/bench-llama-server.lua -- 127.0.0.1:11510 5 metal-host
# Venus
export XDG_CONFIG_HOME=$W/podman-config XDG_DATA_HOME=$W/podman-data CONTAINERS_MACHINE_PROVIDER=libkrun
podman machine init --cpus 4 --memory 8192 --disk-size 30 tgpu-scratch && podman machine start tgpu-scratch
podman run -d --device /dev/dri -e GGML_VK_VISIBLE_DEVICES=0 -v <gguf>:/models/qwen.gguf:ro -p 127.0.0.1:11520:8080 \
  quay.io/ramalama/ramalama:latest llama-server -m /models/qwen.gguf -ngl 99 -c 4096 --host 0.0.0.0 --port 8080
tillandsias-plan script run plan/evidence/mac-gpu-route-20261013/bench-llama-server.lua -- 127.0.0.1:11520 5 venus-guest
```

`GGML_VK_VISIBLE_DEVICES=0` matters: the guest also exposes llvmpipe, a CPU Vulkan device.

The harnesses and the raw run output are in `plan/evidence/mac-gpu-route-20261013/`.
