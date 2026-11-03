# Tasks — local-music-generation

Packet orders in brackets; `1969-sxzc` is this research/proposal row. The
implementation rows are minted only after the operator answers design.md
section 10 (licences first; no model is fetched before that).

## 0. Research and approval

- [x] 0.1 Model survey, ollama feasibility, architecture, tool surface, runtime packaging, licence list [1969-sxzc]
- [ ] 0.2 Operator approves the licence rows in design.md section 9 (MIT, Apache-2.0 rows; CC-BY-4.0 decision; acknowledgements for CC-BY-NC and Stability Community Licence) [to mint]

## 1. Floor tier through the existing endpoint

- [ ] 1.1 ChatMusician Q4 GGUF registered as an inference model row (MIT) with `abc2midi` in the forge image; `music.compose format:midi` works with no engine image [to mint]

## 2. Engine and data

- [ ] 2.1 `images/musicgen` built on first use (ACE-Step 1.5 + Anticipatory MT + Text2midi pinned by tag), CUDA/ROCm/CPU, no egress [to mint]
- [ ] 2.2 `images/musicgen/tiers.tsv` M0–M3 ladder and ceiling classifier reusing the imagegen classifier shape [to mint]
- [ ] 2.3 Licence-register rows for every pinned file; restricted rows filed `pending` until `accept-licence` [to mint]

## 3. Tools and measurement

- [ ] 3.1 `music.compose`, `music.continue`, `music.stems`, `music.variations`, `music.models` on the host socket with the 1871-47ex result shape and `manifest.json` provenance [to mint]
- [ ] 3.2 Measured seconds per 30 s clip for M1 on yoga (iGPU/CPU) and M3 on macuahuitl, recorded in tiers.tsv [to mint]

## 4. Game side (kumbia-kombat repo, not Tillandsias)

- [ ] 4.1 Flame stem mixer reading `manifest.json`, bar-locked tier changes, MIDI twin through the existing synth [kumbia-kombat]
