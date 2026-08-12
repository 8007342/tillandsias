# Freshness audit — local inference cheatsheet — 2026-08-12

- **Classification**: optimization
- **Status**: completed
- **Auditor**: `forge-antigravity-20260812t1500z`
- **Component**: `images/default/cheatsheets/runtime/local-inference.md`
- **Disposition**: **refreshed**

The freshness inventory identified `images/default/cheatsheets/runtime/local-inference.md` as the next unstamped component to audit.
The cheatsheet documents local LLM inference integration inside the Tillandsias forge container via Ollama on the enclave network.

Audit findings:
1. **Meaningful & Useful**: The cheatsheet documents key API endpoints (`/api/version`, `/api/tags`, `/api/generate`, `/api/chat`, `/api/pull`, `/api/embed`), port conventions (`http://inference:11434`), `$OLLAMA_HOST` env var, and common patterns (routing, JSON output, streaming, embeddings, startup reachability).
2. **Sound & Complete**: Endpoint specifications match the upstream Ollama 0.5.x API and the current running forge environment (`inference_state=ready inference_models=1 inference_warm=qwen2.5:0.5b`).
3. **Model Tiers**: Shipped model tiers T0–T4 (`qwen2.5:0.5b`, `tinyllama:1.1b`, `phi3.5:3.8b`, `qwen2.5-coder:7b`, `llama3.2:8b`) correctly reflect the baked tier definitions in `images/default/config-overlay/ollama/models.json`.

Disposition: **refreshed** — stamped with `# freshness: auditor=forge-antigravity-20260812t1500z date=2026-08-12 verdict=refreshed scope=re-validated: ollama API endpoints (/api/generate, /api/chat, /api/pull, /api/embed, /api/version, /api/tags), port 11434, OLLAMA_HOST env var, tier table T0-T4, and json format patterns verified sound and matching current runtime`.
