# Research: CPU/GPU/NPU heterogeneous inference — landscape, engine matrix, policy architecture (v0.5)

- date: 2026-07-24
- agent: claudia-linux-20260724 (operator-directed research wave: 1 code-survey + 3 deep-research agents, adversarially cross-verified)
- packet: `heterogeneous-inference-landscape-research` (order 478, kind: research, status: done)
- consumers: orders 479–484 (spec + implementation packets filed same commit)
- operator intent: "auto-detect and run what's best for every scenario (long-running low-energy
  vs quick interactions vs max results) and support CPU/GPU/NPU transparently out of the box."

## 1. Where the stack is today (code survey)

- Host tier probe `detect_inference_tier()` (`crates/tillandsias-headless/src/main.rs:2931-2959`):
  macOS → hardcoded `"metal"`; else `nvidia-smi` → `gpu-cuda`, `rocminfo` → `gpu-rocm`, fallback `cpu`.
  CDI-absence downgrade at `effective_inference_tier()` (`:2969`), NVIDIA CDI probe at `:2986`.
- Container args `build_inference_run_args()` (`main.rs:3305-3355`): CUDA via CDI
  `--device nvidia.com/gpu=all`; ROCm via `--device /dev/kfd --device /dev/dri`; env
  `TILLANDSIAS_INFERENCE_TIER`.
- In-container re-probe + T0–T5 model tiers by RAM/VRAM: `images/inference/entrypoint.sh:119-124,184-194`;
  model-per-tier table is inline shell, not pluggable.
- Engine: ollama only (`spec:inference-container`, `spec:zen-default-with-ollama-analysis-pool`).
- Known flakiness already filed: order 168 (OOM/`--rm` deaths, fixed), Squid SSL-bump EOF
  (deferred pulls, tolerated), order 313 volume-ownership + proxy warm-up races.
- Adjacent open v0.5 packets this research COMPLEMENTS (not duplicates): 401 (macOS tier
  decision), 402 (WSL2 GPU probe), 406 (CUDA bring-up fat host), 408 (CDI auto-enable),
  409 (VM guest GPU userspace), 410 (ROCm passthrough research).
- Gaps confirmed: zero NPU awareness; no Intel GPU path; no Vulkan path; macOS "metal" tier is
  aspirational (enclave inference actually runs CPU-only in the VM); no energy/battery awareness.

## 2. NPU vendor landscape (mid-2026)

| Vendor | Kernel/node | Userspace | LLM runtime on Linux | Container | Maturity |
|---|---|---|---|---|---|
| AMD XDNA2 (Ryzen AI 300/Max/400) | `amdxdna` mainline 6.14, want ≥7.0; `/dev/accel/accel0`; FW ≥1.1.0.0 | XRT + xdna-driver shim | FastFlowLM (flm) via Lemonade Server 10.x; 256K ctx | PROVEN: `--device /dev/accel/accel0 --ulimit memlock=-1:-1`, udev perms, `iommu=pt`; community recipes | 3.5/5 |
| Intel NPU 3/4/5 | `intel_vpu` since 6.3; `/dev/accel/accelN` | linux-npu-driver (Level Zero + compiler), distro-packaged (Fedora!) | OpenVINO GenAI (INT4, ≤8K ctx, ≤8B) + upstream llama.cpp OpenVINO backend (2026-03) | OFFICIAL docs; OpenVINO images bundle driver; render group | 4/5 |
| Qualcomm Hexagon (X Elite/X2) | `fastrpc` (misc dev); QDA accel driver RFC unmerged | QAIRT proprietary, no Linux-laptop support | none (llama.cpp Hexagon = Android/WoA only) | n/a | 1/5 Linux |
| Apple ANE | macOS-private | Core ML only; MLX is GPU-only (wontfix ANE) | Metal GPU is the real path; ANE niche (whisper encoder) | Linux VMs never see Metal/ANE; podman 6.0 libkrun default → Venus/Vulkan GPU in VM at ~75–85% native | ANE 1.5/5; VM-GPU 3.5/5 |

Cross-cutting: DRM accel class (`/sys/class/accel/accel*`, char major 261) is the uniform Linux
enumeration surface (`device/uevent` `DRIVER=` field distinguishes `amdxdna`/`intel_vpu`).
Six in-tree accel drivers as of 7.x. Permissions convention `root:render 0660` is applied by
vendor udev rules, NOT guaranteed by distros — we must ship our own udev rule or degrade
gracefully. No cross-vendor CDI generator for NPUs exists (gap Tillandsias fills itself,
mirroring order 408's NVIDIA CDI work).

Key sources: https://docs.kernel.org/accel/amdxdna/amdnpu.html,
https://www.phoronix.com/news/AMD-Ryzen-AI-NPUs-Linux-LLMs,
https://lemonade-server.ai/flm_npu_linux.html, https://github.com/oresk/lemonade-npu-toolbox,
https://github.com/intel/linux-npu-driver,
https://github.com/openvinotoolkit/docker_ci/blob/master/docs/npu_accelerator.md,
https://github.com/ggml-org/llama.cpp/blob/master/docs/backend/OPENVINO.md,
https://github.com/apple/containerization/issues/480,
https://developers.redhat.com/articles/2025/06/05/how-we-improved-ai-inference-macos-podman-containers.

## 3. Engine matrix — the strategic conclusion

1. **ollama cannot use any NPU and has no roadmap to** (AMD #11199 closed-no-commit, Intel
   #5747/#8281 unanswered). Its vendored llama.cpp lags upstream; no speculative decoding;
   commercial pivot ($88M raise, closed GUI, cloud tiers). It survives as model-pull UX only.
2. **llama.cpp/llama-server is the correct default engine on every host class.** OpenAI +
   Anthropic-compatible API, built-in model router with LRU load/unload (replaces ollama model
   management), speculative decoding, freshest Vulkan, and NPUs land upstream as
   vendor-contributed backends (Hexagon 2025-10, OpenVINO 2026-03, CANN) — Intel NPU comes
   nearly free by betting on llama.cpp.
3. **Vulkan via `--device /dev/dri` is the universal near-zero-config Linux GPU path**
   (no ROCm/CUDA host stack needed; Mesa in image). ROCm-vs-Vulkan gap is now ~10%.
4. **NPUs and macOS want a host-native "sidecar" slot, not container citizenship**: MLX/Metal on
   Apple Silicon (container Venus caps ~75–85% of native; applehv default has NO GPU), FastFlowLM/
   Lemonade on XDNA2 (container recipes are community-grade; memlock/iommu footguns), OpenVINO on
   Intel NPU (containerizable but host-firmware/image lockstep), Hexagon on WoA. **NPUs are
   structurally unreachable from WSL2** (no CONFIG_DRM_ACCEL in WSL kernel) — Windows NPU
   support REQUIRES the sidecar pattern.
5. **RamaLama (containers org, MIT) is prior art for almost exactly our architecture** —
   hardware auto-detect, per-backend image variants (cuda/rocm/vulkan/intel-gpu), CDI-native,
   security-first defaults (`--network=none`, read-only). Mine it for patterns.
6. Hybrid phase-split (NPU prefill + iGPU decode) ships only on Windows (Ryzen AI OGA);
   Linux gets NPU-only flows. Phase-routing beats model-splitting; per-op splitting is
   research-only and explicitly out of scope (NEG-1).

Key sources: https://github.com/ggml-org/llama.cpp/issues/14377 (closed stale),
https://huggingface.co/blog/ggml-org/model-management-in-llamacpp,
https://ollama.com/blog/new-model-scheduling, https://github.com/containers/ramalama,
https://ryzenai.docs.amd.com/en/latest/linux.html ("Linux currently supports NPU only flow"),
https://github.com/microsoft/WSL/issues/40842,
https://knightli.com/en/2026/04/23/llama-cpp-gpu-benchmark-cuda-rocm-vulkan-scoreboard/.

## 4. Empirical grounding for policy (adversarially verified, 3-vote)

- **Decode is memory-bandwidth-bound** on shared-memory SoCs: all engines converge near
  `bandwidth / model_bytes`; NPU ≈ iGPU ≈ CPU in decode t/s (Lunar Lake NPU 18.55 vs iGPU
  ~19–24 t/s on the same 136.5 GB/s bus). CAVEAT: convergence requires a mature graph-compiled
  backend — immature NPU paths run 3–10× below roofline and BURN energy (hobbyist XDNA2 backend:
  4.1 t/s @ 16.2 J/tok vs Vulkan 43.8 t/s @ 0.95 J/tok). Hence PROBE-2/PROBE-5 below.
- **Prefill is compute-bound**: NPU/GPU crush CPU (llm.npu: >1000 t/s prefill, 22× faster,
  30× energy savings). But a big iGPU out-prefills a small NPU (Strix Halo 8060S ~880–1220 t/s
  vs NPU ~495 on 8B) — measure, don't assume.
- **NPU wins on watts where the stack is mature**: independent measurement (Notebookcheck,
  Ryzen AI 7 350, Gemma3:4B): NPU ≈25 W system vs ≈65 W CPU/iGPU at comparable t/s. Snapdragon
  RAG study: NPU 315 J/query vs CPU 1251 vs GPU 2051. Vendor "10×/67×" claims are NOT
  independently reproduced — never use vendor numbers as routing inputs (NEG-2).
- **Counter-example that justifies measuring**: Lunar Lake community data shows iGPU WINNING
  J/token (1.03 vs 1.17) because throughput offsets watts.
- **Sustained load**: phone-class SoCs lose ~50% throughput to thermals within two runs; NPUs
  hold near-zero-variance low-power throughput → `sustained` class prefers NPU.

Key sources: https://arxiv.org/abs/2501.14794 (HeteroLLM v1), https://arxiv.org/abs/2407.05858
(llm.npu), https://arxiv.org/html/2606.11257v1,
https://www.notebookcheck.net/Running-AI-locally-Acer-Swift-Go-16-AI-tested-with-Stable-Diffusion-ChatGPT-Gemma3-and-others.1173262.0.html,
https://github.com/ggml-org/llama.cpp/discussions/4167,
https://zenn.dev/jkudo/articles/ae85d7d099e672?locale=en, https://arxiv.org/abs/2603.23640.

## 5. Policy prior art distilled into our design rules

Surveyed: Core ML MLComputeUnits (constraint-set model, fp32 bars ANE), ONNX Runtime EP priority
lists + 1.22 device policies (`MAX_EFFICIENCY` "typically chooses NPU"), OpenVINO AUTO/HETERO
(dGPU>iGPU>CPU; **NPU excluded from AUTO's default list — must be explicit**; CPU-first-then-
migrate to hide accelerator warm-up), Windows ML (NPU="battery-efficient sustained", GPU=
throughput, CPU=fallback), NNAPI (`PREFER_LOW_POWER`/`PREFER_SUSTAINED_SPEED`), Android
Acceleration Service (empirical on-device microbenchmark → delegate choice), Gboard federated
learning (background work gated on idle+plugged-in). Nobody in the ollama/LM Studio ecosystem
ships battery-aware routing — **this is a genuine differentiator for the forge**.

Adopted patterns → requirement seeds for the spec packet (order 479):

- PROBE: enumerate CPU (flags/topology), GPUs (`/sys/class/drm` + vulkaninfo), NPUs
  (`/sys/class/accel` + driver name), memory-bandwidth class (SoC table + microbench refine);
  cache `capabilities.json`; **usable=false unless a mature graph-compiled engine exists**
  (PROBE-2); one-time ≤60 s microbenchmark per device×engine records prefill_tps/decode_tps/
  J-per-token (PROBE-3); sanity-check decode vs `bandwidth/model_bytes` roofline, flag <30% as
  degraded (PROBE-5); probe runs on HOST, router knows per-container device passthrough
  (PROBE-6).
- CLASS: `background` (J/token; preemptible), `interactive` (TTFT; default), `quality`
  (biggest fitting model), `sustained` (throttle-proof steady t/s).
- ROUTE: placements are ORDERED FALLBACK CHAINS, CPU tier-S terminates every chain; failures
  advance the chain, 3 strikes quarantines the device until re-probe; model tier must fit
  device-visible memory with ≥10% headroom; serve first request from resident small model while
  preferred loads (AUTO pattern); NPU batches use fixed-shape chunks.
- ADAPT: subscribe push signals — Linux UPower + PowerProfiles D-Bus `PropertiesChanged`
  (works with both power-profiles-daemon and Fedora tuned-ppd), macOS
  `NSProcessInfo` power/thermal notifications, Windows `EffectivePowerMode`; on battery/
  power-saver: suspend background (checkpointed), downgrade interactive, cap contexts within
  5 s; resume background only when AC ∧ thermal-nominal ∧ interactive-idle ≥60 s; self-tag
  engine processes (SCHED_IDLE / EcoQoS / QoS-background); expose `policy status` + pin
  override with auto-release hold semantics.
- NEG (do NOT build): per-op graph splitting (belongs in engines); vendor-TOPS-based routing;
  battery-draining idle model residency.

RAPL note: `/sys/class/powercap/.../energy_uj` is root-only since CVE-2020-8694 — batch the
privilege per the host sudo policy or skip energy measurement gracefully.

## 6. Risks / gating questions (carried into packets)

1. **FastFlowLM license**: MIT CLI + closed NPU kernels; README says "completely free for any
   use, including commercial" but secondary sources mention a revenue cap and the LICENSE file
   fetch 404'd. Two agents independently flagged it. GATE: read the shipped LICENSE before
   bundling; Lemonade itself is clean Apache-2.0.
2. **XRT host/container version coupling** (AMD) and firmware/compiler lockstep (Intel):
   no compat matrices exist; pin versions in image + probe `fw_version` at launch.
3. **Kernel floor**: XDNA2 LLM stack wants kernel ≥7.0 + linux-firmware ≥20260221; degrade to
   GPU/CPU chain on older hosts — never hard-require.
4. **ggml API-remoting on macOS** (95–100% native in-VM) is a tech preview with isolation
   caveats; revisit before preferring it over host-native sidecar.
5. **Enclave boundary**: host-native sidecars bypass the container enclave; they must register
   through the proxy with the same egress discipline (spec question for order 479, and the
   `forge_improvements_preserve_privacy_and_isolation_boundaries` invariant applies).

## 7. Packet map (filed this commit, all v0.5, release_target: forge-local-experts-milestone)

- 478 `heterogeneous-inference-landscape-research` (research, done) — this document.
- 479 `heterogeneous-inference-specs` (spec, ready) — openspec deltas: accel-capability-probe,
  inference-engine-slots, inference-policy-router; NPU rows for the inference-container tier
  table; sidecar/enclave boundary decision.
- 480 `accel-capability-probe` (implementation, ready) — structured probe replacing
  `detect_inference_tier()` string tier.
- 481 `npu-device-passthrough` (implementation, ready) — `/dev/accel` + render-group + memlock
  plumbing in `build_inference_run_args()` + entrypoint NPU detection.
- 482 `llama-server-engine-slot` (implementation, ready, multi-cycle) — llama-server as
  first-class engine beside ollama; Vulkan-first image variant.
- 483 `host-native-sidecar-endpoints` (implementation, ready, multi-cycle) — sidecar registry
  (macOS Metal/MLX, XDNA2 flm/Lemonade, Intel OpenVINO) behind the enclave proxy.
- 484 `inference-policy-router` (implementation, ready, multi-cycle) — workload classes,
  data-driven routing table, adaptive power/thermal signals.
