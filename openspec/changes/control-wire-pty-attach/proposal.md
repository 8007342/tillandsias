## Why

The macOS and Windows host-shell trays need to surface interactive in-VM commands (Open Shell, `tillandsias --opencode`, `tillandsias --github-login` during the OAuth device-code paste) as a host-side terminal window driven by an in-VM PTY. The existing `tillandsias-control-wire` over vsock carries request/reply envelopes but has no bidirectional byte-stream variant, no PTY-resize signalling, and no notion of an opaque session id that lets multiple PTYs coexist on one vsock connection. Without this, the macOS spec's "open terminal" UX (`spec:macos-native-tray`) and the symmetric Windows UX have no concrete wire.

Per owner decision 2026-05-24, this rides the existing vsock connection rather than opening a second port — keeps the entitlement story, CID negotiation, and reconnect backoff unchanged.

## What Changes

- **ADDED** four `ControlMessage` variants on `tillandsias-control-wire`:
  - `PtyOpen { session_id: u32, rows: u16, cols: u16, argv: Vec<String>, env: Vec<(String, String)>, cwd: Option<String> }` — host → guest; starts a PTY-attached subprocess inside the VM.
  - `PtyData { session_id: u32, direction: PtyDirection, bytes: Vec<u8> }` — bidirectional; carries raw terminal bytes (stdin from host, stdout/stderr from guest are multiplexed by `direction`).
  - `PtyResize { session_id: u32, rows: u16, cols: u16 }` — host → guest; relays `SIGWINCH` semantics.
  - `PtyClose { session_id: u32, exit: PtyExit }` — terminal event in either direction; `PtyExit { code: i32, signal: Option<i32> }`.
- **ADDED** `PtyDirection { ToGuest, ToHost }` enum and `PtyExit` struct.
- **ADDED** `MAX_PTY_FRAME_BYTES` constant (recommend 64 KiB) governing the largest single `PtyData` payload. Larger streams chunk transparently at the sender.
- **ADDED** session-id allocation contract: host allocates `session_id` from a per-connection monotonic counter; guest echoes the same id on every reply for that session. Sessions are scoped to the vsock connection — a reconnect terminates all in-flight sessions.
- **MODIFIED** `Hello` capabilities advertise `"pty.attach@v1"` so peers can negotiate. A host that connects without `pty.attach@v1` SHALL NOT receive `Pty*` envelopes from the guest.
- **MODIFIED** `vsock-transport` spec to add the `pty.attach@v1` capability and its session-multiplexing requirements.
- **ADDED** new `tillandsias-host-shell::pty` submodule with a `PtySession` type that owns the host-side PTY (via `nix::pty` on Unix, `winapi`/`windows-rs` ConPTY on Windows) and bridges its file descriptors to `PtyData` envelopes through the control-wire client.
- **ADDED** corresponding in-VM `tillandsias-headless` handler that forks the requested argv on a PTY, mirrors bytes back as `PtyData`, and emits `PtyClose` on child exit.

No breaking change to existing wire consumers — the `ControlMessage` enum is `#[non_exhaustive]` and postcard handles additive variants compatibly. Peers without `pty.attach@v1` in their `Hello` capabilities continue to function for control-plane traffic only.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `vsock-transport`: add `pty.attach@v1` capability + session multiplexing + `Pty*` envelope requirements.

## Impact

- **Spec**: delta to `openspec/specs/vsock-transport/spec.md` (adds the capability + 4–5 requirements).
- **Crates**:
  - `tillandsias-control-wire` — adds 4 enum variants + 2 helper types + 1 constant.
  - `tillandsias-host-shell` — new `pty` submodule (PTY allocation, byte pump, signal relay).
  - `tillandsias-headless` — in-VM handler for `PtyOpen` / `PtyData{ToGuest}` / `PtyResize` / forks subprocess on a PTY, streams output back.
  - `tillandsias-macos-tray` — wires "Open Shell" / "Open Terminal" menu items to `PtySession::open(...)` and spawns Terminal.app/iTerm2 attached to a host pseudo-tty fd.
  - `tillandsias-windows-tray` — symmetric; uses ConPTY + Windows Terminal `wt.exe --pipe`.
- **No breaking change**: existing control-plane consumers ignore new variants per postcard's additive enum semantics; `Hello` capability negotiation gates whether `Pty*` envelopes are sent.
- **Performance**: `PtyData` frames at most 64 KiB per envelope; high-throughput streams (e.g. `cargo build` output) generate many envelopes per second but each is small. Postcard + vsock are both zero-copy-friendly. No new entitlement required.
- **Security**: PTY subprocesses inside the VM inherit the in-VM uid/gid (no host privilege escalation possible across the vsock boundary). The host-side PTY is a normal child fd of the tray binary; no root needed. Credentials remain in-VM per `tillandsias-vault` invariants.
