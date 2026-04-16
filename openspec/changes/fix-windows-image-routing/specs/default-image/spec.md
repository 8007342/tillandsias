# Delta: default-image (Windows image routing)

## MODIFIED Requirements

### Requirement: Image build routes by image_name on every platform

The system SHALL route image builds to the correct Containerfile and build context based on `image_name`, on every platform. Specifically: `forge`/default → `images/default/`; `proxy` → `images/proxy/`; `git` → `images/git/`; `inference` → `images/inference/`; `web` → `images/web/`. The Windows direct-podman build path SHALL apply the same routing as the Linux/macOS `build-image.sh` script.

@trace spec:default-image, spec:fix-windows-image-routing

#### Scenario: Building the proxy image on Windows
- **WHEN** `run_build_image_script("proxy")` is called on Windows
- **THEN** podman SHALL build using `images/proxy/Containerfile` with build context `images/proxy/`
- **AND** the resulting image SHALL be tagged `tillandsias-proxy:v<version>`
- **AND** the resulting image's entrypoint SHALL be the proxy entrypoint (`/usr/local/bin/entrypoint.sh` from `images/proxy/`), NOT the forge entrypoint

#### Scenario: Building the git mirror image on Windows
- **WHEN** `run_build_image_script("git")` is called on Windows
- **THEN** podman SHALL build using `images/git/Containerfile` with build context `images/git/`
- **AND** the resulting image SHALL be tagged `tillandsias-git:v<version>`
- **AND** the resulting image's entrypoint SHALL be the git mirror entrypoint

#### Scenario: Building the inference image on Windows
- **WHEN** `run_build_image_script("inference")` is called on Windows
- **THEN** podman SHALL build using `images/inference/Containerfile` with build context `images/inference/`
- **AND** the resulting image SHALL be tagged `tillandsias-inference:v<version>`
- **AND** the resulting image's entrypoint SHALL be the ollama entrypoint

#### Scenario: Detect duplicate image IDs across enclave tags
- **WHEN** the app starts in debug mode
- **AND** two or more `tillandsias-*:v<version>` tags resolve to the same image ID
- **THEN** the app SHALL emit a warning log via `--log-enclave` naming the affected tags
- **AND** the warning SHALL include `spec = "default-image, fix-windows-image-routing"` for traceability
