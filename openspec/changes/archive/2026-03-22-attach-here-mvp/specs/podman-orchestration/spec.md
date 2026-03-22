## ADDED Requirements

### Requirement: Image build and cache
The podman client SHALL support building container images from a Containerfile and caching them in the local image store.

#### Scenario: Build image
- **WHEN** `build_image` is called with a Containerfile path and image name
- **THEN** `podman build` runs asynchronously and the built image is available locally

#### Scenario: Image cache hit
- **WHEN** `image_exists` returns true for the target image name
- **THEN** the build step is skipped entirely
