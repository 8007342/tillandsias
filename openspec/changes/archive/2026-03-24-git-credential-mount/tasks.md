## 1. Add credential volume mounts to tray-mode launcher

- [x] 1.1 In `src-tauri/src/handlers.rs`, update `build_run_args` to create `secrets/{gh,git}` directories and add `-v` mounts for `~/.config/gh` and `~/.gitconfig`

## 2. Add credential volume mounts to CLI-mode launcher

- [x] 2.1 In `src-tauri/src/runner.rs`, update `build_run_args` to create `secrets/{gh,git}` directories and add `-v` mounts for `~/.config/gh` and `~/.gitconfig`

## 3. Update container entrypoint

- [x] 3.1 In `images/default/entrypoint.sh`, add early directory/file creation to ensure mount targets exist before tools access them

## 4. Build verification

- [x] 4.1 Run `cargo build --workspace` and confirm compilation succeeds with no errors
