## Tasks

- [x] 1. Remove `url` field and `#[allow(dead_code)]` from `GhRepoEntry` in `github.rs`; also remove `url` from the `--json` query to avoid fetching unused data
- [x] 2. Remove `version_full()` function and its `#[allow(dead_code)]` from `cli.rs`
- [x] 3. Remove `#[allow(dead_code)]` from `UpdateState` in `updater.rs`
- [x] 4. Fix placeholder `@trace spec:name https://...` in `log_format.rs:259` to `@trace spec:logging-accountability`
- [x] 5. Run `cargo test --workspace` to verify nothing breaks
- [x] 6. Run `cargo clippy --workspace` to check for new warnings
