## Context

Two audio surfaces already exist and this change extends both, duplicating
neither:

- **The CPU audio appliance** (`images/audio-studio`, registry id `audio`;
  `crates/tillandsias-headless/src/audio_studio.rs`, `audio_separate.rs`):
  `audio.transform` (ffmpeg, sox, rubberband), `audio.detect_glitches`
  (click, dropout, spectral hole, clipping, loop seam), `audio.separate`
  (Demucs from the maintainer's safetensors, restricted
  `demucs-weights-unstated`, behind accept-licence) and `audio-tool tiers`.
  `--network=none`, one container per call, provenance per output. Orders
  2055-grzz, 2055-d9sa, 2068-ypgq, 2068-eeti, 2068-cqis; generative work is
  2055-dihg.
- **The ComfyUI studio** (`images/imagegen-studio`): pinned ComfyUI v0.40.0,
  ACE-Step 1.5 XL turbo/base (2007-acst), LoadAudio/VAEEncodeAudio/
  TrimAudioDuration/AudioConcat (2018-auin), AudioAdjustVolume (2080-avol),
  `studio.run_workflow` admission through `node-classes.tsv`,
  `custom-nodes.toml`, `models.tsv` and the licence registers, the shared GPU
  queue (`gpu_queue.rs`) and provenance.

The operator's ruling (2026-11-13): option A, extend the ComfyUI studio with a
pinned audio node pack; no separate web app; everything host-side generic.

## Goals / Non-Goals

**Goals:** a ComfyUI node graph for audio with per-node caching (ComfyUI
already re-executes only nodes whose inputs changed), players and scopes on
nodes, and the eleven generic capability families the first client listed;
batch 1 runnable end to end for its pilot (D7).

**Non-Goals:** any project-specific exporter or schema (the adaptive-layer
exporter stays in the game, fed by D6's manifest fragment); a separate web UI;
re-registering Demucs (it is registered restricted; acknowledging it needs the
operator's own signed approval); writing any licence acknowledgement.

## Decisions

### D1. Where each family runs

The test is: does the family need the GPU or graph caching across iterations
(ComfyUI node), or a GPL/CLI toolchain and heavy CPU-only dependencies that
do not belong in a 28 GB CUDA image (CPU appliance)?

| # | Family (client section 6) | Home | Batch |
|---|---|---|---|
| 1 | Pipeline engine | ComfyUI (`studio.run_workflow`, its cache, seeds, provenance) | exists |
| 2 | Symbolic I/O and transforms | ComfyUI nodes: `TillandsiasLoadMIDI`, `TillandsiasMIDITransform` (transpose, tempo scale, quantise, part extraction). MIDI write, splice, humanise: later | 1 / 2 |
| 3 | Instrument rendering | SFZ sampler + drum sampler as a ComfyUI node (`TillandsiasSFZRender`, pure numpy). FluidSynth/SF2 and NAM amp + cab IR in the CPU appliance (`audio.render_midi`, `audio.amp`), bridged as nodes (D3) | 1 / 2 |
| 4 | Generative | ComfyUI (ACE-Step 1.5 XL turbo/base/**SFT**; repaint/extend per 2055-dihg) | 1 (row) |
| 5 | Mix and master | Standard processors as ComfyUI nodes (D2 shared DSP). Pedalboard/LSP processors and Matchering reference mastering in the CPU appliance (`audio.master`) | 1 / 2 |
| 6 | Slicing and export | ComfyUI: `TillandsiasBarGrid`, `TillandsiasLoopSeam`, `TillandsiasSaveLoopWAV` (smpl loop points + manifest fragment). Opus/AAC at bitrates: core `SaveAudioOpus` now, AAC via `audio.transform`; sprite assembly later | 1 / 2 |
| 7 | Analysis and screening | ComfyUI: `TillandsiasAudioLoudness` (R128, true peak, bandwidth, centroid), `TillandsiasAudioScope`. Glitch detection stays `audio.detect_glitches` (one canonical detector). Tempo/beat/key, CLAP, Audiobox in the CPU appliance | 1 / 2 |
| 8 | Separation | CPU appliance, exists (`audio.separate`) | exists |
| 9 | Voices | VoxCPM2 as ComfyUI-side GPU job (2080-zq6u voice service decides the host) | 3 |
| 10 | Audition UI | Core `PreviewAudio`/`SaveAudio` players + `TillandsiasAudioScope` → `PreviewImage` now; A/B, solo/mute, loop regions later | 1 / 3 |
| 11 | Jobs | Existing GPU queue and tickets | exists |

The bridge (later batch): nodes such as `TillandsiasApplianceRender` cannot
call the appliance from inside the studio (`--network=none`, separate
container). Instead `studio.run_workflow` gains a pre-pass: an appliance node
in the graph is executed by the tray through the existing `audio.*` tool path,
its output file bound as a `LoadAudio` input, and the provenance chained. That
keeps both containers offline and keeps one implementation per capability.

### D2. One DSP implementation, two callers

`nodes/tillandsias_audio/dsp.py` imports only numpy and scipy (no ComfyUI,
torch or I/O). It is copied unchanged into the appliance when the appliance
gains mix/loudness subcommands, so a node-graph render and an `audio.*` call
measure loudness identically. Loudness is BS.1770-4 with libebur128's
any-rate K-weighting; the limiter is lookahead with a gain that provably never
exceeds the required gain at any sample (moving average of a moving minimum),
so no hard clip is ever applied.

### D3. Symbolic data between nodes

MIDI travels as a plain dict of notes in SECONDS (the tempo map is applied at
load), type `TILLANDSIAS_MIDI`. The SFZ sampler implements the opcode subset
the pinned CC0 libraries use and reports every ignored opcode, unmatched note
and missing sample in its `report_json`, so a pipeline can see what was not
honoured rather than hearing it.

### D4. Pinning a vendored node pack

`custom-nodes.toml` rows clone a git repository at a 40-hex commit. Our own
pack lives in this repository, so a row may say `repo = "vendored:<dir>"`;
`custom-nodes.py install` then copies the directory from the build context and
compares its **tree digest** (sha1 over sorted `path\0sha256(bytes)` lines,
printed by `custom-nodes.py digest <dir>`) to the row's `commit`. An edit to
the pack without a new digest fails the image build; `verify` is unchanged
(it compares the stamp). The pack is GPL-3.0-or-later like the repository and
ComfyUI. It needs no pip lock (comment-only lock file).

### D5. SFZ libraries are fetched, never baked

`sfz-libraries.tsv` pins each library by git commit (which hashes every
sample) and LICENSE blob sha; CC0-1.0 or CC-BY-4.0 only, CC-BY rows carry an
attribution string copied into render reports and export manifests. Fetch
target `cache_root()/models/imagegen/I1/sfz/<name>/`, mapped as the `sfz`
folder, read-only. The fetcher is task 3.1; until it lands a user (or the
fixture) places a library there, or a project puts an SFZ under the studio's
input folder.

### D6. The generic manifest fragment

`TillandsiasSaveLoopWAV` writes, beside each WAV, a JSON object: file, bytes,
sha256, sample rate, channels, samples, seconds, bits, loop
`{start_sample, end_sample_inclusive, start_s, end_s}`, integrated LUFS, true
peak, and the bar grid when given. The WAV carries the same loop in a RIFF
`smpl` chunk and a `cue ` point. Projects map this onto their own schema.

### D7. Batch 1 acceptance: the client's first pilot

One level's committed score (MIDI) renders through `TillandsiasLoadMIDI` →
`TillandsiasMIDITransform` (one per part, by channel) →
`TillandsiasSFZRender` (one stem per part) → EQ/compressor per stem →
`TillandsiasAudioMixBus` → `TillandsiasAudioNormalizeLoudness` →
`SaveAudio` + `TillandsiasAudioLoudness` + `TillandsiasAudioScope`, then
`audio.detect_glitches` on the master. NAM amp/cab is batch 2; until then the
guitar part uses the CC0 sampled guitars directly.

### D8. Licences

Admitted now (verified upstream, operator-approved 2026-11-13): ACE-Step 1.5
XL-SFT (Comfy-Org repackage apache-2.0; upstream ACE-Step mit, commercial
output stated). SFZ: Karoryfer CC0 libraries and VCSL (CC0-1.0, GitHub
licence API). Approved for later batches, registered when their slice lands and only after
that slice re-reads each upstream LICENSE at the pinned version (the ids below
are the expected ones, not yet verified by this change):
FluidSynth (LGPL-2.1, Debian bookworm 2.3.1), LSP (LGPL-3.0), Pedalboard
(GPL-3.0), DawDreamer (GPL-3.0), Matchering (GPL-3.0), NAM core (MIT),
VoxCPM2 (`openbmb/VoxCPM2`, apache-2.0, gated false). Read but NOT admitted:
Audiobox Aesthetics (`facebook/audiobox-aesthetics` reads cc-by-4.0, outside
the permissive register's list: needs an operator ruling to add cc-by-4.0
with an attribution obligation, or the restricted register); CLAP
(`laion/clap-htsat-unfused`, `laion/larger_clap_music` read apache-2.0:
admissible when its slice lands; `microsoft/msclap` reads ms-pl: not used).
Demucs: unchanged, restricted, never acknowledged here.

Update 2026-11-14 (operator approval via the coordinator): cc-by-4.0 joins
the accepted set (`imagegen_tiers::PERMISSIVE_LICENCES`,
`check-model-licence-register.lua`) with its attribution obligation, and the
register now carries Audiobox Aesthetics `model.safetensors` (cc-by-4.0, the
credit line in the row's comment), both CLAP checkpoints (apache-2.0;
`pytorch_model.bin` pickles, so admitted but not fetchable until a
safetensors export is pinned) and VoxCPM2 `model.safetensors` (apache-2.0; its
`audiovae.pth` pickle is not registered).

## Risks / Trade-offs

- [Pure-numpy DSP is slower than JUCE/LSP] → 1 ms block envelopes; heavy
  processors move to the appliance in batch 2.
- [SFZ subset] → the render report names every ignored opcode; libraries are
  pinned, so the subset is tested against exactly what ships.
- [Studio image rebuild cost, ~28 GB] → the pack adds only Python files; the
  layer above the custom-node install is unchanged.
