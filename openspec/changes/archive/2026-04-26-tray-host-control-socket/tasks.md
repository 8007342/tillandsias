# Tasks — tray-host-control-socket

## 1. Wire-format schema crate

- [x] 1.1 Schema lives in `src-tauri/src/control_socket/wire.rs` (in-tree
      module rather than a separate workspace crate; OTP follow-up will
      promote it to a shared crate when the consumer-side client lands).
- [x] 1.2 Defined `ControlEnvelope { wire_version: u16, seq: u64, body: ControlMessage }`.
      Pinned `WIRE_VERSION: u16 = 1`. `ControlMessage` and `ErrorCode` are
      both `#[non_exhaustive]`.
- [x] 1.3 Defined v1 variants: `Hello { from, capabilities }`,
      `HelloAck { wire_version, server_caps }`,
      `IssueWebSession { project_label, cookie_value: [u8; 32] }`,
      `IssueAck { seq_acked }`,
      `Error { seq_in_reply_to: Option<u64>, code, message }`.
- [x] 1.4 Defined `ErrorCode` enum: `UnknownVariant`, `PayloadTooLarge`,
      `Unauthorized`, `Internal`, `Unsupported`.
- [x] 1.5 Pinned `MAX_MESSAGE_BYTES: usize = 65_536` constant.
- [x] 1.6 Round-trip unit tests cover every v1 variant
      (`hello_roundtrip`, `hello_ack_roundtrip`, `issue_web_session_roundtrip`,
      `issue_ack_roundtrip`, `error_roundtrip`,
      `error_without_seq_in_reply_roundtrip`).
- [x] 1.7 `@trace spec:tray-host-control-socket` and
      `@cheatsheet languages/rust.md` present on the schema module.

## 2. Server crate (tray-side)

- [x] 2.1 Server lives in `src-tauri/src/control_socket/mod.rs` (in-tree).
      Workspace deps: `tokio`, `tokio-util` (codec), `futures-util`, `bytes`.
- [x] 2.2 `Server::bind` ensures parent dir exists with mode `0700`,
      binds via `UnixListener::bind`, chmods the socket node to `0600`
      between bind and accept-loop start.
- [x] 2.3 `Server::bind_default` resolves
      `$XDG_RUNTIME_DIR/tillandsias/control.sock` with `$TMPDIR` and
      `/tmp/tillandsias-$UID/control.sock` fallbacks (logs an
      accountability entry on fallback).
- [x] 2.4 Stale-socket recovery: probes existing nodes with a synchronous
      blocking connect (200 ms connect / 500 ms read deadlines); either
      refuses to bind (`AddrInUse` for live peer) or unlinks + binds
      (stale leftover). `NotASocket` arm for non-socket paths.
- [x] 2.5 Accept loop uses `Semaphore` (32 permits) and per-connection
      `tokio::spawn(handle_connection(...))`. Permits release on task exit.
- [x] 2.6 `handle_connection` uses `tokio_util::codec::LengthDelimitedCodec`
      (4-byte big-endian length prefix, 64 KiB max frame) with a
      `tokio::time::timeout` enforcing 60 s idle deadline.
- [ ] 2.7 Per-handler dispatcher trait NOT YET implemented — v1 dispatch is a
      single `match` in `handler::dispatch`. Pluggable handler registration
      lands with the OTP change when there are multiple consumer-specific
      variants to register.
- [x] 2.8 Graceful shutdown via `Server::shutdown` (notifies the accept
      loop, awaits the join handle with a 200 ms grace window) plus a
      `Drop` guard that unlinks the socket node.
- [x] 2.9 Unit tests: bind+chmod permissions
      (`bind_creates_socket_with_owner_only_perms`); stale recovery
      (`stale_socket_is_recovered`, `probe_returns_stale_when_path_missing`,
      `probe_returns_not_a_socket_for_regular_file`); live-peer rejection
      (`second_bind_at_same_path_fails_with_live_peer`); end-to-end
      handshake (`hello_handshake_round_trips_across_socket`). Idle-timeout
      and per-task panic-isolation tests deferred to follow-up.
- [x] 2.10 `@trace spec:tray-host-control-socket` on every public function
      and module-level doc.

## 3. Client crate (consumer-side)

- [ ] 3.1 Deferred to the OTP follow-up change. v1 ships only the
      host-side server; the consumer-side reconnect / handshake / `send`
      API lands when there is an actual consumer (router) ready to
      integrate.
- [ ] 3.2 (deferred) `Client::connect`.
- [ ] 3.3 (deferred) Reconnect loop with exponential backoff.
- [ ] 3.4 (deferred) `send` with sequence numbering + reply correlation.
- [ ] 3.5 (deferred) Per-connection `Hello`/`HelloAck` handshake.
- [ ] 3.6 (deferred) Integration test: in-process server + client,
      `IssueWebSession` + `IssueAck` round-trip.

## 4. Tray-side wiring

- [x] 4.1 `Server::bind_default()` invoked from `src-tauri/src/main.rs`
      inside the Tauri `setup` closure, before enclave infrastructure
      starts. Stored in a `OnceLock<tokio::sync::Mutex<Server>>` so the
      Quit path can reach it.
- [x] 4.2 `Hello` is handled by `control_socket::handler::dispatch` and
      replies with `HelloAck { wire_version: 1, server_caps: ["v1"] }`.
- [x] 4.3 The event loop's Quit arm calls `crate::shutdown_control_socket()`
      after `shutdown_all` and before `app_handle.exit(0)`. The `Drop`
      guard on `Server` unlinks the socket node as a defence-in-depth.
- [x] 4.4 `@trace spec:tray-host-control-socket` annotations cover the
      bind site (`main.rs`), shutdown site (`event_loop.rs`), and the
      mount-injection site (`launch.rs`).
- [ ] 4.5 Singleton-guard end-to-end verification deferred to manual smoke
      (task 7.4 / 7.6) — the unit-level coverage in
      `second_bind_at_same_path_fails_with_live_peer` exercises the same
      probe path against an in-process listener.

## 5. Container bind-mount integration

- [x] 5.1 `mount_control_socket: bool` field added to `ContainerProfile`
      in `crates/tillandsias-core/src/container_profile.rs` (defaults to
      `false`).
- [x] 5.2 `router_profile()` sets `mount_control_socket = true`.
- [x] 5.3 `src-tauri/src/launch.rs::build_podman_args` appends
      `-v <host_socket_path>:/run/host/tillandsias/control.sock:rw` and
      `-e TILLANDSIAS_CONTROL_SOCKET=/run/host/tillandsias/control.sock`
      when the field is true.
- [x] 5.4 Verified by `control_socket_mount_added_when_profile_opts_in`:
      `--cap-drop=ALL`, `--security-opt=no-new-privileges`,
      `--userns=keep-id` remain on the command line.
- [x] 5.5 `control_socket_mount_added_when_profile_opts_in` and
      `control_socket_mount_absent_when_profile_does_not_opt_in` cover
      both directions.
- [x] 5.6 `forge_profiles_default_to_no_control_socket` and
      `service_containers_default_to_no_control_socket` lock down the
      default-deny posture.

## 6. Accountability logging

- [x] 6.1 Accountability entries emitted on:
      - server startup (`operation = "bind"`, path, source enum),
      - fallback-path resolution (`operation = "fallback-path"`),
      - stale detection (`operation = "live-peer" | "stale-cleanup" | "not-a-socket"`),
      - graceful shutdown (`operation = "unlink"`),
      - per-connection lifecycle (`operation = "accept" | "hello" | "idle-timeout" | "decode-failed" | "wire-version-mismatch"`).
- [ ] 6.2 Secret-redaction wrapper for `cookie_value` deferred to OTP
      change (the `IssueWebSession` variant exists in the schema but is
      NOT dispatched in v1; redaction lands with the actual issuance
      flow).
- [x] 6.3 `cheatsheet = "runtime/networking.md"` field present on the
      socket-bind log entry.

## 7. Verification & validation

- [x] 7.1 `toolbox run -c tillandsias cargo test --workspace` — 314 tests
      pass (166 + 92 + 34 + 22), including 27 new control-socket tests.
- [x] 7.2 `toolbox run -c tillandsias cargo clippy --workspace --all-targets`
      — zero new warnings from control-socket code (pre-existing warnings
      elsewhere unaffected).
- [ ] 7.3 `openspec validate tray-host-control-socket --strict` — pending
      orchestrator step.
- [ ] 7.4 Manual smoke (launch tray, verify socket node + perms, Quit
      cleans up) — pending orchestrator step.
- [ ] 7.5 Manual smoke (router exec + handshake) — pending orchestrator
      step; covered at the unit level by
      `hello_handshake_round_trips_across_socket`.
- [ ] 7.6 Manual smoke (SIGKILL + stale recovery) — pending orchestrator
      step; covered at the unit level by `stale_socket_is_recovered`.
