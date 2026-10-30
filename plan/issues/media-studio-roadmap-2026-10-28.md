# Media studio roadmap: local imagegen, ComfyUI studio, co-editing (story 1921)

- date: 2026-10-28
- host: macuahuitl (linux, NVIDIA RTX A5000 24 GB)
- story: 1921-9fa7 (ledger fragment `plan/index.d/20261029t011000z-1921-media-studio-roadmap-macuahuitl.yaml`)
- sources: five research reports, 2026-10-28 (kumbia-imagegen-pipeline, comfyui-local-secure,
  studio-coediting-roadmap, music-models, vision-models). The reports themselves were scratch and are
  not kept; this file is their distillation.
- licence rule (operator 2026-10-25): free licence only; no revenue or user cap; no non-commercial
  weights; no gated repos (the fetcher holds no token, per the no-plaintext-credentials ruling).

## Release map

| Release | desired_release | Scope | Existing rows reused | New rows (1921) |
|---|---|---|---|---|
| R1 local imagegen | v0.6 | `image.generate` on sd.cpp, tiers I0-I3, fetch by sha256, consent token | 1874-4b88 and children b9tg, bair, h9ns, kkrc, p8w7, qyfv, s2q3; 1871-47ex | qqfz gated FLUX source, h4gv licence register, xt97 HF CDN allowlist, 83bd transparent output |
| R2 ComfyUI studio | v0.7 | studio sibling on the generic launcher, music/SFX service, deterministic asset checks | 1860-auhm launcher, 1861-nmpp GrapesJS (second consumer), 1859-57mi picker, 1874-zry8 image, 1913-ebv8 slice | vkrr CUDA probe, 7aa5 node manifest, 2krx studio row, q7q3 memory budget, ju86 idle reap and teardown, x5dk preview spec and allowlist, 6kqv score schema and validator, 3mvy music-service, d2iw preview render, ga2q asset checker, 6is2 rectify tool; operator additions idyv launch verbs, 8up3 launch queue events, f5ty macOS reduced CPU studio, xkhw Venus Vulkan spike |
| R3 co-editing | v0.8 | comfyui MCP with a websocket event bridge, vision MCP, GPU lease arbiter, music models | 1862-1866 studio rows and publish, approvals 1879-5jkt, 1880-9wpd, 1883-c8xr, 1881-ynjn | vebq comfyui MCP and bridge, hih9 workflow persistence, nbxz arbitration and marker, s4bh vision MCP, yxki GPU arbiter, ynar music model spike |

1860-auhm, 1861-1866 and 1859-57mi keep their v0.5 target: they do not depend on imagegen, and R2
needs them to exist first.

Amended: 1874-zry8 now has a title without ComfyUI-Manager, because Manager installs code at runtime.
1861-nmpp was already amended on 2026-10-25 (operator ruling: Silex dropped; title, exit criteria and
closure name GrapesJS only, and `studio_options lists no Silex lane`). Only its immutable packet_id
still says silex. No further edit was needed. On 2026-10-29 the operator said Silex stays out for now while they re-check the ruling; a note event on 1861-nmpp records that.

No new polling: the studio idle reap is armed by router request events (ju86); ComfyUI progress
arrives over its websocket and goes onto the event stream (vebq); GPU lease grants and evictions are
events (yxki).

## Operator additions (2026-10-29)

- "Open this project in <tool>": a launch verb per registry row, listed to the agent and the user from the registry (1921-idyv).
- Expensive launches (cold build, model download) queue with events: queued, building, downloading with progress, ready, failed with retry_after; no polling (1921-8up3).
- macOS reduced mode: ComfyUI CPU-only in the VM, small models, static images (1921-f5ty); spike sd.cpp Vulkan via libkrun virtio-gpu Venus in the VM (1921-xkhw). Native host MPS stays pending an operator decision.
- The studio idle reap (1921-ju86) reuses 1799-haat (router last-request per route) and 1800-465n (idle reaper) instead of a new mechanism.

## Licence verdicts (verified 2026-10-28)

Read from Hugging Face API metadata (licence id and `gated` flag) and GitHub LICENSE files. For rows
excluded only by licence name (custom or NC), the gate alone is already enough to exclude them.

| Item | Licence | Gated | Verdict | Source |
|---|---|---|---|---|
| FLUX.1-schnell (black-forest-labs) | Apache-2.0 | yes (auto) | EXCLUDE upstream repo; ALLOW ungated mirror | huggingface.co/black-forest-labs/FLUX.1-schnell |
| FLUX.1-schnell GGUF mirrors (city96, second-state) | Apache-2.0 | no | ALLOW | huggingface.co/city96/FLUX.1-schnell-gguf |
| FLUX.1-dev | flux-1-dev-non-commercial | yes | EXCLUDE | huggingface.co/black-forest-labs/FLUX.1-dev |
| SDXL base 1.0 | openrail++ | no | ALLOW (use restrictions only) | huggingface.co/stabilityai/stable-diffusion-xl-base-1.0 |
| SDXL-Lightning | openrail++ | no | ALLOW | huggingface.co/ByteDance/SDXL-Lightning |
| SDXS-512-0.9 | openrail++ | no | ALLOW | huggingface.co/IDKiro/sdxs-512-0.9 |
| SD3 medium, SD3.5 large | stabilityai-ai-community | yes | EXCLUDE | huggingface.co/stabilityai/stable-diffusion-3.5-large |
| BiRefNet | MIT | no | ALLOW | huggingface.co/ZhengPeng7/BiRefNet |
| BRIA RMBG-1.4 / 2.0 | custom (bria-rmbg) | 1.4 no, 2.0 yes | EXCLUDE | huggingface.co/briaai/RMBG-2.0 |
| Qwen3-VL 2B/4B/8B/30B-A3B Instruct | Apache-2.0 | no | ALLOW | huggingface.co/Qwen/Qwen3-VL-4B-Instruct |
| Qwen2.5-VL-3B | qwen-research | no | EXCLUDE | huggingface.co/Qwen/Qwen2.5-VL-3B-Instruct |
| Qwen2.5-VL-7B | Apache-2.0 | no | ALLOW | huggingface.co/Qwen/Qwen2.5-VL-7B-Instruct |
| Qwen2.5-VL-72B | qwen (user cap) | no | EXCLUDE | huggingface.co/Qwen/Qwen2.5-VL-72B-Instruct |
| Florence-2 base/large | MIT | no | ALLOW | huggingface.co/microsoft/Florence-2-large |
| SigLIP2 base | Apache-2.0 | no | ALLOW | huggingface.co/google/siglip2-base-patch16-224 |
| DINOv2 small | Apache-2.0 | no | ALLOW | huggingface.co/facebook/dinov2-small |
| DINOv3 | dinov3-license | yes (manual) | EXCLUDE | huggingface.co/facebook/dinov3-vits16-pretrain-lvd1689m |
| SmolVLM2-2.2B | Apache-2.0 | no | ALLOW | huggingface.co/HuggingFaceTB/SmolVLM2-2.2B-Instruct |
| Gemma 3 4B | Gemma terms | yes (manual) | EXCLUDE | huggingface.co/google/gemma-3-4b-it |
| MiniCPM-V 2.6 | model licence (unverified) | yes | EXCLUDE | huggingface.co/openbmb/MiniCPM-V-2_6 |
| Anticipatory Music Transformer | Apache-2.0 (code and weights) | no | ALLOW | huggingface.co/stanford-crfm/music-medium-800k ; github.com/jthickstun/anticipation |
| Stable Audio Open 1.0 / Small | Stability community | yes | EXCLUDE | huggingface.co/stabilityai/stable-audio-open-1.0 |
| AudioLDM2 | CC-BY-NC-SA-4.0 | no | EXCLUDE | huggingface.co/cvssp/audioldm2 |
| AudioGen medium | CC-BY-NC-4.0 | no | EXCLUDE | huggingface.co/facebook/audiogen-medium |
| ZzFX | MIT | n/a | ALLOW | github.com/KilledByAPixel/ZzFX |
| jsfxr | Unlicense | n/a | ALLOW | github.com/chr15m/jsfxr |
| ComfyUI | GPL-3.0 | n/a | ALLOW (run unmodified as a separate container; ship the notice) | github.com/comfyanonymous/ComfyUI |
| Tone.js | MIT | n/a | ALLOW | github.com/Tonejs/Tone.js |
| FluidSynth | LGPL-2.1 | n/a | ALLOW (run as a process, not linked) | github.com/FluidSynth/fluidsynth |
| GeneralUser GS soundfont | custom permissive, commercial use allowed | n/a | ALLOW (default soundfont) | github.com/mrbumpy409/GeneralUser-GS (documentation/LICENSE.txt) |
| FluidR3_GM soundfont | not verified from a primary source | n/a | UNDECIDED, not default | none reached |

Changes from the reports' verdicts:
- FLUX.1-schnell went from OK to an excluded upstream repo, because that repo is gated. The ungated
  Apache-2.0 GGUF mirrors are allowed. Today `images/imagegen/tiers.tsv` rows I2 and I3 cite the
  gated repo: see 1921-qqfz. The VAE and T5 files need the same check.
- Stable Audio Open went from "usable, flag" to excluded, because it is gated.
- Gemma 3 went from "optional" to excluded, because it is gated.
- MiniCPM-V went from "optional, skip by default" to excluded, because it is gated.
- Everything else matched.

## Findings that shaped the packets

- The kumbia-kombat art used the coding agent's built-in cloud image tool. There is no script, the
  provider and cost are unrecorded, and the prompt is stored in a README. Transparency was asked for in
  words and came back with soft edge glow. No asset was ever downscaled to the native pixel grid.
  Every flaw was caught by eye, which is why a model-free checker (ga2q) comes before any vision model.
- Music is authored as data (score JSON schema v1 plus MIDI), not as recordings. A music tool should
  emit that schema (6kqv, 3mvy); models only propose variations, and a deterministic post-processor
  enforces key and tempo (ynar).
- Most asset rules are exact, so a VLM handles only subject, count, style and free questions. Counting
  uses masks or boxes first. Each verdict carries its method and the tier that produced it (s4bh).
- ComfyUI is realistically NVIDIA-only. Other hosts keep the sd.cpp default tool, and the studio is
  offered only after a 1-step placement proof (vkrr). On macOS a reduced CPU mode in the VM is filed (f5ty);
  host-native MPS needs an operator decision and is not filed.
- Custom nodes are arbitrary code. The image has no Manager and nodes are pinned by manifest (7aa5).
- The studio launch pattern already exists: `run_opencode_web_mode` (OTP session through
  `tillandsias_otp::issue_session`, a RouterRoute upsert, and the window opened after an authenticated
  2xx). The browser allowlist widens today only through `with_preview_tls_port` (x5dk).

## Open items not filed

- Kumbia provider, model and spend: ask the project owner (report item 10). This is not Tillandsias work.
- A cost ledger comparing local and cloud generation per accepted asset: file it once R1 measures
  seconds per tier.
- Character consistency with a LoRA or IP-Adapter: experiment after R2. Check each adapter's licence
  (InsightFace FaceID variants are excluded).
