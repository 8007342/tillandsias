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

### Requirement: Outputs carry an exact BPM and a downbeat-aligned bar grid

Every `music.*` output MUST honour a requested `bpm` and `time_signature`
exactly (refusing, not rounding, when the engine cannot), and its
`manifest.json` MUST carry `bpm`, `beats_per_bar`, `total_bars` and
`bar_grid` (bar start times in seconds, downbeat at 0.0). Every stem and
segment file MUST be an integer number of bars long at that BPM, cut on the
bar grid, so files of one theme align when started together.

#### Scenario: A cumbia room theme at 128 BPM in 2/4
- **WHEN** `music.compose` is called with `bpm: 128`, `time_signature: "2/4"`, `duration_s: 60`
- **THEN** the manifest reports `bpm: 128`, `beats_per_bar: 2`, a `bar_grid` whose consecutive entries differ by 0.9375 s, and every file's duration equals `total_bars` times 0.9375 s

#### Scenario: An unhonourable BPM is refused
- **WHEN** the selected engine cannot produce the exact requested `bpm`
- **THEN** the call fails naming the BPM and the engine, and writes no files

### Requirement: Loopable segments cover a room's length

`music.compose` MUST accept `bars` or `duration_s`, resolve them to a
bar-multiple length at the exact BPM, and when a segment role is `loop_*`
MUST make the segment seamless at the loop point.

#### Scenario: A 45–110 s combat loop
- **WHEN** `music.compose` is called with role `loop_a` and `duration_s: 90` at `bpm: 120` in 2/4
- **THEN** the produced segment is 90 bars (90.0 s) long and the manifest marks it `loop: true`

### Requirement: MIDI outputs expose note events per track

`format: midi` or `both` MUST emit a type-1 Standard MIDI File with one
named track per instrument carrying the tempo and time-signature meta
events, plus `events.json` listing every note as `{track, channel,
program, note, velocity, on_beat, off_beat, on_s, off_s}` quantised to the
bar grid.

#### Scenario: Charts are authored from events
- **WHEN** `music.compose` succeeds with `format: midi`
- **THEN** `events.json` exists beside `score.mid`, every event's `on_s` equals `on_beat` times 60 divided by `bpm`, and every `track` name appears in the MIDI file

### Requirement: Themes are distinct per style prompt and reproducible by seed

`music.compose` MUST take a per-level `style` prompt and a `seed`, and
`music.variations` MUST derive its variations from the source's seed
family and record every seed in the manifest, so a theme and its intensity
ladder can be regenerated identically.

#### Scenario: The garden theme "Mojo" is reproducible
- **WHEN** `music.compose` is called twice with the same `style`, `seed`, `bpm` and `bars` on the same model and tier
- **THEN** both outputs' file sha256s are identical and the manifests record the same `seed`
