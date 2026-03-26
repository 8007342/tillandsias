## Why

Power users and maintainers need a fast path to a bash terminal at the root `~/src/` directory — the same scope as the top-level "Attach Here" entry. Today the only way to get there is to use a per-project Maintenance terminal, which scopes the container to a single project directory. A global root terminal opens in the full `~/src/` mount, useful for cross-project tasks, repo management, and quick exploration.

## What Changes

- **Root terminal menu item** — A new `🛠️ Root` item is added immediately below the `~/src/ — Attach Here` entry and above the first separator. Clicking it launches a bash terminal in the forge container at the `src/` root directory.
- **Reserved emoji** — `🛠️` (U+1F6E0+FE0F, hammer and wrench) is reserved exclusively for this global root terminal. It MUST NOT appear in the rotating `TOOL_EMOJIS` pool used by per-project Maintenance containers.

## Capabilities

### New Capabilities
- `root-terminal-launcher`: Global root terminal accessible from the top of the tray menu

### Modified Capabilities
(none)

## Impact

- **Modified files**:
  - `src-tauri/src/menu.rs` — add `🛠️ Root` menu item and `ids::root_terminal()` ID function
  - `crates/tillandsias-core/src/event.rs` — add `MenuCommand::RootTerminal` variant
  - `src-tauri/src/event_loop.rs` — route `MenuCommand::RootTerminal` to handler
  - `src-tauri/src/handlers.rs` — add `handle_root_terminal()` function
  - `crates/tillandsias-core/src/tools.rs` — verify `🛠️` absent from `TOOL_EMOJIS` (already not present; add doc comment marking it reserved)
