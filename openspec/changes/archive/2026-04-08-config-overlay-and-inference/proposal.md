## Why

Forge containers launch with a bare OpenCode config that has no development methodology, no Flutter-first recommendations, and a hardcoded model tier that ignores the host GPU. Agents inside forges start from zero context every time -- they don't know about OpenSpec, monotonic convergence, CRDT patterns, or that we prefer Flutter for cross-platform apps. Meanwhile, inference containers always pull the same small model regardless of whether the host has a powerful GPU or no GPU at all.

The config overlay system (ramdisk at `/home/forge/.config-overlay/`) is already in place but only carries a minimal `config.json`. It needs to carry methodology instructions, MCP server scripts, and GPU-aware model configuration.

## What Changes

Expand the config overlay to include three new capabilities:

1. **Methodology instructions** -- Global and per-language instructions injected into OpenCode's `instructions` field. Agents automatically follow monotonic convergence, suggest Flutter for cross-platform, add `@trace` annotations, and recommend OpenSpec workflows. No new config formats -- instructions are inlined in config.json with full markdown files alongside for reference.

2. **MCP servers** -- Lightweight shell scripts registered as local MCP servers in config.json. Provide git status/diff/log tools and project info (language detection, framework detection) to agents without requiring external dependencies.

3. **GPU-aware model tiers** -- Detect host GPU at enclave startup and select appropriate model tiers (large models for powerful GPUs, small models for CPU-only). Model selection is written into the config overlay before containers launch.

## Capabilities

### New Capabilities
- `config-overlay-instructions`: Methodology-driven agent instructions with Flutter-first recommendations, embedded in the binary and extracted to ramdisk overlay.
- `config-overlay-mcp`: MCP server scripts (git-tools, project-info) extracted to ramdisk overlay, registered in OpenCode config.
- `gpu-aware-model-tiers`: Host GPU detection at enclave startup with tiered model selection written to config overlay.

### Modified Capabilities
- `layered-tools-overlay`: Config overlay now carries instruction files and MCP scripts in addition to config.json.
- `embedded-scripts`: New constants for instruction markdown files and MCP shell scripts.
- `default-image`: OpenCode config.json gains global `""` instruction key with methodology, enriched `**/*.dart` instructions, and MCP server entries.

## Impact

- `images/default/config-overlay/opencode/config.json` -- add global methodology instructions, enrich Flutter instructions, add MCP server entries
- `images/default/config-overlay/opencode/instructions/methodology.md` (new) -- full methodology reference
- `images/default/config-overlay/opencode/instructions/flutter.md` (new) -- Flutter development reference
- `images/default/config-overlay/mcp/git-tools.sh` (new) -- MCP server for git operations
- `images/default/config-overlay/mcp/project-info.sh` (new) -- MCP server for project detection
- `src-tauri/src/embedded.rs` -- add include_str! constants for instruction files and MCP scripts, extract them in both write_image_sources() and extract_config_overlay()
- `src-tauri/src/handlers.rs` -- GPU detection logic, model tier selection, config overlay patching
