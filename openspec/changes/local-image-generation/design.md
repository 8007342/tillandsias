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
`tier-table.tsv`). The table is ordered smallest first; I0 is the floor
every host can run and is fetched on first use unasked. The classifier
computes the host's CEILING tier from the accel envelope. Which tier a
call runs is decided by section 5 (operator ruling 2026-11-01): the highest
tier within the ceiling whose files are present or granted, not I0.

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
`steps`, `count` (≤ 4), `tier` (default: the highest tier within the
ceiling whose files are present or granted; any smaller tier may be named),
`consent_token`.

### 5. The consent gate is a one-time download gate per host

Operator ruling 2026-11-01 (on #825, rows 1957-5m8g and 1957-8hkf),
verbatim: "the bigger models gate should be asked only for downloading
models the first time ... there's no real reason to use the smaller
models". This replaces the 2026-10-25 "smallest first, one tier up at a
time" shape (Q3 below), which in the field (demon_attack-forge rounds 1+2)
cost every I1 picture an extra I0 run and a fresh prompt, and offered
tiers with nothing pinned. The gate protects the host's disk and link,
not image quality; it is not a quality ladder.

1. A tier is AVAILABLE when its pinned files are on this computer, or
   their download was granted on this host. I0 is always available: it is
   fetched on first use unasked, as before, so a fresh host can make a
   first picture.
2. A tierless call runs the highest available tier within the host
   ceiling (I0 only when nothing above it is available). There is no ladder
   walk and no session grant to re-earn.
3. Any tier up to the ceiling may be requested directly by name (I3 on a
   host holding only I0 asks for I3, not I1). Smaller tiers stay available
   by name.
4. Only a tier whose files are missing asks, and only once per host: the
   call returns `consent_required` carrying a download offer — `tier`,
   `model`, `download_bytes`, `ask`, `consent_token`, `how`,
   `expires_in_s` — and runs nothing. The `ask` states the cost honestly
   (1957-8hkf): "This model is not on this computer yet: it needs a
   one-time download of N.N GB (about M min) and that much disk. Download
   it?" GB comes from the pinned sizes, minutes from an assumed link rate
   until one is measured.
5. The agent shows `ask` verbatim. On yes it re-calls with the same
   prompt, `tier` and the `consent_token`; the token is host-minted,
   single-use, bound to the request hash, tier and lane, and expires in
   10 minutes. Redeeming it records a standing HOST grant for that tier's
   download (`grant: {tier, kind: download, scope: host, expiry: none,
   expiry_enforced: false}`, named in the result); that tier never asks
   again on this host. Approvals are standing; no expiry is enforced yet.
6. A result at a tier below the ceiling may still carry
   `bigger_tier_offer`: the next INSTALLABLE tier above everything already
   present, as the same download offer, or null when nothing above needs
   fetching. A tier with no pinned files is never offered, and a direct
   request for it fails `tier_unavailable` (1957-8hkf).
7. Later: a large download may additionally be gated by the OS approval
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
- Q3 Consent (2026-10-25): smallest first, one tier at a time, curated
  sentences, no sizes; 120 s / 2 GB thresholds removed. SUPERSEDED by the
  operator ruling 2026-11-01 (#825, 1957-5m8g): a one-time per-host
  download gate, any tier directly, the ask carries GB and minutes
  (section 5).
- Q4 Studio: a later packet.
