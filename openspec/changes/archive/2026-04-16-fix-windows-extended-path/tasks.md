# Tasks: fix-windows-extended-path

## Investigation
- [x] Reproduce on Windows: `tillandsias .\tillandsias\ --debug` → `hostname contains invalid characters`
- [x] Identify the source: `runner.rs:322` `resolved.canonicalize()` returns `\\?\C:\...` on Windows
- [x] Confirm the same path flows into `handlers.rs::ensure_mirror` → `git clone --mirror <source> <dest>`

## Fix
- [x] Add `pub fn simplify_path(p: &Path) -> PathBuf` in `src-tauri/src/embedded.rs` (alongside the existing `bash_path` helper)
- [x] Strip `\\?\` only when the remainder begins with a drive letter; leave `\\?\UNC\...` alone
- [x] Identity behavior on non-Windows
- [x] Apply at `runner.rs::run_attach_command` immediately after `canonicalize()`
- [x] Apply defensively at `handlers.rs::ensure_mirror` (covers tray-mode callers that may not have stripped)
- [x] Add `// @trace spec:cli-mode, spec:cross-platform, spec:fix-windows-extended-path` at touched sites

## Tests
- [x] `simplify_path_strips_extended_drive_prefix` — `\\?\C:\Users\bullo\...` → `C:\Users\bullo\...`
- [x] `simplify_path_preserves_unc_paths` — `\\?\UNC\server\share\dir` unchanged
- [x] `simplify_path_passthrough_when_no_prefix` — `C:\Users\bullo` unchanged
- [x] `simplify_path_unix_paths_unchanged` — `/home/forge/src/test1` unchanged
- [x] All 4 tests pass

## Verify
- [x] `cargo check --workspace` clean
- [x] End-to-end on Windows: `tillandsias .\tillandsias\ --bash` → `Cloning mirror {project=tillandsias, source=C:\Users\bullo\src\tillandsias, ...}` → `Mirror created successfully`
- [x] Mirror origin correctly set to `https://github.com/8007342/tillandsias.git` for the remote-backed test project
- [x] Full enclave reaches "Enclave ready" and forge container starts

## Local-only support
- [x] Confirm by code reading that local-only projects (no remote) follow the same path
- [x] Document in spec scenario that workflow inside the forge is identical for local-only and remote-backed projects

## Trace + commit
- [x] OpenSpec validate
- [x] Commit body includes `https://github.com/8007342/tillandsias/search?q=%40trace+spec%3Afix-windows-extended-path&type=code`
