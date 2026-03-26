## 1. OpenSpec

- [x] 1.1 Create proposal.md
- [x] 1.2 Create tasks.md
- [x] 1.3 Create specs/root-terminal-launcher/spec.md

## 2. core: event.rs

- [x] 2.1 Add `MenuCommand::RootTerminal` variant to the `MenuCommand` enum

## 3. core: tools.rs

- [x] 3.1 Verify `🛠️` (U+1F6E0+FE0F) is absent from `TOOL_EMOJIS`
- [x] 3.2 Add doc comment marking `🛠️` as reserved for the global root terminal

## 4. menu.rs

- [x] 4.1 Add `ids::root_terminal()` static ID function
- [x] 4.2 Insert `🛠️ Root` menu item immediately after the `~/src/ — Attach Here` item

## 5. event_loop.rs

- [x] 5.1 Add `MenuCommand::RootTerminal` arm to the `match command` block, routing to `handlers::handle_root_terminal()`

## 6. handlers.rs

- [x] 6.1 Implement `handle_root_terminal(watch_path, state, allocator, tool_allocator, build_tx)` — launches bash terminal in forge container at src/ root

## 7. Verification

- [x] 7.1 `./build.sh --check` passes (type-check only)
