## Why

Coding containers currently have unrestricted network access and receive GitHub tokens via bind mounts. AI agents running inside can read secrets and exfiltrate data to any endpoint. This is the most critical security gap in the architecture. Phase 1 lays the foundation by creating an internal podman network (enclave) and a caching proxy container that becomes the only gateway to the internet — all other containers are isolated.

## What Changes

- Create a `tillandsias-enclave` podman internal network that prevents direct external access
- Build a `tillandsias-proxy` container image (Alpine + squid) with a curated domain allowlist for developer sites
- Proxy provides ~500MB disk cache for frequently downloaded packages (npm, cargo, pip, etc.)
- Add proxy container lifecycle management to the host app (start/stop, health check, shared across projects)
- Modify forge container launch to attach to the enclave network and set `HTTP_PROXY`/`HTTPS_PROXY` env vars
- Add new container profile for the proxy in `tillandsias-core`
- Add `--log-proxy` accountability window for proxy request telemetry (domain, allow/deny, cache hit)
- Add `--log-enclave` accountability window for enclave lifecycle events
- Build proxy image via existing `build-image.sh` pipeline with versioned tags
- **BREAKING**: Forge containers will no longer have direct internet access — all HTTP/HTTPS goes through the proxy

## Capabilities

### New Capabilities
- `enclave-network`: Internal podman network creation, lifecycle, and container attachment
- `proxy-container`: Caching HTTP/HTTPS proxy with domain allowlist, egress firewall, and telemetry

### Modified Capabilities
- `podman-orchestration`: Forge containers now attach to the enclave network instead of the default bridge; proxy env vars injected
- `environment-runtime`: Forge profile gains `HTTP_PROXY`/`HTTPS_PROXY` env vars pointing to the proxy container
- `runtime-logging`: New accountability windows `--log-proxy` and `--log-enclave` added

## Impact

- **New files**: `images/proxy/Containerfile`, `images/proxy/squid.conf`, `images/proxy/allowlist.txt`, `images/proxy/entrypoint.sh`
- **Modified crates**: `tillandsias-core` (new proxy profile, enclave network types), `tillandsias-podman` (network create/inspect/remove)
- **Modified binaries**: `src-tauri/src/launch.rs` (enclave network attachment), `src-tauri/src/handlers.rs` (proxy lifecycle), `src-tauri/src/cli.rs` (new log flags)
- **Dependencies**: None new — uses existing podman CLI for network management
- **Image build**: New `tillandsias-proxy:v{VER}` image, ~15-20MB (Alpine-based)
