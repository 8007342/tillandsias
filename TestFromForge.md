# TestFromForge.md — Container Diagnosis

**Generated**: 2026-07-11T07:30Z
**From**: OpenCode agent running inside the Tillandsias forge container

## Container Identity

| Field | Value |
|-------|-------|
| Hostname | `forge-tillandsias` |
| Container engine | Podman (OCI) on overlay |
| Base image | Fedora 44 (Container Image) |
| Kernel | 7.1.3-200.fc44.x86_64 |
| User | `forge` (uid=1000) |
| SELinux context | `container_file_t:s0:c1022,c1023` |

## Resources

| Resource | Value |
|----------|-------|
| CPU | 20 cores |
| RAM | 62 Gi total, 54 Gi available |
| Swap | 8 Gi (unused) |
| Disk (/) | 952 Gi total, 666 Gi used, 284 Gi free (71%) |
| /tmp | 256 Mi tmpfs (16% used) |

## Toolchain

| Tool | Version |
|------|---------|
| Bash | 5.3.9 |
| Git | 2.55.0 |
| Node.js | 22.22.0 |
| Rust/Cargo | 1.96.1 |
| Go | 1.26.5 |
| Python | 3.14.6 |
| Java (OpenJDK) | 25.0.3 |
| Dart | 10.33.0 |
| Flutter | 10.9.7 |
| pnpm | 10.9.7 |
| npm | 10.9.7 |
| uv | 0.11.26 |

## Network

- **HTTPS proxy**: `http://proxy:3128` (all outbound traffic routed through cache proxy)
- **NO_PROXY**: localhost, vault, inference, proxy, git-service, tillandsias-git, 10.0.42.0/24
- **CA trust**: custom combined CA at `/tmp/tillandsias-combined-ca.crt` injected into `SSL_CERT_FILE` and `NODE_EXTRA_CA_CERTS`

## Internal Services

| Service | Address | Notes |
|---------|---------|-------|
| Git mirror | `git://tillandsias-git/tillandsias` | Transparent push/fetch |
| Inference (Ollama) | `http://inference:11434` | May still be warming up |
| Vault | `http://vault:8200` | Token auto-injected |

## Project State

- **Project**: `tillandsias`
- **Branch**: `linux-next`
- **Version**: `0.3.260711.1`
- **Latest commit**: `eb470b19 chore(version): VERSION bump 0.3.260711.1 + trace dashboard regeneration`
- **Working tree**: clean (modulo this file)

## Key Environment Variables

- `TILLANDSIAS_HOST_KIND=forge` — this is a forge (not a dev laptop)
- `TILLANDSIAS_PROJECT_CACHE=/home/forge/.cache/tillandsias-project` — volume-mounted host cache
- `TILLANDSIAS_SHARED_CACHE=/nix/store` — Nix store mounted from host
- `CARGO_TARGET_DIR` / `GOMODCACHE` / `PIP_CACHE_DIR` etc. — all point into the project cache volume for host-side reuse

## Diagnosis Summary

Container is **healthy and fully provisioned**. All expected toolchain versions are present. Network egress is proxied with local services bypassed. Git operations route through the internal mirror transparently. Disk is at 71% but with 284 Gi free — no immediate pressure. Memory is abundant at 54 Gi available. The forge is ready for build, test, and orchestration work.
