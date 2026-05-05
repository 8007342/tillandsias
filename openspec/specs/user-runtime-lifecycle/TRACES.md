# Traces for user-runtime-lifecycle

Code implementing this spec (auto-generated — do not edit).
Run `./scripts/generate-traces.sh` to regenerate.

## Annotated locations

To be populated after first implementation. Add `@trace spec:user-runtime-lifecycle` annotations to:

- src-tauri/src/main.rs — First-launch detection, automatic init
- src-tauri/src/init.rs — Initialization sequence
- src-tauri/src/handlers.rs — Version detection, staleness check
- scripts/build-image.sh — Image building and embedding
- build.sh — Developer workflow

## Implementation Checklist

- [ ] First-launch detection: Check if containers exist
- [ ] Automatic `--init` on first launch (no user action required)
- [ ] Version mismatch detection (binary vs image tags)
- [ ] Container rebuild on update
- [ ] Host pristineness guarantee (no ~/.config/tillandsias/ files)
- [ ] Cache directory validation (~/.cache/tillandsias/)
- [ ] Idempotent container creation (can run multiple times safely)
- [ ] Shutdown cleanup (stop, remove, destroy network)
