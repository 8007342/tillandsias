# spec: wsl-runtime

## Status

active

**Version:** v1.0

**Purpose:** Define the runtime environment and configuration for Tillandsias containers running on Windows WSL2, ensuring seamless Windows/Linux interoperability.

<!-- @trace spec:wsl-runtime -->

## Requirements

### Requirement 1: WSL distribution prerequisites
<!-- req-id: d00b41cb -->
**Modality:** MUST

Tillandsias containers on WSL2 MUST run in a Linux distribution with:
1. systemd enabled (WSL2 20H2+, configured in `/etc/wsl.conf`): `[boot] systemd=true`
2. podman installed (podman ≥ 4.0 for rootless networking support)
3. `/mnt/c` is NOT reachable from the `tillandsias` distro. AMENDED
   2026-11-02 (1410-ugvw follow-up; measured on yoga, live Windows guest,
   relayed by macuahuitl-fedora): the tray writes `[automount] enabled=false`
   (`crates/tillandsias-vm-layer/src/wsl.rs:739-749`), so `/mnt/c` exists as an
   EMPTY directory with nothing mounted on it. The workspace reaches the distro
   through the explicit `/home/forge/src` share (Requirement 3 and
   `cheatsheets/runtime/wsl2-provisioning.md`), never through drvfs. The
   pre-amendment text ("`/mnt/c/Users/<USER>/...` accessible") described the
   WSL default, not what Tillandsias provisions.
4. Windows interop ENABLED but off `$PATH`: `[interop] enabled=true` and
   `appendWindowsPath=false` (`wsl.rs:743-745`; measured on yoga 2026-11-02:
   `/proc/sys/fs/binfmt_misc/WSLInterop` reports `enabled`). Windows binaries
   are runnable via interop by a process holding a path to the `.exe`
   (`wsl.exe`, `wslpath`, the tray's `wsl.exe --exec` round-trips), but are NOT
   on the Linux `$PATH`: `which cmd.exe` fails. This is what makes
   `WSL_INTEROP_ENABLED=true` in Requirement 4.2 truthful.
5. Network connectivity (WSL automatic host gateway at `172.17.0.1`)

**Measurable:** `systemctl --version` returns version info (systemd present); `podman --version` returns ≥4.0; `ls -A /mnt/c` prints NOTHING (directory exists, empty) and `mount | grep ' /mnt/c '` matches nothing; `cat /proc/sys/fs/binfmt_misc/WSLInterop` prints `enabled`; `which cmd.exe` exits non-zero; `cat /etc/wsl.conf` contains exactly `[boot] systemd=true`, `[interop] enabled=true`, `appendWindowsPath=false`, `[automount] enabled=false` (plus `[user] default=forge` on the `provision` path); `ping 172.17.0.1` succeeds from WSL container.

**Scenario:** Fresh WSL2 distribution installation. Verify systemd is enabled, podman is installed, `/mnt/c` is empty, and Windows interop answers through binfmt while `cmd.exe` is not on `$PATH`.

**Design note / drift risk (2026-11-02):** the `/etc/wsl.conf` template is
written TWICE in `crates/tillandsias-vm-layer/src/wsl.rs` — at `739-749`
(recipe-materialized distro, post-import wiring) and at `864-877`
(`VmRuntime::provision`, which also adds `[user] default=forge`). Two copies
of one heredoc drift: a knob added to one path and not the other changes what
this requirement measures depending on which provisioning path ran. Tracked
as a p3 dedupe packet in the ledger (closure: ONE writer, a named cargo test
in `tillandsias-vm-layer` asserting both paths emit the same keys).

---

### Requirement 2: Container networking on WSL
<!-- req-id: 186c6b60 -->
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
<!-- req-id: 1af2e988 -->
**Modality:** MUST

Tillandsias workspace (e.g., `C:\Users\<USER>\src\tillandsias`) MUST:
1. Be bind-mounted into containers at `/workspace` (read-only for cache; read-write for project directories)
2. Use mount type `type=bind` with `--bind-propagation=rslave` to avoid mount storms
3. Include correct ownership: mounted with `--userns=keep-id` to preserve user UID/GID
4. Support both WSL paths (`/mnt/c/Users/...`) and Windows paths (via WSL interop). NOTE 2026-11-02: in the `tillandsias` distro `/mnt/c` is empty (Requirement 1.3), so the `/mnt/c/...` form only resolves where drvfs is mounted (e.g. the `tillandsias-build` distro); the runtime distro's workspace path is `/home/forge/src/...`.

**Measurable:** `podman inspect <container> | jq '.Mounts[]'` shows workspace mount; files are readable/writable with correct user ownership; `stat /workspace` shows correct UID/GID.

**Scenario:** Mount the Tillandsias workspace into a container. Verify files are owned by the correct user (not root). Edit a file in the container and verify the change persists on the Windows host.

---

### Requirement 4: Environment variable inheritance
<!-- req-id: 128bae13 -->
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
<!-- req-id: 9d559142 -->
**Modality:** SHOULD

Containers SHOULD support automatic Windows ↔ Linux path translation:
1. Input: Windows path `C:\Users\bullo\src\project` SHOULD be translated to `/mnt/c/Users/bullo/src/project` inside container (the drvfs form; reachable only where `[automount]` is on — NOT in the `tillandsias` runtime distro, per Requirement 1.3)
2. Output: Linux path `/workspace/project` SHOULD be mountable to Windows host without manual translation
3. SHOULD NOT use hardcoded drive letters (use environment variables or symlinks instead)

**Measurable:** Container receives Windows paths as arguments; they are correctly mounted; symlinks inside container resolve to Windows paths correctly.

**Scenario:** Pass a Windows path to a container as an argument. Verify the container interprets it as a valid Linux path and can access the files.

---

### Requirement 6: Port forwarding to Windows host
<!-- req-id: 4092a906 -->
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
<!-- req-id: aa16c8cc -->
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
<!-- req-id: f0a5da2d -->
**Modality:** MUST

The host tray and WSL daemon MUST communicate asynchronously via:
1. Unix socket at `/run/user/1000/tillandsias/router.sock` (or Windows equivalent)
2. Non-blocking reads/writes (async I/O, MUST NOT use polling)
3. Protocol: JSON request-response over the socket
4. Timeout: 10 seconds for any single operation (prevents hangs)

**Measurable:** Socket communication completes within 10 seconds; no polling loops in code; events are logged with microsecond timestamps; concurrent requests don't block each other.

**Scenario:** Multiple projects try to launch simultaneously from the tray. Verify the router handles requests without blocking and emits distinct event IDs for each request.

---

### Requirement 9: Tillandsias owns its WSL configuration and its block of `.wslconfig`
<!-- req-id: 99436bac -->
**Modality:** MUST

Added 2026-09-27 (order 1437-8c6p; operator directive: "store there our
.wslconfig, .podmanconfigs, etc, and have them all always explicitly use our
config over the system defaults"). WSL reads exactly one global file,
`%USERPROFILE%\.wslconfig`, and one per-distro file, `/etc/wsl.conf` inside
the distro; neither can be pointed elsewhere. Ownership therefore means:

1. The canonical Tillandsias WSL settings (swap, swapFile, sparseVhd,
   autoMemoryReclaim, and any later key) MUST live in ONE Tillandsias-owned
   file under the Tillandsias config directory,
   `%USERPROFILE%\.tillandsias\config\wslconfig.toml` (`TILLANDSIAS_HOME/config`,
   per `host-state-lifecycle`; AMENDED 2026-09-27, 1438-pk9j, from the
   `%LOCALAPPDATA%` path the 1437-8c6p text named), which is operator data
   and survives both the SOFT and the HARD reset.
2. The installer and the tray MUST merge those settings into
   `%USERPROFILE%\.wslconfig` inside a marked block
   (`# >>> tillandsias >>>` … `# <<< tillandsias <<<`), idempotently: a second
   run changes nothing; a changed canonical value updates the block and only
   the block. `Get-WslConfigMerge` is the merge and stays pure. A key the user
   set outside the block MUST NOT be rewritten, EXCEPT a value that breaks a
   hard requirement (below).
   AMENDED 2026-10-12 (order 1560-uam3; operator: "HyperV and SWAP should not
   be prompts, our install should add them forcibly as they're hard
   requirements ... as well as the custom wsl.config file with progressive
   memory reap setting that we shouyd ensure is present in user's runtime, at
   least for our own VM"). The consent prompt (`TILLANDSIAS_WSLCONFIG=apply` or
   the interactive `[y/N]`) is REMOVED. The swap and memory-reclaim keys are
   hard requirements and MUST be ensured without asking, by the installer and
   again by the tray at startup: an absent key is added; a present value that
   breaks a requirement (swap below the 8 GB floor, including `swap=0`;
   `sparseVhd` other than `true`; `autoMemoryReclaim` other than `gradual`) is
   replaced, with the file backed up first and the change recorded in the
   install or tray log, not on screen. `memory` and `processors` stay the
   user's. The keys take effect at the next start of WSL's ONE shared utility
   VM: `.wslconfig` is global, so "our VM" is that shared VM, and swap and
   memory reclaim have no per-distro equivalent. `wsl --shutdown` MUST NOT be
   forced while any other distro is running; it is allowed only when the
   `tillandsias` distro is the sole running one.
3. `/etc/wsl.conf` inside the `tillandsias` distro MUST be provisioned by
   Tillandsias from its own template on every provision (`[boot] systemd=true`
   and whatever Requirement 1 needs), never inherited from the rootfs image's
   default.
4. Uninstall MUST remove the marked block from `%USERPROFILE%\.wslconfig` and
   leave every other line byte-identical; it MUST NOT delete the file.

**Measurable:** `scripts/lua/test-installer-merges-wslconfig-swap-keys.lua` (ported from the
.sh by 1560-uam3, which added the hard-requirement arms) gains
arms: (a) two merges are idempotent (second output equals first); (b) a user
key outside the block survives a merge with a changed canonical value; (c) the
un-merge removes exactly the block. Pre-fix result: (a) passes, (b) and (c)
FAIL — there is no marked block and no un-merge; `-Purge` leaves the keys it
added.

**Scenario:** A user with their own `memory=8GB` line runs the installer
twice, then uninstalls. Verify the swap keys were added once inside the block,
`memory=8GB` never moved, and after uninstall the file holds only
`memory=8GB` and the `[wsl2]` header.

---

### Requirement 10: Windows tray launches a detached forge through `wsl.exe` by translating the podman launch profile
<!-- req-id: 7c3e9a1d -->
**Modality:** MUST

Added 2026-11-02 (order 1410-ugvw). The Windows tray's detached forge launch
(`crates/tillandsias-podman/src/client.rs`, `run_container_wsl_detached`) was
traced to a spec name that never existed; the behaviour it implements belongs
here. On a Windows host the orchestration layer builds ONE podman-shaped
argument vector (`podman-orchestration` detached web profile) and the WSL arm
MUST translate it rather than require a second launch profile:

1. The image reference MUST become the distro name (`image:tag` → `image`),
   and `--entrypoint <path>` MUST become the `wsl.exe --exec` target.
2. Every `-e K=V` MUST reach the process unchanged (an `env K=V` prefix is
   acceptable); `--name` MUST be returned as the launch identifier.
3. `-p` publish specs MUST NOT be passed to `wsl.exe`; the HOST port of the
   first spec (`HOST:CONT`, `IP:HOST:CONT`, with optional `/proto`, lower
   bound of a range) MUST be extracted and handed to the entrypoint as
   `OC_EXPOSED_PORT`, because WSL2 forwards `localhost` binds to the Windows
   host and there is no podman to publish them (Requirement 6 covers the
   podman arm).
4. Mounts, `--userns`, `--cap-drop`, `--rm`, `--tmpfs` and every other
   podman-only flag MUST be dropped, never forwarded: `wsl.exe` rejects
   unknown flags and the host filesystem is already visible per Requirement 3.
5. The spawned process MUST outlive the call: `wsl.exe` is started with stdin
   closed and stdout/stderr redirected to `/tmp/forge-detached.log` inside
   the distro, and the function returns once the spawn succeeds.

**Measurable:** `parse_host_port_from_publish("127.0.0.1:4096:4096")` returns
`Some(4096)`; `("3000-3019:3000-3019/tcp")` returns `Some(3000)`; a malformed
spec returns `None`. On a Windows host, `podman inspect` is never invoked for
a detached launch and the returned identifier equals the `--name` argument.

**Scenario:** WHEN the Windows tray launches OpenCode Web with the detached
profile (`--name forge-x -e OPENCODE_PORT=4096 -p 127.0.0.1:4096:4096
--entrypoint /opt/entrypoint.sh forge:latest`), THEN the tray invokes
`wsl.exe --distribution forge --exec env OPENCODE_PORT=4096
OC_EXPOSED_PORT=4096 /opt/entrypoint.sh`, returns `forge-x` immediately, and
the service is reachable from Windows at `127.0.0.1:4096` while the tray
continues to serve clicks.

---

## Invariants

1. **WSL distribution is always configured**: systemd is enabled before any Tillandsias component runs.
2. **Workspace is always mounted**: Containers always have access to the project workspace; no mounting errors are silent.
3. **Secrets never leak to containers**: Credentials are injected via secure mechanisms; no plaintext secrets in environment.
4. **Port mappings are always explicit**: No implicit port forwarding; all exposed ports are documented and intentional.

## Litmus Tests

Bind to tests in `openspec/litmus-bindings.yaml`:
- `litmus:wsl-runtime-shape`

Gating points:
- The WSL runtime stub remains explicit in source
- The `wsl-runtime` trace annotation still exists on the runtime implementation
- Falsifiable: missing trace or stub marker fails the source-shape check

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

- `cheatsheets/runtime/wsl2-isolation-boundary.md` — the measured `/etc/wsl.conf` (automount off, interop on, appendWindowsPath off) and its writer `crates/tillandsias-vm-layer/src/wsl.rs:739-749`
- `cheatsheets/runtime/wsl-daemon-patterns.md` — WSL boot config, systemd integration, daemon patterns
- `cheatsheets/runtime/podman.md` — Podman on WSL, networking, secret mount, port forwarding
- `cheatsheets/runtime/unix-socket-ipc.md` — Socket communication, non-blocking I/O, protocol design

---

## Implementation References

- **Container launch**: `crates/tillandsias-podman/src/lib.rs` → container spawn with WSL env vars
- **Workspace mount**: `images/forge/Containerfile` → VOLUME and ENV directives
- **Port forwarding**: `src-tauri/src/podman.rs` → port binding logic
- **Socket communication**: `src-tauri/src/wsl_router.rs` → async socket handling
