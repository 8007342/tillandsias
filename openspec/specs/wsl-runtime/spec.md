# spec: wsl-runtime

## Status: active

**Version:** v1.0

**Purpose:** Define the runtime environment and configuration for Tillandsias containers running on Windows WSL2, ensuring seamless Windows/Linux interoperability.

<!-- @trace spec:wsl-runtime -->

## Requirements

### Requirement 1: WSL distribution prerequisites
**Modality:** MUST

Tillandsias containers on WSL2 MUST run in a Linux distribution with:
1. systemd enabled (WSL2 20H2+, configured in `/etc/wsl.conf`): `[boot] systemd=true`
2. podman installed (podman ≥ 4.0 for rootless networking support)
3. Ability to bind Windows mount points (via `mount.wslg` or WSL interop): `/mnt/c/Users/<USER>/...` accessible
4. Network connectivity (WSL automatic host gateway at `172.17.0.1`)

**Measurable:** `systemctl --version` returns version info (systemd present); `podman --version` returns ≥4.0; `ls /mnt/c` shows Windows C: drive; `ping 172.17.0.1` succeeds from WSL container.

**Scenario:** Fresh WSL2 distribution installation. Verify systemd is enabled, podman is installed, and Windows interop is working.

---

### Requirement 2: Container networking on WSL
**Modality:** MUST

Containers launched in WSL MUST:
1. Use podman's default network (bridge mode) that auto-creates `/etc/hosts` entries
2. Resolve Windows host DNS queries (WSL passes `nameserver 127.0.0.11` in container /etc/resolv.conf)
3. Access Windows host services at `host.docker.internal` (WSL automatic alias to gateway IP)
4. MUST NOT require special `--userns=host` flags; MUST use `--userns=keep-id` for security

**Measurable:** `podman run alpine cat /etc/resolv.conf` shows WSL resolver; `podman run alpine ping -c 1 host.docker.internal` succeeds; container DNS resolves external domains; containers get unique IPs (`ip addr` shows `172.17.x.x` range).

**Scenario:** Launch a container, verify it can ping the Windows host and reach external DNS. Verify other containers get unique IP addresses.

---

### Requirement 3: Workspace mount strategy
**Modality:** MUST

Tillandsias workspace (e.g., `C:\Users\<USER>\src\tillandsias`) MUST:
1. Be bind-mounted into containers at `/workspace` (read-only for cache; read-write for project directories)
2. Use mount type `type=bind` with `--bind-propagation=rslave` to avoid mount storms
3. Include correct ownership: mounted with `--userns=keep-id` to preserve user UID/GID
4. Support both WSL paths (`/mnt/c/Users/...`) and Windows paths (via WSL interop)

**Measurable:** `podman inspect <container> | jq '.Mounts[]'` shows workspace mount; files are readable/writable with correct user ownership; `stat /workspace` shows correct UID/GID.

**Scenario:** Mount the Tillandsias workspace into a container. Verify files are owned by the correct user (not root). Edit a file in the container and verify the change persists on the Windows host.

---

### Requirement 4: Environment variable inheritance
**Modality:** MUST

Containers launched in WSL MUST receive:
1. `WSL_DISTRO_NAME` — current WSL distribution name (e.g., "Fedora")
2. `WSL_INTEROP_ENABLED=true` — indicates Windows interop is available
3. `TILLANDSIAS_WSL_MODE=true` — signals container is running in WSL (not native Linux)
4. `TILLANDSIAS_HOST_GATEWAY=host.docker.internal` — Windows host alias (WSL-specific)

**Measurable:** `podman run -e WSL_DISTRO_NAME=Fedora ... env | grep WSL_` shows environment variables; container can use `$WSL_DISTRO_NAME` in scripts.

**Scenario:** Launch a container with WSL environment variables. Verify the container can detect it's running under WSL and adjust behavior accordingly (e.g., using Windows paths instead of Linux paths).

---

### Requirement 5: File path translation
**Modality:** SHOULD

Containers SHOULD support automatic Windows ↔ Linux path translation:
1. Input: Windows path `C:\Users\bullo\src\project` SHOULD be translated to `/mnt/c/Users/bullo/src/project` inside container
2. Output: Linux path `/workspace/project` SHOULD be mountable to Windows host without manual translation
3. SHOULD NOT use hardcoded drive letters (use environment variables or symlinks instead)

**Measurable:** Container receives Windows paths as arguments; they are correctly mounted; symlinks inside container resolve to Windows paths correctly.

**Scenario:** Pass a Windows path to a container as an argument. Verify the container interprets it as a valid Linux path and can access the files.

---

### Requirement 6: Port forwarding to Windows host
**Modality:** MUST

Containers running services (proxy, inference, etc.) MUST:
1. Expose ports on the WSL gateway IP (172.17.0.1) so Windows host can reach them
2. Use `podman run -p 127.0.0.1:<port>:<port>` to bind to localhost only (security default)
3. OR use `podman run -p 0.0.0.0:<port>:<port>` to expose to Windows host network (for browser access)
4. MUST document which ports are Windows-facing vs. container-only

**Measurable:** `podman port <container>` shows port mappings; Windows host can connect to `127.0.0.1:<port>` (if bound to localhost) or `host.docker.internal:<port>` (if bound to all interfaces); container cannot directly access Windows host ports (security).

**Scenario:** Launch a web server in a container exposing port 8080. From Windows, connect to `127.0.0.1:8080` and verify the service is reachable.

---

### Requirement 7: Credential and secret isolation
**Modality:** MUST

On WSL, secrets MUST NOT leak to containers:
1. GitHub tokens MUST be stored in host OS keyring (`Credential Manager` on Windows, `Secret Service` on Linux)
2. Containers MUST receive secrets only via `podman secret` mount (NOT via environment variables)
3. Custom CA certificates MUST be stored in host keyring OR in encrypted file (NOT in workspace)
4. MUST NOT have plaintext credentials in workspace files or container environment

**Measurable:** `podman inspect <container> | jq '.Config.Env'` shows no tokens; secrets are mounted at `/run/secrets/` only; keyring integration works (verify with credential reads from Python/Rust code).

**Scenario:** Add a GitHub token to the Windows Credential Manager. Verify a container can read the secret via keyring D-Bus bridge (if available on WSL) without having the token in `env` or files.

---

### Requirement 8: Event-driven socket communication
**Modality:** MUST

The host tray and WSL daemon MUST communicate asynchronously via:
1. Unix socket at `/run/user/1000/tillandsias/router.sock` (or Windows equivalent)
2. Non-blocking reads/writes (async I/O, MUST NOT use polling)
3. Protocol: JSON request-response over the socket
4. Timeout: 10 seconds for any single operation (prevents hangs)

**Measurable:** Socket communication completes within 10 seconds; no polling loops in code; events are logged with microsecond timestamps; concurrent requests don't block each other.

**Scenario:** Multiple projects try to launch simultaneously from the tray. Verify the router handles requests without blocking and emits distinct event IDs for each request.

---

## Invariants

1. **WSL distribution is always configured**: systemd is enabled before any Tillandsias component runs.
2. **Workspace is always mounted**: Containers always have access to the project workspace; no mounting errors are silent.
3. **Secrets never leak to containers**: Credentials are injected via secure mechanisms; no plaintext secrets in environment.
4. **Port mappings are always explicit**: No implicit port forwarding; all exposed ports are documented and intentional.

---

## Litmus Tests

### Test 1: WSL distribution has systemd enabled
```bash
# Inside WSL
systemctl --version
# Expected: systemd version number (not error)
```

### Test 2: Container can reach Windows host
```bash
# Inside WSL, launch a container
podman run alpine ping -c 1 host.docker.internal
# Expected: success (responds)
```

### Test 3: Workspace is mounted and writable
```bash
# Inside WSL
podman run -v /workspace:/ws alpine touch /ws/test-file
ls /workspace/test-file  # on host
# Expected: file exists and is owned by current user (not root)
```

### Test 4: Container environment variables are inherited
```bash
# Launch a container with WSL environment variables
podman run -e WSL_DISTRO_NAME=Fedora -e TILLANDSIAS_WSL_MODE=true alpine env | grep WSL_
# Expected: WSL_DISTRO_NAME=Fedora TILLANDSIAS_WSL_MODE=true
```

### Test 5: Service ports are accessible from Windows
```bash
# Inside WSL, launch a web server
podman run -p 8080:8080 alpine httpd -f

# From Windows PowerShell
curl http://127.0.0.1:8080
# Expected: 200 OK (or appropriate response)
```

### Test 6: Secrets are not in environment
```bash
# Create a secret
echo "my-token" | podman secret create tillandsias-secret -

# Launch a container with the secret
podman run --secret tillandsias-secret alpine env | grep -i secret
# Expected: nothing (secret is NOT in env)

# Verify secret is accessible at mount path
podman run --secret tillandsias-secret alpine cat /run/secrets/tillandsias-secret
# Expected: my-token
```

### Test 7: Socket communication is non-blocking
```bash
# Start the WSL router daemon
systemctl start tillandsias-router

# Send multiple concurrent requests to the socket
# (e.g., launch 3 projects simultaneously)
# Verify: all requests complete within 10 seconds
# Verify: no request blocks the others
# Verify: logs show unique event IDs for each request
```

---

## Sources of Truth

- `cheatsheets/runtime/wsl-daemon-patterns.md` — WSL boot config, systemd integration, daemon patterns
- `cheatsheets/runtime/podman.md` — Podman on WSL, networking, secret mount, port forwarding
- `cheatsheets/runtime/unix-socket-ipc.md` — Socket communication, non-blocking I/O, protocol design

---

## Implementation References

- **Container launch**: `crates/tillandsias-podman/src/lib.rs` → container spawn with WSL env vars
- **Workspace mount**: `images/forge/Containerfile` → VOLUME and ENV directives
- **Port forwarding**: `src-tauri/src/podman.rs` → port binding logic
- **Socket communication**: `src-tauri/src/wsl_router.rs` → async socket handling
