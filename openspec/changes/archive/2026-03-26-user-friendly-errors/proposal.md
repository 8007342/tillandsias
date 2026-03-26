## Why

Error messages returned by Tillandsias handlers currently contain developer-facing text: internal script names (`build-image.sh`), image tags (`tillandsias-forge:latest`), shell invocations (`./build.sh --install`), and exit codes. These strings leak implementation details to users who have no context for them and cannot act on them.

Tillandsias's core convention is that users never see containers, images, or internal tooling — only plant lifecycle language and outcome-focused messages. Error strings visible to users must follow the same rule.

## What Changes

- **`src-tauri/src/handlers.rs`** — sanitize all `Err()` return strings in the attach, terminal, and build-image paths; keep full detail in `tracing::error!` / `tracing::warn!` logs
- **`src-tauri/src/runner.rs`** — sanitize the image-not-found error printed via `eprintln!` in CLI mode
- **`src-tauri/src/init.rs`** — sanitize the build failure `Err()` message that propagates to CLI output

## Capabilities

### New Capabilities
(none)

### Modified Capabilities
- `tray-app`: Error messages shown to users are outcome-focused and free of internal paths, image names, script names, and exit codes

## Impact

- **Modified files**: `src-tauri/src/handlers.rs`, `src-tauri/src/runner.rs`, `src-tauri/src/init.rs`
- **No behavior change**: Detailed errors are preserved in structured logs; only the user-visible strings are sanitized
