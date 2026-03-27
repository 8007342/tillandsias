## 1. OpenSpec

- [x] 1.1 Write proposal.md
- [x] 1.2 Write tasks.md
- [x] 1.3 Write specs/agent-selection-claude/spec.md

## 2. Implementation — Core Types

- [x] 2.1 Add `SelectedAgent` enum and `AgentConfig` to `config.rs` with serde + Default (opencode)
- [x] 2.2 Add `AgentConfig` field to `GlobalConfig`
- [x] 2.3 Add `MenuCommand::SelectAgent { agent: String }` to `event.rs`

## 3. Implementation — Menu

- [x] 3.1 Add `ids::select_agent(agent_name)` helper to `menu.rs`
- [x] 3.2 Build Seedlings submenu inside `build_settings_submenu()` with pin emoji on selected agent
- [x] 3.3 Add `select-agent` dispatch case in `handle_menu_click()` in `main.rs`

## 4. Implementation — Event Loop

- [x] 4.1 Handle `MenuCommand::SelectAgent` in `event_loop.rs`: update config file, rebuild menu

## 5. Implementation — Container Launch

- [x] 5.1 Add `TILLANDSIAS_AGENT` env var to `build_run_args()` in `handlers.rs`
- [x] 5.2 Add `TILLANDSIAS_AGENT` env var to `handle_terminal()` format string
- [x] 5.3 Add `TILLANDSIAS_AGENT` env var to `handle_root_terminal()` format string
- [x] 5.4 Mount `~/.cache/tillandsias/secrets/claude/` as `/home/forge/.claude:rw` in `build_run_args()`
- [x] 5.5 Mount Claude secrets in `handle_terminal()` and `handle_root_terminal()`

## 6. Implementation — Entrypoint

- [x] 6.1 Add Claude Code install + launch branch to `entrypoint.sh` gated by `TILLANDSIAS_AGENT`

## 7. Implementation — Credential Isolation

- [x] 7.1 Add `~/.claude` and `/home/forge/.claude` to deny list in `opencode.json`

## 8. Verification

- [x] 8.1 `./build.sh --check` passes
- [x] 8.2 `./build.sh --test` passes
