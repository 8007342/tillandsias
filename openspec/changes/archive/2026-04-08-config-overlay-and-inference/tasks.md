## Phase 1: Methodology Instructions

- [x] **M-1**: Create `images/default/config-overlay/opencode/instructions/methodology.md` -- global instructions covering monotonic convergence, CRDT patterns, Flutter-first recommendations, OpenSpec workflows, @trace annotations, code quality, git workflow. @trace spec:layered-tools-overlay
- [x] **M-2**: Create `images/default/config-overlay/opencode/instructions/flutter.md` -- Flutter-specific instructions covering clean architecture, Riverpod, GoRouter, i18n, Material 3, testing strategy. @trace spec:layered-tools-overlay
- [x] **M-3**: Update `images/default/config-overlay/opencode/config.json` -- add global `""` instruction key with condensed methodology, enrich `**/*.dart` instructions with Flutter architecture details. @trace spec:layered-tools-overlay
- [x] **M-4**: Add `CONFIG_OVERLAY_INSTRUCTIONS_METHODOLOGY` and `CONFIG_OVERLAY_INSTRUCTIONS_FLUTTER` constants to `src-tauri/src/embedded.rs` via `include_str!`. @trace spec:layered-tools-overlay
- [x] **M-5**: Extract instruction files in `extract_config_overlay()` to `config-overlay/opencode/instructions/` on ramdisk. @trace spec:layered-tools-overlay
- [x] **M-6**: Extract instruction files in `write_image_sources()` to `images/default/config-overlay/opencode/instructions/` for image builds. @trace spec:layered-tools-overlay

## Phase 1: MCP Servers

- [x] **MCP-1**: Create `images/default/config-overlay/mcp/git-tools.sh` -- MCP server script providing git status, diff, log tools to agents. @trace spec:layered-tools-overlay
- [x] **MCP-2**: Create `images/default/config-overlay/mcp/project-info.sh` -- MCP server script providing project language/framework detection. @trace spec:layered-tools-overlay
- [x] **MCP-3**: Add MCP server entries to `config.json` pointing to `/home/forge/.config-overlay/mcp/` scripts. @trace spec:layered-tools-overlay
- [x] **MCP-4**: Add `CONFIG_OVERLAY_MCP_GIT_TOOLS` and `CONFIG_OVERLAY_MCP_PROJECT_INFO` constants to `embedded.rs`. @trace spec:layered-tools-overlay
- [x] **MCP-5**: Extract MCP scripts in `extract_config_overlay()` with executable permissions. @trace spec:layered-tools-overlay
- [x] **MCP-6**: Extract MCP scripts in `write_image_sources()` for image builds. @trace spec:layered-tools-overlay

## Phase 2: GPU-Aware Model Tiers

- [x] **GPU-1**: Add GPU detection function to `src-tauri/src/handlers.rs` -- detect NVIDIA/AMD GPUs via `lspci`, `nvidia-smi`, or sysfs. Classify into tiers: none, low (<=4GB VRAM), mid (4-12GB), high (>=12GB). @trace spec:inference-container
- [x] **GPU-2**: Define model tier mapping -- high: `qwen2.5:7b`/`qwen2.5:7b`, mid: `qwen2.5:3b`/`qwen2.5:1.5b`, low: `qwen2.5:1.5b`/`qwen2.5:0.5b`, none: `qwen2.5:0.5b`/`qwen2.5:0.5b`. @trace spec:inference-container
- [x] **GPU-3**: Patch config overlay JSON at runtime -- after extracting static config, overwrite model fields based on detected GPU tier. Write patched config.json back to ramdisk. @trace spec:layered-tools-overlay, spec:inference-container
- [x] **GPU-4**: Log GPU detection results at enclave startup -- tier, GPU name, VRAM, selected models. @trace spec:inference-container
- [x] **GPU-5**: Add integration test -- verify model fields in config.json change based on simulated GPU tiers. @trace spec:inference-container
