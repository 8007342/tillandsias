# Encrypted Control Channel — vsock cutover (slice 4) + container hop (slice 6) — 2026-07-02

- class: enhancement (security) — COORDINATED CROSS-HOST CUTOVER
- filed: 2026-07-02
- owner: linux (coordinator) + macos + windows
- status: ready (linux half) / blocked-on-siblings (atomic flip)
- depends_on: encrypted-control-channel-impl (order 141 slices 1-3 — the EncryptedStream primitive is landed)
- trace: plan/issues/encrypted-control-channel-impl-2026-07-01.md, plan/issues/security-audit-zero-trust-2026-07-01.md (P0-1)

## Why this is a separate, coordinated packet

Slices 1-3 landed the reusable `EncryptedStream<S>` + version-bound PSK
(`tillandsias-secure-channel`). Slice 4 *turns it on* for the vsock host↔guest
hop. That is **not** a solo-linux change: the guest responder and all three host
initiators must flip **atomically**, or the control wire bricks on the hosts
that did not.

**Why atomic:** a Noise handshake is all-or-nothing. If the guest
(`vsock_server.rs`) starts requiring the handshake before `Hello`, any host that
still opens a plaintext `Hello` is rejected `Unauthorized`. Accepting *both*
plaintext and encrypted on the guest would be a trivially exploitable downgrade
path — so dual-mode is off the table. Therefore the flip must land with all
initiators adopting it in the same wave.

**Why it needs VM e2e:** the only real proof is a host↔guest handshake over a
live vsock on each platform. A SELinux-Disabled dev Linux box with no VM cannot
exercise it; verification is on the macOS VZ guest and the Windows WSL/hvsock
guest.

## Integration points (exact)

| Role | File | Change |
|---|---|---|
| Guest responder (linux) | `crates/tillandsias-headless/src/vsock_server.rs` `handle_connection` (~:245) | run `secure_channel::server_handshake(stream, channel_psk(VERSION, WIRE_VERSION, HopId::HostGuest))` BEFORE reading `Hello`; on error, send `Error{code: Unauthorized}` and close. Wrap the stream so the existing `read_envelope`/`Hello` path runs inside the tunnel. |
| Host initiator (linux/shared) | `crates/tillandsias-host-shell/src/vsock_client.rs` `Client::connect` / `connect_with_handshake` (:73/:199) | after `transport::connect`, run `client_handshake(stream, channel_psk(...))`, then `Client::from_stream(Box::new(encrypted))`. Shared scope — coordinate. |
| Host initiator (macOS) | `crates/tillandsias-macos-tray/src/diagnose.rs` `open_vsock_stream_current_thread` call sites (:353/:475/:657/:763) | wrap the returned VZ vsock stream with `client_handshake` before building the `Client`. **osx-owned — osx terminal does this half.** |
| Host initiator (Windows) | `crates/tillandsias-windows-tray/src/hvsocket.rs` `open_hvsocket_stream` (:235) + `wsl_lifecycle.rs` (:556) | wrap the hvsocket stream with `client_handshake` before the `Client`/handshake. **windows-owned — windows terminal does this half.** |

All four call `tillandsias_secure_channel::channel_psk(VERSION, WIRE_VERSION,
HopId::HostGuest)` — identical inputs, so the PSK matches iff the versions match.

## Slice 4 execution plan (coordinated)

1. **Prep (linux, safe/additive, can land first):** add a `connect_secure`
   helper in `host-shell/vsock_client.rs` that composes `connect` +
   `client_handshake`, and a `serve_secure` wrapper for the guest — both
   **behind a `TILLANDSIAS_SECURE_CONTROL_WIRE` gate defaulting OFF**, so nothing
   changes behavior until the flip. Add the `tillandsias-secure-channel` dep to
   host-shell + headless. Landable now without breaking any host.
2. **Sibling adoption (osx + windows, parallel):** each wraps its own initiator
   (diagnose.rs / hvsocket.rs) behind the same gate. File as sub-packets on
   `osx-next` / `windows-next`.
3. **Atomic flip (coordinator):** once all three initiators + the guest honor the
   gate and each host has VM-smoked it ON, flip the default to ON and make the
   guest REQUIRE it (reject plaintext). Land the flip + remove the gate in one
   commit after all hosts report green.
4. **Litmus `vsock-unauthenticated-peer-rejected`** (closes order 137): a peer
   that connects without the handshake (or with a mismatched-version PSK) gets
   `Unauthorized` and no `PtyOpen` is served. Runnable in-process against the
   guest responder with a plaintext client — does not need a VM.

## Slice 6 — guest↔container hop (after slice 4)

Reuse `EncryptedStream` with `HopId::GuestContainer` on the guest→innermost-
container transport; the container's matching-version tillandsias binary is the
responder. Then revisit `hardcoded-ip/remove-port-publish` (order 104) — the
encrypted channel is the non-published host-access path that blocker needed.

## Exit criteria

- Gate-off prep landed (no behavior change; all hosts still build+connect).
- Each host initiator wraps its stream with `client_handshake` behind the gate.
- Guest requires the handshake when the gate is ON; rejects plaintext/mismatch
  with `Unauthorized` (litmus `vsock-unauthenticated-peer-rejected` green).
- Each platform VM-smokes `--github-login` over the encrypted wire (evidence per
  host).
- Atomic flip to ON + gate removed once all three are green.
- Slice 6 encrypts the container hop; order-104 port-publish removal revisited.
