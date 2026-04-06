## 1. Add FD sanitization to podman command constructors

- [x] 1.1 Add `libc` dependency to `tillandsias-podman` crate's Cargo.toml (Linux target only)
- [x] 1.2 Add `pre_exec` FD cleanup hook to `podman_cmd_sync()` in `crates/tillandsias-podman/src/lib.rs`
- [x] 1.3 Add `pre_exec` FD cleanup hook to `podman_cmd()` (async variant) in the same file
- [x] 1.4 Gate the pre_exec blocks with `#[cfg(target_os = "linux")]`

## 2. Verify

- [x] 2.1 Run `./build.sh --check` — compilation succeeds with no new warnings
- [x] 2.2 Run `./build.sh` — full debug build succeeds
- [x] 2.3 Run `tillandsias . --bash` from the dev build to verify container launch works
