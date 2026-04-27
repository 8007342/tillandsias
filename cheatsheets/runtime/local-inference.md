---
tags: [inference, ollama, local-models, runtime, gpu]
languages: []
since: 2026-04-26
last_verified: 2026-04-26
sources:
  - https://github.com/ollama/ollama/blob/main/docs/api.md
  - https://github.com/ollama/ollama/blob/main/docs/modelfile.md
  - https://huggingface.co/docs/transformers/main/en/llm_tutorial
authority: high
status: current
---

# Local inference inside the forge

@trace spec:inference-container, spec:opencode-web-session-otp
@cheatsheet runtime/forge-container.md

## Provenance

- Ollama API reference (canonical for the `/api/*` endpoints we consume): <https://github.com/ollama/ollama/blob/main/docs/api.md>
- Ollama Modelfile reference (model naming + tag conventions): <https://github.com/ollama/ollama/blob/main/docs/modelfile.md>
- HuggingFace LLM tutorial (background on quantisation + tier sizing): <https://huggingface.co/docs/transformers/main/en/llm_tutorial>
- Tillandsias model tier definitions: `images/default/config-overlay/ollama/models.json` (canonical tier list, baked into every forge image)
- **Last updated**: 2026-04-26

**Version baseline**: ollama 0.5.x (forge image's pinned version), API revision dated above.
**Use when**: an agent inside the forge needs to call a local LLM — for triggers, summarisation, code generation, or as a routing layer between a fast classifier and a heavyweight model.

## Quick reference

| Concern | Answer |
|---|---|
| **Endpoint URL** | `http://inference:11434` (DNS alias on the enclave bridge — works from every forge container) |
| **Env var** | `$OLLAMA_HOST` is pre-set in the forge — agents that read it get the right URL automatically |
| **Verify alive** | `curl -fsS $OLLAMA_HOST/api/version` → `{"version":"..."}` |
| **List installed models** | `curl -fsS $OLLAMA_HOST/api/tags \| jq '.models[].name'` |
| **One-shot completion** | `curl -fsS $OLLAMA_HOST/api/generate -d '{"model":"qwen2.5:0.5b","prompt":"hi","stream":false}' \| jq -r .response` |
| **Streaming completion** | drop `stream:false` — response is newline-delimited JSON |
| **Chat completion (messages)** | POST to `/api/chat` with `{"model":..., "messages":[{"role":"user","content":"..."}]}` |
| **Pull a new model** | `curl -fsS $OLLAMA_HOST/api/pull -d '{"name":"qwen2.5-coder:7b"}'` (proxy-mediated download — may be slow first time) |

## Model tiers shipped by Tillandsias

Tier list is baked into the forge image at
`images/default/config-overlay/ollama/models.json`. The inference
container's `pull-models.sh` reads this file at first boot and pulls
the tiers that fit in the host's VRAM.

| Tier | Default model | Size | VRAM req | Role |
|---|---|---:|---:|---|
| T0 | `qwen2.5:0.5b` | 350 MB | 0 GB (CPU) | Instant — triggers, classification, tiny edits |
| T1 | `tinyllama:1.1b` | 600 MB | 0 GB (CPU) | Fast — summaries, changelogs, progress tracking |
| T2 | `phi3.5:3.8b` | 2.2 GB | 4 GB | Capable — code generation, refactoring, explanations |
| T3 | `qwen2.5-coder:7b` | 4.5 GB | 6 GB | Code — code-specific, reliable structured output |
| T4 | `llama3.2:8b` | 4.7 GB | 8 GB | General-capable |

T0 + T1 are pulled at init unconditionally (CPU-only, fit on every host).
T2+ are pulled automatically only when the GPU detection step finds enough
VRAM. To pull manually anyway: `ollama pull <model>` from inside the forge.

## Common patterns

### Pattern 1 — fast-classify-then-delegate (the routing pattern)

```bash
# Use T0 (tiny, fast) to classify; on a positive trigger, escalate to T3.
classify=$(curl -fsS "$OLLAMA_HOST/api/generate" \
    -d '{"model":"qwen2.5:0.5b","prompt":"Reply only YES or NO. Is this a code question? '"$user_input"'","stream":false}' \
  | jq -r .response)
if [[ "$classify" == YES* ]]; then
    curl -fsS "$OLLAMA_HOST/api/generate" \
        -d "{\"model\":\"qwen2.5-coder:7b\",\"prompt\":\"$user_input\",\"stream\":false}" \
      | jq -r .response
fi
```

### Pattern 2 — JSON-shaped output (`format=json`)

```bash
curl -fsS "$OLLAMA_HOST/api/generate" \
    -d '{
      "model": "qwen2.5-coder:7b",
      "format": "json",
      "stream": false,
      "prompt": "Return {\"name\": <string>, \"version\": <string>}. Project: tillandsias"
    }' | jq -r .response
```

`format=json` makes ollama post-process the model output to valid JSON.
Useful for structured-output pipelines that parse with `jq`. Doesn't work
with every model — verify the model card supports JSON mode.

### Pattern 3 — context-aware streaming

```bash
# Streaming responses are newline-delimited JSON. Each chunk has a
# `response` field plus a final chunk with `done: true` and metrics.
curl -N "$OLLAMA_HOST/api/generate" \
    -d '{"model":"qwen2.5:0.5b","prompt":"Count 1 to 5"}' \
  | while read -r line; do
      done=$(jq -r .done <<<"$line")
      [[ "$done" == "true" ]] && break
      jq -rj .response <<<"$line"
    done
```

### Pattern 4 — embeddings (for semantic search)

```bash
curl -fsS "$OLLAMA_HOST/api/embeddings" \
    -d '{"model":"nomic-embed-text","prompt":"the quick brown fox"}' \
  | jq -c '.embedding | length'   # → 768 (vector dimension)
```

`nomic-embed-text` is not in the default tier list — pull it explicitly
if you need embeddings: `curl $OLLAMA_HOST/api/pull -d '{"name":"nomic-embed-text"}'`.

### Pattern 5 — verify the inference container is reachable BEFORE the agent loop

```bash
# Use this in your agent's startup — fail fast with a clear message
# instead of dying on the first generate call.
if ! curl -fsS -m 2 "$OLLAMA_HOST/api/version" >/dev/null; then
    echo "[agent] inference unreachable at $OLLAMA_HOST — is the inference container up?" >&2
    echo "[agent] Try: tillandsias-services" >&2
    exit 1
fi
```

`tillandsias-services` (baked into every forge image) lists the enclave
services and their reachability status — see `cheatsheets/agents/`.

## Common pitfalls

- **Hard-coding `localhost:11434`** — agents that hard-code `localhost` instead of `$OLLAMA_HOST` (= `http://inference:11434`) won't reach the inference container. The DNS alias is what works on the enclave network.
- **`http://` not `https://`** — the inference endpoint is plain HTTP on the enclave bridge. Loopback-equivalent inside the enclave; secure context within the bridge boundary.
- **Pulling a model at runtime, then immediately calling it** — `/api/pull` returns when the manifest is fetched, NOT when the blobs are downloaded. Check `/api/tags` confirms the model is installed before the first `/api/generate` call (poll with backoff).
- **Streaming tokens out of order** — ollama emits `response` chunks in order on a single TCP connection, but if your client buffers naively (e.g., `cat` waiting for EOF), you'll see one big blob at the end. Use `read -r` per line, `--no-buffer` in curl, or `jq -j` (no auto-newline).
- **GPU silently CPU-fallback** — if the host has no GPU OR the inference container didn't get the GPU passthrough flags, T2+ models load slowly. Check with: `curl $OLLAMA_HOST/api/ps | jq '.models[].size_vram'`. Zero `size_vram` means CPU-only inference; you probably want a smaller tier.
- **Long context = slow responses** — even small models slow down dramatically beyond ~2k tokens. For chat applications, summarise the history into a sliding window rather than feeding the whole transcript every turn.
- **`format=json` doesn't validate against a schema** — it just constrains the output to valid JSON. The structure is still up to the model. Use `--data-raw` with explicit schema instructions in the prompt for reliable shapes.
- **Concurrent generate requests serialize** — by default ollama serves requests one at a time per model. Set `OLLAMA_NUM_PARALLEL=N` on the inference container if you need parallelism (Tillandsias defaults to N=1; raise via the `inference.parallel` config key in `~/.config/tillandsias/config.toml`).
- **No retry on cold start** — the inference container takes 1-3s to load a model into VRAM the first time. The first request after a long idle can return slowly OR time out if your client uses a tight deadline. Use a 30s timeout on first call, 5s on subsequent calls.

## See also

- `cheatsheets/runtime/forge-container.md` — the surrounding forge runtime contract; `OLLAMA_HOST` is exported as part of the forge's standard env.
- `cheatsheets/runtime/networking.md` — enclave network topology; why `inference:11434` resolves on the bridge.
- `images/default/config-overlay/ollama/models.json` — canonical tier definitions; this file is the source of truth, this cheatsheet is a snapshot.
- `images/default/config-overlay/ollama/pull-models.sh` — the GPU-aware tier puller; useful reference for what gets pulled when.
- Inside a forge: `tillandsias-models` lists installed models + tier mapping; `tillandsias-services` reports inference container health.
