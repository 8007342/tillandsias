# Config-Overlay Runtime Mount Gap

**Filed**: 2026-07-28  
**Agent**: forge-macos-audit-20260728  
**Severity**: P2 (v0.5)

## Finding

The `MountSource::ConfigOverlay` mount mechanism is declared in
`crates/tillandsias-core/src/container_profile.rs:84` but **never wired into
any container launch path**. No podman `--mount` or `--volume` argument is
ever generated from this mount source.

## Impact

The entrypoint function `apply_opencode_config_overlay()` in
`images/default/lib-common.sh:2094-2107` expects to copy the rich OpenCode
configuration from `/home/forge/.config-overlay/` to
`/home/forge/.config/opencode/` at container startup. Since the runtime mount
never supplies this path, the override is a silent no-op:

- MCP tools (git-tools, project-info, host-browser, forge-plan) are **not
  available** in forge containers via the intended runtime overlay path
- The `apply_opencode_config_overlay()` function silently skips
  (`[ -f "$overlay_cfg" ]` guard prevents errors)
- Agent instructions, local provider config, and shell helpers follow the same
  pattern and are likewise absent

## Partial Fix Applied (this cycle)

`images/default/Containerfile` was updated to COPY the rich config and MCP
scripts directly into the image:
- `config-overlay/opencode/config.json` → `/home/forge/.config/opencode/config.json`
- `config-overlay/opencode/config.json` → `/home/forge/.config-overlay/opencode/config.json`
- `config-overlay/mcp/` → `/home/forge/.config-overlay/mcp/`

This ensures MCP tools work even without the runtime mount. However, the
override pattern (host overlay at container launch) remains unimplemented.

## Root Cause

The `ContainerProfile` struct and `ProfileMount` definitions in
`container_profile.rs` are only used in `#[cfg(test)]` blocks. No production
code in `main.rs` or `tray/mod.rs` reads these profiles to generate podman
mount arguments.

## Fix Required

1. Wire `MountSource::ConfigOverlay` into the container launch path in
   `main.rs` (e.g., in `build_forge_agent_run_args_with_vault()` or
   `build_stack_common_args()`)
2. The mount should resolve to
   `$XDG_RUNTIME_DIR/tillandsias/config-overlay/` on the host (tmpfs for fast
   reads, ephemeral per session)
3. Host-side tooling to populate this directory before forge launch (e.g.,
   from a host config directory)

## Related Files

| File | Lines | What |
|------|-------|------|
| `crates/tillandsias-core/src/container_profile.rs` | 84-99 | `MountSource::ConfigOverlay` enum variant |
| `crates/tillandsias-core/src/container_profile.rs` | 584-617 | `common_forge_mounts()` with the `ProfileMount` |
| `crates/tillandsias-headless/src/main.rs` | 10811-11072 | `build_forge_agent_run_args_with_vault()` — NO overlay mount |
| `crates/tillandsias-headless/src/main.rs` | 2277-2324 | `build_stack_common_args()` — NO overlay mount |
| `crates/tillandsias-headless/src/main.rs` | 4743-4862 | `build_opencode_forge_args()` — NO overlay mount |
| `images/default/lib-common.sh` | 2094-2107 | `apply_opencode_config_overlay()` — expects mount |
| `images/default/Containerfile` | 109-116 | COPY instructions added this cycle |
