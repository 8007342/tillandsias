## Why

The forge container today exports `CARGO_HOME=~/.cache/tillandsias/cargo`, `GOPATH=~/.cache/tillandsias/go`, etc. — but the directory those env vars point at is **never bind-mounted**. Every container restart re-downloads every package the agent installs. Maven, Gradle, Flutter pub-cache, yarn, pnpm, and uv don't even have env vars set, so they default to ephemeral `$HOME` paths and lose state on every container stop. Verified by the planner against `crates/tillandsias-core/src/container_profile.rs::common_forge_mounts()` — only `ConfigOverlay` and `ContainerLogs` are mounted.

The user audited this and called for a structural fix. They were also explicit about the **shape** of the fix: TWO caches with zero file overlap.

1. **SHARED cache (read-only)** — host-managed, Nix is the single entry point. Any number of projects can read the same `/nix/store/<hash>-<pkg>` entry without trampling, because nix's content-addressed design is conflict-free by construction.
2. **PER-PROJECT cache (read-write)** — built artifacts that are expensive to rebuild for THIS specific project (cargo `target/`, project `node_modules/`, project `.m2/`, etc.) Persisted across container restarts of the same project. **Project A's forge container CANNOT see project B's cache.**

Plus an explicit categorisation of every path the agent might encounter: shared / per-project / project-workspace / ephemeral. The agent must know with zero ambiguity where to write what.

## What Changes

- **NEW** `MountSource::SharedCache` variant — bind-mounts `~/.cache/tillandsias/forge-shared/nix-store/` (host) → `/nix/store/` (forge) `:ro`. All forge containers share this mount. Single entry point: nix.
- **NEW** `MountSource::ProjectCache` variant — bind-mounts `~/.cache/tillandsias/forge-projects/<project>/` (host) → `/home/forge/.cache/tillandsias-project/` (forge) `:rw`. Per-project, isolated.
- **NEW** Per-language env vars in `lib-common.sh`, ALL pointing into `/home/forge/.cache/tillandsias-project/`:
  - `CARGO_HOME`, `CARGO_TARGET_DIR` → `/home/forge/.cache/tillandsias-project/cargo/`
  - `GOPATH`, `GOMODCACHE` → `/home/forge/.cache/tillandsias-project/go/`
  - `MAVEN_OPTS=-Dmaven.repo.local=/home/forge/.cache/tillandsias-project/maven/`
  - `GRADLE_USER_HOME=/home/forge/.cache/tillandsias-project/gradle/`
  - `PUB_CACHE=/home/forge/.cache/tillandsias-project/pub/`
  - `npm_config_cache=/home/forge/.cache/tillandsias-project/npm/`
  - `YARN_CACHE_FOLDER=/home/forge/.cache/tillandsias-project/yarn/`
  - `PNPM_HOME=/home/forge/.cache/tillandsias-project/pnpm/`
  - `UV_CACHE_DIR=/home/forge/.cache/tillandsias-project/uv/`
  - `PIP_CACHE_DIR=/home/forge/.cache/tillandsias-project/pip/`
- **NEW** Methodology cheatsheet `runtime/forge-paths-ephemeral-vs-persistent.md` with explicit table of every path category. Agents read this before doing any I/O. Replaces the implicit "agent guesses" model.
- **NEW** Methodology cheatsheet `runtime/forge-shared-cache-via-nix.md` explaining how nix is the single shared-cache entry point and why it doesn't trample.
- **NEW** Cache-discipline opencode instruction `images/default/config-overlay/opencode/instructions/cache-discipline.md` — first-turn discipline: where to write, what survives, what doesn't.
- **NEW** Download telemetry — every runtime download (forge, inference, host tray, image build) emits a structured log event with `category="download", url, bytes, target, reason, source` so the aggregate `bytes_downloaded_at_runtime` metric is observable and convergent.
- **NEW** Host-side `tillandsias --download-stats` CLI subcommand reads the structured log + reports per-source / per-day download bytes. NOT a tray menu item (per the no-new-UX rule).
- **MODIFIED** `crates/tillandsias-core/src/container_profile.rs::common_forge_mounts()` adds the two new mounts. Existing `ConfigOverlay` and `ContainerLogs` are unchanged.
- **MODIFIED** `images/default/lib-common.sh` exports the per-language env vars to the new path; tombstones the old paths.

## Capabilities

### New Capabilities
- `forge-cache-dual` — the shared + per-project + workspace + ephemeral path model. Specifies which paths get which mount, isolation guarantees, lifetime guarantees.
- `download-telemetry` — every runtime download is logged + measurable. Aggregate metric converges toward zero.

### Modified Capabilities
- `default-image`: `lib-common.sh` env vars rewritten to point at the per-project cache mount.
- `forge-shell-tools`: each baked language toolchain has the per-language env path documented.
- `podman-orchestration`: forge launch profile gains the SharedCache + ProjectCache mounts.
- `environment-runtime`: per-project cache directory created on first attach, never deleted automatically.
- `agent-cheatsheets`: two new mandatory cheatsheets that the methodology references.

## Impact

**Code**:
- `crates/tillandsias-core/src/container_profile.rs` — add `MountSource::SharedCache` + `MountSource::ProjectCache` variants; extend `common_forge_mounts()` to add both mounts. Per-project mount path resolves from project name at attach time.
- `crates/tillandsias-core/src/state.rs` (or wherever launch context is) — pass project name through to the mount resolution.
- `images/default/lib-common.sh` — new `export` block setting all per-language env vars under `/home/forge/.cache/tillandsias-project/`. Old exports tombstoned.
- `src-tauri/src/handlers.rs::handle_attach_web` (and its terminal cousin) — ensure `~/.cache/tillandsias/forge-projects/<project>/` exists with mode 0700 owned by the host UID before container start.
- `src-tauri/src/handlers.rs::ensure_infrastructure_ready` — ensure `~/.cache/tillandsias/forge-shared/nix-store/` exists. The nix store itself is populated by nix-managed builds (out of scope for this change; the directory just needs to exist as a mount target).

**Telemetry**:
- New `crates/tillandsias-core/src/download_telemetry.rs` (or extend an existing logging module) defining a `log_download(...)` helper that emits the structured event. Every callsite that downloads bytes at runtime calls it.
- Callsite enumeration:
  - `images/inference/entrypoint.sh` — ollama pulls (logged via stdout, host parses)
  - `src-tauri/src/handlers.rs` — image builds (when `nix build` or `podman build` reaches Maven Central etc.)
  - Future `host-chromium-on-demand` — chromium download
  - Future `inference-host-side-pull` — model pulls from host
  - Forge container itself — agents writing to per-project cache count as "download" only if the bytes came from outside the host (cache miss to network)
- Aggregate query: `tillandsias --download-stats [--since=24h]` parses the accountability log and prints a per-category breakdown. **No tray menu item.**

**Cheatsheets** (both authored under v2 methodology, no DRAFT banners):
- `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md`
- `cheatsheets/runtime/forge-shared-cache-via-nix.md`

**Methodology**:
- `images/default/config-overlay/opencode/instructions/cache-discipline.md` — opencode first-turn instruction.
- `~/src/tillandsias/CLAUDE.md` — new section under the existing methodology docs codifying the dual-cache model + ephemeral path table.

**No UX changes**. No new tray items. No new prompts. The CLI subcommand is invoked from a terminal by power users who want to inspect; the metric mostly drives log telemetry.

**Image size**: zero impact — caches live on the host, not in the image.

**Bandwidth impact**: hard to overstate. Today every forge attach re-downloads every Maven/Gradle/cargo/npm/pip dep for the project. After this change, `bytes_downloaded_at_runtime` should approach zero for steady-state development.

## Sources of Truth

- `cheatsheets/runtime/cheatsheet-architecture-v2.md` — cheatsheet system this change ships with new entries for.
- `cheatsheets/runtime/forge-container.md` (DRAFT) — the runtime contract this change tightens.
- `cheatsheets/build/nix-flake-basics.md` — nix as the single shared-cache entry point.
- `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md` (this change creates it) — definitive path-category table.
- `cheatsheets/runtime/forge-shared-cache-via-nix.md` (this change creates it) — why the shared cache doesn't trample.
