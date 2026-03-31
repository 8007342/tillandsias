## Why

Tillandsias currently has a single-layer logging system: `tracing` with an `EnvFilter` that reads from `TILLANDSIAS_LOG` or `RUST_LOG`, defaulting to `tillandsias=info`. There is no CLI flag for controlling log levels, no per-module granularity from the user's perspective, and no way to inspect specific subsystems (like secret handling or container lifecycle) without enabling verbose output for the entire application.

This matters for three reasons:

1. **Debugging is coarse.** When a user reports "my container didn't start," the developer asks them to set `TILLANDSIAS_LOG=debug`, which dumps thousands of irrelevant lines from the scanner, menu, and updater alongside the handful of container-launch lines that matter.

2. **Accountability is invisible.** Tillandsias handles sensitive operations (secret injection, token rotation, image updates) on behalf of the user, but there is no way to inspect what those subsystems did, why they did it, or how. Trust requires transparency.

3. **Spec traceability is disconnected.** Every source file has `@trace spec:...` annotations linking code to specs, but these annotations are only useful to developers reading source. Users (and auditors) have no way to follow the spec trail from runtime behavior back to design decisions.

## What Changes

- **Per-module log levels via CLI flag**: `--log=secrets:trace;containers:debug;scanner:off` — parsed at startup, translated to `tracing::EnvFilter` directives. Six named modules map to Rust module paths.
- **Accountability windows**: Special log modes (`--log-secret-management`, future `--log-image-management`, `--log-update-cycle`) that enable a curated view of a specific subsystem's operations — what was done, why (spec link), how (cheatsheet link), and which version.
- **Zero-cost at lower levels**: Higher-detail log macros (trace, debug) are compile-time NOOPs when the module is at a lower level. The `tracing` crate already provides this via `enabled!` guards, but we formalize it as a project convention.
- **Clickable spec URLs at trace level**: The most detailed log level includes GitHub code search URLs linking to the `@trace` annotations for the spec that governs the logged operation. These URLs are the same format used in commit messages today.

## Capabilities

### New Capabilities
- `logging-accountability`: Per-module log levels, accountability windows, and spec-linked trace output

### Modified Capabilities
- `runtime-logging`: Current file+stderr logging gains CLI-driven filter control
- `cli-mode`: New `--log=...` flag and `--log-secret-management` accountability flag

## Impact

- **Modified files**: `src-tauri/src/logging.rs` (filter construction from CLI args), `src-tauri/src/cli.rs` (new flags), `src-tauri/src/main.rs` (pass log config to init), `src-tauri/src/secrets.rs` (accountability-aware log messages), `src-tauri/src/handlers.rs` (accountability-aware log messages)
- **New files**: `src-tauri/src/accountability.rs` (accountability window formatting and spec URL generation)
- **User-visible change**: New CLI flags in `--help` output. No behavior change without flags.
- **Dependency on**: `cli-welcome-help-redesign` (for the `--help` layout), but can be implemented independently — the flags work regardless of help formatting.
