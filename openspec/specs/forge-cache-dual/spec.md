# forge-cache-dual Specification

## Purpose
TBD - created by archiving change forge-cache-architecture. Update Purpose after archive.
## Requirements
### Requirement: Forge containers see exactly four path categories

The "Ephemeral" category SHALL carry kernel-enforced size caps on `/tmp` (256 MB)
and `/run/user/1000` (64 MB). These paths were previously unbounded (defaulting
to 50% of host RAM under `tmpfs(5)` semantics); after this change they are
bounded and fail with ENOSPC on overflow.

> Delta: the "Ephemeral" row in the path-category table gains explicit kernel-enforced size
> caps on `/tmp` and `/run/user/1000`. These paths were previously unbounded (defaulting
> to 50% of host RAM under `tmpfs(5)` semantics). After this change they are bounded.

| Ephemeral path | Mount type | Size cap |
|---|---|---|
| `/tmp` | tmpfs | **256 MB** (0o1777) |
| `/run/user/1000` | tmpfs | **64 MB** (0o0700) |
| All other unmounted home dirs / overlay | container's own writable layer | (none) |

The `/tmp` and `/run/user/1000` caps are kernel-enforced via `--tmpfs=<path>:size=<N>m,mode=<oct>`.
Writes beyond the cap fail with ENOSPC inside the container.

#### Scenario: /tmp is capped at 256 MB

- **WHEN** a forge container starts
- **THEN** `df --output=size /tmp` reports ≈ 256 MB
- **AND** writing more than 256 MB to `/tmp/` fails with ENOSPC — not silently spilling to disk

#### Scenario: /run/user/1000 is capped at 64 MB

- **WHEN** a forge container starts
- **THEN** `df --output=size /run/user/1000` reports ≈ 64 MB
- **AND** the cap prevents runaway socket or log files from consuming unbounded RAM

#### Scenario: Unbounded overlay still covers non-tmpfs ephemeral paths

- **WHEN** an agent writes to a path that is neither `/tmp` nor `/run/user/1000` nor a
  bind-mounted cache (e.g., `/home/forge/.bashrc`)
- **THEN** the write lands in the container's overlayfs upper-dir on the host storage
  driver — subject to host disk quota, not RAM quota

### Requirement: Per-language env vars resolve into the per-project cache

`lib-common.sh` SHALL export the following environment variables on every forge entrypoint, ALL pointing into subdirectories of the per-project cache mount (`/home/forge/.cache/tillandsias-project/`):

| Tool | Env var | Subdirectory |
|---|---|---|
| Cargo | `CARGO_HOME` | `cargo/` |
| Cargo | `CARGO_TARGET_DIR` | `cargo/target/` |
| Go | `GOPATH` | `go/` |
| Go | `GOMODCACHE` | `go/pkg/mod/` |
| Maven | `MAVEN_OPTS` (with `-Dmaven.repo.local=...`) | `maven/` |
| Gradle | `GRADLE_USER_HOME` | `gradle/` |
| Flutter | `PUB_CACHE` | `pub/` |
| npm | `npm_config_cache` | `npm/` |
| Yarn | `YARN_CACHE_FOLDER` | `yarn/` |
| pnpm | `PNPM_HOME` | `pnpm/` |
| uv | `UV_CACHE_DIR` | `uv/` |
| pip | `PIP_CACHE_DIR` | `pip/` |

Old paths (e.g., `CARGO_HOME=~/.cache/tillandsias/cargo` from before this change) SHALL be tombstoned in `lib-common.sh` per the @tombstone retention rule.

#### Scenario: Cargo cache hits on second build
- **WHEN** an agent runs `cargo build` in a fresh project
- **AND** the build downloads 200 MB of crates.io dependencies
- **AND** the container stops and a new container for the same project starts
- **AND** the agent runs `cargo build` again with no source changes
- **THEN** the second build SHALL NOT re-download the dependencies (cache hit)
- **AND** the `bytes_downloaded_at_runtime` metric for the second build SHALL report close to zero

### Requirement: Shared cache uses nix as the single entry point

The shared cache (`/nix/store/`) SHALL be populated only by nix-managed processes. Other tools (Maven, Gradle, npm, cargo registry, etc.) SHALL NOT write to the shared cache — their downloads land in the per-project cache instead. This makes the shared cache conflict-free by construction (nix's content-addressed storage rules out trampling).

#### Scenario: Two projects sharing a nix-managed dep see the same store entry
- **WHEN** project A and project B both declare a flake input that resolves to `/nix/store/abc123-foo-1.2.3/`
- **THEN** both forge containers SHALL see the same `/nix/store/abc123-foo-1.2.3/` directory contents
- **AND** the entry SHALL be downloaded at most once on this host, ever (until manually GC'd)

#### Scenario: Non-nix tools never write to shared cache
- **WHEN** an agent runs `mvn install`, `npm install`, `cargo build`, etc.
- **THEN** the resulting downloads SHALL land in the per-project cache (`/home/forge/.cache/tillandsias-project/<tool>/`)
- **AND** no bytes SHALL be written under `/nix/store/` (the mount is `:ro`)

### Requirement: Project workspace is the user's git repo, not a cache

The project workspace bind-mount (`<watch_path>/<project>/` → `/home/forge/src/<project>/`) SHALL contain ONLY source code under the user's control. Build artifacts that are expensive to rebuild SHALL be written to the per-project cache, NOT to the project workspace.

This means: `target/`, `node_modules/`, `build/`, `dist/`, `.gradle/`, `.dart_tool/`, etc. when written under the project workspace are anti-patterns — they should either be redirected via env vars (Cargo, Gradle, etc.) into the per-project cache, OR be considered ephemeral and `.gitignore`d.

#### Scenario: cargo target/ does not pollute the project workspace
- **WHEN** an agent runs `cargo build` in `/home/forge/src/<project>/`
- **THEN** `target/` SHALL NOT be created in the project workspace
- **AND** the build artifacts SHALL appear at `/home/forge/.cache/tillandsias-project/cargo/target/` (per `CARGO_TARGET_DIR`)

#### Scenario: Anti-pattern flagged in methodology
- **WHEN** the methodology cheatsheet `runtime/forge-paths-ephemeral-vs-persistent.md` is read by an agent
- **THEN** it SHALL clearly state that build artifacts under the project workspace (e.g., `node_modules/` for projects that don't redirect via tooling) are an anti-pattern, AND it SHALL list which tools have native env-var redirection support

