## 1. Batch 1: node pack, allowlist, registers (order 2090-ausx)

- [x] 1.1 `custom-nodes.py`: `vendored:<dir>` rows copied from the build context and pinned by tree digest; `digest <dir>` subcommand (D4)
- [x] 1.2 `nodes/tillandsias_audio`: mix (pan, mix bus, crossfade, loop seam, EQ, compressor, limiter, saturation), analysis (loudness/true peak/spectrum, scope), export (bar grid, loop WAV + manifest fragment), symbolic (MIDI load/transform, SFZ sampler) (D2, D3, D6)
- [x] 1.3 Containerfile COPY nodes/; custom-nodes.toml row; comment-only lock
- [x] 1.4 node-classes.tsv: the 16 pack classes and six remaining core audio nodes
- [x] 1.5 ACE-Step 1.5 XL-SFT in models.tsv and licence-register.tsv (D8)
- [x] 1.6 sfz-libraries.tsv (CC0, pinned by commit and licence blob) and the `sfz` folder in extra_model_paths.yaml (D5)
- [x] 1.7 Property self-test of every pack class inside the built studio image, CPU, `--network=none` (loudness of a reference sine within 0.1 LU, limiter ceiling never exceeded, loop-seam wrap continuity, smpl loop points read back, MIDI tempo map, SFZ pitch and release)
- [ ] 1.8 Rebuild the studio image on a GPU host and run the pilot graph (D7) through `studio.run_workflow`; commit the fixture workflow JSON as an example
- [ ] 1.9 A Lua fixture that runs the property self-test in the studio image (the repo's no-host-Python rule), wired into the studio gate

## 2. Batch 2: appliance families and the bridge

- [ ] 2.1 `audio.render_midi` (FluidSynth + SF2, LGPL) and `audio.amp` (NAM core MIT + cab IR convolution) in images/audio-studio
- [ ] 2.2 `audio.master`: Pedalboard/LSP processor chains and Matchering reference mastering (GPL, appliance only, never in a release artefact)
- [ ] 2.3 Copy `dsp.py` into the appliance; `audio-tool loudness` uses it (D2)
- [ ] 2.4 The `studio.run_workflow` appliance pre-pass: appliance nodes executed through `audio.*`, outputs bound as LoadAudio inputs, provenance chained (D1)
- [ ] 2.5 Opus/AAC sprite assembly with slot metadata in the manifest fragment
- [ ] 2.6 Tempo/beat/key analysis; CLAP (apache-2.0) similarity; Audiobox Aesthetics after an operator ruling on cc-by-4.0
- [ ] 2.7 MIDI write, section splice, humanise
- [ ] 3.1 The SFZ library fetcher: clone at the pinned commit through the proxy, verify HEAD and LICENSE blob, drop .git, into I1/sfz (D5)

## 3. Batch 3: audition and voices

- [ ] 3.2 Audition UI: A/B against a node or reference, loop regions, solo/mute (ComfyUI frontend extension, pinned)
- [ ] 3.3 VoxCPM2 (apache-2.0) voice generation on the GPU queue (with 2080-zq6u)
