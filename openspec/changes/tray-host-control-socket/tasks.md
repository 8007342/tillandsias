# Tasks — tray-host-control-socket

## 1. Wire-format schema crate

- [ ] 1.1 Create `crates/tillandsias-control-socket-schema/` with `Cargo.toml`
      (deps: `serde`, `postcard` with `alloc` feature, `thiserror`).
- [ ] 1.2 Define `ControlEnvelope { wire_version: u16, seq: u64, body: ControlMessage }`
      with `#[derive(Serialize, Deserialize)]` and `#[non_exhaustive]` enum
      annotations. Pin `WIRE_VERSION: u16 = 1`.
- [ ] 1.3 Define v1 variants: `Hello { from, capabilities }`, `HelloAck { wire_version, server_caps }`,
      `IssueWebSession { project_label, cookie_value: [u8; 32] }`, `IssueAck { seq_acked }`,
      `Error { seq_in_reply_to: Option<u64>, code, message }`.
- [ ] 1.4 Define `ErrorCode` enum: `UnknownVariant`, `PayloadTooLarge`,
      `Unauthorized`, `Internal`, `Unsupported`.
- [ ] 1.5 Pin `MAX_MESSAGE_BYTES: usize = 65_536` constant.
- [ ] 1.6 Add round-trip unit tests: serialise+deserialise every variant;
      assert byte-identical results.
- [ ] 1.7 Add `@trace spec:tray-host-control-socket` and
      `@cheatsheet languages/rust.md` annotations on the schema module.

## 2. Server crate (tray-side)

- [ ] 2.1 Create `crates/tillandsias-control-socket-server/` (deps: `tokio`,
      `tokio-util` with `codec`, schema crate, `tracing`).
- [ ] 2.2 Implement `Server::bind(path: &Path) -> Result<Server>`:
      - Ensure parent dir exists with mode `0700` (mkdir-or-chmod).
      - `UnixListener::bind(path)`.
      - `chmod` socket node to `0600` between bind and accept-loop start.
- [ ] 2.3 Implement `Server::with_xdg_runtime_dir() -> Result<Server>` that
      resolves `$XDG_RUNTIME_DIR/tillandsias/control.sock` with
      `/tmp/tillandsias-$UID/control.sock` fallback (log warning on fallback).
- [ ] 2.4 Implement stale-socket recovery: on bind, if path exists, probe via
      `Hello` envelope with 200 ms connect / 500 ms read deadlines; either
      abort startup (live peer) or unlink + bind (stale).
- [ ] 2.5 Implement accept loop with `Semaphore` (32 permits) and per-connection
      `tokio::spawn(handle_connection(...))`.
- [ ] 2.6 Implement `handle_connection` using `LengthDelimitedCodec` (4-byte
      big-endian length prefix, 64 KiB max frame), with `tokio::time::timeout`
      enforcing 60 s idle deadline.
- [ ] 2.7 Implement `Dispatcher` trait + registration: `register<F>(variant_kind, F)`
      where `F: AsyncFn(ControlMessage) -> ControlMessage`. Variant dispatch is
      a `match` on the deserialised variant.
- [ ] 2.8 Implement graceful shutdown: stop accepting, give in-flight 200 ms
      to flush, cancel, unlink socket node via `Drop` guard.
- [ ] 2.9 Add unit tests: bind+chmod permissions; stale recovery (live, stale,
      not-a-socket, file-permission denied); idle timeout; max-frame rejection;
      semaphore concurrency cap; per-task panic isolation.
- [ ] 2.10 Add `@trace spec:tray-host-control-socket` annotations on every
      public function.

## 3. Client crate (consumer-side)

- [ ] 3.1 Create `crates/tillandsias-control-socket-client/` (deps: `tokio`,
      `tokio-util` with `codec`, schema crate, `tracing`).
- [ ] 3.2 Implement `Client::connect(path: &Path) -> Result<Client>` resolving
      `TILLANDSIAS_CONTROL_SOCKET` env or fallback to default path.
- [ ] 3.3 Implement reconnect loop with exponential backoff
      (100 ms → 200 ms → 500 ms → 1 s → 2 s, cap 5 s, ±10% jitter).
- [ ] 3.4 Implement `send(msg: ControlMessage) -> Result<ControlMessage>`
      with per-connection sequence numbering and reply correlation by `seq`.
- [ ] 3.5 Implement `Hello`/`HelloAck` handshake on every (re)connect with
      1 s deadline; treat mismatch as fatal-after-log.
- [ ] 3.6 Add integration test: spawn server in-process, connect client,
      exchange `IssueWebSession` + `IssueAck`, verify round-trip.

## 4. Tray-side wiring

- [ ] 4.1 In `src-tauri/src/main.rs` (or equivalent startup module), construct
      `Server::with_xdg_runtime_dir()` and spawn the listener task before
      enclave infrastructure starts.
- [ ] 4.2 Register a no-op handler for `Hello` that returns
      `HelloAck { wire_version: 1, server_caps: ["v1"] }`.
- [ ] 4.3 Wire shutdown: on app `Quit` event, call `Server::shutdown()` after
      `shutdown_all` of containers but before process exit.
- [ ] 4.4 Add `@trace spec:tray-host-control-socket` near the bind + shutdown
      call sites.
- [ ] 4.5 Verify singleton-guard interaction: a second tray instance with a
      live first instance hits the live-peer probe path and exits cleanly.

## 5. Container bind-mount integration

- [ ] 5.1 Add `mount_control_socket: bool` field to
      `ContainerProfile` in `tillandsias-core` (default `false`).
- [ ] 5.2 Update router profile to set `mount_control_socket = true`.
- [ ] 5.3 In `tillandsias-podman::build_podman_args`, when the field is true,
      append `-v <host_socket_path>:/run/host/tillandsias/control.sock` and
      set `TILLANDSIAS_CONTROL_SOCKET=/run/host/tillandsias/control.sock` env.
- [ ] 5.4 Verify `--cap-drop=ALL`, `--security-opt=no-new-privileges`,
      `--userns=keep-id` remain applied when the mount is added.
- [ ] 5.5 Add unit test: profile with `mount_control_socket = true` produces
      the expected `-v` and env-var args; profile without it produces neither.
- [ ] 5.6 Add unit test: forge container default profile has
      `mount_control_socket = false`.

## 6. Accountability logging

- [ ] 6.1 Emit accountability log entries on:
      - server startup (`spec = "tray-host-control-socket"`, action = `bind`,
        path, fallback flag),
      - stale-socket detection (action = `live-peer` | `stale-cleanup` |
        `not-a-socket`),
      - graceful shutdown (action = `unlink`),
      - per-connection lifecycle (`accept`, `hello`, `idle-timeout`, `closed`).
- [ ] 6.2 Implement secret-redaction wrapper for log emission: any field
      containing key material (e.g., `cookie_value`) is replaced with
      `<redacted, N bytes>` before formatting. Unit-test that no raw cookie
      bytes ever reach the log writer.
- [ ] 6.3 Add `cheatsheet = "runtime/networking.md"` field on
      socket-bind log entries.

## 7. Verification & validation

- [ ] 7.1 Run `cargo test --workspace` — all new tests pass.
- [ ] 7.2 Run `cargo clippy --workspace -- -D warnings`.
- [ ] 7.3 Run `openspec validate tray-host-control-socket --strict` — must pass.
- [ ] 7.4 Manual smoke: launch tray, verify `ls -la $XDG_RUNTIME_DIR/tillandsias/`
      shows `srw------- ... control.sock`. Quit tray, verify socket gone.
- [ ] 7.5 Manual smoke: launch router profile, exec into container, verify
      `/run/host/tillandsias/control.sock` exists and a test client can
      connect + exchange `Hello`/`HelloAck`.
- [ ] 7.6 Manual smoke: kill tray with `SIGKILL`, restart, verify stale socket
      is detected and replaced (accountability log shows `stale-cleanup`).
