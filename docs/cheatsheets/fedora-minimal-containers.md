---
tags: [fedora, fedora-minimal, containers, microdnf, rpm, packages]
languages: []
since: 2026-04-26
last_verified: 2026-04-27
sources:
  - https://github.com/rpm-software-management/microdnf
authority: high
status: current
---

# Fedora Minimal Container Cheatsheet

@trace spec:default-image, spec:inference-container

## Provenance

- https://github.com/rpm-software-management/microdnf — upstream source repository for microdnf; confirms it is "a minimal dnf for (mostly) Docker containers that uses libdnf and hence doesn't require Python," written in C, GPL-2.0. Fetched 2026-04-27.
- **Last updated:** 2026-04-27

**Note on Fedora release notes URL:** `https://docs.fedoraproject.org/en-US/fedora/latest/release-notes/` returned an Anubis bot-protection page (no content accessible). The microdnf GitHub repo above is the authoritative source for package manager behavior.

Quick reference for Fedora Minimal (fedora-minimal:44) behavior in Tillandsias containers. Minimal images use microdnf, have ~120 packages (vs ~400 standard), and lack many tools you might assume exist.

## Package Manager

| Tool | Available? | Notes |
|------|-----------|-------|
| `microdnf` | Yes | Default in fedora-minimal |
| `dnf` / `dnf5` | No | Not installed; `microdnf` is the replacement |
| `dnf5 config-manager` | No | Requires plugin: `dnf5 install 'dnf5-command(config-manager)'` |
| `rpm` | Yes | Low-level package management |

```sh
# Install packages
microdnf install -y bash curl ca-certificates && microdnf clean all

# DO NOT use dnf -- it's not in fedora-minimal
dnf install -y foo    # command not found
```

## Our Fedora Minimal Images

| Image | Base | Key Packages | Entrypoint | Shell |
|-------|------|-------------|------------|-------|
| tillandsias-forge | fedora-minimal:44 | bash, git, gh, nodejs, npm, curl, wget, fish, ripgrep, ... | entrypoint-forge-*.sh | bash |
| tillandsias-inference | fedora-minimal:44 | bash, curl, pciutils (NOT wget) | entrypoint.sh | bash |

## Health Checks (Rust -> Container)

The Rust app runs health checks via `podman exec`. Tool availability depends on what each Containerfile installs.

| Container | Has curl? | Has wget? | Health check uses |
|-----------|-----------|-----------|-------------------|
| Forge | Yes | Yes | (no health check) |
| Inference | Yes | **No** | `curl -sf -o /dev/null` |

## Common Pitfalls

### 1. ollama installer + dnf5 config-manager

The ollama install script tries to add the NVIDIA repo via `dnf5 config-manager`, which is a plugin not present in fedora-minimal. The installer exits non-zero but ollama installs successfully.

```dockerfile
# The || true is REQUIRED -- installer fails on dnf5 config-manager
RUN curl -fsSL https://ollama.com/install.sh | sh || true
RUN test -x /usr/local/bin/ollama || { echo "ERROR: ollama not found"; exit 1; }
```

### 2. wget is NOT in fedora-minimal base

Unlike the standard Fedora image, fedora-minimal does not include wget. If you need HTTP probes:

```sh
# Inference container: use curl (installed)
curl -sf -o /dev/null http://localhost:11434/api/version

# DO NOT assume wget exists
wget --spider http://localhost:11434    # command not found (unless explicitly installed)
```

### 3. CA certificate paths (Fedora)

```sh
# System CA bundle
/etc/pki/tls/certs/ca-bundle.crt

# Drop custom CAs here
/etc/pki/ca-trust/source/anchors/

# Rebuild trust store
update-ca-trust

# NOTE: update-ca-trust requires root -- fails under --cap-drop=ALL
# Production approach: concatenate system bundle + custom CA into /tmp
```

### 4. User management (Fedora)

```sh
# Fedora uses shadow-utils
useradd -u 1000 -m -s /bin/bash forge

# NOT Alpine's adduser
adduser -D -u 1000 forge    # wrong syntax on Fedora
```

### 5. Missing tools in fedora-minimal

These common tools are NOT in fedora-minimal and must be explicitly installed:

| Tool | Package |
|------|---------|
| `wget` | `wget` |
| `git` | `git` |
| `vim` | `vim-minimal` |
| `make` | `make` |
| `gcc` | `gcc` |
| `ps` | `procps-ng` |
| `find` | `findutils` |
| `xargs` | `findutils` |
| `tar` | `tar` |
| `jq` | `jq` |

### 6. GPU detection in containers

The ollama install script uses `lspci` to detect GPUs. Install `pciutils` in the Containerfile:

```dockerfile
RUN microdnf install -y pciutils  # provides lspci
```

At runtime, GPU devices are passed through via podman flags:
```sh
--device=/dev/nvidia0
--device=/dev/nvidiactl
--device=/dev/nvidia-uvm
```

### 7. Signal handling

Same as Alpine: use `exec` for foreground processes so they receive SIGTERM as PID 1. The inference entrypoint starts ollama in background for model pre-pull, then waits:

```sh
ollama serve &
OLLAMA_PID=$!
# ... pre-pull models ...
wait $OLLAMA_PID    # ollama becomes the foreground concern
```

## Cross-Distro Comparison

| Feature | Alpine | Fedora Minimal |
|---------|--------|---------------|
| Default shell | busybox ash | bash |
| Package manager | `apk add --no-cache` | `microdnf install -y` + `microdnf clean all` |
| CA bundle path | `/etc/ssl/certs/ca-certificates.crt` | `/etc/pki/tls/certs/ca-bundle.crt` |
| CA trust command | `update-ca-certificates` | `update-ca-trust` |
| CA drop-in dir | `/usr/local/share/ca-certificates/` | `/etc/pki/ca-trust/source/anchors/` |
| User creation | `adduser -D -u UID` | `useradd -u UID -m` |
| HTTP client | `wget` (busybox) | `curl` (if installed) |
| Init system | None | None (no systemd in minimal) |
| Image size | ~7MB base | ~100MB base |
| libc | musl | glibc |
