# Proposal — local-music-generation

Order: `1969-sxzc` (research and proposal row; desired_release v0.6,
priority p2). Sibling of `openspec/changes/local-image-generation/`
(epic `1874-4b88`), whose tier ladder, licence register, consent grant and
host-MCP-socket tool shape this change reuses. Research record:
`research:games/adaptive-music-immersion-hutchings-mccormack-2019`.

## Why

Operator direction (2026-11-02): kumbia-kombat is a musical project (a
Flutter/Flame portrait rhythm dance game with a MIDI synthesizer). Forge
agents should be able to answer requests like "create a dynamic background
chill theme of country music with a hint of metal to match the storytelling"
and, for kumbia-kombat, produce dynamic scores that reward good gameplay with
more engaging and catchy arrangements. macuahuitl (RTX A5000 24 GB) is the
intended heavy host; smaller hosts (yoga, AMD 840M iGPU, 14 GB) need a
smaller tier. The operator's expectation is that this is mostly allowlisting
the right models, perhaps an MCP wrapper, and that the generic inference
endpoint may suffice if the models are right.

This change records the research (design.md sections 1–4), answers the
"can ollama serve it" question concretely (section 5), and proposes the
minimal architecture and tool surface (sections 6–8). It is docs only:
no model is downloaded, no code is written, no GPU run happens, because every
new licence needs the operator first (design.md section 9 lists them).

SOURCE READ (2026-11-02, trunk `572fed56e`):

- `image.generate` exists on the host MCP socket
  (`crates/tillandsias-headless/src/imagegen_tool.rs`, dispatched from
  `fn handle_mcp_jsonrpc` in `mcp_socket.rs`); its tier ladder is
  `images/imagegen/tiers.tsv` (I0–I3, smallest first, ceiling from the accel
  envelope), its licence register is `images/models/licence-register.tsv`
  (one row per fetched file, consulted by
  `scripts/lua/check-model-licence-register.lua`; a file not listed is not
  fetched), and consent is a per-host download grant (1957-5m8g).
- Restricted licences go through the `accept-licence` skill (1956-ecpb):
  verbatim text, OS-verified signed approval, an acknowledgement record and
  an obligations spec committed into the agreeing project.
- The generic inference endpoint is ollama in the `inference` image
  (`images/inference/`), tiered T0–T5 by `images/inference/tiers/tier-table.tsv`.
- There is no music or audio generation code anywhere in the tree, and no
  `music.*` tool on the socket.

## What Changes

- A new `musicgen` engine image (built on first use, no egress, CUDA on
  NVIDIA hosts, ROCm/CPU elsewhere) hosting the audio and symbolic models
  that ollama cannot serve, behind one host-socket tool family `music.*`.
- A declarative music tier ladder `images/musicgen/tiers.tsv` (M0–M3,
  smallest first, licence per row) mirroring the imagegen ladder; two
  columns of models per tier: `symbolic` (MIDI out) and `audio` (WAV out).
- New rows in `images/models/licence-register.tsv` for every pinned music
  model file, each with its licence as the model card states it; rows whose
  licence is outside the permissive list are filed `pending` and are never
  fetched until the operator accepts the licence through `accept-licence`.
- One symbolic model served by ollama as a GGUF (ChatMusician, MIT weights,
  ABC notation) registered as an inference-tier model, so hosts with no
  engine image still get MIDI-first composition through the existing
  endpoint plus an `abc2midi` step.
- A `music.*` MCP tool surface: `music.compose`, `music.continue`,
  `music.stems`, `music.variations`, each returning a saved path plus
  provenance (model, licence, tier, backend, seed, elapsed_s), never inline
  audio, following the 1871-47ex result schema.
- A runtime recommendation for Flame games (design.md section 8):
  pre-generated stem sets per intensity level plus a small on-device mixer
  that switches layers on bar boundaries; no generation in the frame loop.

## Capabilities

### New Capabilities

- `music-generation`: the musicgen engine, tier ladder, model cache rows,
  the `music.*` result contract and the adaptive-score packaging format.

### Modified Capabilities

- `mcp-tool-socket`: the socket also carries `music.*` tools.
- `image-generation`: the licence register gains an `audio` family of rows
  (same file, same checker); no behaviour change for images.

## Impact

Docs only in this change. Implementation packets (tasks.md) touch
`crates/tillandsias-headless` (a `musicgen_tool.rs` beside
`imagegen_tool.rs`, dispatch in `mcp_socket.rs`), `images/musicgen/`
(new), `images/models/licence-register.tsv`, `images/inference/` (one GGUF
pull), the forge instruction overlays, and kumbia-kombat's own repo (the
Flame stem mixer, out of scope for Tillandsias).

## Non-goals

- Real-time generation inside the game loop (design.md section 8 explains
  why pre-generated stems win on every host tier).
- Vocals/lyrics-to-song as a first tier (YuE and the lyric models are
  non-commercial or 24 GB-only; listed, not pinned).
- A music studio UI (DAW-like); the ComfyUI studio (1935-k2ib) may later
  mount the same model cache.
