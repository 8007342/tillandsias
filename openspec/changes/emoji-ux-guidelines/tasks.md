## 1. Tool Emoji Pool

- [ ] 1.1 Create `crates/tillandsias-core/src/tools.rs` with `TOOL_EMOJIS: &[&str]` pool (16+ curated tools: 🔧🪛🔩⚙️🪚🔨🪜🧲🪣🧰🪝🔗📐🪤🧱🪵)
- [ ] 1.2 Add `ToolAllocator` (mirrors GenusAllocator pattern) — allocate/release per project
- [ ] 1.3 Add `tool_emoji(index)` helper
- [ ] 1.4 Expose module in `lib.rs`

## 2. ContainerInfo display_emoji

- [ ] 2.1 Add `display_emoji: String` field to `ContainerInfo` in `state.rs`
- [ ] 2.2 In `handle_attach_here()`: set `display_emoji = genus.flower().to_string()`
- [ ] 2.3 In `handle_terminal()`: allocate tool from ToolAllocator, set `display_emoji = tool`
- [ ] 2.4 In startup container discovery: set `display_emoji = genus.flower()` for discovered containers (default to Forge)

## 3. Window Titles

- [ ] 3.1 In `handle_attach_here()`: window title = `"{display_emoji} {project_name}"`
- [ ] 3.2 In `handle_terminal()`: window title = `"{display_emoji} {project_name}"` (tool emoji, NOT flower)

## 4. Menu Label Layout

- [ ] 4.1 In `build_project_submenu()`: collect all display_emojis for running containers of this project
- [ ] 4.2 Separate into tools (Maintenance) and flowers (Forge) groups
- [ ] 4.3 Format label: `"{project_name}  {tools}{flowers}"` — tools first, flowers after
- [ ] 4.4 Idle projects: plain name, no emojis
- [ ] 4.5 Maintenance menu item: show tool emoji when running (`"🔧 Maintenance"` → `"{tool} Maintenance"`)

## 5. Cleanup

- [ ] 5.1 Release tool emoji from ToolAllocator when Maintenance container stops (in handle_podman_event)
- [ ] 5.2 Update tests for new ContainerInfo field

## 6. Verification

- [ ] 6.1 `./build.sh --check` passes
- [ ] 6.2 `./build.sh --test` passes
- [ ] 6.3 Manual: launch Forge → window title has flower, menu shows flower suffix
- [ ] 6.4 Manual: launch Maintenance → window title has tool, menu shows tool suffix
- [ ] 6.5 Manual: launch 2 Maintenance + 1 Forge → project shows `project  🔧🪛🌸`
