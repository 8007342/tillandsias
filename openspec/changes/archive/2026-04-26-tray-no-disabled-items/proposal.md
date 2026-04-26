## Why

The tray menu's current rendering of the five-stage state machine fills the menu with disabled placeholder items (`Building [...]`, `Ready`, `Sign in to GitHub` when not in NoAuth, `(GitHub unreachable…)`, `No local projects`, `No remote projects`, separate `version` and `— by Tlatoāni` lines). Users read disabled rows as broken UI. The `Include remote` checkbox toggle additionally rebuilds the Projects submenu on click, which the user perceives as a jarring "reload". The original spec for the running-stack rendering (top-level per-project entries with attach/maintenance children) was lost when the menu was flattened.

## What Changes

- **BREAKING** Drop the `Include remote` `CheckMenuItem` and the `MenuCommand::IncludeRemoteToggle` event variant. Remote projects render as a sibling top-level submenu, not a toggleable section inside `Projects ▸`.
- **BREAKING** Forbid disabled placeholder items in the tray menu. Any item whose only purpose was to communicate "nothing to show here" (`No local projects`, `No remote projects`, `Sign in to GitHub` when not actionable, `(GitHub unreachable…)`, `Building […]` when idle) must either be hidden, replaced by a hidden submenu, or collapsed into the single contextual status line described below.
- Collapse `version` (line 1) and `— by Tlatoāni` (line 2) into a single disabled line: `v0.1.169.225 — by Tlatoāni`.
- Add at most ONE optional contextual status line above the Projects/Remote submenus, surfaced only while a relevant condition holds: forge build in progress, enclave step in progress, transient `Ready` window, GitHub unreachable. When idle and authed, no status line is rendered.
- Promote running per-project stacks to the top of the menu. Each running project renders as `<Project> <bloom> <tools…> ▸` with children `🌱 Attach Here` (opens another browser window against the same forge — multiple concurrent windows allowed) and `🔧 Maintenance` (multiple concurrent terminals allowed). No Stop item; only `Quit` tears the stack down.
- Render `Projects ▸` and `Remote Projects ▸` as siblings only when both are non-empty. Empty submenus are hidden, never shown disabled. Clicking a remote item still dispatches `MenuCommand::CloneProject` which auto-launches via the existing `handle_clone_project` path.
- Rename `menu.launch` → `menu.attach_here` across all locale files; the per-project action carries the 🌱 plant emoji.
- Tray-state-machine cheatsheet updated to match the new visibility table.

## Capabilities

### New Capabilities
None.

### Modified Capabilities
- `tray-app`: changes the five-stage menu visibility table to forbid disabled placeholders, collapse the signature pair into one line, hide empty submenus, replace the `Include remote` toggle with a sibling `Remote Projects ▸` submenu, restore top-level rendering of running per-project stacks with `Attach Here` / `Maintenance` children, and rename Launch → Attach Here.
- `remote-projects`: drops the "Login to GitHub first" and "Could not fetch repos" disabled placeholders inside the Remote Projects submenu — the submenu itself is hidden when not actionable. Remote-projects fetching, caching, and clone-and-launch behavior are unchanged.

## Impact

- `src-tauri/src/tray_menu.rs` — heavy rewrite of `TrayMenu::new`, `set_stage`, `update_projects`; new top-level running-stack rendering; remove `INCLUDE_REMOTE` ID and the `CheckMenuItem` machinery; rename `ids::launch` users.
- `src-tauri/src/event_loop.rs` — drop `MenuCommand::IncludeRemoteToggle` arm; verify `MenuCommand::Launch` still dispatches `handle_attach_web` (rename in i18n only, command stays).
- `crates/tillandsias-core/src/event.rs` — remove `IncludeRemoteToggle` variant.
- `src-tauri/locales/*.json` — rename `menu.launch` → `menu.attach_here`; remove `menu.include_remote`, `menu.no_local_projects`, `menu.no_remote_projects`, `menu.sign_in_github` (when used as disabled banner — the click-able sign-in keeps its own key), and `menu.github_unreachable_banner` if collapsed into the contextual status line.
- `docs/cheatsheets/tray-state-machine.md` — rewrite the visibility table.
- Tests in `src-tauri/src/tray_menu.rs` `tests` module — `stage_visibility_table_matches_spec` and `dispatch_click_known_actions` need updating; new test for the "no disabled items" invariant.
- No runtime, network, or container changes. Pure menu-rendering and event-routing change.
