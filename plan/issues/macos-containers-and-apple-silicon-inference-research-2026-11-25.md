# macOS containers and Apple Silicon inference: state of the art, 2026-11-25

@trace order:2381-778w, order:1921-kr7v, order:1653-77bt, order:1654-6me6, order:2094-65yz

Filed by tlatoanis-macbook-air (Claude) for the operator ruling recorded as 2381-778w. Two web-research
passes were made on 2026-11-25, plus a read of this repo. Versions were read from GitHub and crates.io
that day. **No benchmark below was run by us**: every number is a cited third party's, and vendor claims
are marked as such. This host is a base M5 with 16 GB on macOS 27.2.1; no source covers small models on
that exact machine (see 2381-tfna).

## 1. Linux containers on macOS

**Finding: nothing replaces "VZ VM + Podman inside" today.** The only GPU path into a Linux guest is
libkrun/krunkit (virtio-gpu). No source describes any Neural Engine path for a Linux guest. That is an
absence of evidence, not a documented statement.

| Option | Shape | State | GPU in a Linux container | Embeddable from Rust | Licence |
|---|---|---|---|---|---|
| Apple `container` + Containerization | one VZ VM per container, XPC daemon | `container` 1.7.1 (2026-11-06); library still 0.x, breaking changes every few weeks | none ([apple/container#1511](https://github.com/apple/container/issues/1511) open) | Swift only; young community crates | Apache-2.0 |
| Podman machine on libkrun | one shared VM via krunkit on HVF | Podman 6.2.1; libkrun is the Mac default since 6.0.0 | yes: Venus (Vulkan→MoltenVK→Metal); llama.cpp API remoting | CLI/REST | Apache-2.0 |
| libkrun directly | VMM as a library | 1.19.8 (2026-11-06); `main` is an unstable 2.0 | yes (virtio-gpu) | native Rust + C API (`libkrun` crate) | Apache-2.0 |
| Docker Desktop | shared VM; Model Runner runs engines **on the host** | mature | no | no | paid above 250 staff / $10M |
| OrbStack, Colima/Lima, Tart, UTM | shared VMs | various | only Lima's krunkit driver (experimental) | no | mixed |

Apple `container` facts that matter to us:
- Freed guest memory is not returned to macOS ([resource usage](https://github.com/apple/container/blob/main/docs/resource-usage.md)).
- Container-to-container networking needs macOS 26.
- No compose.
- Its "container machines" mode trades isolation away ([docs](https://github.com/apple/container/blob/main/docs/container-machine.md)).

The June rejection (`plan/archive/apple-containerization-evaluation-2026-06-14.md`) still holds.

libkrun/krunkit:
- **GPU speed, vendor-measured** ([Red Hat, Jun 2025](https://developers.redhat.com/articles/2025/06/05/how-we-improved-ai-inference-macos-podman-containers), [Red Hat, Sep 2025](https://developers.redhat.com/articles/2025/09/18/reach-native-speed-macos-llamacpp-container-inference); M4 Pro):
  - Venus reaches 74-80% of native Metal.
  - API remoting is "mostly on par" with native.
- **Costs:**
  - libkrun's own docs say "The VM boundary does not restrict host resources exposed through devices" ([security model](https://github.com/libkrun/libkrun/blob/main/docs/security-model.md)).
  - API remoting "isn't multitenant safe" and runs one container at a time.
  - API remoting accelerates only llama.cpp, and is documented for macOS 14-15 only ([VirtGPU.md](https://github.com/ggml-org/llama.cpp/blob/master/docs/backend/VirtGPU.md)).
- **Gain:** libkrun 1.19.8 returns free guest pages to the host on macOS.

## 2. Local inference on Apple Silicon

**Finding: on macOS inference has to run host-native on the Metal GPU.** Docker: "there is no GPU
passthrough for Metal in containers" ([Docker](https://www.docker.com/blog/docker-model-runner-vllm-metal-macos/)).

| Runtime | State | Notes |
|---|---|---|
| Ollama | 0.40.18 (2026-11-24) | MLX engine since 0.19, on by default on macOS arm64 for safetensors models; llama.cpp for GGUF; concurrent requests on Apple silicon since 0.40.17 ([releases](https://github.com/ollama/ollama/releases), [blog](https://ollama.com/blog/mlx)); this host has 0.40.16 |
| MLX / mlx-lm | mlx 0.32.5, mlx-lm 0.32.2 | `mlx_lm.server` is OpenAI-compatible, but "not recommended for production" and does only "basic security checks" ([SERVER.md](https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/SERVER.md)) |
| llama.cpp (Metal) | active | `llama-server` includes embeddings |
| Foundation Models | macOS 26+; `fm` CLI and Python SDK in macOS 27 | on-device ~3B; 8,192-token context; guided generation, tool calling; no embeddings API; needs Apple Intelligence enabled ([WWDC26](https://developer.apple.com/videos/play/wwdc2026/232/)) |
| Core AI / ANE | WWDC26 | ANE decode measured well behind the GPU; Core AI on the GPU ties MLX |

**M5 Neural Accelerators** (Apple's claim): time-to-first-token 3.3-4.1x faster than M4, generation only
19-27% faster ([Apple ML Research](https://machinelearning.apple.com/research/exploring-llms-mlx-m5)). The
gain is in prompt processing, which is what classification, summarising and embeddings mostly are.

**Third-party numbers** (one author, M4 Max, 4-bit, decode tok/s) ([apple-silicon-llm-bench](https://raw.githubusercontent.com/john-rocky/apple-silicon-llm-bench/main/LEADERBOARD.md)):

| Model | MLX | llama.cpp |
|---|---|---|
| Qwen2.5 0.5B | 528 | 301 |
| Qwen3.5 2B | 295 | 151 |
| Gemma 4 E4B | 111 | 81 |

Other comparisons conflict: Docker measured llama.cpp ahead of vllm-metal. Measure here before choosing.

**Security precedents for a host endpoint:**
- Ollama DNS-rebinding ([CVE-2024-28224](https://nvd.nist.gov/vuln/detail/CVE-2024-28224)).
- A 0.0.0.0-bound Ollama let a web page rewrite a chat template via `/api/create` ([THN, Aug 2026](https://thehackernews.com/2026/08/a-malicious-webpage-could-poison-your.html)).

## 3. What this repo had (read 2026-11-25)

- **macOS VM:** a Fedora 44 guest on Virtualization.framework (`crates/tillandsias-vm-layer/src/vz.rs`).
- **In-guest inference:** CPU only. The guest has no `/dev/dri` (`plan/issues/macos-gpu-isolation-2026-10-28.md`).
- **The one host route was opt-in:** `TILLANDSIAS_HOST_VSOCK_PORT`, relayed by `host_vsock_forward.rs`. The spec is SLOT-6 in `openspec/specs/inference-engine-slots/spec.md`.
- **Already filed and `ready`:**
  - 1921-kr7v (krunkit provider)
  - 1653-77bt (Metal vs Vulkan-in-krunkit decision)
  - 1654-6me6 (Seatbelt-sandboxed host Metal/ANE helper)
- **Babysitter design:** 2094-65yz places the macOS judge on guest CPU until "an operator ruling recorded for that platform".

## 4. Not verified

- Cold-start, idle memory and virtiofs throughput for any container option.
- Whether Ollama's MLX engine serves embedding models.
- Foundation Models' context on macOS 26, and whether it has any on-device rate limits.
- LM Studio's current terms.
- All Red Hat figures are image-only charts.
