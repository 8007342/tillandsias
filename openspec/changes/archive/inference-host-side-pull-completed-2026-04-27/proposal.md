## Why

Per `~/src/java/local_model_testrun.md`: agents need higher-tier models (T2-T5) for analysis tasks but the in-container ollama pull goes through Squid which `project_squid_ollama_eof.md` documents EOFs hard on big manifests. Plus the user's directive: "Models lazily load on the background automatically on first launch, only the correct sizes for the supported tier."

Per the new no-new-UX rule: this is **fully automatic, host-driven, no tray menu item**. VRAM detection (already in `gpu.rs`) decides the tier; the host tray triggers `ollama pull` host-side; bytes land in `~/.cache/tillandsias/models/` which the inference container already bind-mounts.

## What Changes

- **NEW** Background task spawned by the tray right after the inference container reports ready. Reads VRAM from `gpu.rs`, picks tier (T0-T5), pulls models that aren't already cached.
- **NEW** Pull goes via `ollama` host-side (not in-container) — bypasses Squid entirely. Bytes land in `~/.cache/tillandsias/models/` (already bind-mounted into inference RW). Inference container picks them up on next `/api/tags` call (ollama re-scans on demand).
- **NEW** Download events emit via `download_telemetry` (per `forge-cache-architecture`'s `download-telemetry` capability). Source is `inference-host-pull`.
- **NEW** Tier model mapping (audit-cited):
  - T0 baked: `qwen2.5:0.5b`
  - T1 baked: `llama3.2:3b`
  - T2 lazy: `qwen2.5-coder:7b`
  - T3 lazy: `qwen2.5-coder:14b`
  - T4 lazy: `gpt-oss:20b`
  - T5 lazy: `qwen2.5-coder:32b`
- **NEW** Cache-resume: ollama pulls are resumable. Skip if `manifests/registry.ollama.ai/library/<name>/<tag>` exists AND blob sizes match.
- **NO** tray menu item. **NO** notification. **NO** prompt. Background only. Power user can inspect via `tillandsias --download-stats` (per `forge-cache-architecture`).

## Capabilities

### New Capabilities
- `inference-host-side-pull` — host-side lazy model pull, fully automatic, no UX surface.

### Modified Capabilities
- `inference-container`: documents that T2-T5 arrive via host-side pull (not in-container). Existing T0+T1 baked behavior unchanged.

## Impact

- New module `src-tauri/src/inference_lazy_pull.rs` (~200 LOC).
- Spawned from inference startup path in `handlers.rs::ensure_inference_running`. Fire-and-forget; logs progress + emits download telemetry events.
- Shells out to `ollama` (host-side binary) — host needs ollama installed. If missing, log a `RUNTIME_LIMITATIONS`-style report (host-side equivalent) and skip.
- No image change. No new tray UX. No changes to the inference container itself.

## Sources of Truth

- `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md` — confirms `~/.cache/tillandsias/models/` is host-managed shared state.
- `cheatsheets/runtime/forge-shared-cache-via-nix.md` — sister concept (different cache; same "host populates, container reads" pattern).
- (Host memory) `project_squid_ollama_eof.md` — the workaround this change embodies.
