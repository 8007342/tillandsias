## 1. Control wire enum + constants

- [ ] 1.1 Add `PtyDirection { ToGuest, ToHost }` and `PtyExit { code: i32, signal: Option<i32> }` types to `crates/tillandsias-control-wire/src/lib.rs`.
- [ ] 1.2 Add four `ControlMessage` variants: `PtyOpen`, `PtyData`, `PtyResize`, `PtyClose` per `proposal.md`.
- [ ] 1.3 Add `pub const MAX_PTY_FRAME_BYTES: usize = 65_536` next to `MAX_MESSAGE_BYTES`; add a debug_assert that `MAX_PTY_FRAME_BYTES < MAX_MESSAGE_BYTES`.
- [ ] 1.4 Update postcard roundtrip tests in `lib.rs#tests` to cover each new variant (PtyOpen full, PtyData empty + full chunk, PtyResize, PtyClose normal + signal).
- [ ] 1.5 Add a `Hello.capabilities` constant `pub const CAP_PTY_ATTACH_V1: &str = "pty.attach@v1";` and reference it in tests.

## 2. Capability gating + session id allocator

- [ ] 2.1 Add `PtySessionAllocator` (per-connection AtomicU32 starting at 1) in `crates/tillandsias-control-wire/src/transport.rs`.
- [ ] 2.2 Extend the connection handshake to capture peer capabilities from `HelloAck`. Expose `Connection::peer_supports(cap: &str) -> bool`.
- [ ] 2.3 Add a debug_assertion in the connection's `send(envelope)` that any `Pty*` body requires `peer_supports(CAP_PTY_ATTACH_V1)`; treat violation as a programming error.
- [ ] 2.4 Add `TransportError::MessageTooLarge` validation on receive for `PtyData.bytes.len() > MAX_PTY_FRAME_BYTES` — close connection with the documented diagnostic.

## 3. Host-side `tillandsias-host-shell::pty`

- [ ] 3.1 Create `crates/tillandsias-host-shell/src/pty/mod.rs` exposing `PtySession::open(conn: &Connection, opts: PtyOpenOpts) -> Result<PtySession>`.
- [ ] 3.2 Unix path: implement `PtySession::new_unix` using `nix::pty::openpty` + `tokio::process::Command` to fork a host-side helper that owns the slave fd. Master fd is owned by `PtySession`.
- [ ] 3.3 Windows path: stub `PtySession::new_windows` with a `#[cfg(windows)]` ConPTY implementation (`CreatePseudoConsole`); detailed work owned by the Windows tray change.
- [ ] 3.4 Implement `PtySession::pump_io()` — spawns two tokio tasks: (a) reads master fd, encodes `PtyData{ToGuest}` envelopes capped at `MAX_PTY_FRAME_BYTES`, sends via connection; (b) consumes `PtyData{ToHost}` envelopes from the connection's session-id-routed receiver and writes to the master fd.
- [ ] 3.5 Implement `PtySession::resize(rows, cols)` — sends `PtyResize` on the connection and updates local TIOCSWINSZ via `nix::sys::termios`/`ioctl` as appropriate.
- [ ] 3.6 Implement `PtySession::close()` — sends host-initiated `PtyClose`, then `drop`s the master fd.
- [ ] 3.7 Add per-session bounded channel (capacity 256 frames) per design D3.
- [ ] 3.8 Unit tests with `FakeConnection`: open, write, resize, close roundtrip; concurrent two-session interleaving; oversized frame rejection.

## 4. In-VM `tillandsias-headless` handler

- [ ] 4.1 Add `crates/tillandsias-headless/src/pty_handler.rs` registered as a `ControlMessage` dispatch.
- [ ] 4.2 On `PtyOpen`: allocate PTY pair via `nix::pty::openpty`, fork+exec `argv` with slave as controlling tty, env scrubbed and re-set per `PtyOpen.env` (no host-env inheritance), `cwd` set if Some.
- [ ] 4.3 Spawn a tokio task reading the master fd; emit `PtyData{ToHost}` frames chunked at `MAX_PTY_FRAME_BYTES`.
- [ ] 4.4 On incoming `PtyData{ToGuest}`: write to master fd.
- [ ] 4.5 On `PtyResize`: invoke `TIOCSWINSZ` ioctl on master fd.
- [ ] 4.6 On host-initiated `PtyClose`: SIGTERM the child PID; escalate to SIGKILL after 2-second grace.
- [ ] 4.7 On child exit (`waitpid`): emit `PtyClose` with `code`/`signal` populated; release session resources.
- [ ] 4.8 Gate the entire handler behind a `--enable-pty-attach` CLI flag during rollout; default off in v1, on by v2.

## 5. Wire-level integration tests

- [ ] 5.1 Create `crates/tillandsias-control-wire/tests/pty_attach_integration.rs`: spawn an in-process `Connection` pair, run `/bin/echo hello` via PtyOpen, assert PtyData chunks contain `hello\n`, assert PtyClose with `code: 0`.
- [ ] 5.2 Add test for backpressure scenario per design D3: saturate a session with a 10 MB stream; concurrently inject a `VmStatusRequest`; assert reply latency < 250 ms.
- [ ] 5.3 Add test for capability gating: simulate a peer without `pty.attach@v1` in `HelloAck`; assert `PtySession::open` returns `PeerLacksCapability` error.

## 6. Developer CLI for smoke testing

- [ ] 6.1 Add `cargo run -p tillandsias-host-shell --bin pty-test -- --vsock-cid <CID> --port 42420 -- /bin/bash` to verify the wire end-to-end without the tray binary.
- [ ] 6.2 Document usage in `crates/tillandsias-host-shell/README.md`.

## 7. Spec sync

- [ ] 7.1 Run `/opsx:sync control-wire-pty-attach` to merge the delta into `openspec/specs/vsock-transport/spec.md`.
- [ ] 7.2 Regenerate `openspec/specs/vsock-transport/TRACES.md`.
- [ ] 7.3 Add cross-reference notes in `openspec/specs/macos-native-tray/spec.md` and `openspec/specs/windows-native-tray/spec.md` pointing at `pty.attach@v1`.

## 8. Verify

- [ ] 8.1 Run `openspec validate control-wire-pty-attach` — expect "valid".
- [ ] 8.2 Run `cargo test -p tillandsias-control-wire` — all green.
- [ ] 8.3 Run `cargo test -p tillandsias-host-shell` — all green.
- [ ] 8.4 Run `cargo test -p tillandsias-headless --features pty-attach` — all green.
- [ ] 8.5 Smoke test on a real Fedora 44 Core VM: launch `pty-test`, run `bash -c 'for i in $(seq 1 5); do echo "line $i"; done; exit 7'`, observe lines streamed back, observe `PtyClose { code: 7 }`.

## 9. Archive

- [ ] 9.1 Once verified, run `/opsx:archive control-wire-pty-attach`.
