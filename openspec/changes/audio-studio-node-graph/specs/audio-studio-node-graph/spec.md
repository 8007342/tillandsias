## ADDED Requirements

### Requirement: Audio pipelines run as pinned ComfyUI node graphs

The ComfyUI studio SHALL provide generic audio node classes (mix, dynamics, loudness, scopes, bar grid, loop export, MIDI, SFZ sampling) from a node pack pinned in `custom-nodes.toml`, each listed in `node-classes.tsv`, so a project's committed API-format workflow runs through `studio.run_workflow` with the same admission, GPU queue and provenance as an image workflow. No class SHALL name, read or emit a specific project's schema.

#### Scenario: An audio workflow of pinned classes runs
- **WHEN** a forge runs a committed workflow whose classes are all `tillandsias_audio` or core rows of `node-classes.tsv`
- **THEN** it is queued and its outputs carry provenance like any studio job

#### Scenario: An edited pack without a new pin fails the image build
- **WHEN** a file of the vendored pack changes and `custom-nodes.toml` still names the old tree digest
- **THEN** the studio image build fails with `vendored-tree-not-at-pinned-digest`

### Requirement: Loudness and peaks are measured to the broadcast standard

`TillandsiasAudioLoudness` SHALL report BS.1770-4 gated integrated loudness and 4x-oversampled true peak. `TillandsiasAudioNormalizeLoudness` SHALL reach the requested integrated loudness and SHALL NOT let any sample exceed its ceiling.

#### Scenario: A reference sine reads its known loudness
- **WHEN** a 1 kHz stereo sine at -6.02 dBFS peak is measured
- **THEN** the integrated loudness is -6.02 LUFS within 0.1 LU

### Requirement: Loop exports carry their loop points and a manifest fragment

`TillandsiasSaveLoopWAV` SHALL write a WAV with a RIFF `smpl` loop and a JSON manifest fragment beside it (file, bytes, sha256, format, loop points in samples and seconds, loudness, optional bar grid), for a project-side exporter to map onto its own schema.

#### Scenario: Loop points round-trip
- **WHEN** a loop from 0.5 s to 2.5 s at 48 kHz is exported
- **THEN** the WAV's `smpl` chunk reads start 24000 and end 119999, and the fragment's sha256 and bytes match the file

### Requirement: Sampled instruments are fetched, pinned and never baked

SFZ libraries SHALL be listed in `sfz-libraries.tsv` with a pinned commit and licence blob, CC0-1.0 or CC-BY-4.0 only (CC-BY with an attribution line), fetched to the user's model cache and mounted read-only; no image or release SHALL contain them.

#### Scenario: The sampler reports what it did not honour
- **WHEN** `TillandsiasSFZRender` plays an instrument using an opcode outside its subset, or a note no region covers
- **THEN** its `report_json` names the ignored opcode and counts the unmatched note
