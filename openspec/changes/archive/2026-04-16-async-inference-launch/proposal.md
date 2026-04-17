# Change: async-inference-launch

## Why

`ensure_enclave_ready()` in `src-tauri/src/handlers.rs` currently awaits `ensure_inference_running()` synchronously (handlers.rs:1498). The inference container is the slowest enclave service to come up: ollama takes 15–30 s to initialize, plus a 10-attempt exponential-backoff health check that can extend the launch path by another 1–55 s. Inference is also explicitly a *soft* requirement — failure logs a `DEGRADED` warning but does not block the forge.

The forge container does not need inference to start. The user gets a usable shell within seconds of clicking "Attach Here", but only if we stop blocking on inference. Today every "Attach Here" pays the inference startup tax even when the user immediately starts editing or running shell commands that have nothing to do with the LLM.

This is the single biggest item on the path to the <2 s warm-launch target.

## What Changes

- Spawn `ensure_inference_running()` as a detached `tokio::spawn(...)` task at the same point in `ensure_enclave_ready()` where it currently awaits, instead of `await`ing it inline. Drop the `JoinHandle`; we don't need the result.
- Move the `info!`/`warn!` accountability log into the spawned task so the readiness/failure event still appears in the log, just not on the critical path.
- The build mutex (`BUILD_MUTEX` in handlers.rs:54) already serializes concurrent `podman build` calls, so the existing "must run sequentially" comment is already satisfied — the spawned task will queue behind any other in-flight build naturally.
- Forge entrypoints (and any code path that reads `inference:11434` / `localhost:11434`) must already tolerate inference being unavailable; verify and document this. `entrypoint-forge-claude.sh` and `entrypoint-forge-opencode.sh` should fail soft — quick connect probe with short timeout, fall back to "no local LLM available right now" UX.
- Add a small "inference status" line to the tray menu (or the existing `--log-enclave` output) so the user can see *was inference ready when you launched* without surprise.
- Add `@trace spec:inference-container, spec:async-inference-launch` to the new spawn site and a startup-time timer log to confirm the savings empirically.

## Capabilities

### Modified Capabilities
- `inference-container`: launch is fire-and-forget from `ensure_enclave_ready`; readiness/failure logged from inside the spawned task, not on the critical path.
- `enclave-network`: the readiness log line at the end of `ensure_enclave_ready` now reflects "proxy + git ready; inference launching async" instead of "all three ready".

### New Capabilities
None — behavior change to existing capability.
