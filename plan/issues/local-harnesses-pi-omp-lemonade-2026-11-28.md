# Local harnesses: Pi and Oh My Pi on host Lemonade (2026-11-28)

**Scope.** Operator goal. Windows is led by doris, and macuahuitl-fedora orchestrates Linux and macOS parity.

**What it adds.** Two tray menus, "Pi" (`pi`, earendil-works/pi, formerly badlogic/pi-mono) and "Oh My Pi" (`omp`, can1357/oh-my-pi). Both run in a forge and use local models only. Those models are served by Lemonade Server on the host, and Ollama stays alongside it.

## Principles

- **Inference runs on the host.** The VM stays at 2–4 GB of RAM, and the host owns model memory. Research found no NPU passthrough into WSL2, and no supported ROCm or Vulkan path for APU iGPUs inside WSL. So Lemonade-in-VM (the Fedora RPM, or `ghcr.io/lemonade-sdk/lemonade-server`) is kept for CPU-only smoke tests and is not the product path.
- **Device priority is GPU > NPU > CPU.** These are measured on doris (bench, PR #1703). Vulkan beats the NPU at every size: 4B 26.5 vs 18.8 tok/s, 8B 14.8 vs 10.6, gpt-oss-20b 23.2 vs 10.3. The NPU is the second lane for small models and STT, where it keeps the GPU free. ROCm is never preferred: it was never faster and loaded 5–15x slower.
- **Lemonade adds to Ollama.** The enclave `inference` (Ollama) remains. Lemonade is an additional engine, chosen per host when it is present.
- **Forges never reach host localhost.** This is the `wsl2-isolation-boundary` cheatsheet rule. Inference goes over the existing host↔guest secure channel only.

## Transport: reuse the macOS host-native-inference relay

- **What exists.** `ControlMessage::SetVsockForwardTarget{cid,port}` (control-wire) makes the guest start `tillandsias-vsock-forwarder`. That forwarder takes the `inference` network alias, so forges keep `http://inference:<port>`. macOS sends the message today (`macos-tray/src/action_host.rs:630`), and the design is `openspec/changes/macos-host-native-inference`.
- **New on Windows.** An hvsocket listener in `tillandsias-windows-tray` relays to Lemonade on `127.0.0.1:13305`. It enforces the same allowlist as macOS:
  - only `POST /api/v1/chat/completions`, `/completions`, `/embeddings`, `/audio/*`, `/images/*`, plus `GET /api/v1/models`;
  - only approved models;
  - no pull, delete or load-unload of arbitrary models;
  - a per-VM credential and request and size caps.
- **Open decision: port and path.** The forwarder is named for Ollama's 11434. Lemonade gets its own alias and port (proposed `lemonade:13305`), so Ollama keeps `inference:11434` and both can be present.
- **Linux.** The host tray sends the same message to a local relay. **macOS.** The relay exists, but its upstream may be the Metal container instead of Lemonade (to be triaged).

## Harnesses

| | Pi | Oh My Pi |
|---|---|---|
| Install | `npm i -g --ignore-scripts @earendil-works/pi-coding-agent` (Node ≥ 22.19), pinned and checked twice the way the Copilot lane is (2063-nfag) | Prebuilt linux-x64 binary from the omp install, SHA-256 checked and pinned |
| Config | `$PI_CODING_AGENT_DIR/models.json` provider `lemonade`, `api: openai-completions` | `models.yml` provider `lemonade`, `discovery: {type: openai-models-list}`, `auth: none` |
| Models | No autodiscovery. The entrypoint writes `models.json` from `GET /api/v1/models` (labels `tool-calling`/`chat`, `context_length`), and `/model` reloads it | Autodiscovered |
| Offline | `PI_OFFLINE=1`, `enabledModels: ["lemonade/*"]`, no cloud keys | `disabledProviders` lists every cloud provider, `OTEL_SDK_DISABLED=true`, `OMP_SKIP_SETUP=1`. Update checks and crash reports are stopped by the proxy (no allowlist row) |

- **Wiring.** Follow the Copilot lane's three commits as the checklist:
  - host-shell `SelectedAgent` plus the `VERB_PI`/`VERB_OMP` rows, `resolve_project` suffixes and `agent_flag`;
  - headless `ForgeAgentMode::{Pi,OhMyPi}` with `--pi`/`--omp`, entrypoints, slugs and status events, and `ProviderId → None` (no Vault secret);
  - the three tray menus, `portable_smoke`, locales, command policy, litmus and the openspec change.
- **Proxy allowlist.** Add the npm registry for the install only. Add no cloud model hosts.

## Models: autodetect, recommend, and download on first use

- **Autodetect.** `GET /api/v1/models` returns `downloaded`, `labels`, `recipe`, `context_length` and `size`, and that is enough to rank models.
- **Recommend.** A small tracked catalog maps each role to a Lemonade id and its preferred device. Anything missing is offered on first use.
- **Download.** It is a **tray-side** action (`POST /api/v1/pull`, progress from `GET /api/v1/downloads`) and never goes through the forge relay. It reuses the first-use consent pattern (`imagegen_consent.rs`: a host-minted, single-use token tied to the tier). A model whose licence needs acceptance (gated FLUX non-commercial, LTX, Llama, Gemma terms) goes through the approval broker with an OS check. **Windows Hello is not implemented yet** and is its own packet; until it lands, gated licences stay manual.

### Lineup (leaning larger, as the operator asked)

★ = already on doris (2026-11-28).

| Role | Pick | Device | Size |
|---|---|---|---|
| Coding agent (default) | `Qwen3-Coder-30B-A3B-Instruct-GGUF` | GPU | 18.6 GB |
| Coding agent (large) | `Qwen3-Coder-Next-GGUF` | GPU | 48 GB |
| Reasoning + tools | ★ `gpt-oss-20b-mxfp4-GGUF` (GPU 23.2 tok/s); `gpt-oss-120b-mxfp-GGUF` large | GPU | 11.3 / 63.4 GB |
| General MoE + vision | ★ `qwen3.6-moe-35b-a3b-FLM` (NPU, 16.9 tok/s); `Qwen3.6-35B-A3B-GGUF` for GPU | NPU / GPU | 20.6 / 23.3 GB |
| Mid general | ★ `Qwen3-14B-GGUF` | GPU | 8 GB |
| Fast small | ★ `qwen3.5-9b-FLM`; `Qwen3-1.7B-NPU` (~40 tok/s) | NPU | 7.6 / 2.7 GB |
| Embeddings | ★ `nomic-embed-text-v1-GGUF`; `Qwen3-Embedding-4B-GGUF` + `bge-reranker-v2-m3-GGUF` | GPU / CPU | 0.07 / 4.9 GB |
| Speech-to-text | ★ `Whisper-Large-v3-Turbo`, ★ `whisper-v3-turbo-FLM` | NPU | 1.5 GB |
| Text-to-speech | ★ `kokoro-v1` (CPU); `OpenMOSS-TTS` | CPU / GPU | 0.35 / 12.5 GB |
| Images | ★ `Qwen-Image-2512-GGUF`, ★ `SDXL-Turbo`, ★ `SD-Turbo`; `Z-Image-Turbo`, `Flux-2-Klein-4B` (edit), `SDXL-Base-1.0` | GPU | 4.9–20.7 GB |
| Music | ★ `ACE-Step-Music` | GPU | 16.1 GB |
| Sound effects | ★ `ThinkSound-SFX`, ★ `MOSS-SoundEffect` | GPU | 10.4 / 6.6 GB |
| 3D | ★ `TRELLIS-3D` | GPU | 3.9 GB |
| Video | `Wan2.1-T2V-1.3B` (sd-cpp, Vulkan). Wan2.2 and LTX-2.x are ROCm-only (thenoise) | GPU | 8.8 GB |

**Not used:** ★ `Bonsai-8B-gguf` (a 1-bit quant; as an agent it gets weak tool calls), ★ `chatglm3-6b-NPU` and ★ `Qwen2.5-Coder-7B-Instruct-NPU` (superseded). The operator decides on deleting them.

## demon_attack pipelines on a local forge

demon_attack ran its asset pipelines locally, with ComfyUI workflows plus code (Blender, Go, Lua-to-MIDI). Lemonade v2026.48 covers most of them on this host's Vulkan:

| Pipeline | Lemonade on this host | Still needs |
|---|---|---|
| SDXL pixel art | `SDXL-Base-1.0` | The pixel-art LoRA, LayerDiffuse transparency, and LoRA support in sd-cpp (unverified) |
| Qwen-Image-Edit sprite variants | `Flux-2-Klein-4B` edit | The Edit-2511 + ControlNet / IP-Adapter workflow, which needs ComfyUI |
| ACE-Step music | ★ `ACE-Step-Music` (direct match) | Audio-to-audio (unverified) |
| Sound effects | ★ ThinkSound, ★ MOSS-SFX | n/a |
| Voice | ★ kokoro, OpenMOSS-TTS | VoxCPM2 and Dia, which are not in the catalog |
| Wan VACE in-betweens | `Wan2.1-1.3B` only | VACE keyframe conditioning, which needs ComfyUI and is ROCm-heavy |
| Blender rigs | n/a (code, CPU) | Runs in a forge as is |

**Verdict.** Text, music, SFX, TTS, STT, images and 3D can run locally through Lemonade now. Keyframe-conditioned video and the advanced image-edit workflows still need ComfyUI, either as a host-side runner behind the same relay or as follow-up work. **Generation jobs run one at a time:** demon_attack crashed when jobs shared VRAM, so the relay serializes heavy modalities.

## Orders (proposed, Windows-first)

1. **The relay.** The Windows hvsocket relay plus the `lemonade` alias and its allowlist. This is the transport and needs a security review.
2. **Pi.** The Pi lane: menu, flag, entrypoint, pinned install and `models.json` generator.
3. **Oh My Pi.** The omp lane: the same with discovery config.
4. **Downloads.** The model catalog plus a tray-side first-use pull with consent.
5. **Windows Hello.** The approval signer for gated licences.
6. **Parity.** Linux and macOS parity rows, orchestrated by macuahuitl.
7. **Pipelines.** A demon_attack-style local pipeline smoke covering image, TTS, music and 3D through the relay.
