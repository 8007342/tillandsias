## ADDED Requirements

### Requirement: Music generation has a symbolic floor on the generic inference endpoint

Tillandsias MUST offer MIDI-first composition through the existing
inference endpoint (ollama) using a plain text LLM that emits a text music
notation (ABC) with a permissive weights licence, converted to MIDI inside
the forge, so a host with no music engine image can still answer
`music.compose` with `format: midi`.

#### Scenario: A host with no engine image composes MIDI
- **WHEN** `music.compose` is called with `format: midi` on a host whose musicgen image has never been built
- **THEN** the result is a saved `.mid` path produced through the inference endpoint and the result's `tier` is `M0`

### Requirement: Audio and custom-token models run in a dedicated engine image

Audio generation and custom-token symbolic generation MUST run in a
`musicgen` engine image built on first use, with no egress, selecting CUDA,
ROCm or CPU from the accel envelope, never inside the inference (ollama)
image and never in the tray process.

#### Scenario: First audio request builds the engine
- **WHEN** `music.compose` with `format: wav` is called on a host that has never built `musicgen`
- **THEN** the image is built through the on-demand build path and the result reports `first_use: true`

### Requirement: Music models form a smallest-first ladder whose pinned rows are permissive

The tier table (M0–M3) MUST be declarative, ordered smallest first, with
the accel envelope setting only the ceiling. Every pinned row MUST name its
model and licence, and every pinned licence MUST be on the permissive list.
Models under a non-commercial, revenue-capped or custom licence MUST be
registered with a pending licence row and MUST NOT be fetched until an
`accept-licence` acknowledgement exists in the agreeing project.

#### Scenario: A restricted model is registered but never fetched
- **WHEN** an agent asks for a model whose register row is `pending` and no acknowledgement exists
- **THEN** the call returns `licence_acknowledgement_required` naming the licence and downloads nothing

#### Scenario: No pinned row is restricted
- **WHEN** the tier table is loaded
- **THEN** no pinned row names a non-commercial, revenue-capped or custom licence

### Requirement: music.* results are saved files with provenance

Every `music.*` tool MUST return saved paths (MIDI, WAV, stems) plus a
`manifest.json` carrying model, file sha256s, licence, prompt, seed, BPM,
key, time signature and bar count, and MUST NOT return inline audio or any
base64 run longer than 256 characters.

#### Scenario: A composed track is traceable to its licence
- **WHEN** `music.compose` succeeds
- **THEN** the output directory holds `manifest.json` whose `licence` matches the register row of the model that produced it

### Requirement: Adaptive material is bar-aligned and tiered for a runtime mixer

`music.variations` MUST produce N arrangements of one theme at the same
BPM, key and bar-multiple length, with a manifest listing layers by minimum
intensity tier and segments by role, so a game can switch layers and
segments on bar boundaries without generating at runtime.

#### Scenario: Variations share tempo and length
- **WHEN** `music.variations` is called with `intensity_levels: 4`
- **THEN** every produced file reports the same `bpm`, `key` and `bars`, and the manifest lists four layers with ascending `min_tier`
