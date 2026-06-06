---
tags: [build, ci, nix, release, crane, caching]
languages: [nix, rust]
since: 2026-06-05
last_verified: 2026-06-05
sources: [external]
authority: internal
status: draft
tier: bundled
---
# Nix CI: Incremental Builds, Caching, and Image Distribution
@trace spec:ci-release
**Use when**: keeping the release Nix build fast/incremental, and shipping container images so the runtime only *pulls* (never compiles).

## Provenance
- Magic Nix Cache free-tier EOL — https://determinate.systems/blog/magic-nix-cache-free-tier-eol/ (GitHub rewrote the Actions cache API on 2025-02-01; the legacy magic-nix-cache service was sunset by 2025-03-01).
- Magic Nix Cache revival (reverse-engineered, fragile) — https://determinate.systems/blog/bringing-back-magic-nix-cache-action/ and https://github.com/DeterminateSystems/magic-nix-cache-action
- Recommended replacements — https://github.com/nix-community/cache-nix-action (free, GitHub-Actions-cache-backed save/restore of `/nix/store`) and FlakeHub Cache (Determinate, requires a FlakeHub account + `permissions: id-token: write`).
- Cache-tool performance comparison — https://zenn.dev/trifolium/articles/1a2eeca4775e56?locale=en
- crane (incremental artifact caching) — https://github.com/ipetkov/crane ("Never build twice"), API: https://github.com/ipetkov/crane/blob/master/docs/API.md , dep-caching discussion: https://github.com/ipetkov/crane/discussions/213 , workspace example: https://github.com/ipetkov/crane/blob/master/examples/quick-start-workspace/flake.nix
- GitHub Container Registry (publish images, pull at runtime) — https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry
- **Last updated:** 2026-06-05

## Why our release rebuilt 604 derivations (~34 min)

Two independent causes, both fixable:

1. **No crane dependency split.** `flake.nix` calls `craneLib.buildPackage` directly on the *full* source for each target. crane's incremental model requires building dependencies *separately* via `buildDepsOnly` into a `cargoArtifacts` derivation, then building the workspace crate with `cargoArtifacts` imported. Without this, any source change invalidates the whole derivation and every dependency recompiles. Per crane: `buildDepsOnly` strips the crate's real source so the dep derivation is stable; `cargoArtifacts` is a target-dir reused at the start of later derivations.
2. **No durable cross-run cache.** The run used `magic-nix-cache-action`, whose FlakeHub login *failed* (`determinate-nixd login github-action` → transient auth error), so only `cache.nixos.org` (no project-specific paths) + the branch-scoped GitHub Actions cache were available. GHA cache is **scoped per branch** and **10 GB-evicting**, so a release dispatched on a tag can't read caches a `main` run wrote, and vice-versa.

## Recommended setup

- **Caching:** drop `magic-nix-cache-action` (deprecated/fragile post-EOL). Use **`nix-community/cache-nix-action`** (free, no account, GHA-cache-backed) OR **FlakeHub Cache** (`permissions: id-token: write` + FlakeHub account) for a non-branch-scoped store. Always dispatch the release on a **consistent ref (`main`)** so GHA-cache scope is stable.
- **crane:** add `cargoArtifacts = craneLib.buildDepsOnly commonArgs;` once, then `craneLib.buildPackage (commonArgs // { inherit cargoArtifacts; ... })` per target. Now only changed crates rebuild; deps land in the cache and persist.
- **Images: build once, push, pull — never build at runtime.** `flake.nix` already defines reproducible images via `dockerTools.buildLayeredImage` (`packages.forge-image`, `packages.web-image`) — no cargo-binstall, no GitHub API. Build these in CI, push to **GHCR** (`ghcr.io/<owner>/tillandsias-<image>:<version>`), and have `tillandsias --init` do `podman pull` only. Dev toolchains (rust/go/python/cargo-* tools) belong in the Nix image inputs (all in nixpkgs), not a runtime `cargo binstall`.
- **Release hygiene:** the release runner builds the Linux musl binaries + signs + publishes only. No `--install`, no `--init`, no local image builds, no `cargo binstall`, no GitHub API calls from the build (publishing API calls are fine).

## Lifecycle boundaries (do not cross)

| Phase | Allowed | Forbidden |
| --- | --- | --- |
| Release CI (release.yml) | `nix build` Linux headless musl, cosign, `gh release` | `--install`, `--init`, `cargo binstall`, building/​compiling container images |
| Image publish CI | build image (Nix dockerTools / buildah) → push to GHCR | shipping a half-built image; runtime compilation |
| User runtime (`--init`) | `podman pull <registry>/<image>:<version>` | building/​compiling ANY image or toolchain locally |
