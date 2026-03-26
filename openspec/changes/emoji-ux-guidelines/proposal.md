## Why

The emoji system is inconsistent: Maintenance terminals show flower emojis (from the genus) instead of tool emojis, breaking the visual link between the menu item and the window title. The core UX principle — every window "plants" its emoji on the menu item that launched it — is undermined when emoji families don't match intent.

Currently:
- Flowers (🌸🌺🌻...) = AI engines / Attach Here → but terminals also use them
- Tools (⛏️) = Maintenance → but only when idle, running terminals switch to flowers
- Project labels show emojis as PREFIX → hard to scan when names are different lengths

## What Changes

### Emoji Family System
- **Flowers** = AI engine environments (Attach Here / OpenCode). One flower per genus.
- **Tools** = Maintenance terminals. Curated rotating pool (🔧🪛🔩⚙️🪚🔨🪜🧲 etc.). Each terminal gets a unique tool.
- Each emoji family is self-contained: flowers never appear on terminals, tools never appear on flowers.
- Window title emoji MUST match the menu item emoji that launched it.

### Project Label Layout
- Emojis move from PREFIX to SUFFIX (after project name)
- Right-aligned: `project-name         🔧🌸`
- Order: tools first, then flowers (left to right = older to newer launches)
- Idle projects: plain name, no emojis
- Multiple terminals append their tool emojis: `project   🔧🪛🌸`

### Tool Emoji Pool
Curated set of 16+ tool/craft emojis for rotating assignment:
🔧 🪛 🔩 ⚙️ 🪚 🔨 🪜 🧲 🪣 🧰 🪝 🔗 📐 🪤 🧱 🪵

### Window Title Format
- Attach Here: `<flower> project-name` (unchanged)
- Maintenance: `<tool> project-name` (was using flower, now uses tool)

## Capabilities

### New Capabilities
- `emoji-ux-guidelines`: Formal UX rules for emoji usage, family separation, and visual consistency
- `tool-emoji-pool`: Rotating pool of tool emojis for Maintenance containers

### Modified Capabilities
- `menu-ux-polish`: Project labels use suffix layout, emoji families match container types

## Impact

- **New file**: `crates/tillandsias-core/src/tools.rs` — tool emoji pool and allocation
- **Modified**: `crates/tillandsias-core/src/genus.rs` — genus flower() is now exclusively for Forge/AI containers
- **Modified**: `src-tauri/src/menu.rs` — project label layout, maintenance emoji rendering
- **Modified**: `src-tauri/src/handlers.rs` — terminal title uses tool emoji, not flower
