# Tasks: async-inference-launch

## Refactor
- [x] Verify `TrayState` shareability across spawned tasks — `#[derive(Clone)]` on the struct in `crates/tillandsias-core/src/state.rs:191`
- [x] Replace the inline `match ensure_inference_running(...).await` in `ensure_enclave_ready` (handlers.rs ~line 1498) with `tokio::spawn(async move { ... })`
- [x] Move the `info!`/`warn!` accountability log into the spawned task body
- [x] Add an `Instant::now()` timer at spawn site and log elapsed seconds when the spawned task completes (both Ok and Err paths)
- [x] Update the "Enclave ready" log line at the end of `ensure_enclave_ready` to reflect "inference launching async"
- [x] Add `@trace spec:inference-container, spec:async-inference-launch` to the new spawn site

## Forge entrypoint tolerance
- [ ] Audit `images/default/entrypoint-forge-claude.sh` for any inference URL references; confirm graceful behavior
- [ ] Update `images/default/entrypoint-forge-opencode.sh` to probe `http://inference:11434/api/version` with `curl -m 1 -sf` before setting local-LLM env vars
- [ ] On probe failure, unset opencode's local-LLM env vars so it uses cloud or no-LLM mode (do NOT crash)

## Verify
- [ ] Local build (`./build-local.sh`) passes
- [ ] Manual: launch the tray, click "Attach Here", measure time from click to terminal open vs. baseline; both warm and cold inference cases
- [ ] Manual: kill the inference container after launch; confirm forge still works (probe falls back)
- [ ] Manual: check `--log-enclave` output for the new "inference ready (async)" line and the elapsed-seconds log

## Cheatsheet
- [ ] Update `docs/cheatsheets/enclave-architecture.md` to document the async-launch behavior and the `inference:11434` probe contract for forge entrypoints

## Trace + commit
- [ ] Commit body includes `https://github.com/8007342/tillandsias/search?q=%40trace+spec%3Aasync-inference-launch&type=code`
- [ ] `npx openspec validate async-inference-launch`
