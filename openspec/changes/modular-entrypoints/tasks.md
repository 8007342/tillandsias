## 1. Create Shared Library

- [ ] 1.1 Create `images/default/entrypoint-common.sh` with shared setup: `set -euo pipefail`, `umask 0022`, `trap`, secrets dirs, `gh auth setup-git`, shell config deployment, common PATH setup
- [ ] 1.2 Verify the library is sourceable (no `exit`, no `exec`, exports only what is needed)
- [ ] 1.3 Update `flake.nix` to copy `entrypoint-common.sh` to `/usr/local/lib/tillandsias/entrypoint-common.sh` in the image

## 2. Create Per-Type Entrypoints

- [ ] 2.1 Create `images/default/entrypoint-forge-opencode.sh`: source common, install/update OpenCode, install OpenSpec, find project dir, openspec init, print banner, `exec env opencode`
- [ ] 2.2 Create `images/default/entrypoint-forge-claude.sh`: source common, install/update Claude Code, install OpenSpec, find project dir, openspec init, print banner, `exec env ANTHROPIC_API_KEY="$_CLAUDE_KEY" claude`
- [ ] 2.3 Create `images/default/entrypoint-terminal.sh`: source common, find project dir, print welcome banner (via `forge-welcome.sh`), `exec fish`
- [ ] 2.4 Each entrypoint must be independently executable (`chmod +x`, proper shebang, no dependency on being called from another script)

## 3. Update Image Build

- [ ] 3.1 Update `flake.nix` `fakeRootCommands` to copy all new entrypoints to `/usr/local/bin/` and the library to `/usr/local/lib/tillandsias/`
- [ ] 3.2 Update `flake.nix` image `config.Entrypoint` to use `entrypoint-forge-claude.sh` (default agent)
- [ ] 3.3 Keep the old `tillandsias-entrypoint.sh` as a backward-compat redirect that dispatches based on `TILLANDSIAS_AGENT`
- [ ] 3.4 Add all new files to the `forgeEntrypoint*` local file references at the top of `flake.nix` so changes trigger rebuilds

## 4. Update Rust Launch Code

- [ ] 4.1 In `handlers.rs::build_run_args()`, add `--entrypoint` argument based on agent selection: `SelectedAgent::OpenCode` -> `entrypoint-forge-opencode.sh`, `SelectedAgent::Claude` -> `entrypoint-forge-claude.sh`
- [ ] 4.2 In `handlers.rs::handle_terminal()`, replace `--entrypoint fish` with `--entrypoint /usr/local/bin/entrypoint-terminal.sh`
- [ ] 4.3 In `handlers.rs::handle_root_terminal()`, replace `--entrypoint fish` with `--entrypoint /usr/local/bin/entrypoint-terminal.sh`
- [ ] 4.4 In `runner.rs::build_run_args()`, add `--entrypoint` argument based on agent selection (same logic as 4.1)
- [ ] 4.5 In `runner.rs` bash mode, replace `--entrypoint fish` with `--entrypoint /usr/local/bin/entrypoint-terminal.sh`

## 5. Privacy Enforcement

- [ ] 5.1 In `handlers.rs::build_run_args()`, conditionally mount Claude dir and inject API key ONLY when agent is Claude (currently always mounted)
- [ ] 5.2 In `runner.rs::build_run_args()`, same conditional mount logic
- [ ] 5.3 In `handle_terminal()` and `handle_root_terminal()`, remove Claude dir mount and API key injection entirely (terminal doesn't need agent secrets)
- [ ] 5.4 Verify: launch an OpenCode forge, confirm `~/.claude` is NOT mounted inside the container
- [ ] 5.5 Verify: launch a maintenance terminal, confirm neither `~/.claude` nor `ANTHROPIC_API_KEY` is present

## 6. Image Rebuild and Test

- [ ] 6.1 Rebuild forge image via `scripts/build-image.sh forge --force`
- [ ] 6.2 Test: Claude forge launch — verify `entrypoint-forge-claude.sh` runs, Claude Code starts
- [ ] 6.3 Test: OpenCode forge launch — verify `entrypoint-forge-opencode.sh` runs, OpenCode starts
- [ ] 6.4 Test: Maintenance terminal — verify `entrypoint-terminal.sh` runs, fish starts with welcome banner and proper PATH
- [ ] 6.5 Test: Old cached image (if possible) — verify backward-compat redirect still works
- [ ] 6.6 Test: `cargo test --workspace` passes
