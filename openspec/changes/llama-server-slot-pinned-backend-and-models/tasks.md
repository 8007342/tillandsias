# Tasks: llama-server-slot-pinned-backend-and-models (order 482b)

- [x] Backend selection (vulkan on a usable render node, else cpu; cuda/rocm refused off their lane), pinned with GGML_BACKEND_PATH
- [x] Closure verdict: unpinned multi-backend payload refused; engine set must name the selected backend
- [x] gguf-pins.tsv (T0) and fail-closed ensure: unpinned refused, mismatch refused and deleted
- [x] caddy shim on :11434, /api/version from a healthy /health; supervised pair exits non-zero when either dies
- [x] litmus:inference-llama-server-lane-shape
- [ ] 482-igky: per-shard pins for the remaining tier rows
- [ ] Sync this delta into openspec/specs/inference-engine-slots/spec.md and archive after the PR lands
