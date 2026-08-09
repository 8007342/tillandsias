<!-- @trace spec:init-incremental-builds -->
# init-incremental-builds Specification

## Status

status: active

## Purpose
Track and resume partial `tillandsias --init` builds, with debug logging for failed images and content-based runtime asset staleness.

## Requirements

### Requirement: Incremental build state tracking
The init command MUST maintain a state file at `$HOME/.cache/tillandsias/init-build-state.json` tracking which images were successfully built, the runtime asset manifest digest, and the per-image source digest used for the build.

#### Scenario: First run with no state file
- **WHEN** `tillandsias --init` is run and no state file exists
- **THEN** all images MUST be built in sequence (proxy, git, vault, inference, router, chromium-core, chromium-framework, forge-base, forge, web)

#### Scenario: Re-run after partial failure
- **WHEN** `tillandsias --init` is run and the state file shows proxy=success, forge=failed
- **THEN** proxy MUST be skipped (image exists check), forge MUST be rebuilt, and git, vault, inference, router, chromium-core, chromium-framework, forge-base, and web MUST proceed normally

#### Scenario: Image deleted after successful build
- **WHEN** `tillandsias --init` is run, state shows forge=success, but `podman image exists tillandsias-forge:vX.Y.Z` returns false
- **THEN** forge MUST be rebuilt despite state showing success

#### Scenario: Runtime image source digest changes
- **WHEN** `tillandsias --init` is run and the state file shows an image success, but the current release runtime source digest for that image differs from the cached digest
- **THEN** that image MUST be rebuilt even if the image tag exists
- **AND** the state file MUST be refreshed with the new digest after a successful build

### Requirement: Final Containerfile instruction layers are squashed

Every Tillandsias Podman build from a Containerfile MUST pass exactly one
`--squash`, collapsing the layers created by that Containerfile into one final
new layer. It MUST NOT pass `--squash-all`: inherited images such as
`forge-base` and `chromium-core` remain independently reusable and shared with
their final images. Podman's intermediate layer cache MAY remain enabled.

The `squash-new` policy MUST participate in the image content identity and be
recorded as `io.tillandsias.image.layer-policy=squash-new`, so an image built
under the previous unsquashed policy cannot be accepted as a current canonical
image. This requirement applies equally to compiled init, compiled on-demand
missing-image construction, and the developer `scripts/build-image.sh` path.
Nix `dockerTools` reference tarballs do not execute Containerfiles and remain
governed by `spec:nix-builder`.

#### Scenario: Forge final image preserves its shared base

- **WHEN** forge-base and forge are built from their Containerfiles
- **THEN** forge SHALL contain no more than the forge-base RootFS layer count plus one
- **AND** forge-base SHALL remain a separately tagged reusable image
- **AND** neither build command SHALL contain `--squash-all`

#### Scenario: Layer policy migration invalidates an old image

- **WHEN** an otherwise identical image exists without the `squash-new` identity input and label
- **THEN** the content-addressed canonical identity SHALL differ
- **AND** init SHALL build the squashed canonical image once instead of treating the old image as a cache hit
- **AND** subsequent unchanged init runs MAY reuse the squashed image and intermediate build cache

### Requirement: Debug flag for init command
The init command MUST accept a `--debug` flag that enables verbose output and failed build log capture.

#### Scenario: Init with debug flag
- **WHEN** `tillandsias --init --debug` is run
- **THEN** build output MUST be shown on terminal AND captured to `/tmp/tillandsias-init-<image>.log` for each image

#### Scenario: Init without debug flag
- **WHEN** `tillandsias --init` is run without `--debug`
- **THEN** no debug logs MUST be captured and no log files MUST be created

### Requirement: Failed build log display
After all images are processed, if `--debug` was used and any builds failed, the init command MUST display the last 10 lines of each failed build's log file.

#### Scenario: Failed builds with debug mode
- **WHEN** `tillandsias --init --debug` completes and forge + inference builds failed
- **THEN** the output MUST include `tail -10 /tmp/tillandsias-init-forge.log` and `tail -10 /tmp/tillandsias-init-inference.log` content

#### Scenario: All builds successful
- **WHEN** `tillandsias --init --debug` completes with all images built successfully
- **THEN** no failed build logs MUST be displayed

#### Scenario: No debug mode
- **WHEN** `tillandsias --init` (without `--debug`) completes with failures
- **THEN** no failed build logs MUST be displayed (user should re-run with `--debug`)

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:init-log-cleanup` — Verify init logs are collected, displayed on failure, and cleaned up on success

Gating points:
- On first init, all images build (cold start)
- Subsequent init with unchanged Containerfile/flake.nix uses cached layers; rebuilds skip unchanged stages
- Source file staleness tracked via hash; if source.hash == cached.hash, layer rebuild skipped
- Init success (all images built/cached) removes temp logs; user never sees log files
- Init failure logs are displayed inline (with `--debug`, full output; without `--debug`, error summary only)
- Build errors are non-fatal to tray startup; tray shows degraded status until user fixes and re-runs init

## Sources of Truth

- `cheatsheets/build/cargo.md` — Cargo reference and patterns
- `cheatsheets/build/nix-flake-basics.md` — Nix Flake Basics reference and patterns
- `cheatsheets/runtime/image-lifecycle.md` — Runtime source digest and rebuild lifecycle
- `cheatsheets/runtime/user-runtime-install.md` — Release-shipped runtime asset root

## Observability

Annotations referencing this spec can be found by:
```bash
grep -rn "@trace spec:init-incremental-builds" src-tauri/ scripts/ crates/ images/ --include="*.rs" --include="*.sh"
```
