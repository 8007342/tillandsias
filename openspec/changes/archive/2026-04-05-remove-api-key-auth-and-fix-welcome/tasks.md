## 1. Remove API key from container profiles and launch

- [x] 1.1 Remove `SecretKind::ClaudeApiKey` variant from `container_profile.rs`
- [x] 1.2 Remove `claude_api_key: Option<String>` from `LaunchContext` (now non-optional `claude_dir: PathBuf`)
- [x] 1.3 Remove `ClaudeApiKey` handling from `build_podman_args()` in `launch.rs`
- [x] 1.4 Remove `claude_api_key` population in `runner.rs` and `handlers.rs`
- [x] 1.5 Ensure `~/.claude/` is always created and mounted (even on first run before auth)

## 2. Remove API key keyring and prompt infrastructure

- [x] 2.1 Remove `store_claude_api_key()` and `retrieve_claude_api_key()` from `secrets.rs`
- [x] 2.2 Remove `CLAUDE_API_KEY_KEY` constant from `secrets.rs`
- [x] 2.3 Delete `claude-api-key-prompt.sh`
- [x] 2.4 Remove embedded `CLAUDE_API_KEY_PROMPT` constant from `embedded.rs`

## 3. Remove ClaudeLogin handler and menu command

- [x] 3.1 Replace `ClaudeLogin` with `ClaudeResetCredentials` variant in `MenuCommand` in `event.rs`
- [x] 3.2 Remove `handle_claude_login()`, add `handle_claude_reset_credentials()` in `handlers.rs`
- [x] 3.3 Replace `ClaudeLogin` dispatch with `ClaudeResetCredentials` in `event_loop.rs`
- [x] 3.4 Replace `CLAUDE_LOGIN` with `CLAUDE_RESET_CREDENTIALS` menu ID constant
- [x] 3.5 Update dispatch in `handle_menu_click()` in `main.rs`

## 4. Add Claude Reset Credentials menu item

- [x] 4.1 Replace Claude Login/Refresh menu item with "Claude Reset Credentials" in Seedlings submenu
- [x] 4.2 Only show when `~/.claude/` exists and has content (lock icon)
- [x] 4.3 Handler removes `~/.claude/` contents, sends notification, rebuilds menu

## 5. Clean up entrypoint

- [x] 5.1 Remove API key capture/scrub from `entrypoint-forge-claude.sh` (`_CLAUDE_KEY`, `ANTHROPIC_API_KEY`)
- [x] 5.2 Simplify final `exec` — no conditional key injection, just `exec "$CC_BIN" "$@"`

## 6. Fix double welcome

- [x] 6.1 Export `TILLANDSIAS_WELCOME_SHOWN=1` in `entrypoint-terminal.sh` before `exec fish`

## 7. Update locale strings

- [x] 7.1 Replace `claude.login` / `claude.login_refresh` with `claude.reset_credentials` in `en.toml`
- [x] 7.2 Same for `es.toml`
- [x] 7.3 Replace `claude_key_saved` notification with `claude_credentials_cleared`

## 8. Verify

- [x] 8.1 `./build-osx.sh --check` compiles clean
- [x] 8.2 `./build-osx.sh --test` — all 55 tests pass
- [x] 8.3 Installed and verified with `tillandsias --version`
