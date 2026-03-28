## 1. OpenSpec

- [x] 1.1 Write proposal.md
- [x] 1.2 Write tasks.md
- [x] 1.3 Write specs/claude-api-key-login/spec.md

## 2. Implementation — Keyring Storage

- [x] 2.1 Add `CLAUDE_API_KEY_KEY` constant and `store_claude_api_key()` to `secrets.rs`
- [x] 2.2 Add `retrieve_claude_api_key()` to `secrets.rs`
- [ ] 2.3 Add unit tests for Claude API key keyring functions

## 3. Implementation — Menu & Event

- [x] 3.1 Add `MenuCommand::ClaudeLogin` to `event.rs`
- [x] 3.2 Add `CLAUDE_LOGIN` ID constant and `claude_login()` helper to `menu.rs` ids
- [x] 3.3 Add Claude Login item to `build_seedlings_submenu()` with key status indicator
- [x] 3.4 Add `claude-login` dispatch case in `handle_menu_click()` in `main.rs`
- [x] 3.5 Handle `MenuCommand::ClaudeLogin` in `event_loop.rs`

## 4. Implementation — Login Handler

- [x] 4.1 Create `claude-api-key-prompt.sh` embedded script
- [x] 4.2 Embed script in `embedded.rs` via `include_str!`
- [x] 4.3 Implement `handle_claude_login()` in `handlers.rs` — extract script, open terminal, read temp file, store in keyring

## 5. Implementation — Container Injection

- [x] 5.1 Add `ANTHROPIC_API_KEY` env var to `build_run_args()` in `handlers.rs` (when key present in keyring)
- [x] 5.2 Add `ANTHROPIC_API_KEY` env var to `handle_terminal()` format string
- [x] 5.3 Add `ANTHROPIC_API_KEY` env var to `handle_root_terminal()` format string
- [x] 5.4 Add `ANTHROPIC_API_KEY` env var to `build_run_args()` in `runner.rs` (CLI mode)

## 6. Implementation — Entrypoint Key Scrubbing

- [x] 6.1 Capture `ANTHROPIC_API_KEY` into local var and unset from environment in `entrypoint.sh`
- [x] 6.2 Re-inject key only into claude exec in the `claude)` case branch

## 7. Implementation — Credential Isolation

- [x] 7.1 Add `/proc/*/environ` to deny list in `opencode.json`

## 8. Verification

- [x] 8.1 `./build.sh --check` passes
- [x] 8.2 `./build.sh --test` passes
