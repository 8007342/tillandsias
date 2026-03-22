## 1. Logging Infrastructure

- [x] 1.1 Add `tracing-appender` to workspace dependencies in root Cargo.toml and src-tauri/Cargo.toml
- [x] 1.2 Create `src-tauri/src/logging.rs` module: init function that sets up dual subscriber (stderr if TTY + file appender to state dir)
- [x] 1.3 Use `TILLANDSIAS_LOG` env var for filtering (default: `tillandsias=info`), fall back to `RUST_LOG` if set
- [x] 1.4 Platform-aware log directory: Linux `~/.local/state/tillandsias/`, macOS `~/Library/Logs/tillandsias/`, Windows `%LOCALAPPDATA%/tillandsias/logs/`
- [x] 1.5 Remove `#[cfg(debug_assertions)]` guard from logging init in main.rs — enable in all builds

## 2. Lifecycle Spans

- [x] 2.1 Add tracing instrument spans to handlers.rs: handle_attach_here, handle_stop, handle_destroy with structured fields (container.name, project, genus)
- [x] 2.2 Add image build span with duration tracking in podman client ensure_image_built
- [x] 2.3 Add scanner lifecycle logging: initial scan count, watch start, project discovered/removed events

## 3. Build and Test

- [ ] 3.1 Build, install, run from terminal and verify logs appear on stderr
- [ ] 3.2 Verify log file is created at ~/.local/state/tillandsias/tillandsias.log
- [ ] 3.3 Test TILLANDSIAS_LOG=tillandsias=debug shows debug output
