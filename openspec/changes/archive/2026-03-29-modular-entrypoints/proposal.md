## Why

The current forge image has a single monolithic entrypoint (`images/default/entrypoint.sh`, 144 lines) that handles every container type: OpenCode forges, Claude forges, maintenance terminals, and (eventually) web servers. This is a growing source of fragility:

1. **Cross-contamination of concerns**: The entrypoint installs OpenCode binaries even when launching a Claude container (the `install_opencode` function exists alongside `install_claude`). Every agent's install logic, PATH setup, and config is in one file. A bug in Claude's npm install can break OpenCode launches and vice versa.

2. **Secret leakage surface**: The entrypoint receives `ANTHROPIC_API_KEY` even when launching an OpenCode container. It receives OpenCode's cache paths even when launching Claude. The scrubbing (`unset ANTHROPIC_API_KEY`) is best-effort — a single missed env var means one agent's secrets are visible to another agent's runtime.

3. **Debugging difficulty**: When a launch fails, the user sees "Starting bash" with no indication of which agent failed, which install step broke, or what the user should do. The monolithic structure makes it impossible to isolate failures.

4. **No terminal-only path**: The maintenance terminal (`--bash` / fish entrypoint) uses `--entrypoint fish` to bypass the script entirely, but this means the terminal misses the setup steps (gh auth, shell configs, PATH). The welcome script runs from fish's config.fish but the environment is only partially initialized.

5. **Industry practice**: Per-image entrypoints are standard in container orchestration. Docker Compose, Kubernetes, and Podman all expect each image to have a single-purpose entrypoint. Multi-purpose entrypoints are an anti-pattern because they make images non-composable and harder to reason about.

**Industry research — per-image entrypoints**:

- **Docker best practices** explicitly state: "Each container should have only one concern." The official documentation recommends one process per container, with each Dockerfile having a purpose-built ENTRYPOINT.
- **Kubernetes**: Pod specs set `command` and `args` per container. Multi-purpose images are discouraged because health checks, resource limits, and restart policies apply to the entire container — not to sub-processes.
- **Docker Compose**: Each `service:` block specifies its own `entrypoint:` and `command:`. Services are separated by purpose (web, worker, db), never multiplexed.
- **Podman**: Same model as Docker. The `--entrypoint` flag overrides the image default, but the expectation is that each image ships with a sensible single-purpose default.
- **12-Factor App principle VI** ("Processes"): "Execute the app as one or more stateless processes." Each process type gets its own entry point.

The pattern is clear: one entrypoint per container type, not one entrypoint that branches on environment variables.

## What Changes

Split the monolithic `images/default/entrypoint.sh` into four focused entrypoint scripts:

- **`entrypoint-forge-opencode.sh`** — Installs/updates OpenCode binary, configures OpenSpec, launches OpenCode
- **`entrypoint-forge-claude.sh`** — Installs/updates Claude Code via npm, injects API key, launches Claude Code
- **`entrypoint-terminal.sh`** — Sets up shell environment (gh auth, shell configs, PATH, welcome banner), launches fish
- **`entrypoint-web.sh`** — Already exists at `images/web/entrypoint.sh`, no changes needed

Each entrypoint is ONLY aware of its own runtime, its own secrets, and its own mounts. A shared library (`entrypoint-common.sh`) holds the 6 lines of truly shared setup (umask, trap, shell config deployment, gh auth).

## Capabilities

### New Capabilities
- `forge-entrypoint`: Per-type entrypoint scripts with isolated concerns, clear lifecycle, and proper error handling

### Modified Capabilities
- `default-image`: Image bakes in all four entrypoints; Rust code selects which one to use via the `--entrypoint` podman flag or image config

## Impact

- **New files**: `images/default/entrypoint-forge-opencode.sh`, `images/default/entrypoint-forge-claude.sh`, `images/default/entrypoint-terminal.sh`, `images/default/entrypoint-common.sh`
- **Modified files**: `images/default/entrypoint.sh` (deprecated, becomes a thin redirect during transition), `flake.nix` (copy new entrypoints into image), `src-tauri/src/handlers.rs` (set `--entrypoint` based on container type), `src-tauri/src/runner.rs` (set `--entrypoint` for CLI mode)
- **Deleted files** (eventual): `images/default/entrypoint.sh` after migration
- **Image size impact**: Negligible — four small scripts instead of one medium script
- **Breaking change**: None. The default entrypoint in the image config can remain the Claude entrypoint (current default agent). The Rust code explicitly sets `--entrypoint` for each container type.
