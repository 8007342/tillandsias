# Observable Streams Contract — All Transport Boundaries

**Filed 2026-06-30 | Status: DRAFT — pending multi-agent ratification**

---

## 1. Principle

> Every transport boundary in Tillandsias MUST expose an observable async stream.
> No component may poll a boundary that could instead push events.
> Overhead at any boundary under any load condition is O(0) in the idle case
> and O(1) per message in the active case, with no constant-rate CPU cost.

"Observable stream" in this codebase means a value that implements
`futures::Stream<Item = Event>` (or its tokio equivalent) and satisfies:

| Property | Requirement |
|----------|-------------|
| Non-blocking | All reads/writes use `AsyncRead`/`AsyncWrite`, never `std::io::{Read,Write}` on async threads |
| Push-not-poll | Producers push on state change; consumers do not query on timers |
| Bounded | Every channel has a fixed capacity; `unbounded_channel()` is forbidden on transport paths |
| Backpressure | A slow consumer slows the producer (never silently drops); `try_send` may only be used at terminal sinks where dropping is explicitly acceptable and documented |
| Composable | Stream adapters (`StreamExt::map`, `StreamExt::filter`, `select!`) are used instead of hand-rolled dispatch loops |
| Zero idle cost | A connection with no events uses zero CPU: no timer wakeups, no sleep loops, no empty polls |

---

## 2. Boundary Inventory

### B1 — Windows Tray ↔ VM Headless (AF_HYPERV / HvSocket)

**Current (WRONG):**
```
loop {
    refresh_vm_status(hwnd).await;   // sends VmStatusRequest, awaits VmStatusReply
    if tick % 10 == 0 {
        refresh_cloud_projects(hwnd).await;
        refresh_github_login(hwnd).await;
    }
    tokio::time::sleep(30s).await;
}
```
Problems: 30s polling, half-duplex request-response, wire oscillation visible to user,
cloud/login only refresh every 5 minutes.

**Required (CORRECT):**
```rust
// One persistent reader task per connection:
let mut stream = live_client.into_stream();       // AsyncRead + AsyncWrite
let (status_tx, status_rx) = watch::channel(VmStatus::Unknown);
let (login_tx, login_rx)   = watch::channel(LoginState::Unknown);
let (cloud_tx, cloud_rx)   = watch::channel(vec![]);

tokio::spawn(async move {
    while let Some(envelope) = stream.next().await {
        match envelope.body {
            ControlMessage::VmStatusPush { .. }       => { let _ = status_tx.send(...); }
            ControlMessage::LoginStatePush { .. }     => { let _ = login_tx.send(...); }
            ControlMessage::CloudProjectsPush { .. }  => { let _ = cloud_tx.send(...); }
            ControlMessage::PtyData { .. }            => pty_router.route(&envelope); }
        }
    }
});

// Menu rebuilds are driven by watch receivers, not by timers:
tokio::spawn(async move {
    loop {
        status_rx.changed().await?;
        update_menu_state(*status_rx.borrow());
    }
});
```

### B2 — macOS Tray ↔ VM Headless (VZ framework / AF_VSOCK)

Same structural requirement as B1. The macOS tray must have an identical
multiplexed reader task — no polling loop for VM status, login, or cloud projects.

### B3 — Linux Native Tray ↔ Headless (local / D-Bus or vsock)

Same requirement. If the Linux tray uses an in-process call rather than vsock,
it must use `tokio::sync::watch` channels driven by the headless's internal event
bus, not periodic in-process function calls.

### B4 — VM Headless Internal: Control Wire Listener

The headless vsock listener currently handles one request then (possibly) closes
the connection. **Required:** persistent bidirectional stream per connected client.
The headless must:
1. Keep the connection open indefinitely after handshake
2. Push `VmStatusPush`, `LoginStatePush`, `CloudProjectsPush` events on internal
   state changes without being asked
3. Handle interleaved `PtyOpen`, `PtyData`, `PtyResize`, `PtyClose` messages on
   the same stream (multiplexed by `session_id`)

### B5 — VM Headless ↔ Podman Containers (Unix socket / vsock-loopback)

Each Podman container (forge, vault, inference, web) that needs to communicate
with the headless must use a persistent async stream, not:
- `podman exec -it` (spawns a process, not a stream)
- HTTP polling to a container's port
- Shell-out commands with `std::process::Command`

Required: AF_UNIX socket per container type, with `tokio::net::UnixStream`,
with framed messages (postcard or length-prefixed), with bounded channels.

### B6 — Vault Token API (within VM)

Vault supports a blocking watch API (`GET /v1/secret/data/KEY?wait=<version>`).
The headless MUST use this instead of polling Vault for token changes.
When a new GitHub token is stored, Vault pushes the update to the headless watcher,
which then sends `LoginStatePush` to all connected host trays.

---

## 3. Protocol Additions Required

The following `ControlMessage` variants MUST be added to `tillandsias-control-wire`:

```rust
// Server-push (headless → host, no request needed):
VmStatusPush {
    seq: u32,
    phase: VmPhase,
    podman_ready: bool,
    last_event: Option<String>,
},
LoginStatePush {
    seq: u32,
    logged_in: bool,
    handle: Option<String>,
},
CloudProjectsPush {
    seq: u32,
    projects: Vec<CloudProjectEntry>,
},

// Subscription (host → headless, sent once after handshake):
Subscribe {
    seq: u32,
    topics: Vec<SubscriptionTopic>,  // [VmStatus, LoginState, CloudProjects]
},
SubscribeAck {
    seq: u32,
    accepted: Vec<SubscriptionTopic>,
},
```

After `Subscribe`, the headless sends the current state immediately (initial push),
then sends updates on change. The host never needs to send `VmStatusRequest` again.

---

## 4. Verification Criteria (machine-checkable)

Each criterion is assigned a code so agents can reference it precisely.

| Code | Criterion | Checked by |
|------|-----------|------------|
| SC-01 | No `tokio::time::sleep` in any async fn that handles socket I/O | grep + manual |
| SC-02 | No `loop { ... sleep ... }` within 20 lines of a socket read/write | grep + manual |
| SC-03 | No `std::io::Read` or `std::io::Write` implemented on types used in async context without `spawn_blocking` wrapping | grep + clippy |
| SC-04 | All `mpsc` and `broadcast` channels have a documented finite capacity | grep `unbounded` must be zero |
| SC-05 | `try_send` usage must be documented as "terminal sink acceptable drop" or must be replaced with `.send().await` | grep + manual |
| SC-06 | The control wire reader is a single long-lived task per connection, not re-created per request | code review |
| SC-07 | `VmStatusRequest` is not sent after the initial subscription handshake | grep + protocol trace |
| SC-08 | The headless vsock listener holds the connection open until client disconnect | integration test |
| SC-09 | The headless sends `VmStatusPush` within 500ms of an internal phase change | integration test |
| SC-10 | A consumer that is 1000ms slow (simulated) does not cause the producer to drop frames | backpressure test |
| SC-11 | CPU usage of a tray with a healthy idle VM is <0.1% over a 5-minute window | perf test |
| SC-12 | No `podman exec` in the data path for PTY or exec operations | grep + code review |
| SC-13 | No `std::process::Command::output()` called from an `async fn` without `spawn_blocking` | grep |
| SC-14 | Vault token changes are observed via blocking-watch HTTP, not via periodic GET | code review |
| SC-15 | All stream error paths propagate backpressure signals to the source | code review |
| SC-16 | No `AtomicBool` + `sleep` used as a signaling primitive; use `tokio::sync::Notify` or `watch::channel` | grep `AtomicBool.*sleep` |
| SC-17 | PTY outbound channels in headless are bounded; `mpsc::unbounded_channel` is forbidden on the PTY data path | grep `unbounded_channel` in pty_handler.rs + vsock_server.rs |
| SC-18 | `PtyRouter::route` must NOT silently drop frames on a full channel; `try_send` + silent `let _ =` = data loss, not backpressure. Must use `.send().await` or return `Err` to caller | code review + test |

---

## 4b. Confirmed Findings (FatOpus Audit — 2026-06-30)

Audit agent survey of 8 files found 14 findings (3 Critical, 8 High, 3 Medium).

| File | Finding | Severity | SC |
|------|---------|----------|----|
| `notify_icon.rs`:1958 | `loop { refresh_vm_status; sleep(30s) }` — entire host-side status pipeline is timer-poll | Critical | SC-01, SC-02, SC-07 |
| `notify_icon.rs`:1554+ | `std::process::Command::output()` called on async thread (wsl/distro sniff) | High | SC-13 |
| `action_host.rs`:1565 | Identical 30s poll loop to Windows tray | Critical | SC-01, SC-02 |
| `vsock_server.rs`:162 | `AtomicBool` + 250ms sleep for shutdown signal | High | SC-16 |
| `vsock_server.rs`:219 | `listener.accept()` wrapped in 250ms timeout to re-check shutdown flag | Medium | SC-16 |
| `vsock_server.rs`:602 | `GetVaultHandover` inline poll: `for _ in 0..8 { sleep(1s); try_get() }` — blocks entire connection | High | SC-02 |
| `vsock_server.rs`:305 | `mpsc::unbounded_channel()` for PTY outbound — no backpressure | High | SC-04, SC-17 |
| `vault_bootstrap.rs`:271 | `std::thread::sleep` inside `rt.block_on()` nested inside async context | **Critical** | SC-03 |
| `vault_bootstrap.rs`:211+ | `std::process::Command::new("openssl")...output()` in async task | High | SC-13 |
| `wsl_lifecycle.rs`:166 | `for attempt in 1..=36 { sleep(5s) }` retry loop — timer-based, no VM signal | High | SC-01, SC-02 |
| `pty_handler.rs`:77 | `PtySessionStore` holds `mpsc::UnboundedSender` for PTY output | High | SC-04, SC-17 |
| `pty/mod.rs`:331 | `let _ = tx.try_send(...)` — **comment says "backpressure" but actual behavior is silent data loss** | High | SC-05, SC-18 |
| `vsock_exec.rs`:197+ | Exec drain loop buffers full stdout in `Vec<u8>` — unbounded latency/memory for large outputs | Medium | SC-10 |
| `pty/mod.rs`:197 | `exec_over_stream` non-streaming variant: first-byte latency = full execution time | Medium | SC-10 |

**Most critical bug**: `PtyRouter::route` (`pty/mod.rs`:331) — the comment explicitly says
"applies backpressure to the guest" but `try_send` on a full channel silently drops the frame.
PTY data loss under load. Must be replaced with `send().await` (making route async) or
an error return that causes the connection reader to stall.

---

## 5. Multi-Agent Verification Protocol

A boundary implementation is **COMPLETE** only when ALL FOUR of the following
agents have independently reviewed it and emitted a `verified-by` record:

| Agent ID | Model | Requirement |
|----------|-------|-------------|
| `claude-opus-highthink` | Claude Opus 4.8 + extended thinking | Must check all 15 SC-* criteria |
| `opencode-bigpickle` | OpenCode BigPickle model | Must check SC-01–SC-07, SC-12–SC-13 |
| `antigravity-gemini` | AntiGravity (Gemini 2.5 Pro + high effort) | Must check SC-06–SC-11, SC-14–SC-15 |
| `codex-gpt55-highthink` | Codex (GPT-5.5 + high thinking) | Must check all 15 SC-* criteria |

### Verification record format

Each agent emits a record in the plan packet's `events:` block:

```yaml
- type: verified-by
  ts: "<ISO8601>"
  agent_id: "claude-opus-highthink-20260701"
  verdict: "SOUND | COMPLETE | PERFORMANT"   # all three required
  criteria_checked:
    SC-01: pass
    SC-02: pass
    SC-03: pass
    ...
    SC-15: pass
  notes: >
    Optional: findings or caveats. If any criterion is 'fail' or 'partial',
    this field is required and must describe what needs fixing.
```

**Disagreement protocol**: If any two agents disagree on any criterion, the
implementation MUST be revised and all four agents must re-verify from scratch.
A criterion is `pass` only if all verifying agents marked it `pass`.

### Completion gate

A boundary packet transitions from `in_progress` to `completed` ONLY when:
1. All 4 agents have emitted `verified-by` records
2. All 15 SC-* criteria are `pass` in all 4 records
3. At least one integration test proves SC-09 and SC-10

---

## 6. Implementation Order

The boundaries have dependencies. Implement in this order:

1. **Control wire protocol additions** (new `ControlMessage` variants) — unblocks all boundaries
2. **B4: VM Headless listener** (persistent stream + server-push) — unblocks B1, B2, B3
3. **B1: Windows Tray** (remove polling loop, add reader task + watch channels)
4. **B2: macOS Tray** (same refactor as B1, different socket layer)
5. **B3: Linux Native Tray** (same refactor)
6. **B5: Headless ↔ Podman** (Unix socket streams per container)
7. **B6: Vault blocking-watch** (replace periodic Vault poll)

All boundaries must be complete before the master audit packet closes.
