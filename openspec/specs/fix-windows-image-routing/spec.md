<!-- @trace spec:fix-windows-image-routing -->
# fix-windows-image-routing Specification

## Status

status: active
promoted-from: openspec/changes/archive/2026-04-16-fix-windows-image-routing/
annotation-count: 1
implementation-complete: true

## Purpose

Fix Windows container image building by routing each image type (forge, proxy, git, inference, web) to its own Containerfile and build context. Previously, Windows hardcoded all builds to `images/default/Containerfile` (the forge), resulting in four image tags pointing to the same image ID.

## Requirements

### Requirement: Image Build Path Routing by Type

The Windows direct-podman build path in `run_build_image_script()` MUST route each image type to its correct Containerfile and context directory.

#### Routing Table

| Image Type | Containerfile | Context Directory |
|------------|---------------|-------------------|
| `forge` | `images/default/Containerfile` | `images/default/` |
| `proxy` | `images/proxy/Containerfile` | `images/proxy/` |
| `git` | `images/git/Containerfile` | `images/git/` |
| `inference` | `images/inference/Containerfile` | `images/inference/` |
| `web` | `images/web/Containerfile` | `images/web/` |

#### Scenario: Build proxy image on Windows
- **WHEN** `run_build_image_script("proxy", "v0.1.37.42")` is called on Windows
- **WHEN** the function uses the direct-podman build path (not Linux/macOS shelling out to `build-image.sh`)
- **THEN** `podman build` is invoked with `images/proxy/Containerfile` as the Dockerfile
- **THEN** `images/proxy/` is the build context directory

#### Scenario: Build git image on Windows
- **WHEN** `run_build_image_script("git", "v0.1.37.42")` is called on Windows
- **THEN** `podman build` is invoked with `images/git/Containerfile` as the Dockerfile
- **THEN** `images/git/` is the build context directory

#### Scenario: Build inference image on Windows
- **WHEN** `run_build_image_script("inference", "v0.1.37.42")` is called on Windows
- **THEN** `podman build` is invoked with `images/inference/Containerfile` as the Dockerfile
- **THEN** `images/inference/` is the build context directory

### Requirement: Correct Image Entrypoints

Each built image MUST contain the correct entrypoint for its service type.

#### Scenario: Proxy container starts with squid
- **WHEN** the `tillandsias-proxy` image (built from `images/proxy/Containerfile`) is started
- **THEN** the entrypoint runs the proxy service (squid), not the forge entrypoint

#### Scenario: Git container starts with git-daemon
- **WHEN** the `tillandsias-git` image (built from `images/git/Containerfile`) is started
- **THEN** the entrypoint runs git-daemon, not the forge entrypoint

#### Scenario: Inference container starts with ollama
- **WHEN** the `tillandsias-inference` image (built from `images/inference/Containerfile`) is started
- **THEN** the entrypoint runs ollama, not the forge entrypoint

### Requirement: Image Build Centralized in Helper

The routing logic MUST be encapsulated in a small `image_build_paths(image_name: &str) -> (Containerfile, ContextDir)` helper function.

#### Behavior

- The helper returns the tuple `(Containerfile, context_dir)` for the given `image_name`
- The helper is used by the Windows direct-podman build path
- The helper is available for reuse if/when a unified Phase-2 path from `direct-podman-calls` lands

### Requirement: Defensive Integration Test or Self-Check

A defensive mechanism MUST flag duplicate image IDs across `tillandsias-{forge,proxy,git,inference}` tags.

#### Detection Mechanism

Either:
- An integration test that builds all four images and asserts they have distinct image IDs
- OR a startup self-check that compares the image IDs of the four tags and logs a FATAL error if duplicates are found

#### Scenario: All images have unique IDs
- **WHEN** the application starts or builds complete
- **THEN** the check runs
- **THEN** no error is logged

#### Scenario: Duplicate image IDs detected
- **WHEN** two or more of `tillandsias-{forge,proxy,git,inference}` point to the same image ID
- **THEN** a FATAL error is logged immediately
- **THEN** the enclave cannot launch until the images are rebuilt

### Requirement: Build Number Bump

After the fix is merged, the build number MUST be incremented.

#### Scenario: Existing Windows installs
- **WHEN** an existing Windows install runs the staleness check
- **THEN** it observes the build number has changed
- **THEN** it triggers a rebuild to pull the freshly-built images with correct entrypoints

## Rationale

The Windows direct-podman build path (used when `build-image.sh` is unavailable) previously hardcoded the build context to `images/default/Containerfile` for all image types. This meant every image (proxy, git, inference) was built from the forge Containerfile, resulting in four tags pointing to the same image containing only the forge entrypoint and dependencies. When the enclave tried to start a proxy or git service, it would run the forge entrypoint (wrong USER, missing squid/git-daemon binaries) or crash. Routing by `image_name` restores parity with the Linux/macOS path (which uses `build-image.sh` with a `case` statement) and ensures the Windows enclave bring-up works correctly.

## Sources of Truth

- `cheatsheets/build/image-building.md` — container image build routing and Containerfile selection
- `cheatsheets/runtime/enclave-services.md` — enclave service architecture and entrypoints

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:ephemeral-guarantee`

Gating points:
- Image routing state is ephemeral; WSL containers are cleaned up
- Deterministic and reproducible: test results do not depend on prior state
- Falsifiable: failure modes (leaked state, persistence) are detectable
