---
tags: [podman, containers, runtime, events]
languages: [bash, rust]
since: 2026-05-12
last_verified: 2026-05-12
sources:
  - https://docs.podman.io/en/stable/
  - https://www.redhat.com/en/blog/rootless-podman
  - https://github.com/opencontainers/runtime-spec
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: false
---
# Podman Idiomatic Patterns

**Use when**: Building container orchestration logic, integrating container events, optimizing performance, securing container deployments

## Provenance

- [Podman Official Documentation](https://docs.podman.io/) — authoritative reference
- [Red Hat Enterprise Container Security](https://www.redhat.com/en/blog/rootless-podman) — production hardening
- [OCI Runtime Specification](https://github.com/opencontainers/runtime-spec) — container standards
- [Linux Capabilities Manual (man7)](https://man7.org/linux/man-pages/man7/capabilities.7.html) — security primitives
- [Podman Events Documentation](https://docs.podman.io/en/stable/markdown/podman-events.1.html) — event streaming
- **Last updated**: 2026-05-12

@trace spec:podman-orchestration

---

## Event Streaming (Non-Polling)

### ❌ DON'T: Poll containers in a loop

```bash
# Bad: CPU wakes every 5 seconds, wastes energy, adds latency
while true; do
  podman ps --format='{{.ID}}:{{.Status}}'
  sleep 5
done
```

```rust
// Bad Rust equivalent
loop {
    let containers = client.list_containers().await?;
    // process containers...
    tokio::time::sleep(Duration::from_secs(5)).await;
}
```

### ✅ DO: Subscribe to events (real-time)

```bash
# Good: Wakes only when container state changes
podman events --format=json --filter type=container --filter status=start,stop,die
```

**Output structure**:
```json
{
  "Type": "container",
  "Status": "start",
  "Name": "tillandsias-my-project-forge",
  "ID": "abc123def456",
  "Time": "2026-05-12T14:23:45.123Z",
  "TimeNano": 1715517825123000000,
  "Attributes": {
    "name": "tillandsias-my-project-forge",
    "image": "tillandsias-forge:v0.1.169"
  }
}
```

**Rust implementation**:
```rust
pub async fn watch_enclave_events(enclave_name: &str) {
    let client = PodmanClient::new();
    
    let mut event_stream = client.events(
        &EventFilter {
            types: vec!["container".into()],
            filters: vec![
                ("label".into(), format!("tillandsias-enclave={}", enclave_name)),
            ],
        }
    ).await.expect("failed to subscribe");
    
    while let Some(event) = event_stream.next().await {
        match event {
            Event::Container { status, name, .. } => {
                match status.as_str() {
                    "start" => println!("✓ {} started", name),
                    "stop" => println!("○ {} stopped", name),
                    "die" => println!("✗ {} died", name),
                    _ => {}
                }
            }
        }
    }
}
```

### Why: Industry Standard
- **Kubernetes CRI**: Uses event-driven architecture, not polling
- **systemd**: Event loop model (sd-event) is standard
- **Docker**: Supports `docker events`, same pattern
- **Podman**: Native `podman events` backed by journald or file-based
- **Performance**: CPU wakes only on state change (ms latency), not fixed intervals
- **Scalability**: Constant O(1) overhead vs O(N) for polling N containers

---

## Security Flags (Always Required)

### Minimum Hardening (Non-Negotiable)

```bash
podman run \
  --cap-drop=ALL                              \
  --security-opt=no-new-privileges            \
  --userns=keep-id                            \
  --rm                                        \
  IMAGE COMMAND
```

| Flag | Purpose | Impact |
|------|---------|--------|
| `--cap-drop=ALL` | Drop all Linux capabilities (default: 14) | Container cannot use privileged syscalls |
| `--security-opt=no-new-privileges` | Prevent privilege escalation via setuid/setgid | Even if container binary is setuid, won't escalate |
| `--userns=keep-id` | Map container root → invoking user | Container UID 0 = host UID $USER, not host root |
| `--rm` | Auto-remove container on exit | No filesystem leftovers; ephemeral by design |

### Additional Hardening (Scenario-Dependent)

```bash
# SELinux label isolation (Linux only)
podman run --security-opt=label=disable ...

# Custom seccomp profile (restrict syscalls)
podman run --security-opt=seccomp=unconfined ...  # DO NOT use in production

# Read-only root filesystem
podman run --read-only ...

# Resource limits
podman run --memory=512m --cpus=1 ...

# Drop unused capabilities
podman run --cap-drop=NET_RAW --cap-drop=NET_ADMIN ...
```

### Why: Threat Model
- **Capability 0**: Even if container breaks out, attacker has unprivileged user access, not root
- **SELinux**: Kernel-level mandatory access control (MAC)
- **Seccomp**: Whitelist dangerous syscalls (execve, ptrace, etc)
- **No-new-privileges**: Blocks setuid tricks
- **Rootless mode**: No setuid binaries needed in host; even daemon breakout is unprivileged

### Verification
```bash
# Check applied capabilities
podman inspect CONTAINER | jq '.HostConfig.CapAdd, .HostConfig.CapDrop'

# Confirm rootless execution
podman run --userns=keep-id --rm alpine id
# Output: uid=1000(user) gid=1000(user) groups=1000(user)
# ✓ Correct: container uid 1000 = host invoking user
```

---

## Storage Isolation (Enclave Model)

### One Enclave Per Project

```bash
# Define per-project storage roots
export TILLANDSIAS_PODMAN_GRAPHROOT="/var/cache/tillandsias/my-project/graphroot"
export TILLANDSIAS_PODMAN_RUNROOT="/var/cache/tillandsias/my-project/runroot"
export TILLANDSIAS_PODMAN_RUNTIME_DIR="/tmp/tillandsias/my-project/runtime"

# All podman commands within this session use isolated storage
podman run --name=proxy ...
podman run --name=forge ...
podman network create tillandsias-my-project-enclave
```

### Why: Isolation
- **Zero cross-project contamination**: Project A's images/containers never visible to Project B
- **Clean teardown**: `rm -rf /var/cache/tillandsias/my-project/` removes everything
- **Parallel enclaves**: Run multiple projects simultaneously without interference
- **Test isolation**: CI/CD can spin up fully isolated enclaves per test

### Storage Structure
```
/var/cache/tillandsias/
├── my-project/
│   ├── graphroot/           # Image layers, container RO layers
│   │   └── overlay-images/  # COW filesystem structure
│   ├── runroot/             # Container RW layers, metadata
│   │   └── containers/      # Per-container state
│   └── runtime/             # Ephemeral sockets, PIDs, logs
├── other-project/           # Separate enclave
│   ├── graphroot/
│   ├── runroot/
│   └── runtime/
└── shared/                  # Nix cache, shared deps (RO)
```

### Cleanup
```bash
# On enclave shutdown
podman network rm tillandsias-my-project-enclave  # Delete network
rm -rf /var/cache/tillandsias/my-project/         # Delete all storage
```

---

## Secrets (Ephemeral-First Architecture)

### ❌ DON'T: Embed in image or env vars

```dockerfile
# Bad: Secret baked into image
RUN echo "my-token" > /app/.env
ENV GITHUB_TOKEN="secret123"
```

```bash
# Bad: Secret in env var (visible in ps, logs)
podman run -e GITHUB_TOKEN="secret123" IMAGE
# ps output: SECRET VISIBLE!
# logs: might accidentally log env vars
```

### ✅ DO: Ephemeral file mounts

```bash
# Create secret at startup (from keyring or env)
echo "my-github-token" | podman secret create tillandsias-github-token -

# Launch container with secret mounted
podman run \
  --secret tillandsias-github-token \
  --name=forge \
  IMAGE

# Inside container: read from file
# cat /run/secrets/tillandsias-github-token

# Cleanup on shutdown (critical!)
podman secret rm tillandsias-github-token
```

### Implementation Pattern
```rust
// Startup: Create secrets from host OS keyring
pub async fn setup_secrets(
    keyring: &LinuxSecretService,
    config: &Config,
) -> Result<Vec<String>> {
    let mut secret_names = Vec::new();
    
    // GitHub token from keyring
    if let Ok(token) = keyring.get("github-token") {
        podman_secret_create("tillandsias-github-token", token).await?;
        secret_names.push("tillandsias-github-token".to_string());
    }
    
    // CA certificate for HTTPS proxy
    if let Ok(cert) = keyring.get("ca-cert") {
        podman_secret_create("tillandsias-ca-cert", cert).await?;
        secret_names.push("tillandsias-ca-cert".to_string());
    }
    
    Ok(secret_names)
}

// Mount in container
pub async fn launch_forge_with_secrets(
    config: &Config,
    secrets: &[String],
) -> Result<String> {
    let mut args = vec!["run", "--rm", "-d"];
    
    for secret in secrets {
        args.push("--secret");
        args.push(secret);
    }
    
    args.push(config.image.as_str());
    podman(args).await
}

// Shutdown: Cleanup all secrets
pub async fn cleanup_secrets(secret_names: &[String]) -> Result<()> {
    for name in secret_names {
        podman(&["secret", "rm", name]).await.ok(); // Ignore errors
    }
    Ok(())
}
```

### Why: Security
- **Not in logs**: File mount doesn't appear in ps/logs
- **Not in images**: `podman commit` and `podman export` exclude /run/secrets/
- **Namespace-isolated**: Secret mounted in forge container, NOT in proxy/git/inference containers
- **Ephemeral**: Secret lifespan = container lifespan; no persistent disk storage
- **Automatic cleanup**: Podman removes mount point on container exit

### Verification
```bash
# Check secret is mounted
podman run --secret my-secret --rm alpine ls -la /run/secrets/
# ✓ Should show: my-secret

# Confirm it's NOT visible in ps
podman run --secret my-secret -d alpine sleep 100
ps aux | grep -i secret
# ✓ Should NOT show secret value in output

# Confirm it's NOT in logs
podman logs CONTAINER_ID
# ✓ Should NOT contain secret text
```

---

## Error Handling and Retry Logic

### Common Exit Codes

| Code | Meaning | Action |
|------|---------|--------|
| `0` | Success | Proceed |
| `125` | Podman error (invalid flags) | Don't retry; configuration error |
| `126` | Command cannot execute | Don't retry; permission/binary issue |
| `127` | Command not found | Don't retry; missing dependency |
| `> 128` | Process killed by signal (128 + sig#) | May be transient; retry with backoff |
| Custom (1-127) | Application exit code | Depends on app |

### Categorize Errors for Retry Strategy

```rust
pub enum PodmanError {
    // Transient — RETRY with exponential backoff
    NetworkUnreachable,
    TemporaryFailure { message: String },
    Timeout,
    
    // Not found — DO NOT retry
    ImageNotFound { image: String },
    ContainerNotFound { container: String },
    NetworkNotFound { network: String },
    
    // Configuration — DO NOT retry
    InvalidConfig { reason: String },
    PermissionDenied { detail: String },
    
    // Unknown — LOG and propagate
    Unknown { message: String },
}

impl PodmanError {
    pub fn is_transient(&self) -> bool {
        matches!(self,
            PodmanError::NetworkUnreachable |
            PodmanError::TemporaryFailure { .. } |
            PodmanError::Timeout
        )
    }
    
    pub fn is_not_found(&self) -> bool {
        matches!(self,
            PodmanError::ImageNotFound { .. } |
            PodmanError::ContainerNotFound { .. } |
            PodmanError::NetworkNotFound { .. }
        )
    }
}
```

### Retry with Exponential Backoff

```rust
pub async fn launch_with_backoff(
    client: &PodmanClient,
    spec: &ContainerSpec,
    max_retries: usize,
) -> Result<String> {
    let mut backoff = Duration::from_millis(100);
    
    for attempt in 1..=max_retries {
        match client.launch(spec).await {
            Ok(id) => {
                info!(attempt, "Container launched: {}", id);
                return Ok(id);
            },
            
            Err(e) if e.is_transient() => {
                warn!(
                    attempt,
                    backoff_ms = backoff.as_millis(),
                    error = ?e,
                    "Transient error, retrying..."
                );
                tokio::time::sleep(backoff).await;
                backoff = (backoff * 2).min(Duration::from_secs(30));
            },
            
            Err(e) if e.is_not_found() => {
                error!(attempt, error = ?e, "Image/container not found, aborting");
                return Err(e);
            },
            
            Err(e) => {
                error!(attempt, error = ?e, "Unrecoverable error");
                return Err(e);
            }
        }
    }
    
    Err(PodmanError::TemporaryFailure {
        message: format!("Failed after {} retries", max_retries)
    })
}
```

### Why: Production Resilience
- **Network hiccups**: Transient DNS failures, temporary socket closures
- **Resource contention**: Temporary I/O saturation
- **Don't retry permanent errors**: Saves time, prevents retry storms
- **Exponential backoff**: Prevents thundering herd (all clients retry at same time)

---

## Networking (Enclave Model)

### Create Isolated Network Per Enclave

```bash
# Network for my-project enclave
podman network create tillandsias-my-project-enclave

# Launch containers on that network
podman run \
  --network=tillandsias-my-project-enclave \
  --name=proxy \
  IMAGE

podman run \
  --network=tillandsias-my-project-enclave \
  --name=forge \
  IMAGE

# Containers on same network can DNS-resolve each other
podman run --rm --network=tillandsias-my-project-enclave \
  alpine ping -c1 proxy
# ✓ Works: DNS resolves 'proxy' to other container's IP
```

### Network Properties (Default)

```
Network: tillandsias-my-project-enclave
├── Driver: bridge (default)
├── Subnet: 10.89.0.0/16 (auto-assigned)
├── Containers:
│   ├── proxy     (10.89.0.2)
│   ├── git       (10.89.0.3)
│   ├── forge     (10.89.0.4)
│   └── inference (10.89.0.5)
│
└── Properties:
    ├── Internal DNS: enabled (containers resolve by name)
    ├── Firewall: isolated from other networks
    ├── Host access: via docker-host gateway (10.89.0.1)
    └── External access: only via port mappings (-p)
```

### Port Mappings (External Access)

```bash
# Expose proxy to host on port 3128
podman run \
  --network=tillandsias-my-project-enclave \
  --publish=3128:3128 \
  --name=proxy \
  IMAGE

# From host: curl localhost:3128/health
# From other containers: curl http://proxy:3128/health
```

### Cleanup

```bash
# Remove all containers on network
podman ps --filter network=tillandsias-my-project-enclave --format='{{.ID}}' | xargs podman stop

# Remove network
podman network rm tillandsias-my-project-enclave
```

---

## Rootless Mode (Best Practice)

### Linux: Works Out-of-the-Box

```bash
# No special setup required
podman ps

# Verify rootless
podman run --rm alpine whoami
# Output: root (but namespace-mapped to your UID)

podman run --userns=keep-id --rm alpine whoami
# Output: your username (explicit keep-id mapping)
```

### Verify Rootless Execution

```bash
# Check if podman daemon is rootless
podman info | grep "Rootless"
# ✓ Should show: "Rootless": true

# Verify socket is in user namespace
ls -la $XDG_RUNTIME_DIR/podman/podman.sock
# ✓ Should be readable by your user only
```

### macOS/Windows: Requires Setup

```bash
# Create lightweight Linux VM
podman machine init

# Start the machine
podman machine start

# Verify connection
podman ps
# ✓ Should show empty list (ready to use)

# Destroy when done
podman machine stop
podman machine rm
```

### Key Property: Unprivileged Breakout

```bash
# Even if container escapes, attacker is unprivileged
podman run --cap-drop=ALL --userns=keep-id --rm alpine

# Inside container (hypothetical escape):
id
# Output: uid=1000 gid=1000 (maps to your UID, not root)

# Damage is limited to $HOME, not /etc, /root, /sys
```

---

## GPU Passthrough (Linux Only, Optional)

### Detect Available GPUs

```bash
lspci | grep -i nvidia
# 01:00.0 VGA compatible controller: NVIDIA Corporation ...

nvidia-smi
# +-----------------------------------------------------------------------------+
# | NVIDIA-SMI 550.54.14                Driver Version: 550.54.14               |
# | GPU  Name                 Persistence-M | Bus-Id        Disp.A | Volatile |
# | 0    NVIDIA RTX 4090                On   | 00:1D.0       Off   |    0%   |
# +-----------------------------------------------------------------------------+
```

### Mount GPUs into Container

```bash
podman run \
  --device=/dev/nvidia0 \
  --device=/dev/nvidia1 \
  --device=/dev/nvidiactl \
  --device=/dev/nvidia-modeset \
  --device=/dev/nvidia-uvm \
  --device=/dev/nvidia-uvm-tools \
  --device=/dev/nvidia-caps/manage \
  --cap-add=SYS_PTRACE \
  IMAGE cuda-app
```

### Verify GPU Inside Container

```bash
# Run container with GPU
podman run --device=/dev/nvidia0 --device=/dev/nvidiactl --rm nvidia/cuda:12.0 nvidia-smi

# ✓ Should show GPU information
# If it fails, check driver/kernel compatibility
```

### Why Only Linux
- **macOS**: GPU is part of unified memory pool; no direct /dev/nvidia access
- **Windows**: WSL 2 GPU support in progress (2026), currently limited

---

## Logging and Observability

### Container Logs

```bash
# Stream logs (tail -f equivalent)
podman logs -f CONTAINER_NAME

# Get last N lines
podman logs --tail=100 CONTAINER_NAME

# Show timestamps
podman logs -t CONTAINER_NAME

# Follow with timestamps
podman logs -f -t CONTAINER_NAME
```

### Structured Logging (journald)

```bash
# Launch container with journald logging
podman run --log-driver=journald --name=forge IMAGE

# Query logs from host
journalctl CONTAINER_ID=<id> -f

# Query by container name
journalctl CONTAINER_NAME=forge -f

# Combined: container + kernel logs
journalctl --boot -f
```

### Container Inspection

```bash
# Full JSON state
podman inspect CONTAINER_ID | jq '.State'

# Specific fields
podman inspect CONTAINER_ID --format='{{.State.Status}}'
podman inspect CONTAINER_ID --format='{{.State.ExitCode}}'

# All running containers' IPs on a network
podman inspect -l --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'
```

---

## Common Error Patterns and Fixes

| Error | Cause | Fix |
|-------|-------|-----|
| `Error: image not found` | Image doesn't exist in storage | `podman pull IMAGE:TAG` first, or check image name |
| `Error: network not found` | Network doesn't exist | `podman network create NETWORK_NAME` |
| `Error: name already in use` | Container name taken | Use `--replace` to overwrite, or use unique names |
| `Error: access denied` | Mounted volume permission issue | Check file ownership, use `:z` label (SELinux relabel) |
| `Error: operation timed out` | Network slow or container hung | Increase timeout, check network connectivity |
| `Error: ENOENT` | Config file doesn't exist | Verify file path, check if secret/volume exists |
| `Error: 137` | Container killed (OOMKilled) | Increase `--memory` limit |
| `Error: 143` | Container terminated by SIGTERM | Graceful shutdown; check timeout settings |

---

## Performance Tips

### Avoid Repeated Pulls

```bash
# Pre-pull images before launching
podman pull IMAGE:TAG

# Then launch (fast)
podman run IMAGE:TAG
```

### Use Volume Mounts Instead of Copy

```bash
# ❌ Slow: Copy large files into container
COPY /huge/project /app
RUN build...

# ✅ Fast: Mount from host
podman run -v /huge/project:/app IMAGE build
```

### Layer Caching (Buildah)

```bash
# Build with layer caching
buildah build-using-dockerfile --layers Dockerfile

# Layers are cached; rebuilds are fast
```

### Keep Containers Small

```dockerfile
# Multi-stage build
FROM rust:latest AS builder
RUN cargo build --release
FROM alpine:latest
COPY --from=builder /app/target/release/myapp /app/myapp
CMD ["/app/myapp"]
```

---

## References

- `@trace spec:podman-orchestration` — Tillandsias implementation
- `@trace spec:security-privacy-isolation` — Security hardening
- `@trace spec:enclave-network` — Network isolation
- `@trace spec:container-state-machine` — Lifecycle management

**See also**:
- `research/IDIOMATIC_PODMAN.md` — Full architecture research report
- `docs/cheatsheets/README.md` — Index of all cheatsheets
