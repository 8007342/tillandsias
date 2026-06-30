# Plan: incremental Nix release + registry-distributed images (2026-06-05)

trace: cheatsheets/build/nix-ci-incremental-release.md, .github/workflows/release.yml,
       flake.nix, openspec/specs/ci-release/spec.md, plan/index.yaml (steps 38–41)

- **Host / branch**: linux (`linux-next`) — plan writes only; this is a PLAN, not an implementation.
- **Origin**: operator review of the v0.3.260603.1 release (run 27044586574). The release
  *succeeded* but the Nix build rebuilt **604 derivations from source (~34 min)** and the
  FlakeHub login failed. Operator goals (authoritative): (1) Nix builds INCREMENTAL across runs;
  (2) the Nix release builds ONLY the Linux headless (Windows/macOS are separate thin-wrapper
  cargo builds); (3) end-user `--init` only DOWNLOADS images from a registry, never builds/compiles;
  (4) release GitHub Actions never run `--install`/`--init`/expensive dev computation.

This note is intake/report; durable knowledge is in the cheatsheet above; actionable work is
shaped as steps 38–41 in `plan/index.yaml`.

## Root-cause findings (verified)

1. **crane is misused for incrementality.** `flake.nix` calls `craneLib.buildPackage` on the full
   source for each of the 3 targets, with **no `buildDepsOnly`/`cargoArtifacts`**. crane's whole
   value ("never build twice") requires building deps separately into `cargoArtifacts` and importing
   it into the crate build. Without it, every source change recompiles all deps → the 604 derivations.
   (Sources in the cheatsheet: crane README/API/discussion-213/workspace-example.)
2. **The cache is deprecated + failing.** `magic-nix-cache-action`'s free tier was EOL'd 2025-02
   (GitHub rewrote the Actions cache API); it was revived only via reverse-engineering. In our run the
   FlakeHub login *failed*, leaving only `cache.nixos.org` (no project paths) + the branch-scoped,
   10 GB-evicting GHA cache → nothing durable persisted across release runs.
3. **The forge image is built the wrong way for distribution.** `images/default/Containerfile` installs
   the Rust toolchain via `cargo binstall` (GitHub-API-dependent → the 403 rabbit hole) and is built
   *locally* at `tillandsias --init`. Yet `flake.nix` ALREADY defines a reproducible
   `packages.forge-image` (`dockerTools.buildLayeredImage`, no cargo-binstall, no GitHub API). Nothing
   publishes images to a registry, so `--init` has no choice but to build locally.

## The 3 Nix targets (for the "Linux headless only" decision)

| flake target | cargo | consumer |
| --- | --- | --- |
| `tillandsias-x86_64-musl` | `--bin tillandsias --features tray` | Linux desktop/tray app (end users) |
| `tillandsias-headless-x86_64-musl` | `-p tillandsias-headless --features listen-vsock` | in-VM agent for **Windows WSL** |
| `tillandsias-headless-aarch64-musl` | same, aarch64 (pulls `pkgsCross` cross-GCC) | in-VM agent for **macOS Fedora VM** |

All three are **Linux musl** binaries (the headless aarch64 runs in macOS's *Linux* VM, not on macOS).
The expensive part is the aarch64 `pkgsCross` cross-GCC — which, once cached, is a one-time cost.

## Implementation plan (steps 38–41)

### Step 38 — Incremental Nix CI caching (the ~34 min → minutes fix)
- `flake.nix`: introduce `cargoArtifacts = craneLib.buildDepsOnly commonCraneArgs` (one per target arch,
  since x86_64 and aarch64 have distinct dep artifacts) and pass `inherit cargoArtifacts` into each
  `buildPackage`. Now only changed crates rebuild.
- `release.yml`: replace `magic-nix-cache-action` with **`nix-community/cache-nix-action`** (free, no
  account) — or FlakeHub Cache if the operator wants it (`permissions: id-token: write` + FlakeHub
  account). Keep dispatching on a consistent ref (`main`) for stable GHA-cache scope.
- Acceptance: a second back-to-back release run reuses the cached cross-GCC + dep artifacts (build
  step drops from ~34 min to a few minutes; log shows mostly "copying path" not "will be built").

### Step 39 — Release Nix path builds only Linux (decision-gated)
- The Nix job already builds only Linux musl (no macOS/Windows compilation). Confirm and document the
  lifecycle boundary. **OPEN DECISION (operator):** do we keep the aarch64 headless in the Nix release
  (it's the macOS VM's Linux agent), or move it elsewhere? Default recommendation: KEEP it (it's a Linux
  binary; the cache makes it cheap) but gate it behind step 38 so it stops being the slow path.
- Acceptance: release.yml's `release` job builds exactly the agreed Linux targets; macOS/Windows tray
  builds remain in their own `needs: release` jobs (cargo, not Nix).

### Step 40 — Build images in CI, push to registry; `--init` pulls only (no runtime compile)
- New CI workflow (or release.yml job) builds the images **once** and pushes to **GHCR**
  (`ghcr.io/<owner>/tillandsias-<image>:v<version>`). Prefer the reproducible Nix `dockerTools` images
  (`packages.forge-image`, `web-image`) — no cargo-binstall, no GitHub API. If the full dev toolchain is
  required, add those tools to the Nix `forgeImageRoot` inputs (rust/go/python/cargo-* are all in nixpkgs)
  rather than `cargo binstall`.
- `tillandsias --init`: change the image-provisioning path to `podman pull
  ghcr.io/<owner>/tillandsias-<image>:v<version>` and FAIL LOUDLY if the registry image is missing —
  never fall back to a local build/compile. Retire the `cargo binstall` Containerfile layer (and revert
  the gh-token build-secret band-aid from commit 8f3d6eb6).
- Acceptance: on a clean host, `--init` pulls all images and compiles nothing; no GitHub API call; the
  `cargo binstall` layer is gone.

### Step 41 — Release-workflow hygiene (no `--install`/`--init`/expensive dev steps on runners)
- Audit `release.yml` (+ `ci.yml`) and confirm the release runners do ONLY: Nix build (Linux headless) →
  validate (cheap `--version`/`--headless` smoke is OK) → cosign → publish. No `--install`, no `--init`,
  no image builds, no `cargo binstall`. (Current release.yml already avoids `--install`/`--init`; this
  step pins it with an assertion/comment and removes anything that drifts in.)
- Acceptance: a grep gate in CI (or a litmus) asserts release.yml contains no `--install|--init|cargo binstall|podman build`.

## Open decisions for the operator
1. **Cache**: `nix-community/cache-nix-action` (free, GHA-cache) vs **FlakeHub Cache** (Determinate, needs
   account + `id-token`)? Recommend cache-nix-action to start (free, no account).
2. **aarch64 headless**: keep in the Nix release (recommended, cache makes it cheap) or drop/relocate?
3. **Registry**: GHCR (`ghcr.io`) assumed. Confirm, and whether images are public or private (affects
   `podman pull` auth at `--init`).
4. **Forge toolchain**: ship the lean Nix `forge-image` as-is, or port the full dev toolchain
   (cargo-*/go/python) into the Nix image inputs so it's reproducible and registry-distributed?

## Operator decisions + model correction (2026-06-05)

1. **Cache** → `nix-community/cache-nix-action` (free community cache) for every Nix build that benefits
   (all Linux targets). macOS/Windows tray builds already cache via `swatinem/rust-cache` (cargo analog).
2. **aarch64 headless** → KEEP (it's the macOS VM's *Linux* agent; the cache makes it cheap). Release
   artifacts are exactly: **LINUX (headless + tray)**, **MACOS thin wrapper**, **WINDOWS thin wrapper**.
3. **No registry / no image publishing — MODEL CORRECTED.** We build/push NO images. The Containerfile
   is a runtime RECIPE: at `--init` the idiomatic layer DOWNLOADS predistributed third-party binaries
   from FREE PUBLIC no-login repos (Fedora `microdnf`; direct release-asset URLs
   `github.com/.../releases/download/...` — NOT the rate-limited GitHub API) and ASSEMBLES them. Never
   compiles. Step 40 rewritten accordingly.
4. **Re-explained**: the only thing that compiles is `cargo install` (pre-step-28) and `cargo binstall`'s
   compile-fallback. CURRENT `cargo binstall --disable-strategies compile` is download-only but queries
   the GitHub API (60/hr → 403, needs token). Fix = Fedora packages + direct release-asset URLs
   (download-only, no login, no rate limit); **prefer lean**; drop tools that can't be download-only.
   My earlier "remove --disable-strategies compile" is WITHDRAWN (it re-enables compiling). The gh-token
   band-aid (commit 8f3d6eb6) is reverted.

## Cross-compile reach (operator question)
- **Linux** (headless x86_64/aarch64, tray x86_64): YES — Nix cross-compiles, shares the Nix cache.
- **macOS thin wrapper**: NO — Darwin needs Apple's SDK (license-restricted) + `codesign`/virtualization
  entitlement (macOS-only) → must build on a macOS runner.
- **Windows thin wrapper**: MAYBE — `pkgsCross.mingwW64` (`x86_64-pc-windows-gnu`) can cross-compile from
  Linux and would join the Nix cache, but it's a real port from `-msvc` (windows-crate import libs,
  ConPTY/HvSocket, `.rc`/`.ico` via windres). Optional spike, not a committed step.
