# Proposal — macOS inference runs host-native by default; krunkit is the VM layer, not the inference path (2381-778w)

Status: **operator-approved direction, 2026-11-25; nothing is built.**

@trace order:2381-778w, order:2381-iy9u, order:2381-t39p, order:2381-rt4e, order:2381-tfna, order:2381-zueb, order:1921-kr7v, order:1653-77bt, order:1654-6me6, order:2094-65yz

## The ruling

The operator, in session on tlatoanis-macbook-air, 2026-11-25, after reading the research in
`plan/issues/macos-containers-and-apple-silicon-inference-research-2026-11-25.md`:

> "Excellent. I approve krunkit as the direction to follow, please triage it appropriately and relay to
> /list-agents macuahuitl-fedora these updates, make sure the specs and plan are updated accordingly. I
> approve your suggestions on what we should reconsider. As per the token limits, our fleet leader
> /list-agents macuahuitl-fedora is also planning on using small models to run babysitter jobs on the
> metal, and inside the containers, all of these need to be resource-aware and plan-aware, they all play
> together, and should compliment each other."

"Your suggestions on what we should reconsider" were the four items listed under What Changes below,
stated to the operator in the same session.

## Why

On macOS every model in the enclave runs on the guest CPU today. The Virtualization.framework guest has no
virtio-gpu (`plan/issues/macos-gpu-isolation-2026-10-28.md`). The one route to the Apple GPU, the host
vsock relay behind SLOT-6, is opt-in (`TILLANDSIAS_HOST_VSOCK_PORT`).

The 2026-11-25 research found three things:
1. No Mac container stack except libkrun/krunkit gives a Linux guest the GPU.
2. libkrun's own documentation says its GPU device weakens the VM boundary. Its near-native mode is a
   preview, "not multitenant safe", and accelerates only llama.cpp.
3. The runtimes that matter on Apple Silicon run host-native on Metal:
   - Ollama, whose MLX engine has been the default on macOS since 0.19, with concurrent serving since 0.40.17.
   - mlx-lm.
   - llama.cpp.
   - Apple's on-device Foundation Models.

The equivalent of "NPU in a container" on Linux and Windows is, on macOS, a host-native service that the
VM reaches over a narrow channel.

## What Changes

1. **krunkit stays the macOS VM direction** (1921-kr7v, approved 2026-10-29, reaffirmed). Its job is a
   better VM layer: free-page reclaim, one backbone across platforms, and a Rust-native VMM. It is **not**
   the inference path. Venus and API-remoting GPU into containers are deprioritised (1653-77bt, 1921-vk4i).
2. **Host-native inference becomes the macOS default** (2381-iy9u, spec SLOT-10). The tray runs and
   leases a host inference service and binds SLOT-6's sidecar to it. Forge containers keep
   `http://inference:11434` (SLOT-1). The 1654-6me6 Seatbelt helper becomes this service's sandbox.
3. **The service sits behind an allowlist** (2381-t39p, SLOT-10):
   - Only chat-completions and embeddings, only for approved models.
   - No pull, create or delete.
   - A per-VM credential, plus concurrency, token and context caps.
4. **Apple Foundation Models is an optional first tier** (2381-rt4e, SLOT-11) for classification, routing
   and short structured output. It falls back to the default host service when it is unavailable.
5. **Measure before choosing an engine** (2381-tfna): Ollama-MLX vs `mlx_lm.server` vs `llama-server` on
   this base M5, 16 GB.
6. **One budget for every model on a host** (2381-zueb). Host-service residency, in-guest models and the
   babysitter's judge are admitted against one memory budget, kept in `job-admission-queue` (2094-65yz). On a
   Mac the guest and the host service draw from one unified-memory pool. This spec references that rule
   and does not restate it.
7. **The babysitter's macOS host-judge row** (2094-65yz, `watchdog-judge-placement`): this ruling is the
   "operator ruling recorded for that platform" that row waits for. The judge uses the same sandboxed host
   service, and all its existing offline-proof conditions still apply.

## Out of scope

- The Neural Engine for third-party LLMs: measured well behind the GPU for decode.
- Apple `container`: the June rejection still holds.
- Docker Desktop and OrbStack.
- vllm-metal, unless concurrency becomes the bottleneck.
