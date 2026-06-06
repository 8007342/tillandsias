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
- **Images: a RECIPE assembled at runtime by download-only — NO push-to-registry, NO compile.** We publish no images. The `Containerfile` is a *recipe* (embedded in the Linux binary); `tillandsias --init` runs it to ASSEMBLE predistributed third-party binaries pulled from **free public repos that need no login**: Fedora `microdnf` first (most forge tools are packaged), direct release-asset URLs second (`github.com/<o>/<r>/releases/download/<tag>/<asset>` is a public CDN — NOT the 60/hr GitHub API). Prefer LEAN; never `cargo install`/compile; never `cargo binstall` (it queries the rate-limited GitHub API → 403). The `flake.nix` Nix `dockerTools` images stay as a dev/reference convenience, not a release/publish artifact.
- **Release artifacts (exactly three):** LINUX (headless + tray musl binaries — carry the Containerfile recipes, speak idiomatic podman/UX), MACOS-THIN-WRAPPER (idiomatic VM, native UX — built on a macOS runner), WINDOWS-THIN-WRAPPER (idiomatic WSL2, native UX — Windows runner today; candidate for Nix windows-gnu cross). Linux uses the Nix cache; macOS/Windows use `swatinem/rust-cache` (the cargo analog).
- **Release hygiene:** release runners build/sign/publish ONLY. No `--install`, no `--init`, no image builds, no `cargo binstall`, no GitHub *API build* calls (publishing API calls are fine).
- **Cross-compile reach:** Nix cross-compiles all Linux targets (headless x86_64/aarch64, tray x86_64). macOS = NOT cross-compilable (Apple SDK + codesign → macOS runner). Windows = possibly via `pkgsCross.mingwW64` (windows-gnu) — a spike, not guaranteed.

## Lifecycle boundaries (do not cross)

| Phase | Allowed | Forbidden |
| --- | --- | --- |
| Release CI (release.yml) | `nix build` Linux musl (headless+tray); macOS/Windows wrapper builds on native runners; cosign; `gh release` | `--install`, `--init`, `cargo binstall`, building/publishing container images |
| User runtime (`--init`) | run the Containerfile *recipe*: download prebuilt binaries from FREE PUBLIC no-login repos (Fedora `microdnf`, release-asset URLs) and ASSEMBLE | compiling / `cargo install` / `cargo binstall` / any login or rate-limited API |
| Registry push | (none — we publish no images) | building/pushing any image from our side |
