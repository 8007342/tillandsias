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

### 3. Hardware tier → model ladder (permissive licences only)

Operator ruling 2026-10-25: no model whose licence carries a revenue cap or
non-commercial term. Only permissive or open licences (Apache-2.0, MIT,
BSD, CreativeML OpenRAIL-M / OpenRAIL++-M, whose use restrictions carry no
revenue cap) may appear. The Stability AI Community Licence (SD-Turbo,
SD3.5) is removed.

Rows live in `images/imagegen/tiers.tsv` (declarative, read like
`tier-table.tsv`). The table is a LADDER, smallest first. Every host starts
at I0, whatever its hardware. The classifier computes the host's CEILING
tier from the accel envelope; it never starts above I0.

| Tier | Model | Licence | Default size / steps | Hardware needed to OFFER it |
|---|---|---|---|---|
| I0 (floor, every host) | SDXS-512-0.9 (0.3B one-step SD-class) | OpenRAIL++-M | 512², 1 step | any (esme, macneo included) |
| I1 | SDXL-Lightning 4-step | OpenRAIL++-M | 1024² (768² on CPU), 4 steps | VRAM ≥ 4 GB, or RAM ≥ 16 GB |
| I2 | FLUX.1-schnell q4_k + T5-XXL q4 | Apache-2.0 | 1024², 4 steps | VRAM ≥ 8 GB, or Apple unified ≥ 16 GB |
| I3 | FLUX.1-schnell q8_0 + T5-XXL q8 | Apache-2.0 | 1024², 4–8 steps | VRAM ≥ 16 GB, or Apple unified ≥ 32 GB |

I0 licence verified 2026-10-25 on the model card
https://huggingface.co/IDKiro/sdxs-512-0.9 (metadata `license: openrail++`,
no revenue cap). 1874-h9ns must also prove sd.cpp loads it; if it does not,
the I0 fallback is segmind/tiny-sd (CreativeML OpenRAIL-M, verified on
https://huggingface.co/segmind/tiny-sd), and then SD1.5 (CreativeML
OpenRAIL-M). Every other row's licence is re-verified on its model card by
1874-h9ns before its pin lands; a row whose licence cannot be confirmed is
not shipped.

Never shippable: SD-Turbo, SD3.5 Large/Medium (Stability Community Licence,
revenue cap), SDXL-Turbo, FLUX.1-dev, RMBG-1.4/2.0 (non-commercial).

Byte sizes stay inside `tiers.tsv` and the download manifest for the
approval dialog and disk accounting; they are never shown to the user by
the tool (section 5).

### 4. Result contract and output location

Images are generated exactly as the requesting agent asks: `width`,
`height`, `steps`, `seed`, `count` and `negative_prompt` are honoured as
given (rounded only to the engine's multiple-of-64 grid, and the rounding
is reported). The tier sets defaults only for fields the agent omits.

Output goes to a SHARED scratch directory, `/work/tmp/imagegen/`, mounted
read-write into both the `imagegen` container and the forge. It is
DESTROYED on forge teardown. The tool description, its result and the
forge instruction overlays say so in plain words: "This folder is deleted
when the forge shuts down. Copy or commit anything you want to keep." The
agent decides what to keep or commit; nothing is written into the project
tree by default. (`.tillandsias/generated` is no longer the default.)

`image.generate` returns exactly the 1871-47ex schema: `path`, `width`,
`height`, `has_alpha`, `thumbnail_path` (≤ 256 px), plus `model`,
`licence`, `tier`, `backend`, `seed`, `steps`, `elapsed_s`, `ephemeral:
true`, and `bigger_tier_offer` (section 5). No base64 anywhere in the
text result.

Request: `prompt` (required), `negative_prompt`, `width`, `height`, `seed`,
`steps`, `count` (≤ 4), `tier` (default: the smallest cached tier, I0 on
first use), `consent_token`.

### 5. Smallest first, one tier up at a time

1. Every request runs on the smallest tier available (I0 on first use). It
   never asks.
2. When the host's ceiling is above the tier just used, the result carries
   `bigger_tier_offer`: the next tier only (never a jump of two), a
   `consent_token`, and one curated `ask` sentence, e.g. "There are bigger
   models that give better results, but they are slower. Want to try the
   next one?" When that tier's files are not yet downloaded, the sentence
   is the honest one: "We only download the big files if you're OK waiting
   longer for better results."
3. User-facing text MUST NOT carry raw download sizes, gigabyte figures or
   second estimates. Numbers stay in structured fields the agent may log.
4. The agent shows `ask` to the user verbatim. On yes it re-calls with
   `tier` set to the offered tier and the `consent_token`; the token is
   host-minted, single-use, bound to the request hash, tier and lane, and
   expires in 10 minutes. A request for a tier above the last accepted one
   without a token returns `consent_required` with the same offer and does
   nothing else.
5. After the user accepts tier N, the next result offers tier N+1 if the
   ceiling allows, and so on.
6. Later: a large download may additionally be gated by the OS approval
   dialog, which shows sizes and a disk bar — see the parallel change
   `os-verified-approval-gates`. This change does not depend on it.

### Metered services

Only free Cloudflare and free GitHub are acceptable metered services. The
tool, its docs and agent overlays never recommend a hosted image API or
anything that could later cost money.

### 6. First use

First call: `ensure_image_exists("imagegen")` (announced as slow work), model
fetch with progress into `cache_root()/models/imagegen/<model>/` under a
per-model flock, sha256 verified, then generate. The first-call result
carries `first_use: true` and the elapsed build/fetch time. The engine
container is idle-reaped; the cache survives `--reset` like the LLM models.

### 7. Optional studio (ComfyUI)

Off by default; enabled per project. Shortlist:

Only tools with open licences (OSI or OpenRAIL without revenue caps) stay on
the list; this remains a later packet.

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
- CPU minutes per image on floor hosts → I0 is a one-step 512² model.
- Licence drift on model cards → licence recorded per row, checked at pin.
- Scratch output is lost on teardown → said in the tool description and
  every result (`ephemeral: true`).

## Resolved (operator rulings 2026-10-25)

- Q1 Output: shared `/work/tmp/imagegen/`, destroyed on teardown.
- Q2 Licences: permissive/open only; Stability Community rows removed.
- Q3 Consent: smallest first, one tier at a time, curated sentences, no
  sizes; 120 s / 2 GB thresholds removed.
- Q4 Studio: a later packet.
