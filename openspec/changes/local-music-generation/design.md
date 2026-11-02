# Design — local-music-generation

Order `1969-sxzc`. Research date 2026-11-02. Every licence, size and speed
claim below cites the official model card or repository it was read from;
a claim read only from a mirror, aggregator or search snippet is marked
**UNVERIFIED** and must be re-read on the official page before a row is
pinned. Archive links were resolved on 2026-11-02 through
`web.archive.org/web/2026/<url>`.

Operator rulings this design obeys: permissive licences (Apache-2.0, MIT,
BSD, CreativeML OpenRAIL-M, OpenRAIL family) are shippable; anything else
(non-commercial, share-alike, revenue-capped, custom) only behind a durable
user acknowledgement (`accept-licence`, 1956-ecpb), never bundled; the
operator approves every new licence; the operator's own non-sale projects
have a standing approval to use free models including non-commercial ones,
but each licence is still listed honestly.

## 1. Symbolic (MIDI / ABC) models — fit the MIDI synthesizer

| Model | Code licence | Weights licence | Size | Architecture | Conditioning | Output | Runtime |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Anticipatory Music Transformer (Stanford CRFM) | Apache-2.0 (README) | Apache-2.0 (HF card tag) | `music-medium-800k`, 360M params | GPT-style causal LM over custom event tokens (HF `AutoModelForCausalLM`) | time range; `inputs=history` (continuation); `controls=melody` (accompaniment/infilling); instrument extraction | MIDI | PyTorch; README loads `.cuda()`; CPU plausible at 360M (not measured) |
| Text2midi (AMAAI Lab) | MIT (GitHub) | Apache-2.0 (HF card tag) | ~1.06 GB repo (UNVERIFIED, search snippet); params not stated | FLAN-T5 encoder + REMI decoder (custom) | free-text caption (key, tempo, chords, style, mood) | MIDI (REMI tokens) | PyTorch, CUDA/MPS/CPU; no infilling |
| ChatMusician (m-a-p) | UNVERIFIED (GitHub page 404 on fetch) | MIT (HF card) | 7B LLaMA-2; ~14 GB fp16; third-party GGUF Q4_K_M ~4.1 GB (UNVERIFIED, mirror `MaziyarPanahi/ChatMusician-GGUF`) | plain decoder-only text LLM | text instruction; ABC continuation as prompt text | ABC notation (needs `abc2midi`) | llama.cpp / **ollama-servable** |
| NotaGen | not checked | MIT (HF card) | 110M / 244M / 516M | hierarchical patch + character model (custom) | period / composer / instrumentation | ABC-style classical score | PyTorch; no infilling |
| MIDI-GPT (Metacreation Lab) | MIT (README) | **Metacreation Non-Commercial Research License** (README: "pretrained weights are not covered by the MIT License") | four checkpoints (`yellow_small`, `yellow_medium`, `prism_medium`, `expressive_medium`), params not stated | custom multi-track transformer | bar- and track-level infilling (`TrackPrompt(bars=[...])`, `ignore=True`), note density, polyphony, duration attributes | MIDI | PyTorch, CPU default, `--device cuda`/`mps`; HTTP server included |
| Aria (EleutherAI) | Apache-2.0 (README, "models and MIDI tooling") | Apache-2.0 (same sentence, not separated) | Llama-3.2-1B-class | custom MIDI tokens | prompt MIDI + duration (continuation only; piano-centric) | MIDI | PyTorch CUDA or MLX |
| MIDI-LLM (`slseanwu/MIDI-LLM_Llama-3.2-1B`) | UNVERIFIED | Llama 3.2 Community License (UNVERIFIED, mirror) | ~1B | Llama 3.2 with MIDI-token vocabulary | text → MIDI | MIDI | PyTorch; GGUF plausible, none found |
| MusicLang predict | GPL-3.0 (README) | custom; README says commercial use requires contacting the developers | not stated | Llama-2-shaped with custom tokens | chords per bar, time signature, continuation | MIDI | CPU-friendly |
| Moonbeam | UNVERIFIED | UNVERIFIED (CC BY-SA 4.0 seen on an aggregator, likely the paper's licence) | ~309M / ~839M (paper) | Llama-style, custom embedding | continuation / infilling (paper) | MIDI | PyTorch |
| SkyTNT midi-model | Apache-2.0 (repo) | not stated | not stated | event transformer | continuation, editing (demo) | MIDI | PyTorch + ONNX export scripts |
| Multitrack Music Transformer | MIT | unknown | not stated | research code (2023) | — | MIDI | skip |

Sources: <https://github.com/jthickstun/anticipation>
(archived <https://web.archive.org/web/20260303042359/https://github.com/jthickstun/anticipation>),
<https://huggingface.co/stanford-crfm/music-medium-800k>
(archived <https://web.archive.org/web/20261006142653/https://huggingface.co/stanford-crfm/music-medium-800k>),
<https://huggingface.co/amaai-lab/text2midi>
(archived <https://web.archive.org/web/20261005152024/https://huggingface.co/amaai-lab/text2midi>),
<https://huggingface.co/m-a-p/ChatMusician>
(archived <https://web.archive.org/web/20260518105650/https://huggingface.co/m-a-p/ChatMusician>),
<https://huggingface.co/ElectricAlexis/NotaGen>,
<https://github.com/Metacreation-Lab/MIDI-GPT> (no Wayback snapshot on 2026-11-02),
<https://github.com/loubbrad/aria>, <https://github.com/MusicLang/musiclang_predict>,
<https://github.com/SkyTNT/midi-model>, <https://github.com/salu133445/mmt>.

Not found on ollama.com's library: any ABC or MIDI model (checked by the
research agent through search only — UNVERIFIED; re-check at pin time).

### Symbolic verdict

- **Continuation and infilling (the adaptive feature) with a permissive
  licence**: Anticipatory Music Transformer. 360M params, Apache-2.0 on both
  sides, `generate(model, start, end, inputs=history, controls=melody)` is
  exactly "write the other layers around this melody for bars N..M".
- **Text prompt → MIDI**: Text2midi (Apache-2.0 weights, MIT code).
- **Through the existing ollama endpoint, no engine image**: ChatMusician
  GGUF (MIT weights). Quality caveat from the authors: bias toward Irish
  folk tunes, hallucinations; output is ABC and needs `abc2midi` (abcMIDI,
  GPL-2.0, as a tool in the forge image only, never linked into the tray).
- **Best infilling but non-commercial**: MIDI-GPT. Listed for the operator's
  own non-sale projects under the standing approval; never pinned in a
  shippable tier.

## 2. Audio (WAV) models — full tracks and stems from text

| Model | Code licence | Weights licence | Size / VRAM | Speed (documented) | Output | Conditioning | Runtime |
| --- | --- | --- | --- | --- | --- | --- | --- |
| **ACE-Step 1.5 / 1.5 XL** (ace-step) | MIT (repo) | MIT (HF card "License: [MIT]") | DiT 2B (turbo/sft) or 4B (XL); LM planner 0.6B/1.7B/4B (Qwen3). Repo tiers: ≤6 GB (2B turbo, INT8, CPU offload), 8–16 GB (2B + 0.6B/1.7B LM), 20–24 GB (XL turbo/sft + 1.7B LM, no offload), ≥24 GB (XL sft/base + 4B LM) | "under 2 seconds per full song on an A100 and under 10 seconds on an RTX 3090"; "0.5 s to 10 s on A100 depending on think mode & diffusion steps" | full songs 10 s – 10 min; sample rate not stated on the pages read (48 kHz stereo UNVERIFIED, HF Space) | text, lyrics (50+ languages), cover, **repaint/edit**, reference audio, **extract / lego (stem-wise) / complete (base model only)**, Vocal2BGM; metadata control for **duration, BPM, key/scale, time signature**; LoRA training | PyTorch; "CUDA GPU recommended (also supports MPS / ROCm / Intel XPU / CPU)"; community GGUF engine `acestep.cpp` (UNVERIFIED, HF Space credit); ComfyUI nodes |
| Stable Audio Open 1.0 (Stability AI) | stable-audio-tools MIT | **Stability AI Community License** (free under USD 1M annual revenue; above that a licence "Stability AI may grant in its sole discretion"; "Powered by Stability AI" attribution) | 1.2B params (card says 1B class); VRAM not stated (≈6–8 GB fp16 in practice, UNVERIFIED) | not stated | up to 47 s, 44.1 kHz stereo | text; timing (`seconds_total`); init-audio/inpainting via stable-audio-tools (UNVERIFIED) | PyTorch (stable-audio-tools); ComfyUI nodes exist (UNVERIFIED) |
| Stable Audio Open Small | as above | Stability AI Community License | 0.5B | 8 diffusion steps in the card example, no timing stated; card links an Arm CPU optimisation guide | up to 11 s, 44.1 kHz stereo | text, `seconds_total` | PyTorch; Arm CPU path documented |
| MusicGen / AudioCraft (Meta): musicgen-small/medium/large, melody, stereo, MusicGen-Style, JASCO, MAGNeT | MIT (repo) | **CC-BY-NC 4.0** (repo and HF card) | 300M / 1.5B / 3.3B | not on the pages read; community figure ≈1.5–2× realtime for large on a 24 GB card (UNVERIFIED) | 32 kHz mono (large), stereo variants; 30 s typical | text; melody audio; **continuation of an audio prompt**; style audio (MusicGen-Style); chords + melody + drums (JASCO) | PyTorch; community ONNX/GGUF ports UNVERIFIED |
| Magenta RealTime (`mrt2`) (Google) | Apache-2.0 (repo) | **CC-BY-4.0** (HF card) | mrt2_small 230M, mrt2_base 2.4B (repo) | real-time streaming "faster than playback" (repo); 2-second chunks, 10 s context | 48 kHz stereo (SpectroStream) | text and/or audio style embedding, weighted blends; live note-control example | JAX/TPU-first (trained on TPUv6e, Colab TPU); repo demos Apple M4 Pro for base; CUDA path not documented on the pages read |
| YuE / YuE2 (m-a-p) | Apache-2.0 (repo) | **CC-BY-NC 4.0 + creator permission** (personal users/creators may monetise outputs; companies must contact the authors) | needs 24 GB BF16 NVIDIA on Linux (quick start) | not stated | 48 kHz stereo FLAC, full songs | lyrics → song | PyTorch CUDA; AMD/Apple/Intel experimental; ComfyUI nodes |
| DiffRhythm 2 (ASLP-lab) | Apache-2.0 | Apache-2.0 (HF card) | not stated; v1 needed 8 GB with `--chunked` | not stated | full songs; rate not stated | lyrics + reference audio | PyTorch. Caveat: v1's VAE is under the Stability AI Community License (`ASLP-lab/DiffRhythm-vae`); whether v2 reuses it is UNVERIFIED |
| HeartMuLa / heartlib | Apache-2.0 (UNVERIFIED, snippet) | UNVERIFIED | not found | — | songs | lyrics | PyTorch |
| LeVo / SongBloom (Tencent) | UNVERIFIED (apache-2.0 vs MIT conflict between cards) | UNVERIFIED | not found | — | songs | lyrics | PyTorch |

Sources: <https://github.com/ace-step/ACE-Step-1.5>
(archived <https://web.archive.org/web/20261014074221/https://github.com/ace-step/ACE-Step-1.5>),
<https://huggingface.co/ACE-Step/Ace-Step1.5>
(archived <https://web.archive.org/web/20261014050729/https://huggingface.co/ACE-Step/Ace-Step1.5>),
<https://huggingface.co/stabilityai/stable-audio-open-1.0>
(archived <https://web.archive.org/web/20261020005019/https://huggingface.co/stabilityai/stable-audio-open-1.0>),
<https://huggingface.co/stabilityai/stable-audio-open-small>
(archived <https://web.archive.org/web/20260921200940/https://huggingface.co/stabilityai/stable-audio-open-small>),
<https://stability.ai/community-license-agreement>
(archived <https://web.archive.org/web/20261014214716/https://stability.ai/community-license-agreement>),
<https://github.com/facebookresearch/audiocraft>
(archived <https://web.archive.org/web/20261018093917/https://github.com/facebookresearch/audiocraft>),
<https://huggingface.co/facebook/musicgen-large>
(archived <https://web.archive.org/web/20260804040525/https://huggingface.co/facebook/musicgen-large>),
<https://huggingface.co/google/magenta-realtime>
(archived <https://web.archive.org/web/20251122074624/https://huggingface.co/google/magenta-realtime>),
<https://github.com/magenta/magenta-realtime>
(archived <https://web.archive.org/web/20260831105304/https://github.com/magenta/magenta-realtime>),
<https://github.com/multimodal-art-projection/YuE>
(archived <https://web.archive.org/web/20261026033817/https://github.com/multimodal-art-projection/YuE>),
<https://huggingface.co/ASLP-lab/DiffRhythm2>
(archived <https://web.archive.org/web/20260124084009/https://huggingface.co/ASLP-lab/DiffRhythm2>),
<https://huggingface.co/ASLP-lab/DiffRhythm-vae>.

### Audio verdict

- **Best quality on macuahuitl (24 GB)**: ACE-Step 1.5 XL sft with the
  1.7B LM (the repo's 20–24 GB row); add the XL **base** DiT when stems are
  needed (extract / lego / complete are base-only). MIT on both sides, BPM,
  key, time-signature and duration controls, repaint and reference audio,
  seconds per song on a 3090-class card. The A5000 is a 3090-class card
  (same GA102 die, 24 GB), so "under 10 s per song" is the planning figure
  until measured.
- **Small hosts (yoga, 14 GB RAM, AMD iGPU, no CUDA)**: ACE-Step 1.5 2B turbo
  with INT8 + CPU offload (repo claims ≤6 GB; ROCm/CPU listed), with
  **Stable Audio Open Small** (0.5B, 11 s clips, Arm/CPU path documented)
  as the loop-and-stinger fallback once its licence is acknowledged. Neither
  is measured on an 840M; a measurement packet is filed (tasks 3.2).
- **Controllability**: ACE-Step base (stems, repaint, complete) covers
  vertical layering; MusicGen (audio-prompt continuation) and JASCO
  (chords/drums) are the strongest horizontal tools but are CC-BY-NC, so
  they sit behind the acknowledgement gate.
- **Live streaming**: Magenta RealTime is the only true real-time model and
  its weights are CC-BY-4.0 (attribution, permissive); its CUDA path is
  undocumented on the official pages and it is TPU/Apple-first, so it is
  listed as a later experiment, not a tier.

## 3. Controllable and adaptive capabilities

What a game needs from the generator, and which model delivers it:

| Need | Technique | Model(s) that can do it |
| --- | --- | --- |
| Intensity levels of the same theme (vertical layering) | generate one full arrangement, then `extract`/`lego` it into stems (drums, bass, harmony, lead, pads); or generate N variations with fixed seed and BPM, ascending density | ACE-Step base (extract/lego); symbolic: Anticipatory MT accompaniment per instrument set; MIDI-GPT density/polyphony attributes (NC) |
| Segment transitions (horizontal re-sequencing) | generate intro / loop A / loop B / stinger / outro at one BPM and key; transition on bar boundaries | ACE-Step (BPM, key, duration control; `repaint` to patch a seam); MusicGen continuation (NC); Stable Audio Open `seconds_total` for short loops |
| Continue or infill an existing segment | audio continuation / repaint / complete; symbolic infill | ACE-Step repaint/complete; MusicGen continuation (NC); Anticipatory MT (history + controls); MIDI-GPT bar infill (NC) |
| Tempo / key conditioning | metadata controls | ACE-Step (BPM, key/scale, time signature); Text2midi (caption); MusicLang (chords) |
| Loopable segments | fixed BPM, bar-multiple duration, repaint the seam, or symbolic export (MIDI loops are trivially seamless) | ACE-Step; any symbolic model |
| Reward good play | raise the intensity layer or switch to the "A+" segment on the next bar when combo/accuracy crosses a threshold | runtime mixer (section 8), fed by pre-generated material |

Note: no model surveyed documents a native "seamless loop" flag; loops come
from fixed BPM + bar-multiple duration plus a seam repaint, or from MIDI.

## 4. Adaptive scoring for gameplay (how the material is used)

Per `research:games/adaptive-music-immersion-hutchings-mccormack-2019`,
music that adapts to player action raises reported immersion and fit over a
fixed soundtrack; the adaptation signal is what players hear, not live
synthesis. The two industry techniques (Wwise interactive music and FMOD
Studio both implement them; their documentation pages returned 403 to the
fetcher on 2026-11-02 and are cited by name only, UNVERIFIED as URLs):

- **Vertical layering (vertical remixing)**: all stems play in sync; the
  mixer fades layers in and out by intensity. Cheapest at runtime, seamless
  by construction, best for continuous signals (combo meter, health).
- **Horizontal re-sequencing**: segments (intro, loops, transitions,
  stingers) chained at bar/beat sync points. Best for discrete events (boss
  phase, chorus unlock, fail state). Transitions must land on a bar boundary
  or on a transition segment, which is why every generated segment needs a
  known BPM, time signature and bar-multiple length.

For kumbia-kombat (portrait rhythm dance game, MIDI synth, hero Mācron):

1. The MIDI synthesizer is already a perfect vertical mixer: tracks are
   channels, intensity is a per-channel gain and a note-mask. Symbolic
   generation (section 1) therefore fits the existing engine with no new
   audio stack: generate the full multi-track MIDI once, play channels
   0..k by combo tier.
2. Audio stems (section 2) add timbre quality the GM soundfont lacks; they
   fit the same mixer if each stem is a bar-aligned loop at the chart's BPM.
3. Combo tier → layer count; perfect-hit streak → "A+" segment (horizontal
   switch at the next bar); miss streak → drop one layer at the next bar,
   never mid-bar (the switch must read as musical).
4. No generation in the frame loop on any host tier: ACE-Step's seconds-per-
   song is minutes on an iGPU, and a rhythm game cannot tolerate a stall.
   Generate at authoring time (forge agent, `music.*`) or at level load with
   a cached fallback.

## 5. Can the generic inference endpoint (ollama) serve any of these?

Concretely:

- **Yes** for plain decoder-only text LLMs whose output is a text music
  format: **ChatMusician (ABC, MIT weights, GGUF conversions exist)** and,
  in principle, MIDI-LLM (Llama 3.2 vocabulary extension — no GGUF found,
  Llama licence UNVERIFIED). These register as inference models in
  `images/inference/` like any GGUF; the forge needs `abc2midi` to turn ABC
  into MIDI. This is the "just allowlist a model" path the operator hoped
  for, and it works today for MIDI-first use, at folk-tune quality.
- **No** for every audio model (ACE-Step, Stable Audio Open, MusicGen,
  Magenta RT, YuE, DiffRhythm): they are diffusion/DiT or codec-token
  stacks with audio VAEs, outside ollama's supported LLM/vision
  architectures. They need their own engine process.
- **No** for the custom-token symbolic models (Anticipatory MT, Text2midi,
  Aria, NotaGen, MIDI-GPT): custom tokenisers and encoders; even the
  GPT-shaped ones need their own event tokeniser and MIDI codec around the
  model, which ollama cannot host.

Conclusion: ollama covers the MIDI-first floor; the quality path needs one
dedicated engine image, the same shape as `imagegen`.

## 6. Minimal architecture

```
forge agent ──MCP──▶ host socket (mcp_socket.rs) ──▶ music.* dispatcher
                                                    ├─ symbolic via ollama (ChatMusician GGUF) + abc2midi      [M0]
                                                    └─ musicgen engine image (podman, no egress, CUDA/ROCm/CPU)
                                                         ├─ symbolic: Anticipatory MT, Text2midi (PyTorch, small)   [M1]
                                                         └─ audio: ACE-Step 1.5 (2B turbo → XL sft/base)            [M2–M3]
models: cache_root()/models/musicgen/<model>/  (pinned URL + sha256 + licence row), never in an image
output: <project>/.tillandsias/generated/music/<job>/ {score.mid | mix.wav, stems/*.wav, manifest.json}
```

- One engine image, `images/musicgen/`, Fedora-based like `inference` and
  `imagegen`, PyTorch + ACE-Step + the two symbolic libraries pinned by tag;
  CUDA via the existing CDI path, ROCm/CPU otherwise. Built on first use via
  `fn ensure_image_exists`. Serves an HTTP job API on the enclave network.
- Tier ladder `images/musicgen/tiers.tsv` (smallest first, ceiling from the
  accel envelope, exactly like `images/imagegen/tiers.tsv`):

| Tier | Symbolic model | Audio model | Needs | Licence (sym / audio) |
| --- | --- | --- | --- | --- |
| M0 | ChatMusician Q4 GGUF via ollama + abc2midi | — | any host that runs T1 inference | MIT / — |
| M1 | Anticipatory MT 360M; Text2midi | ACE-Step 1.5 2B turbo INT8 + offload | CPU or any GPU, ≥16 GB RAM (unmeasured on iGPU) | Apache-2.0 / MIT |
| M2 | as M1 | ACE-Step 1.5 2B sft + 1.7B LM | 12–16 GB VRAM | Apache-2.0 / MIT |
| M3 | as M1 | ACE-Step 1.5 XL sft + base + 1.7B–4B LM | 20–24 GB VRAM | Apache-2.0 / MIT |

  Every pinned row above is permissive. Stable Audio Open Small (Community
  Licence), MusicGen (CC-BY-NC), MIDI-GPT (NC) and YuE (CC-BY-NC) are
  **registered, not pinned**: `licence-register.tsv` rows with
  `licence_sha256 pending` until `accept-licence` records the operator's
  acknowledgement in the agreeing project (the 1958-p4sw CorridorKey
  precedent).
- Consent: the per-host download grant from imagegen (1957-5m8g) applies
  unchanged; ACE-Step XL + LM is a multi-GB download and a first-use image
  build, so the grant sentence states size and minutes.

## 7. MCP tool surface (`music.*`)

All tools return the 1871-47ex shape: saved paths plus metadata, never
inline audio or base64. Common result fields: `path`, `format`, `duration_s`,
`sample_rate`, `channels`, `bpm`, `key`, `time_signature`, `bars`, `seed`,
`model`, `licence`, `tier`, `backend`, `elapsed_s`, `first_use`,
`consent_required` (with the imagegen grant fields when a download or a
long run is needed).

- `music.compose {prompt, style?, key?, bpm?, time_signature?, bars?,
  duration_s?, format: midi|wav|both, instruments?, seed?, tier?,
  dest_path?}` — text → score. `format: midi` routes to the symbolic column
  (M0 ollama when no engine), `wav` to the audio column.
- `music.continue {source_path, bars|duration_s, prompt?, mode:
  continue|repaint|infill, region?: {start_bar, end_bar}}` — extend or
  patch an existing MIDI or WAV; symbolic uses Anticipatory MT history +
  controls, audio uses ACE-Step repaint/complete.
- `music.stems {source_path|prompt, stems: [drums, bass, harmony, lead,
  pads, ...]}` — separate (ACE-Step base extract) or generate stem-wise
  (lego); MIDI sources split by channel/instrument with no model call.
- `music.variations {source_path, intensity_levels: N, seed?}` — produce
  the intensity ladder for the runtime mixer: the same theme at N
  arrangement densities, bar-aligned, same BPM/key, plus a `manifest.json`
  (section 8) the game loads directly.
- `music.models` — list tiers, installed state, licence and the grant
  sentence per tier (mirrors `image.generate`'s offer list, 1957-8hkf).

Provenance: every output directory carries `manifest.json` with model name,
file sha256s, licence id, prompt, seed, BPM/key/bars, and the engine image
tag, so a shipped asset can be traced to its licence row.

### 7.1 Consumer requirements from kumbia-kombat (2026-11-02)

Relayed by the coordinator from kumbia-kombat-macuahuitl-forge; folded into
the `music.*` contract and the spec scenarios:

- **Cumbia at 112–144 BPM in a 2/4 feel.** `music.compose` and
  `music.variations` take `bpm` and `time_signature` as hard constraints,
  not hints: the audio path passes them to ACE-Step's BPM/time-signature
  metadata controls, the symbolic path writes them into the MIDI tempo and
  time-signature meta events, and the result is refused (not rounded) when
  the engine cannot honour the exact BPM.
- **Charts are beat-judged: exact BPM and a downbeat-aligned bar grid.**
  `manifest.json` carries `bpm` as the exact value requested, `beats_per_bar`,
  `bar_grid: [t0, t1, ...]` (bar start times in seconds from file start,
  downbeat at `t0 = 0.0`), `total_bars`, and `sample_rate`. Every stem and
  segment file is cut on those bar starts: a file's length is an integer
  number of bars at the exact BPM (silence-padded or seam-repainted, never
  trimmed off-grid), so files of the same theme line up sample-accurately
  when started together.
- **Rooms are ~45–110 s of combat.** `music.compose` accepts `bars` or
  `duration_s` and resolves them against the BPM to a bar-multiple length;
  loopable segments (`loop_a`, `loop_aplus`) target 45–110 s and are
  seamless at the loop point (seam repaint on audio; trivial on MIDI).
- **Intensity ladder = crowd interest / combo layering.** `music.variations`
  produces N layers whose `min_tier` maps to the game's combo/crowd tier;
  the manifest states the mapping so the mixer needs no music knowledge.
- **MIDI-first: note events per track.** `format: midi|both` emits a
  multi-track Standard MIDI File (type 1) with one track per instrument,
  named, plus `events.json`: `[{track, channel, program, note, velocity,
  on_beat, off_beat, on_s, off_s}]` quantised to the bar grid, so charts can
  be authored per limb from musical events without parsing MIDI.
- **Distinct theme per level, seeded variations.** `music.compose` takes a
  per-room `style` prompt and a `seed`; `music.variations` reuses the seed
  family (`seed`, `seed+1`, …) and records every seed, so the garden theme
  "Mojo" is reproducible and its variations are siblings, not strangers.

## 8. Runtime packaging for Flame (kumbia-kombat)

Recommended: **pre-generated stem sets per intensity level + a small
runtime mixer**, not on-the-fly generation.

```
assets/music/<theme>/manifest.json
  { theme: "Mojo", style: "<per-room prompt>", seed, bpm: 128, time_signature: "2/4",
    beats_per_bar: 2, bar_grid: [0.0, 0.9375, 1.875, ...], total_bars, key,
    bars_per_loop,
    layers: [ {name: "drums", file: "drums.ogg", min_tier: 0},
              {name: "bass",  file: "bass.ogg",  min_tier: 1},
              {name: "lead",  file: "lead.ogg",  min_tier: 2},
              {name: "hype",  file: "hype.ogg",  min_tier: 3} ],
    segments: { intro, loop_a, loop_aplus, fail, outro },   // horizontal
    stingers: { perfect_streak, combo_break },
    midi: "score.mid", events: "events.json" }              // symbolic twin
```

Chart authoring reads `events.json` (per-track note events on the bar
grid) and judges hits against `bar_grid` and `bpm`; the mixer reads
`layers[].min_tier` against the combo/crowd tier.

- Mixer: all layers start together, bar-locked; tier changes apply at the
  next bar line (gain ramp ≤ 1 beat). Segment switches queue for the next
  bar boundary; stingers play immediately on top.
- Flutter audio engines: `flutter_soloud` offers multiple voices with
  per-handle volume and gapless looping (pub.dev docs, UNVERIFIED as a URL
  here), which is the stem-mixer fit; `flame_audio` (audioplayers) loops
  gaplessly but is weaker for many synchronised streams. For the MIDI twin,
  `flutter_midi_pro` (SoundFont/FluidSynth, MIT) exposes per-channel
  control, so the symbolic score plays through the existing synth with the
  same manifest.
- Why not generate on the fly: ACE-Step is seconds per song on a 3090-class
  card and far slower on iGPU/CPU; Magenta RT is the only real-time model
  and has no documented CUDA path; a rhythm game needs sample-accurate beat
  alignment that a streaming generator cannot promise. Pre-generation also
  makes every shipped asset licence-traceable (section 7 manifest).

## 9. Licences the operator must approve (none fetched until then)

| Licence | Models | Terms in one line | Shippable? |
| --- | --- | --- | --- |
| MIT (weights) | ACE-Step 1.5 / XL, ChatMusician, NotaGen | permissive | yes (already on the permissive list; still a NEW model family, so each row needs the operator's pin approval) |
| Apache-2.0 (weights) | Anticipatory MT, Text2midi, Aria, DiffRhythm 2 | permissive | yes |
| CC-BY-4.0 | Magenta RealTime weights | attribution required | permissive family, **not yet on the project list** — operator decision |
| Stability AI Community License | Stable Audio Open 1.0 / Small | free under USD 1M annual revenue, then at Stability's discretion; "Powered by Stability AI" notice | **no** (revenue cap) — acknowledgement only; same ruling as SD3.5 in imagegen |
| CC-BY-NC 4.0 | MusicGen family, JASCO, MAGNeT; YuE (+ creator permission) | non-commercial | **no** — acknowledgement only (standing approval covers the operator's own non-sale projects) |
| Metacreation Non-Commercial Research License | MIDI-GPT weights | research/education only | **no** — acknowledgement only |
| GPL-3.0 (code) + custom weights | MusicLang | copyleft code, commercial use by contact | **no** |
| GPL-2.0 (tool) | abcMIDI (`abc2midi`) | copyleft tool | as an in-image CLI only, never linked |
| Llama 3.2 Community License (UNVERIFIED) | MIDI-LLM | custom | pending verification |

## 10. Open questions for the operator

1. Approve ACE-Step 1.5 (MIT) as the audio spine and Anticipatory MT +
   Text2midi (Apache-2.0) as the symbolic spine? (These are the only rows a
   shippable ladder needs.)
2. Add CC-BY-4.0 to the permissive list (Magenta RT) or keep it behind the
   acknowledgement gate?
3. Acknowledge CC-BY-NC (MusicGen/JASCO) and the Stability Community Licence
   (Stable Audio Open Small) for kumbia-kombat under the standing non-sale
   approval, so the small-host loop fallback and chord/drum conditioning are
   available in that forge only?
4. Is `abc2midi` (GPL-2.0 CLI inside the forge image) acceptable under the
   no-licence-without-operator rule?
