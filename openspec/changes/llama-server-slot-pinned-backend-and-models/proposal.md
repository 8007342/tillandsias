## Why

Order 482b adds the llama-server engine slot to the inference image
(`TILLANDSIAS_INFERENCE_ENGINE=llama-server`; ollama stays the default under
SLOT-3). Two of its properties are contracts and not just implementation, and
neither is written in `inference-engine-slots` yet:

- **Exactly one backend, pinned.** The ollama slot pins its runner with
  `OLLAMA_LLM_LIBRARY` (482a). The llama-server slot has no such variable. On
  2026-10-12 the payload's llama-server listed no devices at all with a vulkan dir
  beside it, and exactly the RADV iGPU once `GGML_BACKEND_PATH` named the library.
  The pin is what decides the backend, so it must be required and checked against
  what is installed.
- **Models fail closed.** llama.cpp's own `-hf` download verifies nothing. Ollama
  pulls are digest-addressed manifests; GGUF downloads are not. Without a rule,
  the second engine would be the one path that executes unverified model bytes.

## What Changes

- ADDED `inference-engine-slots` "SLOT-9 — The llama-server slot runs exactly one
  pinned backend and only digest-pinned models".

## Impact

- `images/inference/llama-server-lane.sh` (new), `images/inference/llama-server.Caddyfile` (new),
  `images/inference/tiers/gguf-pins.tsv` (new; T0 only), `images/inference/entrypoint.sh`,
  `images/inference/Containerfile` (caddy)
- `crates/tillandsias-headless/src/engine_slots.rs`, `main.rs` (engine switch, render-node delivery)
- `openspec/litmus-tests/litmus-inference-llama-server-lane-shape.yaml` (new)
- Follow-up: 482-igky pins the remaining tier rows per shard.
