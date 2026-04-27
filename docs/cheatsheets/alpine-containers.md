---
tags: [alpine, containers, apk, busybox, musl, shell, packages]
languages: []
since: 2026-04-26
last_verified: 2026-04-27
sources:
  - https://wiki.alpinelinux.org/wiki/Alpine_Linux_package_management
  - https://pkgs.alpinelinux.org/packages
authority: high
status: current
---

# Alpine Container Cheatsheet

@trace spec:proxy-container, spec:git-mirror-service

## Provenance

- https://wiki.alpinelinux.org/wiki/Alpine_Linux_package_management — official Alpine wiki; authoritative reference for apk commands, flags, cache behavior, and WORLD file semantics. Fetched 2026-04-27.
- https://pkgs.alpinelinux.org/packages — official Alpine package search index; confirms available branches (edge, v3.23, v3.22, v3.21, v3.20 …) and repos (main, community, testing). Fetched 2026-04-27.
- **Last updated:** 2026-04-27

Quick reference for Alpine-specific behavior in Tillandsias containers. Alpine uses busybox, musl libc, and apk -- most assumptions from Fedora/Debian break here.

## Shell

Alpine's default shell (`/bin/sh`) is busybox ash, NOT bash.

| Feature | Bash (Fedora) | Busybox ash (Alpine) |
|---------|---------------|----------------------|
| `[[ ]]` | Yes | No -- use `[ ]` with quoting |
| Arrays | `arr=(a b c)` | No -- use positional params |
| `$RANDOM` | Yes | No -- use `$(od -An -N2 -tu2 /dev/urandom \| tr -d ' ')` |
| `/dev/tcp` | Yes | No -- use `nc -z host port` or `wget --spider` |
| `read -p` | Yes | No -- use `printf` then `read` |
| `${var,,}` | Yes | No -- use `$(echo "$var" \| tr A-Z a-z)` |
| `&>` redirect | Yes | No -- use `>/dev/null 2>&1` |
| Here-string `<<<` | Yes | No -- use `echo "$var" \| cmd` |
| `source` | Yes | No -- use `.` (dot) |

**Our Alpine images install bash explicitly** (`apk add bash`), and entrypoints use `#!/bin/bash`. If adding new scripts to Alpine images, either:
1. Use `#!/bin/bash` and ensure bash is in the Containerfile, OR
2. Write POSIX sh and use `#!/bin/sh`

## Available Tools (busybox)

| Need | Use | NOT available by default |
|------|-----|--------------------------|
| TCP probe | `nc -z host port` | bash `/dev/tcp` |
| HTTP check | `wget -q --spider URL` | `curl` (not in base) |
| Process list | `ps` | `ps -ef` (different output format) |
| User creation | `adduser -D -u 1000` | `useradd` (shadow-utils) |
| Group creation | `addgroup -g 1000 name` | `groupadd` |
| Package install | `apk add --no-cache pkg` | `dnf`, `microdnf`, `apt` |
| CA trust update | `update-ca-certificates` | `update-ca-trust` (Fedora) |
| CA trust dir | `/usr/local/share/ca-certificates/` | `/etc/pki/ca-trust/source/anchors/` |
| System CA bundle | `/etc/ssl/certs/ca-certificates.crt` | `/etc/pki/tls/certs/ca-bundle.crt` |
| Service management | Direct exec (no systemd) | `systemctl` |

## Our Alpine Images

| Image | Base | Packages installed | Entrypoint | Shell |
|-------|------|-------------------|------------|-------|
| tillandsias-proxy | alpine:3.20 | squid, openssl, bash, ca-certificates | entrypoint.sh | bash |
| tillandsias-git | alpine:3.20 | git, git-daemon, bash, openssh-client | entrypoint.sh | bash |
| tillandsias-web | alpine:latest | busybox-extras | entrypoint.sh | sh |

## Health Checks (Rust -> Container)

The Rust app (`handlers.rs`) runs health checks via `podman exec`. These must use tools available in the target container.

| Container | Health check tool | Why |
|-----------|-------------------|-----|
| Proxy (Alpine) | `wget -q --spider` | busybox wget, always available |
| Git (Alpine) | `nc -z localhost 9418` | busybox netcat, always available |
| Inference (Fedora) | `curl -sf -o /dev/null` | curl installed, wget is NOT |

## Common Pitfalls

### 1. curl is NOT in Alpine base
Alpine's busybox provides `wget` but NOT `curl`. If you need HTTP in Alpine:
```sh
# YES: busybox wget (always available)
wget -q --spider http://localhost:3128

# NO: curl is not installed
curl -sf http://localhost:3128    # command not found
```

### 2. CA certificate paths differ
```sh
# Alpine
/etc/ssl/certs/ca-certificates.crt          # System CA bundle
/usr/local/share/ca-certificates/           # Drop custom CAs here
update-ca-certificates                       # Rebuild bundle

# Fedora
/etc/pki/tls/certs/ca-bundle.crt            # System CA bundle
/etc/pki/ca-trust/source/anchors/           # Drop custom CAs here
update-ca-trust                              # Rebuild bundle
```

### 3. User management commands differ
```sh
# Alpine
adduser -D -u 1000 -s /sbin/nologin proxy

# Fedora
useradd -u 1000 -m -s /bin/bash forge
```

### 4. Package caching

`apk add --no-cache` skips writing to `/var/cache/apk/`, keeping image layers lean.
`apk cache clean` removes older cached package versions; `apk cache sync` downloads
missing packages and removes stale ones in a single pass (source: Alpine wiki).

```sh
# Alpine: --no-cache prevents /var/cache/apk/ bloat
apk add --no-cache squid openssl

# Fedora Minimal: clean all after install
microdnf install -y bash curl && microdnf clean all
```

### 5. Signal handling
Alpine busybox `sh` handles signals differently. Always use `exec` for PID 1 processes so they receive SIGTERM directly:
```sh
# YES: exec replaces shell, squid is PID 1
exec squid -N

# NO: shell is PID 1, squid won't get signals
squid -N
```

### 6. squid paths
```sh
# Alpine squid
/usr/lib/squid/security_file_certgen    # SSL cert generator
/var/spool/squid/                        # Cache dir
/etc/squid/squid.conf                    # Config

# squid config references Alpine CA path:
# tls_outgoing_options cafile=/etc/ssl/certs/ca-certificates.crt
```
