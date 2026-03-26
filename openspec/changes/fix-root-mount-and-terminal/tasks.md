## 1. Fix root mount double-nesting

- [ ] 1.1 In `build_run_args()`, detect when `project_path.file_name()` == the last component of the watch path (i.e., the path IS the watch root, not a project inside it) and mount at `/home/forge/src/` instead of `/home/forge/src/<name>/`
- [ ] 1.2 Alternatively, fix in `handle_attach_here()` by adjusting the project_path before calling `build_run_args()` when the path is the watch root

## 2. Fix root terminal entrypoint

- [ ] 2.1 Change `--entrypoint bash` to `--entrypoint fish` in `handle_root_terminal()`

## 3. Verification

- [ ] 3.1 `cargo check --workspace` passes
- [ ] 3.2 `cargo test --workspace` passes
- [ ] 3.3 Manual: Root "Attach Here" mounts `~/src/` at `/home/forge/src/` (not `src/src/`)
- [ ] 3.4 Manual: Root terminal opens fish with welcome banner
