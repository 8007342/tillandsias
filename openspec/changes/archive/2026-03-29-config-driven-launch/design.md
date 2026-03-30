## Context

Container launch arguments are currently built in four places in the Rust codebase:

1. `handlers.rs::build_run_args()` — 130 lines of Vec push statements for tray mode
2. `handlers.rs::handle_terminal()` — 40-line `format!()` string with 15+ interpolated variables
3. `handlers.rs::handle_root_terminal()` — Copy-paste of the above with minor differences
4. `runner.rs::build_run_args()` — 120 lines, duplicate of #1 with slight variations

All four share the same security flags, the same mount patterns, and the same env var injection. But they diverge in subtle ways: the maintenance terminal format string passes `TILLANDSIAS_AGENT` but also sets `--entrypoint fish` (so the agent env var is meaningless). The root terminal mounts the watch path at `/home/forge/src` directly, while per-project terminals mount at `/home/forge/src/<name>`. The CLI mode mounts Claude credentials in ALL container types, even when OpenCode is selected.

The `config.rs` already has `MountConfig`, `SecurityConfig`, `ProjectConfig`, and `ResolvedConfig` types. But these only cover per-project overrides — there is no concept of a "container profile" that describes the full launch configuration for a given container type.

**Constraints:**
- Must not break existing `.tillandsias/config.toml` files
- Must not add external dependencies (no new crates)
- The TOML schema must be versioned for forward compatibility
- Security flags are non-negotiable and cannot be overridden
- Per-project config can add mounts and env vars but cannot remove built-in ones

## Goals / Non-Goals

**Goals:**
- Define a `ContainerProfile` type that fully describes how to launch a container type
- Provide built-in profiles for all four types (forge-opencode, forge-claude, terminal, web)
- Refactor all four launch paths to use profiles
- Enable per-project overrides (extra mounts, env vars, port overrides)
- Version the config format for forward compatibility
- Compile-time validation of launch arguments (Rust types, not format strings)

**Non-Goals:**
- User-facing profile editor or GUI configuration
- Custom container types (only the four built-in types)
- Remote/registry-based profiles
- Runtime profile switching (profile is fixed at launch time)

## Decisions

### D1: ContainerProfile struct

**Choice:**

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ContainerProfile {
    pub entrypoint: String,
    pub working_dir: Option<String>,
    pub mounts: Vec<ProfileMount>,
    pub env: Vec<String>,
    pub secrets: Vec<SecretMount>,
    pub ports: Option<String>,
    pub image: Option<String>,  // Override default image (e.g., web uses tillandsias-web)
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProfileMount {
    pub host_key: String,       // Logical key: "project", "cache", "secrets/gh", "secrets/git"
    pub container_path: String,
    pub mode: String,           // "ro" or "rw"
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SecretMount {
    pub host_key: String,       // "claude_dir", "claude_api_key"
    pub container_path: String,
    pub mode: String,
    pub env_var: Option<String>, // If set, inject as env var instead of mount
}
```

**Why:** The profile is a Rust struct, not TOML. Built-in profiles are defined in code (not config files). This gives compile-time checking, no parsing at runtime, and makes it impossible to ship a broken profile.

### D2: Logical mount keys

**Choice:** Mounts use logical keys ("project", "cache", "secrets/gh") that are resolved to absolute paths at launch time by the Rust code.

**Why:** The profile should not contain absolute paths — those vary by platform (Linux vs macOS vs Windows) and by user. The Rust code resolves `"cache"` to `~/.cache/tillandsias` on Linux, `~/Library/Caches/tillandsias` on macOS, etc. The profile says WHAT to mount, the Rust code says WHERE from.

### D3: Built-in profiles

| Profile | Entrypoint | Mounts | Secrets | Env |
|---------|-----------|--------|---------|-----|
| `forge-opencode` | `entrypoint-forge-opencode.sh` | project(rw), cache(rw) | gh(ro), git(rw) | PROJECT, HOST_OS, AGENT, GIT_CONFIG_GLOBAL |
| `forge-claude` | `entrypoint-forge-claude.sh` | project(rw), cache(rw) | gh(ro), git(rw), claude_dir(rw) | PROJECT, HOST_OS, AGENT, GIT_CONFIG_GLOBAL, ANTHROPIC_API_KEY |
| `terminal` | `entrypoint-terminal.sh` | project(rw), cache(rw) | gh(ro), git(rw) | PROJECT, HOST_OS, AGENT, GIT_CONFIG_GLOBAL |
| `web` | `/entrypoint.sh` | project/public(ro) | (none) | (none) |

Key privacy boundary: `forge-opencode` does NOT get `claude_dir` or `ANTHROPIC_API_KEY`. `terminal` does NOT get `claude_dir` or `ANTHROPIC_API_KEY`. `web` gets NOTHING except the static files mount.

### D4: Single build_podman_args function

**Choice:** Replace all four launch arg builders with one function:

```rust
pub fn build_podman_args(
    profile: &ContainerProfile,
    context: &LaunchContext,
) -> Vec<String>
```

Where `LaunchContext` contains:
```rust
pub struct LaunchContext {
    pub container_name: String,
    pub project_path: PathBuf,
    pub project_name: String,
    pub cache_dir: PathBuf,
    pub port_range: (u16, u16),
    pub host_os: String,
    pub detached: bool,
    pub is_watch_root: bool,
    // Resolved secrets (from keyring, filesystem)
    pub claude_api_key: Option<String>,
    pub claude_dir: Option<PathBuf>,
    pub gh_dir: PathBuf,
    pub git_dir: PathBuf,
}
```

The function:
1. Starts with non-negotiable security flags (always hardcoded, never from profile)
2. Adds `--entrypoint` from profile
3. Resolves mount keys to absolute paths using context
4. Adds env vars from profile
5. Adds GPU passthrough (Linux only)
6. Adds port range
7. Adds custom mounts from project config
8. Adds image tag (from profile override or default)

**Why:** One function, one place to audit, one place to add new flags. The function signature makes the inputs explicit. The security flags are hardcoded in the function body — they cannot be overridden by profiles or project config.

### D5: Versioned config schema

**Choice:** Add `version: u32` to the TOML schema:

```toml
version = 1

[forge.opencode]
# ... profile fields
```

Parsing rules:
- `version` absent: treat as version 1
- `version = 1`: current schema
- `version > max_supported`: log warning "Config version {n} is newer than this version of Tillandsias supports. Some settings may be ignored.", parse what we can
- Unknown fields: silently ignored (serde `#[serde(deny_unknown_fields)]` is NOT used)
- Deprecated fields: log warning with migration instruction

**Why:** Forward compatibility. A user running Tillandsias v0.1.40 with a config written for v0.2.0 should still work — just without the new features. This follows the protobuf wire format philosophy: additive changes only, never break old readers.

### D6: Security flags are NOT in profiles

**Choice:** The non-negotiable security flags (`--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`, `--security-opt=label=disable`, `--rm`, `--init`, `--stop-timeout=10`) are hardcoded in `build_podman_args()`. They never appear in profiles, project config, or global config.

**Why:** These flags must always be present. If they were in profiles, a bug or config error could omit them. Hardcoding means the only way to disable them is to modify Rust source code, compile, and ship a new binary. This is the correct level of protection.

## Architecture

```
crates/tillandsias-core/src/
  container_profile.rs    # ContainerProfile, ProfileMount, SecretMount, LaunchContext
  config.rs               # Existing config types (unchanged, plus version field)

src-tauri/src/
  handlers.rs             # handle_attach_here, handle_terminal, etc. call build_podman_args()
  runner.rs               # CLI run() calls build_podman_args()
  launch.rs (new)         # build_podman_args() function + mount resolution logic
```

## Risks / Trade-offs

**[Abstraction overhead]** Adding a profile layer means more indirection. Mitigation: The profile struct is simple (5 fields). The single `build_podman_args` function replaces 400+ lines of duplicated code. Net reduction in complexity.

**[Profile drift from reality]** If someone changes a podman flag in `build_podman_args` but forgets to update the profile, the profile docs become misleading. Mitigation: Profiles are the source of truth for mounts and env vars. Security flags and structural args (`-it`, `--rm`) are not in profiles.

**[Testing surface]** The single function must be tested with all four profile types. Mitigation: Unit tests with mock contexts. Each profile type gets a test that verifies the correct args are produced.
