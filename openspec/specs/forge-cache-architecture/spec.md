# spec: forge-cache-architecture

## Status

active

## Overview

Define the dual-cache architecture for the forge container: a shared, read-only Nix store (`/nix/store/`) and per-project, read-write cache directories (`~/.cache/tillandsias-project/`) for build artifacts. This spec ensures zero file overlap between projects and guarantees that package downloads and build artifacts survive container restarts.

@trace spec:forge-cache-architecture

## Requirements

### Requirement: Shared cache entry point via Nix

The forge MUST provide a read-only shared Nix store mounted at `/nix/store/` on all containers. The host MUST maintain `~/.cache/tillandsias/forge-shared/nix-store/` (or equivalent platform path) as the backing mount source.

#### Scenario: Shared dependency accessed by two projects
- **WHEN** project-a and project-b both declare `openssl` in their `flake.nix`
- **THEN** both projects see the same `/nix/store/<hash>-openssl-3.2/` path
- **AND** the content is byte-identical; no trampling or version conflicts occur
- **AND** the mount is read-only (`:ro`) from the forge perspective

#### Scenario: Nix store population
- **WHEN** the host runs `nix build` or `nix flake update` for any project
- **THEN** new store entries populate `~/.cache/tillandsias/forge-shared/nix-store/`
- **AND** the next forge container restart sees those entries immediately
- **AND** no forge container has write access to `/nix/store/`

### Requirement: Per-project cache isolation

Each forge container launched for a project MUST mount a project-specific cache directory at `/home/forge/.cache/tillandsias-project/` with read-write access. The host path MUST be `~/.cache/tillandsias/forge-projects/<project>/` (or platform equivalent). Project A's cache MUST be completely invisible to project B's forge container.

#### Scenario: Per-project cache creation
- **WHEN** a forge container is launched for project "visual-chess"
- **THEN** the tray MUST ensure `~/.cache/tillandsias/forge-projects/visual-chess/` exists with mode 0700
- **AND** the container sees it mounted at `/home/forge/.cache/tillandsias-project/` with `:rw` permissions

#### Scenario: Cache persistence across restarts
- **WHEN** a forge container for "visual-chess" downloads Maven artifacts and builds Gradle output
- **THEN** those files land in `/home/forge/.cache/tillandsias-project/` (host: `~/.cache/tillandsias/forge-projects/visual-chess/`)
- **AND** when the container is stopped and restarted
- **THEN** the cache is still present and the next build is a cache hit

#### Scenario: Cache isolation between projects
- **WHEN** project A's forge container runs `npm install`
- **THEN** `npm` writes to `/home/forge/.cache/tillandsias-project/npm/`
- **AND** project B's forge container MUST NOT have access to that directory
- **AND** project B's `npm install` writes to its own isolated cache

### Requirement: Per-language environment variables

The forge MUST export environment variables for each supported language/toolchain that direct all package caches and build output to the per-project cache directory. These MUST be set in `images/default/lib-common.sh` and applied to all interactive shells.

#### Scenario: Cargo uses per-project cache
- **WHEN** a user runs `cargo build` inside the forge
- **THEN** `CARGO_HOME=/home/forge/.cache/tillandsias-project/cargo` and `CARGO_TARGET_DIR=/home/forge/.cache/tillandsias-project/cargo/target` are set
- **AND** build output lands in the per-project cache, not the workspace

#### Scenario: npm uses per-project cache
- **WHEN** a user runs `npm install` inside the forge
- **THEN** `npm_config_cache=/home/forge/.cache/tillandsias-project/npm` is set
- **AND** the npm package cache is stored in the per-project cache directory

#### Scenario: Maven/Gradle use per-project cache
- **WHEN** a user runs `mvn clean package` or `gradle build`
- **THEN** `MAVEN_OPTS=-Dmaven.repo.local=/home/forge/.cache/tillandsias-project/maven/` and `GRADLE_USER_HOME=/home/forge/.cache/tillandsias-project/gradle/` are set
- **AND** Maven Central and Gradle plugin repos are cached in the per-project cache

#### Full list of environment variables
- **Rust**: `CARGO_HOME`, `CARGO_TARGET_DIR`
- **Go**: `GOPATH`, `GOMODCACHE`
- **Maven**: `MAVEN_OPTS` (`-Dmaven.repo.local=...`)
- **Gradle**: `GRADLE_USER_HOME`
- **Python**: `PIP_CACHE_DIR`
- **Node/npm**: `npm_config_cache`
- **Yarn**: `YARN_CACHE_FOLDER`
- **pnpm**: `PNPM_HOME`
- **uv**: `UV_CACHE_DIR`
- **Flutter/Dart**: `PUB_CACHE`

### Requirement: Four path categories must be documented and enforced

The forge environment MUST provide clear guidance on the four distinct path categories: shared cache (nix), per-project cache, project workspace, and ephemeral scratch. This guidance MUST be available as an agent-accessible methodology cheatsheet.

#### Scenario: Agent reads cache discipline on first turn
- **WHEN** an agent enters the forge for the first time
- **THEN** the `cache-discipline.md` instruction in the config overlay SHOULD be displayed or linked
- **AND** it MUST clearly distinguish which paths persist, which are shared, and which are ephemeral

### Requirement: Zero overlap between caches

The caches MUST be architected such that project A's cache directory has zero overlap with project B's cache directory or with the shared nix store. Cross-project reads are forbidden; cross-project writes are impossible by design.

#### Scenario: No shared write surface except nix
- **WHEN** a build in project A populates cache entries
- **THEN** those entries MUST NOT appear in any other project's cache directory
- **AND** the shared `/nix/store/` is the ONLY writable-shared surface in the forge model

## Implementation Notes

This spec is created retroactively as part of the traces-audit refactor. It may represent:
- An abandoned initiative that was never fully spec'd
- A feature whose spec was lost or mishandled
- A trace annotation that should have been corrected instead

## Sources of Truth

- `cheatsheets/runtime/forge-shared-cache-via-nix.md` — Forge Shared Cache Via Nix reference and patterns
- `cheatsheets/runtime/forge-hot-cold-split.md` — Forge Hot Cold Split reference and patterns

## Observability

```bash
git log --all --grep="forge-cache-architecture" --oneline
git grep -n "@trace spec:forge-cache-architecture"
```

