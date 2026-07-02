# Master Audit: Observable Streams at All Transport Boundaries

**Order 141 — MASTER PACKET** — filed 2026-06-30
**Requires ratification by 4 agents before closing. See SC-01–SC-15 in observable-streams-contract-2026-06-30.md.**

---

## Why this exists

The current transport implementation mixes:
- 30-second polling loops (CPU waste, 30s staleness)
- Half-duplex request-response on a full-duplex stream (underuses the protocol)
- Blocking I/O calls in async tasks (potential thread-pool starvation)
- One-shot vsock connections (causing the "wire oscillation" symptom)
- No server-push (headless cannot notify trays of state changes)
- `podman exec -it` for PTY (process-based, not stream-based)

These are fundamental design gaps, not superficial bugs. The fix is a systematic
refactor of ALL transport boundaries to use observable async streams.

---

## Scope

All six boundaries defined in `observable-streams-contract-2026-06-30.md`:

| Boundary | Owner | Dependent packets |
|----------|-------|------------------|
| B1: Windows Tray ↔ VM | windows | order 142 |
| B2: macOS Tray ↔ VM | macos | order 143 |
| B3: Linux Native Tray | linux | order 144 |
| B4: VM Headless listener | linux | order 145 |
| B5: Headless ↔ Podman | linux | order 146 |
| B6: Vault blocking-watch | linux | order 147 |

This master packet is `completed` only when orders 142–147 are ALL completed
and ALL four agents have verified the full system end-to-end.

---

## Anti-patterns to eliminate (audit checklist)

### AP-1: Sleep-based polling loop (CRITICAL)

Anywhere in transport code (host tray, headless, lifecycle):
```rust
// FORBIDDEN:
loop {
    do_some_io().await;
    tokio::time::sleep(Duration::from_secs(30)).await;
}
```
Replacement: `watch::Receiver::changed().await` or a server-push stream.

### AP-2: Request-response per poll tick (CRITICAL)

```rust
// FORBIDDEN:
loop {
    client.send(VmStatusRequest { seq }).await?;
    let reply = client.recv().await?;    // blocks entire connection
    // ... 30s later, repeat
}
```
Replacement: headless sends `VmStatusPush` on change; client routes by type.

### AP-3: One-shot vsock connection (CRITICAL)

```rust
// FORBIDDEN — if headless closes stream after ONE response:
let stream = open_hvsocket_stream(port).await?;
send_request(&mut stream, req).await?;
let reply = recv_reply(&mut stream).await?;
drop(stream);  // connection dies; next request must reconnect
```
Replacement: connection persists for the client's lifetime; multiplexed by `seq`.

### AP-4: Blocking I/O on async thread (HIGH)

```rust
// FORBIDDEN in async fn:
let output = std::process::Command::new("hcsdiag").arg("list").output()?;
// or:
let data: Vec<u8> = std::fs::read("/some/file")?;
```
Replacement: `tokio::task::spawn_blocking(|| ...)` or `tokio::fs::read`.

### AP-5: Unbounded channel (HIGH)

```rust
// FORBIDDEN:
let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
```
Replacement: `mpsc::channel(N)` with documented `N`; slow consumers get backpressure.

### AP-6: Silent try_send drop (MEDIUM)

```rust
// FORBIDDEN without documenting drop intent:
let _ = tx.try_send(event);
```
Allowed ONLY at terminal sinks (e.g., PTY output to a closed terminal window)
where dropping is explicitly acceptable. Must be commented:
```rust
// Terminal sink: drop if terminal is not consuming fast enough.
// The PTY session's bounded channel (SESSION_CHANNEL_CAPACITY) applies
// OS-level backpressure to the guest via the vsock reader task.
let _ = tx.try_send(event);
```

---

## Verification protocol (summary — full spec in observable-streams-contract.md)

Each of the 4 required agents MUST verify all 15 SC-* criteria (SC-01 through SC-15)
and emit a `verified-by` event. The packet is complete only when:
- All 4 agents have verified
- All criteria are `pass` across all 4 records
- Integration tests for SC-09 and SC-10 pass in CI

Required agents and models:
- `claude-opus-highthink` (Claude Opus 4.8 + extended thinking)
- `opencode-bigpickle` (OpenCode BigPickle)
- `antigravity-gemini` (AntiGravity Gemini 2.5 Pro + high effort)
- `codex-gpt55-highthink` (Codex GPT-5.5 + high thinking)

---

## Exit criteria for this master packet

- [ ] Orders 142–147 all completed
- [ ] All 4 agents emit `verified-by` records for the full system
- [ ] CI passes: `litmus:no-polling-sleep-in-transport`, `litmus:no-blocking-io-in-async`
- [ ] E2E test: headless phase change → tray menu update in <500ms
- [ ] Perf test: idle tray CPU < 0.1% over 5 minutes (no polling wakeups)
- [ ] Vault watch test: token change → tray login state update in <1s
