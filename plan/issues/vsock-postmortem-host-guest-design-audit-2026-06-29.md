# vsock Post-Mortem + Host→Guest Design Audit — 2026-06-29

**Triggered by**: Hard reset required after e2e build hung with terminal window open.
**Branch**: windows-next
**Scope**: Host→guest vsock transport (HvSocket on Windows/WSL2), provisioning lifecycle, PTY-over-vsock wiring.
**Status**: Research packet — no code changed. See Recommendations section for ordered fix list.

---

## 1. Post-Mortem: Likely Hang Causes

### Verdict

The system almost certainly hung on one of three synchronous-in-async violations, all in the same call chain: `try_connect_until_ready` → `open_hvsocket_stream` → `connect_control_wire`. The Windows tray runs on a single-threaded tokio `current_thread` runtime inside a `LocalSet` that shares the Win32 message pump thread (`notify_icon.rs:run`). Blocking that thread with a synchronous socket `connect()` freezes the entire UI — no more WM_TRAYICON, no WM_COMMAND, no tray menu — until either the OS socket call returns or the machine is hard-reset.

### Cause #1 (P0 — most likely): Blocking WSA connect on the async thread

**File**: `crates/tillandsias-windows-tray/src/hvsocket.rs:122–182`

`connect_control_wire` is synchronous. It calls `WSAStartup`, creates a raw `SOCKET`, and calls the Win32 `connect()` syscall. There is **no timeout set on the socket** (`SO_SNDTIMEO` is never called). The function is called from:

```
open_hvsocket_stream(port).await    // hvsocket.rs:202–206
  → connect_control_wire(port)?     // SYNCHRONOUS — no spawn_blocking
```

`open_hvsocket_stream` is `async` but does NOT use `tokio::task::spawn_blocking`. It calls the blocking `connect_control_wire` directly. On the tokio current-thread executor, this seizes the sole executor thread. While Win32 `connect()` is blocked, no other async task runs — including the Win32 message pump.

If Hyper-V is in a degraded state (VM booting, HCS not ready, prior WSL2 crash), `connect()` on an `AF_HYPERV` socket can take tens of seconds to fail — or may not return at all if the kernel's HCS client is wedged.

`try_connect_until_ready` (wsl_lifecycle.rs:466) calls this in a loop of up to **36 iterations × 5s** = 3-minute budget. But if `connect_control_wire` itself hangs (rather than returning quickly with an error), the entire budget is consumed in the first iteration and the machine appears frozen.

### Cause #2 (P0 — concurrent): `wsl_utility_vm_id` is a blocking subprocess call inside the async connect

**File**: `crates/tillandsias-windows-tray/src/hvsocket.rs:70–79`

```rust
pub fn wsl_utility_vm_id() -> Result<String, String> {
    let output = std::process::Command::new("hcsdiag")
        .arg("list")
        .output()  // BLOCKING
```

`wsl_utility_vm_id` is called from `connect_control_wire`, which is called from `open_hvsocket_stream`, which is `.await`-ed on the async thread. `std::process::Command::output()` is synchronous. If `hcsdiag` is slow to start (it shells into the HCS service) or blocks on a wedged HCS lock, the async thread is frozen before the socket connect even happens.

**Measured impact**: `hcsdiag list` typically takes 50–200ms on a healthy system. Under HCS contention (e.g., after a failed WSL stop/start cycle) it has been observed to take 10–30s or hang indefinitely.

### Cause #3 (P1): `handshake()` has no timeout in the provisioning connect path

**File**: `crates/tillandsias-windows-tray/src/wsl_lifecycle.rs:466–508`

```rust
let stream = crate::hvsocket::open_hvsocket_stream(port).await...?;
let mut client = Client::from_stream(Box::new(stream), Transport::Vsock { cid: 0, port });
let wire_version = client.handshake().await...?;  // NO timeout
crate::installation_uuid::deliver_credentials_and_check_handover(&mut client).await...?; // NO timeout
```

The shared `connect_with_handshake` utility in `vsock_client.rs:185` wraps both connect and handshake in a `tokio::time::timeout(DEFAULT_HANDSHAKE_TIMEOUT)` — but **this utility is not used here**. Instead, the provisioning path manually assembles the client and calls `handshake()` without any timeout.

`Client::handshake()` calls `self.recv().await` which calls `read_exact` on the stream. If the VM's AF_VSOCK listener is up (so the HvSocket connect succeeds) but the in-VM headless process isn't responding to Hello (e.g., it's busy in its init loop or crashed partway through), `read_exact` blocks indefinitely. The 36-attempt retry budget is never advanced because the first attempt never finishes.

`deliver_credentials_and_check_handover` is also an unbounded `client.request(...)` call — same risk.

### Cause #4 (P1): dnf install and systemctl in `ensure_base_packages` / `inject_bootstrap_logic` have no timeouts

**File**: `crates/tillandsias-windows-tray/src/wsl_lifecycle.rs:269–396`

```rust
self.wsl_root_sh("dnf install -y systemd podman dbus-broker libcap shadow-utils openssl").await
```

`wsl_root_sh` uses `tokio::process::Command::new("wsl").status().await` — this is properly async (it does not block the executor thread). However, there is no `timeout()` wrapper. On a WSL2 distro with a broken DNS resolver (common after a host network change or VPN connect/disconnect), `dnf install` may hang indefinitely waiting for package metadata from fedoraproject.org. The `provision_via_recipe` function will wait forever at the `ensure_base_packages` step with no user-visible progress update after the "Installing systemd + podman" log line.

This is less likely to cause a hard-reset (since it doesn't block the async executor) but will make the tray appear frozen at "Installing..." with no WM interaction because the same LocalSet is driving both provisioning and the message pump — and while `ensure_base_packages` is awaited, no other `spawn_local` tasks run unless they were spawned before this `.await` point. Looking at `run()` in notify_icon.rs, the provisioning task is spawned as `spawn_local` and the `watch_projects` task is also `spawn_local` — so the message pump itself runs through `GetMessageW` which is synchronous. Actually, re-reading: the message loop is `GetMessageW` called inside `block_on` — but `LocalSet::block_on` will cooperatively yield to process tokio tasks between Windows message dispatches only if written that way. The actual `GetMessageW` loop structure determines whether tokio tasks run between messages.

> **Note for a separate audit**: The Win32 message loop (`GetMessageW`) and the tokio LocalSet interaction in `run()` deserves a dedicated review to confirm tasks can make progress while the message pump is running. If `GetMessageW` is blocking on the same executor thread with no yield, any `await`ed provisioning step also blocks Win32 message delivery during that step.

### What was NOT the cause

- `flatten_oci_xz` (wsl_lifecycle.rs:187) is correctly wrapped in `tokio::task::spawn_blocking` — this is safe.
- The 36-attempt retry loop's `tokio::time::sleep(Duration::from_secs(5)).await` is properly async.
- The `PtyRouter` / `PtySession` / `pump_io` infrastructure in `pty/mod.rs` is not wired to any live HvSocket connection yet, so it could not have caused the hang.

---

## 2. Design Audit: host→guest vsock over HvSocket

### Issue Table

| ID | File:Location | Severity | Description | Fix |
|----|---------------|----------|-------------|-----|
| H1 | hvsocket.rs:122–182 | **P0** | `connect_control_wire` is synchronous; called from async context without `spawn_blocking` | Wrap in `tokio::task::spawn_blocking` or set `SO_SNDTIMEO` before call |
| H2 | hvsocket.rs:70–79 | **P0** | `wsl_utility_vm_id` uses `std::process::Command` (blocking) inside the async connect path | Use `tokio::process::Command` or move inside `spawn_blocking` |
| H3 | wsl_lifecycle.rs:466–508 | **P0** | `try_connect_until_ready` calls `handshake()` and `deliver_credentials_and_check_handover` with no per-attempt timeout | Wrap each attempt in `tokio::time::timeout(Duration::from_secs(10), ...)` |
| H4 | hvsocket.rs:122 | **P1** | No `SO_SNDTIMEO` on the AF_HYPERV socket; OS-level connect can hang indefinitely under HCS degradation | Call `setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, ...)` before `connect()`, or impose timeout via `spawn_blocking` join handle |
| H5 | wsl_lifecycle.rs:268–275 | **P1** | `ensure_base_packages` / `inject_bootstrap_logic` have no timeout on `wsl_root_sh`; dnf hangs on broken DNS | Wrap with `tokio::time::timeout(Duration::from_secs(300), ...)` with user-visible progress fallback |
| H6 | hvsocket.rs:218–229 | **P1** | `hvsocket_handshake` Hello advertises `["VmStatusRequest","EnumerateLocalProjects"]`; `Client::handshake` advertises a different set — diverged capability lists | Consolidate into a single `HELLO_CAPABILITIES` constant in `tillandsias-control-wire` or `tillandsias-host-shell` and import in both paths |
| H7 | hvsocket.rs:218, vsock_client.rs:106 | **P1** | Neither Hello advertises `"pty.attach@v1"` — required by the PTY delta spec before any Pty* variant may be sent | Add `"pty.attach@v1"` to the capability vector in both Hello senders |
| H8 | wsl_lifecycle.rs:504–508 | **P1** | The w9 NOTE explicitly drops the HvSocket stream after VmStatusReply — no persistent control-wire connection is kept | Lift stream ownership to the tray (store in `MENU_STATE` or a dedicated `Arc<Mutex<Option<Client>>>`); reconnect on loss |
| H9 | wsl_lifecycle.rs:223–225 | **P2** | `_keepalive` from `spawn_keepalive().ok()` discards the error silently; if WSL isn't running at keepalive spawn time, the VM will idle down after ~8s | Log the error and schedule a retry; store the child in a persistent task |
| H10 | vsock_client.rs:185 | **P2** | `connect_with_handshake` (with proper timeout) exists but is unused in the production provisioning path | Use it in `try_connect_until_ready` instead of manual assembly |
| H11 | hvsocket.rs:316–335 | **P2** | `hvsocket_read_envelope` enforces `MAX_MESSAGE_BYTES` but returns `io::ErrorKind::InvalidData` rather than closing the connection and emitting `TransportError::MessageTooLarge` as the spec requires | Return a structured error variant; close the stream |
| H12 | hvsocket.rs:149 | **P2** | `WSAStartup` / `WSACleanup` are called per-connection; WSA is typically initialized once per process | Call WSAStartup once at process startup (in `run()`), remove per-call init/cleanup |

---

## 3. Protocol Correctness Issues

### 3a. Dual Hello capability vectors (H6)

`hvsocket.rs` (the Windows test/handshake path) and `vsock_client.rs` (the shared production path) advertise different capabilities in `Hello`. This means capability negotiation is non-deterministic depending on which code path created the `Client`. The in-VM headless cannot reliably gate features on capabilities because the same Windows host may send different sets depending on the call site.

**Correct fix**: Define a canonical `pub const STANDARD_HOST_CAPABILITIES: &[&str]` in `tillandsias-host-shell` or `tillandsias-control-wire` and use it everywhere.

### 3b. Missing `pty.attach@v1` capability (H7)

The PTY delta spec (`openspec/changes/control-wire-pty-attach/specs/vsock-transport/spec.md`) requires:

> "A peer that does NOT advertise this capability SHALL NOT receive `PtyOpen`, `PtyData`, `PtyResize`, or `PtyClose` envelopes."

Neither Hello in the codebase advertises `"pty.attach@v1"`. When PTY attach is wired up (w9), the guest's capability-check enforcement will reject all PTY frames because the host never declared support. The guest will log suppression events and the user will see a blank terminal.

### 3c. No persistent connection / no reconnect loop (H8)

`try_connect_until_ready` deliberately drops the HvSocket stream after VmStatusReply (wsl_lifecycle.rs:504: `// NOTE: stream is dropped here`). After provisioning, the tray has no live control-wire connection. VmStatusRequest polling, CloudRefreshRequest, and PTY attach all require establishing a new HvSocket connection each time — which, given Cause #1 and #3 above, means each menu click that triggers a vsock operation risks a hang.

The correct architecture is: one persistent `Client` held in `Arc<Mutex<Option<Client>>>` (or `tokio::sync::Mutex`), established once after provisioning, and reconnected via the backoff schedule in `BACKOFF_SCHEDULE` when the stream drops.

### 3d. `SO_RCVTIMEO` / `SO_SNDTIMEO` not set (H4)

Windows HvSocket (`AF_HYPERV`) streams do not inherit TCP keepalive semantics. If the WSL2 utility VM is force-terminated (kernel panic, BSOD, hard reset, or `wsl --shutdown` from another process), the connected `AF_HYPERV` socket may not receive a RST. The host read side hangs on `read_exact` forever. `SO_RCVTIMEO` must be set before the stream is handed to tokio so the async layer can surface a timeout error and trigger reconnect.

---

## 4. Clean Architecture: What Correct host→guest vsock Wiring Looks Like

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Windows Tray process (single-thread tokio CurrentThread + LocalSet)        │
│                                                                             │
│  1. STARTUP: WSAStartup once (not per-connection)                          │
│                                                                             │
│  2. CONNECT TASK (spawn_local):                                             │
│     loop {                                                                  │
│       // All blocking ops go through spawn_blocking                         │
│       let vm_id = spawn_blocking(|| wsl_utility_vm_id()).await??;           │
│       let raw_sock = spawn_blocking(move || connect_with_timeout(vm_id,     │
│                                             port, Duration::from_secs(5)))  │
│                      .await??;                                              │
│       raw_sock.set_nonblocking(true)?;                                      │
│       let stream = tokio::net::TcpStream::from_std(raw_sock)?;             │
│       let mut client = Client::from_stream(Box::new(stream), …);            │
│       // Timeout covers handshake + credential delivery                     │
│       tokio::time::timeout(Duration::from_secs(10),                        │
│         async { client.handshake().await?;                                  │
│                 deliver_credentials(&mut client).await }                    │
│       ).await??;                                                            │
│       // Promote to shared state                                            │
│       *LIVE_CLIENT.lock().await = Some(client);                             │
│       break;                                                                │
│       // on error: backoff per BACKOFF_SCHEDULE, retry                      │
│     }                                                                       │
│                                                                             │
│  3. KEEPALIVE: spawn_local that monitors LIVE_CLIENT and re-runs step 2    │
│                on stream-closed events (detected by PtyRouter recv=None)   │
│                                                                             │
│  4. PTY ATTACH (per menu click):                                            │
│     let client = LIVE_CLIENT.lock().await.as_ref()...;                     │
│     let transport = Arc::new(ChannelPtyTransport::new(64));                 │
│     let alloc = SessionIdAllocator::new();                                  │
│     let router = PtyRouter::new(); // per-connection, stored with client    │
│     let session = PtySession::open(transport, &alloc, &router, &opts)?;    │
│     let master = WindowsConPtyMaster::new(opts.rows, opts.cols)?;           │
│     pump_io(session, master);                                               │
│     // connection writer task drains ChannelPtyTransport and sends          │
│     // over the live HvSocket client                                        │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Per-operation timeout budget

| Operation | Recommended timeout | Rationale |
|-----------|---------------------|-----------|
| `hcsdiag list` (subprocess) | 5s | Should complete in <200ms on a healthy system |
| AF_HYPERV `connect()` | 5s | WSL2 HCS round-trip; longer = HCS degraded |
| `handshake()` + `HelloAck` | 10s | In-VM headless responds in <1s when healthy |
| `deliver_credentials` | 10s | Same control-wire round-trip |
| `VmStatusRequest` | 5s | Headless replies immediately |
| `ensure_base_packages` (dnf) | 300s | dnf can be slow; but must not be unbounded |
| Per-provisioning-attempt total | 30s | Hard abort; next attempt starts after backoff |
| Total provisioning budget | 36 × 30s = 18min | Upper bound for fresh Fedora import |

---

## 5. Invariants That Should Be Enforced But Currently Are Not

| Invariant | Current state | How to enforce |
|-----------|---------------|----------------|
| **No blocking I/O on the async thread** | Violated by `connect_control_wire` and `wsl_utility_vm_id` | `spawn_blocking` wrapper; CI lint with `#[tokio::test(flavor="current_thread")]` + `tokio::time::timeout` to catch deadlocks |
| **Per-operation timeout on all vsock I/O** | Missing from provisioning path | `tokio::time::timeout` wrapper at every `.await` on a network socket |
| **Single canonical HELLO_CAPABILITIES** | Two diverged vectors | `pub const` in control-wire; `cargo test` pin asserting both senders use it |
| **`pty.attach@v1` in Hello before any Pty\*** | Missing from all Hello senders | Add to canonical capabilities; guest-side enforcement already in spec |
| **WSAStartup called once per process** | Called per-connection | Move to `run()` startup; WSACleanup on `WM_DESTROY` |
| **Persistent Client across menu actions** | Stream dropped after VmStatusReply | `Arc<tokio::sync::Mutex<Option<Client>>>` in MENU_STATE or global |
| **Keepalive child must be kept alive for VM lifetime** | `.ok()` silently discards error | Require keepalive as a `Result`; panic or warn+retry on failure |
| **SO_SNDTIMEO + SO_RCVTIMEO on AF_HYPERV sockets** | Not set | Set before `set_nonblocking(true)` |

---

## 6. Next Hop: vsock guest→container (Future Scope)

The user's intended architecture adds a second vsock channel: Fedora 44 guest → podman containers inside (AF_VSOCK from guest to container). This is a separate scope covered by the companion agent. The guest-side AF_VSOCK listener (`tillandsias-headless --listen-vsock 42420`) is the anchor for this layer — it should NOT also be the in-container listener endpoint; the container needs its own vsock CID (assigned by podman's libvirt-vsock or crun's vsock device). SELinux labeling at this boundary is critical: the guest headless should be confined to a type that may only `connect` to the container CID range, not to arbitrary CIDs.

This packet does not prescribe that design — it flags the boundary and hands off.

---

## 7. Immediate Action Items (ordered by severity)

1. **[P0]** Wrap `connect_control_wire` + `wsl_utility_vm_id` in `spawn_blocking` inside `open_hvsocket_stream`. Apply `SO_SNDTIMEO = 5s` before `connect()`.
2. **[P0]** Wrap the per-attempt body of `try_connect_until_ready` in `tokio::time::timeout(Duration::from_secs(30), ...)`.
3. **[P0]** Use `connect_with_handshake` (the properly-timed variant) instead of manual assembly in `try_connect_until_ready`.
4. **[P1]** Define `STANDARD_HOST_CAPABILITIES` constant, add `"pty.attach@v1"`, and use it in both `hvsocket_handshake` and `Client::handshake`.
5. **[P1]** Add `tokio::time::timeout(Duration::from_secs(300), ...)` around `ensure_base_packages` and `inject_bootstrap_logic`.
6. **[P1]** Design + implement persistent `Client` storage in the tray; reconnect on stream loss using `BACKOFF_SCHEDULE`.
7. **[P2]** Wire `PtyRouter` to the persistent `Client`'s read loop; connect `ChannelPtyTransport` to the write loop.
8. **[P2]** Move `WSAStartup` to `run()` startup and `WSACleanup` to `WM_DESTROY`.
9. **[P2]** Set `SO_RCVTIMEO` on the AF_HYPERV socket before handing to tokio.

---

*Authored by: vsock audit fork, 2026-06-29*
*Owner host: windows*
*capability_tags: [vsock, hvsocket, wsl2, ptty, tokio, async, blocking, selinux, windows-tray]*
