## Context

Tillandsias currently launches a single forge container per project with direct internet access and credential mounts (GitHub token, hosts.yml, Claude dir). AI agents running inside can reach any endpoint and read secrets. This is the most critical security gap.

Phase 1 introduces the enclave foundation: an internal podman network and a caching proxy container. Subsequent phases (git mirror, offline forge, inference) build on this network isolation.

The proxy is the first "internal" container — invisible to users, managed entirely by the host app. It is shared across all projects and long-lived (started once, stays up until app exit).

@trace spec:enclave-network, spec:proxy-container

## Goals / Non-Goals

**Goals:**
- Create an internal podman network (`tillandsias-enclave`) that prevents direct external access
- Build and manage a proxy container that caches packages and enforces a domain allowlist
- Modify forge launch to route HTTP/HTTPS through the proxy
- Add `--log-proxy` and `--log-enclave` accountability windows
- Version the proxy image alongside other Tillandsias images
- Prepare for CA cert propagation in future phases

**Non-Goals:**
- Git mirror or credential isolation (Phase 2-3)
- Inference container (Phase 4)
- TLS interception / MITM proxy (future, when needed)
- Per-project allowlist customization (future, settings page)
- Removing credential mounts from forge (Phase 3 — forge still gets tokens in Phase 1)

## Decisions

### D1: Squid as the proxy engine

**Choice**: Squid on Alpine Linux (~15MB image)

**Alternatives considered**:
- tinyproxy: Simpler, but no disk caching and limited access control
- nginx: HTTP-only proxy, no native HTTPS CONNECT support
- mitmproxy: Full MITM but requires CA cert injection, overkill for Phase 1

**Rationale**: Squid handles HTTP + HTTPS CONNECT transparently, has robust disk caching, and domain-based ACLs via `dstdomain`. Battle-tested in enterprise environments. Alpine keeps the image tiny.

### D2: Internal podman network with `--internal` flag

**Choice**: `podman network create tillandsias-enclave --internal`

**Alternatives considered**:
- Unix sockets only (no podman network): More secure but tools like npm/pip don't support socket-based HTTP_PROXY
- Default bridge with iptables: Complex, fragile across podman versions

**Rationale**: `--internal` is the podman-native way to prevent external access. The proxy container is dual-homed (internal + default bridge). Clean, portable, works on Linux/macOS/Windows.

### D3: Proxy lifecycle — shared, long-lived

**Choice**: Start proxy on first container launch, keep alive until app exit. Shared across all projects.

**Rationale**: Starting/stopping a proxy per project would add latency and complicate cache sharing. A single proxy with a shared cache benefits all projects. Health-checked periodically via the event loop.

### D4: Domain allowlist — built-in, generous

**Choice**: Hardcoded allowlist in `squid.conf` covering web/mobile/cloud development. Not user-configurable in Phase 1.

**Rationale**: Beginners need everything to work out of the box. A restrictive allowlist that breaks `npm install` is worse than no proxy at all. Power users will figure out workarounds. User-configurable allowlists come with a settings page (future).

### D5: Proxy container uses same security flags

**Choice**: `--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`, `--rm`

**Rationale**: Same non-negotiable security flags as all Tillandsias containers. The proxy doesn't need any capabilities — squid runs as a non-root user.

### D6: Forge gets HTTP_PROXY env vars, still has direct network (transitional)

**Choice**: In Phase 1, forge is on BOTH the enclave network and the default bridge. `HTTP_PROXY`/`HTTPS_PROXY` point to the proxy. Direct access is still possible but discouraged.

**Rationale**: Removing direct access requires the git mirror (Phase 2) to be in place first. Phase 1 is additive — it introduces the proxy without breaking existing workflows. Phase 3 removes the default bridge from forge.

## Risks / Trade-offs

- **[Allowlist gaps]** → Generous default list. Denied requests return clear error with the blocked domain. `--log-proxy` shows every deny. Easy to add domains.
- **[Proxy crash]** → All package installs fail. Mitigated by health check in event loop + auto-restart. Forge still has direct network in Phase 1 (transitional).
- **[Cache corruption]** → Squid's cache is in a volume. `tillandsias --clean` can purge it. Corruption is rare with squid's cache_dir ufs backend.
- **[Podman network conflicts]** → Name collision with existing `tillandsias-enclave` network. Check existence before creation, reuse if present.
- **[Cross-platform]** → `podman network create --internal` works on Linux/macOS (podman machine). Windows TBD but podman machine on Windows uses the same Linux networking.
