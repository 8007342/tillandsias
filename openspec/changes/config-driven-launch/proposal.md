## Why

The Rust code that builds `podman run` arguments is duplicated across three locations with subtle differences:

1. **`handlers.rs::build_run_args()`** (lines 353-483) — Tray mode. Builds args with `--cap-drop=ALL`, security flags, volume mounts, env vars, agent selection, Claude API key injection, Claude dir mount. Uses a proper function with parameters.

2. **`handlers.rs::handle_terminal()`** (lines 951-989) — Maintenance terminal. Builds the entire podman command as a format string with 15+ interpolated variables. Duplicates every security flag, every mount, every env var from `build_run_args()` but as a string template instead of a Vec. Adds `--entrypoint fish` and different `-w` flag.

3. **`handlers.rs::handle_root_terminal()`** (lines 1114-1149) — Root terminal. Copy-paste of the maintenance terminal format string with minor differences (`-w /home/forge/src` instead of `-w /home/forge/src/{project_name}`, different `TILLANDSIAS_PROJECT` value).

4. **`runner.rs::build_run_args()`** (lines 124-243) — CLI mode. A separate but nearly identical function to `handlers.rs::build_run_args()`. Same mounts, same security flags, same env vars, but constructed independently.

This means:
- Adding a new mount requires changes in **four places**
- Adding a new env var requires changes in **four places**
- A security flag typo in one location silently weakens one launch path
- The maintenance terminal format string has **no compile-time checking** — a missing `{}` or wrong argument order produces silent runtime bugs
- Claude credentials are mounted into every container type, even maintenance terminals that don't need them

A declarative config that describes each container type's requirements would:
- Eliminate duplication (single source of truth for mounts, env, entrypoint per type)
- Enable compile-time validation (Rust structs, not format strings)
- Make the privacy model explicit (each type declares exactly what it sees)
- Allow per-project overrides via `.tillandsias/config.toml`

## What Changes

- **New TOML config schema**: `ContainerProfile` structs that describe each container type's entrypoint, mounts, env vars, and ports
- **New Rust module**: `crates/tillandsias-core/src/container_profile.rs` — Defines `ContainerProfile`, loads built-in profiles, merges with project config
- **Refactored launch logic**: `handlers.rs` and `runner.rs` both call a single `build_podman_args(profile, context)` function instead of building args manually
- **Versioned config format**: `version = 1` field in the profile config, with forward-compatible parsing (unknown fields ignored, deprecated fields log warnings)

## Capabilities

### New Capabilities
- `launch-config`: Declarative container profiles with versioned schema
- `container-profiles`: Built-in profiles for forge-opencode, forge-claude, terminal, web

### Modified Capabilities
- `podman-orchestration`: Launch logic reads from profiles instead of hardcoded args
- `environment-runtime`: Per-project config can override profiles

## Impact

- **New files**: `crates/tillandsias-core/src/container_profile.rs`
- **Modified files**: `src-tauri/src/handlers.rs` (refactor all four launch paths), `src-tauri/src/runner.rs` (refactor CLI launch), `crates/tillandsias-core/src/config.rs` (add profile types)
- **Risk**: Medium. This is a refactor of critical launch paths. Must be tested across all four container types (forge-opencode, forge-claude, terminal, root-terminal) on both tray and CLI modes.
- **Breaking change**: None for users. The TOML schema is new and additive. Existing `config.toml` files continue to work. The `version` field defaults to 1 when absent.
