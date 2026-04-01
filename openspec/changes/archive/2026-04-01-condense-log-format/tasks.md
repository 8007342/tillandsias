## 1. Custom Formatter

- [x] 1.1 Create `src-tauri/src/log_format.rs` with `EventFields` visitor that classifies fields into accountability metadata vs regular fields
- [x] 1.2 Implement `TillandsiasFormat` struct with `FormatEvent<S, N>` trait — compact format for regular events, structured multi-line for accountability events
- [x] 1.3 Add `shorten_target()` helper and `level_ansi()` color helper
- [x] 1.4 Add unit tests for `shorten_target` and field classification

## 2. Subscriber Integration

- [x] 2.1 Add `mod log_format;` to `src-tauri/src/main.rs`
- [x] 2.2 Update `logging::init()` — replace default file format with `.event_format(TillandsiasFormat)`
- [x] 2.3 Update `logging::init()` — replace `.pretty()` stderr format with `.event_format(TillandsiasFormat)`
- [x] 2.4 Remove `AccountabilityLayer` construction and `.with(accountability_layer)` from subscriber stack

## 3. Verify

- [x] 3.1 Build with `cargo build --workspace` — no compile errors
- [x] 3.2 Run `cargo test --workspace` — all existing tests pass
- [x] 3.3 Run `cargo clippy --workspace` — no new warnings
