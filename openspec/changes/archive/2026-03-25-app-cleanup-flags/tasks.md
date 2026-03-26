## 1. OpenSpec

- [x] 1.1 Write proposal.md
- [x] 1.2 Write tasks.md
- [x] 1.3 Write specs/app-cleanup-flags/spec.md

## 2. CLI Parser

- [x] 2.1 Add `Stats` variant to `CliMode` enum in `cli.rs`
- [x] 2.2 Add `Clean` variant to `CliMode` enum in `cli.rs`
- [x] 2.3 Parse `--stats` and `--clean` flags in `cli::parse()`
- [x] 2.4 Update `USAGE` string to document new flags

## 3. Implementation

- [x] 3.1 Create `src-tauri/src/cleanup.rs` with `run_stats()` and `run_clean()`
- [x] 3.2 Implement podman image listing (images matching `tillandsias-*` or `macuahuitl*`) with sizes
- [x] 3.3 Implement container listing (all containers matching `tillandsias-*`) with status
- [x] 3.4 Implement disk usage checks for Nix cache, Cargo cache, and installed binary
- [x] 3.5 Implement `run_clean()`: podman image prune, stopped container removal, Nix cache wipe
- [x] 3.6 Dispatch `CliMode::Stats` and `CliMode::Clean` early in `main.rs`

## 4. build.sh

- [x] 4.1 Add `podman image prune -f` after successful debug build
- [x] 4.2 Add `podman image prune -f` after successful release build

## 5. Verification

- [x] 5.1 `cargo check --workspace` passes
- [ ] 5.2 `tillandsias --stats` prints expected output on a machine with images
- [ ] 5.3 `tillandsias --clean` removes stopped containers and dangling images
