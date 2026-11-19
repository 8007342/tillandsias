## Why

Forge agents build images as iterative, cached ComfyUI node graphs, but audio
work is a set of one-shot tools: `audio.transform`, `audio.detect_glitches`
and `audio.separate` on the CPU audio-studio appliance (orders 2055-grzz,
2055-d9sa, 2068-*), plus ACE-Step text-to-music and a handful of core audio
nodes in the ComfyUI studio (2007-acst, 2018-auin). The operator made an
"audio studio, like ComfyUI but for muxing music" the top priority
(2026-11-13): node graphs saved as JSON in the project, re-rendering only what
changed, with players on the nodes. The first client's requirements
(a game's `plan/audio-studio/music-requirements.md`, sections 6 and 7) ask
for eleven GENERIC capability families; nothing here is specific to that game.

## What Changes

- The ComfyUI studio image gains a **vendored, reviewed node pack**,
  `tillandsias_audio`, pinned by a tree digest (a new `vendored:` form of
  `custom-nodes.toml`, checked at image build). Batch 1 classes: mix bus,
  pan, crossfade, loop seam, EQ, compressor, limiter, saturation, EBU R128
  loudness and true peak, loudness normalisation, spectrum/bandwidth report,
  spectrogram+waveform scope, bar grid, loop WAV export with a manifest
  fragment, MIDI load and transform, and an SFZ sampler (which is also the
  drum sampler). No new pip dependency, no network.
- The node-class allowlist admits those classes and the remaining core audio
  nodes (PreviewAudio, AudioMerge, EmptyAudio, AudioEqualizer3Band,
  SplitAudioChannels, JoinAudioChannels).
- The model and licence registers admit ACE-Step 1.5 **XL-SFT** (the 4B LM is
  the already-registered `qwen_4b_ace15`).
- A new `sfz-libraries.tsv` pins CC0 SFZ libraries by git commit and licence
  blob, fetched to the user's cache (never baked), mapped as the `sfz` model
  folder.
- Specified for later batches: FluidSynth/SF2, NAM amp + cab IR, Pedalboard
  and LSP processors, Matchering reference mastering, Opus/AAC loop sprites,
  Audiobox/CLAP scoring, VoxCPM2 voices, audition UI (A/B, solo/mute, loop
  regions), and the CPU-appliance bridge (D1). The game-specific adaptive-layer
  exporter is NOT host scope: it stays in the game and consumes the generic
  manifest fragment.

## Capabilities

### New Capabilities
- `audio-studio-node-graph`: generic node-graph audio pipelines in the
  ComfyUI studio, sharing one DSP implementation with the CPU audio appliance.

### Modified Capabilities
- (none: `imagegen-studio` admission rules are reused unchanged, plus the
  `vendored:` manifest form described in design D4)

## Impact

- `images/imagegen-studio/`: Containerfile (COPY nodes/), custom-nodes.py
  (vendored install and `digest`), custom-nodes.toml, node-classes.tsv,
  extra_model_paths.yaml (`sfz`), locks/tillandsias_audio.txt,
  sfz-libraries.tsv, nodes/tillandsias_audio/.
- `images/imagegen/models.tsv`, `images/models/licence-register.tsv`: one
  XL-SFT row each.
- The studio image must be rebuilt for the nodes to exist; until then the new
  rows admit nothing that can run (studio_tool refuses unknown classes at
  ComfyUI's own validation).
