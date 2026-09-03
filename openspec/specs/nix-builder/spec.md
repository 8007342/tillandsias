<!-- @trace spec:nix-builder -->
## Status

active

## Requirements

### Requirement: Build-time Nix only
<!-- req-id: 7627de5c -->
Nix SHALL be used only for build-time reproducibility and image-input materialization. It MUST NOT participate in user runtime launch paths, browser launch paths, or container lifecycle orchestration.

#### Scenario: Build-time-only boundary stays intact
- **WHEN** the build tooling references the Nix flake
- **THEN** it MUST be limited to Rust/toolchain/package inputs and image-root derivation
- **AND** it MUST NOT be referenced as part of `tillandsias --tray`, `--opencode-web`, or any runtime Podman launcher path

### Requirement: Git-tracked files for flake builds
<!-- req-id: b276171d -->
Nix flake builds MUST only see files that are tracked by git. The staleness check in `build-image.sh` MUST use `git ls-files` to enumerate source files, ensuring the staleness hash covers exactly the same files that the build inputs will include.

#### Scenario: Staleness check matches Nix view
- **WHEN** `build-image.sh` computes a staleness hash for image sources
- **THEN** it MUST use `git ls-files` to enumerate files in `images/default/` and `images/web/`
- **AND** the hash MUST cover exactly the same files that the image build inputs will include

#### Scenario: Untracked file detected in image sources
- **WHEN** untracked files exist in `images/default/` or `images/web/` directories
- **THEN** `build-image.sh` MUST fail with a clear error listing the untracked files and instructing the developer to run `git add`

#### Scenario: Staged file included in build
- **WHEN** a new file is added to the `images/` directory and staged with `git add`
- **THEN** both the staleness check and the Nix flake build MUST include that file

#### Scenario: Non-git environment fallback
- **WHEN** `build-image.sh` runs outside a git repository (e.g., from a source tarball)
- **THEN** the staleness check MUST fall back to `find`-based enumeration with a warning that untracked file detection is unavailable

### Requirement: dockerTools builder/attribute pairing
<!-- req-id: 4d2fec95 -->
The flake.nix image definitions MUST pass the image root through the parameter the builder actually declares: `dockerTools.buildLayeredImage` (a wrapper over `streamLayeredImage`) takes `contents`; only `dockerTools.buildImage` takes `copyToRoot`. nixpkgs-26.05 rejects `copyToRoot` in `buildLayeredImage` outright (first red: commit 9b0c27c1c, the 24.11 → 26.05 bump), so the previous requirement here — prefer `copyToRoot` in `buildLayeredImage` — pinned a parameter the builder does not accept.

#### Scenario: Layered image definition uses contents
- **WHEN** an image is defined in `flake.nix` using `dockerTools.buildLayeredImage`
- **THEN** the `contents` attribute MUST be used to specify the image root
- **AND** `copyToRoot` MUST NOT appear in the definition — it is a `buildImage`-only parameter and nixpkgs-26.05 fails evaluation on it

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:nix-builder-shape`

Gating points:
- Nix flake evaluates without errors and produces valid image tarballs
- `flake.nix` uses `dockerTools.buildLayeredImage` with `contents` (`copyToRoot` is `buildImage`-only; nixpkgs-26.05 rejects it in `buildLayeredImage`)
- `nix build` inside tillandsias-builder toolbox produces .tar.gz at expected output path
- Image tarball can be loaded into podman via `podman load`
- Image passes `podman inspect` and shows correct layer structure
- Reproducible builds: same source inputs produce identical image hash (bit-for-bit)

## Sources of Truth

- `cheatsheets/build/cargo.md` — Cargo reference and patterns
- `cheatsheets/build/nix-flake-basics.md` — Nix Flake Basics reference and patterns
- `cheatsheets/build/nix-flake-caching.md` — Nix build input hashing and cache semantics

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:nix-builder" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
