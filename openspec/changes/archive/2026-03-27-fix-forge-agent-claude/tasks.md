## 1. Change default agent to Claude

- [x] 1.1 In `crates/tillandsias-core/src/config.rs:27`, change `SelectedAgent::default()` to return `Self::Claude`
- [x] 1.2 Update `entrypoint.sh:37` default from `opencode` to `claude`: `AGENT="${TILLANDSIAS_AGENT:-claude}"`

## 2. Remove opencode from entrypoint

- [x] 2.1 Make `install_opencode()` conditional — only runs if `TILLANDSIAS_AGENT=opencode`
- [x] 2.2 Remove unconditional `$CACHE/opencode` mkdir; keep `$OS_PREFIX` and `$CACHE/nix`
- [x] 2.3 Remove opencode from PATH (entrypoint): keep only `$OS_PREFIX/bin:$PATH`
- [ ] 2.4 Remove the `opencode` case from the launch switch (lines 131-138): only keep claude + fallback to bash
- [x] 2.5 Update `openspec init --tools opencode` (line 105) to `--tools claude`

## 3. Remove opencode from shell configs

- [x] 3.1 `images/default/shell/bashrc:13` -- replace opencode with claude/bin in PATH
- [x] 3.2 `images/default/shell/zshrc:9` -- replace opencode with claude/bin in PATH
- [x] 3.3 `images/default/shell/config.fish:10` -- replace opencode with claude/bin in fish_add_path

## 4. Remove opencode.json and its references

- [ ] 4.1 Delete `images/default/opencode.json`
- [ ] 4.2 In `flake.nix:16`, remove `forgeOpencode = ./images/default/opencode.json;`
- [ ] 4.3 In `flake.nix:82-83`, remove `mkdir -p ./home/forge/.cache/tillandsias/{nix,opencode}` -- keep only nix
- [ ] 4.4 In `flake.nix:93-94`, remove `cp ${forgeOpencode} ./home/forge/.config/opencode/config.json`
- [ ] 4.5 In `src-tauri/src/embedded.rs:38`, remove `FORGE_OPENCODE_JSON` constant
- [ ] 4.6 In `src-tauri/src/embedded.rs:101,144-145`, remove opencode.json from extraction list and write call

## 5. Fix Claude auth: mount host ~/.claude/ for OAuth

- [x] 5.1 In `handlers.rs:469-473` (`build_run_args()`): changed to `dirs::home_dir().join(".claude")`
- [x] 5.2 In `runner.rs:221-225`: same change -- mount host `~/.claude/` instead of empty secrets dir
- [x] 5.3 In `handlers.rs:934-935,965` (`handle_terminal()`): same mount path change
- [x] 5.4 In `handlers.rs:1096-1097,1127` (`handle_root_terminal()`): same mount path change
- [x] 5.5 Removed `std::fs::create_dir_all(&claude_dir)` calls -- the host `~/.claude/` should already exist from `claude login`

## 6. Remove API key infrastructure

- [ ] 6.1 Remove `ANTHROPIC_API_KEY` env var injection from `handlers.rs:463-465` (`build_run_args()`)
- [ ] 6.2 Remove `ANTHROPIC_API_KEY` env var injection from `runner.rs:215-217`
- [ ] 6.3 Remove `claude_api_key_arg` from `handlers.rs:941-943` (`handle_terminal()`)
- [ ] 6.4 Remove `claude_api_key_arg` from `handlers.rs:1103-1105` (`handle_root_terminal()`)
- [ ] 6.5 Remove API key capture/scrubbing from `entrypoint.sh:41-42` (`_CLAUDE_KEY` / `unset ANTHROPIC_API_KEY`)
- [x] 6.6 Remove `env ANTHROPIC_API_KEY=...` from claude exec in entrypoint (lines 121-122) — claude now uses OAuth via mounted ~/.claude/
- [ ] 6.7 Remove `store_claude_api_key()` and `retrieve_claude_api_key()` from `secrets.rs`
- [ ] 6.8 Remove `CLAUDE_API_KEY_KEY` constant from `secrets.rs:36`
- [ ] 6.9 Delete `claude-api-key-prompt.sh` from project root
- [ ] 6.10 Remove `CLAUDE_API_KEY_PROMPT` from `embedded.rs:24`

## 7. Update Claude Login menu action

- [ ] 7.1 Decide: either (a) run `claude login` on the host via terminal, or (b) remove the menu item entirely if auth is expected to be done externally
- [ ] 7.2 If keeping: update `handle_claude_login()` in `handlers.rs:1266` to run `claude login` instead of the API key prompt script
- [ ] 7.3 Update menu label/state logic in `menu.rs:458-466` -- no longer checks keyring for claude key; could check if `~/.claude/` exists and has credentials

## 8. Update flake.nix image build

- [ ] 8.1 Remove `mkdir -p ./home/forge/.config/opencode` from fakeRootCommands
- [ ] 8.2 Remove opencode config copy from fakeRootCommands
- [ ] 8.3 Verify `mkdir -p ./home/forge/.cache/tillandsias/nix` still works without the opencode joint mkdir
- [ ] 8.4 Add `mkdir -p ./home/forge/.cache/tillandsias/claude` for npm-installed claude code cache

## 9. Rebuild and test

- [ ] 9.1 Rebuild forge image: `scripts/build-image.sh forge --force`
- [ ] 9.2 Rebuild app: `./build.sh`
- [ ] 9.3 Test: click "Attach Here" -- should launch claude, not opencode
- [ ] 9.4 Test: claude should authenticate via OAuth (no API key prompt)
- [ ] 9.5 Test: maintenance terminal (fish shell) should not have opencode in PATH
- [ ] 9.6 Test: new config files default to `[agent]\nselected = "claude"`

## Notes

- The entrypoint still installs OpenSpec via npm -- this is independent of the agent choice
- Claude Code's own permission system replaces the role of `opencode.json` deny lists
- The `opencode` directory references in `flake.nix` line 64 comment and line 82 mkdir should both be cleaned up
- Consider whether to keep `SelectedAgent::OpenCode` in the Rust enum for config backward compatibility (existing config files with `selected = "opencode"` would fail to parse if the variant is removed)
- Items in sections 4, 6-8 are deferred — they are a bigger refactor (removing opencode.json, API key infra, flake.nix cleanup) and will be done in a follow-up change
