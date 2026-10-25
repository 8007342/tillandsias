# Design — local-image-generation

## Context

See proposal SOURCE READ. Research sources (2026-10-25):
stable-diffusion.cpp README, releases and docs/flux.md
(github.com/leejet/stable-diffusion.cpp), its server PR #1037, and
github.com/skeeto/sdmcp (an MCP adaptor over the same endpoint).

## Goals / Non-Goals

Goals: one tool for three agents; every fleet substrate; zero questions on
the default path; one explicit question before a long run; models in the
reusable cache; results as files.

Non-goals: video models, training/LoRA fine-tuning, a human UI in the
default path (that is the studio, section 7).

## Decisions

### 1. Engine: stable-diffusion.cpp `sd-server`

MIT, one C++ binary, GGUF quantisation (q8_0, q4_0, q4_k, q3_k, q2_k),
backends CPU, CUDA, Vulkan, Metal, OpenCL, SYCL (HIP documented on Windows
only). Model families include SD1.x/Turbo, SDXL, SD3.5, FLUX.1, Chroma,
Qwen-Image; add-ons include ESRGAN upscaling, LoRA, ControlNet, TAESD.
Upstream tags are automated `master-<n>-<sha>` with no semver and the README
warns the CLI/API changes often — so the tag is pinned in
`images/image-pins.yaml` and bumped only by a packet that re-runs the
contract fixture. The server's OpenAI-style `POST /v1/images/generations`
returns `b64_json`; that base64 is decoded on the HOST side and written to a
file — it never reaches an agent (1871-47ex).

Alternatives: ComfyUI as the default (rejected: Python + PyTorch, multi-GB
image, GPL, CUDA-first; kept as the studio); ollama image models (not
cross-backend today); diffusers (PyTorch, no Metal-in-VM answer).

### 2. Where it runs

| Substrate | Lane | Backend |
|---|---|---|
| Linux NVIDIA | `imagegen` container, CDI device | CUDA (fallback Vulkan) |
| Linux AMD / Intel | `imagegen` container, `/dev/dri` | Vulkan (radv / anv) |
| Linux, no usable GPU | `imagegen` container | CPU (AVX2/AVX512) |
| Windows WSL2 | guest `imagegen` container | Vulkan via Dozen when the probe proves a real device, else CPU (same verdict as `fn wsl2_vulkan_verdict_from`) |
| macOS Apple Silicon | host-native helper (VM has no Metal) | Metal |

The engine choice consumes the existing accel probe; it adds no second GPU
probe. A lane whose backend does not place the model (the 917-zkge lesson:
a backend that is installed is not a backend that loads) falls back to CPU
and says so in the result's `backend` field.

The macOS helper is a pinned upstream Metal build, downloaded on first use
into the host cache with its sha256 checked, run by the tray as a loopback
child, reached from the VM by the same vsock path the MCP socket already
uses. NPU/Metal host helpers are an operator-approved pattern (open-it
browser direction).

### 3. Hardware tier → model table

Rows live in `images/imagegen/tiers.tsv` (declarative, read like
`tier-table.tsv`); first matching row wins, highest first.

| Tier | Host signal | Default model (fast) | Quality model (asks first) | Disk | Peak memory |
|---|---|---|---|---|---|
| I3 | GPU VRAM ≥ 16 GB, or Apple unified ≥ 32 GB | FLUX.1-schnell q8_0 + T5-XXL q8, 1024², 4 steps | SD3.5 Large q8, 1024², 28 steps | ~17 GB / ~9 GB | ~14 GB |
| I2 | VRAM 8–15 GB, or Apple ≥ 16 GB | FLUX.1-schnell q4_k + T5-XXL q4, 1024², 4 steps | FLUX.1-schnell q8_0, 1024², 8 steps | ~10 GB | ~8 GB |
| I1 | VRAM 4–7 GB, or CPU with RAM ≥ 16 GB | SDXL-Lightning 4-step q8, 1024² (768² on CPU) | FLUX.1-schnell q4_k, 1024², 4 steps | ~3.5 GB | ~5 GB |
| I0 | everything else (floor: esme, macneo) | SD-Turbo q8, 512², 1–2 steps | SDXL-Lightning q8, 768², 4 steps | ~1.3 GB | ~2.5 GB |

Licences (re-verified on each model card by 1874-h9ns before the pin
lands; a row whose licence cannot be confirmed is not shipped):

| Model | Licence | Shippable as default |
|---|---|---|
| FLUX.1-schnell, T5-XXL, CLIP-L | Apache-2.0 | yes |
| SDXL base / SDXL-Lightning | CreativeML OpenRAIL++-M (use restrictions) | yes, restrictions surfaced |
| SD-Turbo | Stability AI Community Licence (free < $1M revenue) | open question Q2 |
| SD3.5 Large / Medium | Stability AI Community Licence | quality-only, open question Q2 |
| SDXL-Turbo | historically SAI non-commercial | no |
| FLUX.1-dev | FLUX.1-dev Non-Commercial | no |
| RMBG-1.4 / 2.0 | CC BY-NC | no |

Sizes are upstream-published for FLUX GGUF (q8_0 ≈ 12.1 GB, q4_k ≈ 6.4 GB)
and estimates elsewhere; 1874-bair's fixture pins the measured numbers.
A CPU host at I1 gets 768² by default because SDXL at 1024² on CPU is
minutes per image.

### 4. Result contract

`image.generate` returns exactly the 1871-47ex schema: `path` (under the
project's `.tillandsias/generated/images/`, so it is visible to the agent and
git-ignorable), `width`, `height`, `has_alpha`, `thumbnail_path` (≤ 256 px),
plus `model`, `licence`, `tier`, `backend`, `seed`, `steps`, `elapsed_s`.
No base64 anywhere in the text result.

Request: `prompt` (required), `negative_prompt`, `width`, `height`, `seed`,
`count` (≤ 4), `quality` (`fast` default | `high`), `consent_token`.

### 5. Consent before a long run

1. The tool estimates wall time from the tier row's measured
   seconds-per-step-per-megapixel and whether the model is cached.
2. `fast` requests at the default model never ask.
3. A request that would (a) use the quality model, or (b) exceed 120 s
   estimated, or (c) download more than 2 GB not yet cached, returns
   `{"status":"consent_required","estimate_s":…,"download_gb":…,
   "model":…,"licence":…,"consent_token":…,"ask":"<one plain sentence>"}`
   and does nothing else.
4. The agent shows `ask` to the user verbatim. On yes it re-calls with
   `consent_token`; the token is single-use, bound to the request hash and
   lane, and expires in 10 minutes.
5. An agent cannot mint a token: the host mints it, and the token proves
   only that this exact request was presented. The forge instructions
   (CLAUDE/OpenCode/Codex overlays) state the user must be asked.

### 6. First use

First call: `ensure_image_exists("imagegen")` (announced as slow work), model
fetch with progress into `cache_root()/models/imagegen/<model>/` under a
per-model flock, sha256 verified, then generate. The first-call result
carries `first_use: true` and the elapsed build/fetch time. The engine
container is idle-reaped; the cache survives `--reset` like the LLM models.

### 7. Optional studio (ComfyUI)

Off by default; enabled per project. Shortlist:

1. ComfyUI (GPL-3.0) + ComfyUI-Manager (GPL-3.0) in our own Fedora-based
   `imagegen-studio` image — community images (`yanwk/comfyui-boot`,
   `ai-dock/comfyui`) are reference recipes, not bases.
2. Front-end: the stock ComfyUI frontend in a browser window via
   `browser.open`; SwarmUI (MIT) as the friendlier front-end over the same
   backend; InvokeAI (Apache-2.0) is the alternative if canvas inpainting
   is the main need. Krita AI Diffusion (GPL-3.0) for artists on the host.
3. Upscaling: Real-ESRGAN (BSD-3) — also native in sd.cpp, so it can join
   the default tool as `image.upscale` without the studio.
4. Background removal: rembg (MIT, u2net Apache-2.0) or BiRefNet (MIT).
   NOT RMBG-1.4/2.0 (non-commercial). Candidate for `image.remove_background`
   in the light tool.
5. Style consistency / asset sets: IP-Adapter (Apache-2.0; avoid the
   InsightFace face variants, non-commercial weights) and LoRA (licence of
   the base model); asset sheets = fixed seed + IP-Adapter reference + a
   grid layout node.

Models are shared with the light tool's cache where formats allow.

## Risks / Trade-offs

- Upstream API churn → pinned tag + contract fixture.
- CPU minutes per image on floor hosts → I0 default is a 1–2 step 512² model.
- Licence drift on model cards → licence recorded per row, checked at pin.
- Disk on small hosts → download size is part of the consent trigger.

## Open Questions

- Q1 Output location: project `.tillandsias/generated/images/` (assumed) vs a
  host-only cache.
- Q2 Stability Community Licence models (SD-Turbo default at I0, SD3.5 as
  I3 quality): acceptable, or keep only Apache/OpenRAIL rows (I0 would fall
  back to SD1.5-class OpenRAIL-M)?
- Q3 Consent threshold: 120 s / 2 GB, or different numbers?
- Q4 Studio scope for v0.6, or research-only until the light tool ships.
