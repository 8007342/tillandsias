# Enclave Architecture

## Overview

Tillandsias isolates development environments using a 4-container enclave behind an internal podman network. The forge container (where the user works) has ZERO direct internet access and ZERO credentials. All external traffic flows through a caching proxy. Credentials are held by a dedicated git service that communicates with the host keyring via D-Bus. An inference container provides local AI model access without external network.

@trace spec:enclave-network, spec:proxy-container

## Architecture Diagram

```
                          ┌─────────────────────────────────────────────────┐
                          │           tillandsias-enclave (--internal)      │
                          │                                                 │
  ┌──────────┐            │  ┌──────────┐    ┌──────────┐   ┌───────────┐  │
  │          │◄──bridge───┤  │  proxy   │    │   git    │   │ inference │  │
  │ internet │            │  │  :3128   │    │ service  │   │  (ollama) │  │
  │          ├──bridge───►│  │  squid   │    │  mirror  │   │           │  │
  └──────────┘            │  └────▲─────┘    └────▲─────┘   └─────▲─────┘  │
                          │       │               │               │        │
                          │       │ HTTP_PROXY    │ git://        │ :11434 │
                          │       │               │               │        │
                          │  ┌────┴───────────────┴───────────────┴─────┐  │
                          │  │                forge                     │  │
                          │  │     user workspace + AI agent           │  │
                          │  │     NO credentials, NO external net     │  │
                          │  └─────────────────────────────────────────┘  │
                          │                                                 │
                          └─────────────────────────────────────────────────┘
                                        ▲
                                        │ D-Bus (git service only)
                                        ▼
                               ┌─────────────────┐
                               │   host keyring   │
                               │  (GNOME/KDE/     │
                               │   macOS/Windows) │
                               └─────────────────┘
```

**Key invariant**: Only the proxy container is dual-homed (enclave + bridge). Every other container is enclave-only. The forge has no route to the internet except through the proxy, and no credentials at all.

@trace spec:enclave-network

## Container Types

| Container | Image | Network | Credentials | Lifecycle | Purpose |
|-----------|-------|---------|-------------|-----------|---------|
| **proxy** | `tillandsias-proxy:v{VER}` (~15MB, Alpine + squid) | enclave + bridge (dual-homed) | None | Shared, long-lived (app lifetime) | Caching HTTP/HTTPS proxy, domain allowlist, egress firewall |
| **git** | `tillandsias-git:v{VER}` | enclave only | D-Bus to host keyring | Shared, long-lived (app lifetime) | Git mirror, credential-isolated push/pull (Phase 2-3) |
| **forge** | `tillandsias-forge:v{VER}` or `macuahuitl:latest` | enclave only | None (Phase 3+) | Per-project, user-initiated | Development environment, AI agent workspace |
| **inference** | `tillandsias-inference:v{VER}` | enclave only | None | Shared, long-lived (app lifetime) | Local AI model serving via ollama (Phase 4) |

All containers: `--cap-drop=ALL`, `--security-opt=no-new-privileges`, `--userns=keep-id`, `--security-opt=label=disable`, `--rm`, `--init`, `--stop-timeout=10`

Source: `src-tauri/src/launch.rs`, `crates/tillandsias-core/src/container_profile.rs`
@trace spec:podman-orchestration, spec:enclave-network

## Phased Rollout

| Phase | What ships | Forge network | Forge credentials | Status |
|-------|-----------|---------------|-------------------|--------|
| **Phase 1** | Proxy + enclave network | Enclave + bridge (transitional) | Still has token mounts | COMPLETE |
| **Phase 2** | Git mirror service | Enclave + bridge (transitional) | Still has token mounts | COMPLETE |
| **Phase 3** | Credential isolation + mirror-only clone | Enclave only | ZERO — git service handles all auth | COMPLETE |
| **Phase 4** | Inference container | Enclave only | ZERO | Planned |

Phases 1-3 are complete. Phase 3 is the security milestone where forge loses both direct internet and credentials. Forge containers clone from the git mirror at startup (no fallback to direct mount) and push back via the enclave network. GitHub Login now runs inside the git service container instead of a standalone forge.

@trace spec:enclave-network, spec:proxy-container

## IPC Model

### Fast paths (direct enclave network)

These use the internal `tillandsias-enclave` network. No host mediation, low latency.

| Path | Protocol | From | To | Port | Purpose |
|------|----------|------|----|------|---------|
| Package install | HTTP/HTTPS via CONNECT | forge | proxy | 3128 | npm, pip, cargo, apt — cached |
| Git clone/fetch | git:// | forge | git service | 9418 | Local mirror, no credentials needed |
| AI inference | HTTP | forge | inference | 11434 | ollama API for local models |
| DNS (internal) | podman DNS | all containers | podman | — | Hostnames: `proxy`, `git-service`, `inference` |

### Audited paths (host-mediated)

These cross the enclave boundary. Each is logged to an accountability window.

| Path | Mechanism | From | To | Accountability | Purpose |
|------|-----------|------|----|----------------|---------|
| Remote push/pull | D-Bus | git service | host keyring | `--log-git` | Credential retrieval for authenticated git ops |
| Secret injection | D-Bus | git service | host keyring | `--log-secret-management` | Token read from OS keyring |
| Model downloads | HTTP via proxy | inference | proxy -> internet | `--log-proxy` | Pulling ollama models through allowlist |
| Proxy egress | HTTP/HTTPS | proxy | internet | `--log-proxy` | All outbound traffic (allowlist enforced) |

@trace spec:enclave-network, spec:proxy-container

## Accountability Windows

Three new accountability windows provide visibility into enclave operations without exposing secrets or request content.

| Flag | What it shows | What it hides |
|------|--------------|---------------|
| `--log-enclave` | Network creation/removal, container attach/detach, health checks | Internal traffic content |
| `--log-proxy` | Domain, request size, allow/deny, cache hit/miss | Request bodies, headers, cookies, credentials |
| `--log-git` | Mirror sync events, push/pull operations (Phase 2) | Token values, credential content |

Example output:

```
[enclave] v0.1.110.96 | Network created: tillandsias-enclave
  @trace https://github.com/8007342/tillandsias/search?q=%40trace+spec%3Aenclave-network&type=code

[enclave] v0.1.110.96 | Container attached: tillandsias-myapp-aeranthos (forge)
  @trace https://github.com/8007342/tillandsias/search?q=%40trace+spec%3Aenclave-network&type=code

[proxy] v0.1.110.96 | ALLOW registry.npmjs.org (cached, 2.1MB)
  @trace https://github.com/8007342/tillandsias/search?q=%40trace+spec%3Aproxy-container&type=code

[proxy] v0.1.110.96 | DENY evil-exfil.example.com (not in allowlist)
  @trace https://github.com/8007342/tillandsias/search?q=%40trace+spec%3Aproxy-container&type=code
```

@trace spec:runtime-logging, spec:enclave-network, spec:proxy-container

## Domain Allowlist

The proxy enforces a curated domain allowlist via squid ACLs. Requests to unlisted domains are denied with a clear error. The allowlist is built into the proxy image and is not user-configurable in Phase 1.

Reference: `images/proxy/allowlist.txt`

| Category | Example domains | Why allowed |
|----------|----------------|-------------|
| Package registries | `registry.npmjs.org`, `crates.io`, `pypi.org`, `rubygems.org` | Package installation |
| CDNs | `cdn.jsdelivr.net`, `unpkg.com`, `cdnjs.cloudflare.com` | Frontend dependencies |
| Cloud SDKs | `*.amazonaws.com`, `*.googleapis.com`, `*.azure.com` | Cloud development |
| VCS | `github.com`, `gitlab.com`, `bitbucket.org` | Source code fetch (read-only via proxy) |
| Docs | `docs.rs`, `doc.rust-lang.org`, `developer.mozilla.org` | Documentation access |
| AI/ML | `ollama.com`, `huggingface.co`, `*.openai.com`, `api.anthropic.com` | Model downloads, API access |
| Security | `nvd.nist.gov`, `osv.dev`, `cve.org` | Vulnerability databases |

Denied requests appear in `--log-proxy` with the blocked domain. Power users can inspect denies and request additions. Per-project allowlist customization is planned for a future settings page.

@trace spec:proxy-container

## CLI Commands

```bash
# Watch proxy requests (allow/deny, cache hits, domains)
tillandsias --log-proxy

# Watch enclave lifecycle (network, container attach/detach)
tillandsias --log-enclave

# Watch both simultaneously
tillandsias --log-proxy --log-enclave

# Detailed proxy tracing (includes request sizes, timing)
tillandsias --log=proxy:trace

# Detailed enclave tracing (includes health check intervals)
tillandsias --log=enclave:trace

# All enclave-related telemetry at once
tillandsias --log-proxy --log-enclave --log-secret-management

# Purge proxy cache (force re-download of all packages)
tillandsias --clean
```

@trace spec:runtime-logging

## Security Model

### Defense in depth

| Layer | Mechanism | What it prevents |
|-------|-----------|------------------|
| **Network isolation** | `podman network create --internal` | Forge cannot reach internet directly |
| **Egress firewall** | Squid domain allowlist | Proxy blocks unlisted domains |
| **Credential isolation** | D-Bus to host keyring (git service only) | Tokens never enter forge containers (Phase 3+) |
| **Capability drop** | `--cap-drop=ALL` on every container | No privilege escalation |
| **No new privileges** | `--security-opt=no-new-privileges` | No setuid/setgid exploitation |
| **User namespace** | `--userns=keep-id` | Container user matches host user (no root) |
| **Ephemeral containers** | `--rm` on every container | No persistent state leakage |
| **Agent deny list** | OpenCode `opencode.json` | AI agent cannot read `/run/secrets/` |

### Per-container security posture

| Container | External network | Credentials | Attack surface |
|-----------|-----------------|-------------|----------------|
| **forge** | ZERO (enclave only, Phase 3+) | ZERO (Phase 3+) | Largest — runs user code and AI agents |
| **proxy** | Yes (dual-homed, allowlist only) | None | Medium — squid attack surface, but no credentials |
| **git** | ZERO (enclave only) | D-Bus to host keyring | Small — only handles git protocol |
| **inference** | ZERO (enclave only) | None | Small — ollama API, local models only |

### Threat model summary

The enclave architecture addresses three primary threats:

1. **AI agent exfiltration** — An agent inside forge cannot reach the internet directly. The proxy allowlist blocks unknown domains. Even if an agent crafts an HTTP request, it can only reach allowlisted package registries and docs sites.

2. **Credential theft** — In Phase 3+, forge containers have ZERO credentials. The git service holds tokens but has no external network access. An attacker must compromise both the git service AND the proxy to exfiltrate a token — and the proxy only allows specific domains.

3. **Supply chain poisoning** — The proxy caches packages, making repeated installs fast and reducing exposure to registry compromises. Cache integrity is verified by package managers (npm, cargo, pip) via their own checksums.

**What is NOT protected:**
- If the host is compromised, the attacker has access to everything (keyring, D-Bus, podman socket).
- The proxy allowlist is generous by design — a determined attacker could encode data in DNS queries or HTTP headers to an allowed domain.
- Phase 1-2 are transitional: forge still has direct network and/or credentials until Phase 3.

@trace spec:enclave-network, spec:proxy-container

## Related

**Specs:**
- `openspec/changes/enclave-proxy-network/` — Phase 1 design, specs, and tasks
- `openspec/changes/enclave-proxy-network/specs/enclave-network/spec.md` — Network isolation requirements
- `openspec/changes/enclave-proxy-network/specs/podman-orchestration/spec.md` — Container security flags

**Source files:**
- `src-tauri/src/launch.rs` — Container launch with enclave network attachment
- `src-tauri/src/handlers.rs` — Proxy lifecycle management
- `src-tauri/src/cli.rs` — `--log-proxy` and `--log-enclave` flags
- `crates/tillandsias-core/src/container_profile.rs` — Proxy and forge profiles
- `crates/tillandsias-podman/` — Network create/inspect/remove

**Cheatsheets:**
- `docs/cheatsheets/secret-management.md` — Token lifecycle and credential delivery
- `docs/cheatsheets/token-rotation.md` — Fine-grained PAT refresh schedule
- `docs/cheatsheets/logging-levels.md` — Full logging system reference
