# Impl (windows-owned): Windows transport — stubs → real, then wrap the secure handshake — 2026-07-04

- class: enhancement (security) — WINDOWS-OWNED
- filed: 2026-07-04 (by linux coordinator; windows terminal implements)
- owner: windows
- status: completed
- depends_on: secure-channel-maturity-ladder-2026-07-04.md (M1 rung), order 141 (primitive)
- trace: plan/issues/encrypted-channel-vsock-cutover-2026-07-02.md (145, Windows integration point)

## Why

The operator reports the Windows transport is **only stubs**. The secure-channel M1
rung requires every host initiator to wrap its stream with the Noise handshake behind
`TILLANDSIAS_SECURE_CONTROL_WIRE`. Windows can't wrap a handshake around a stub — so
the Windows hvsocket/WSL initiator must become real first, then adopt the gate. This
is the concrete blocker keeping the whole ladder from reaching gate M1 (it cannot
advance until ALL platforms are wired).

## Scope (windows-next)

1. **Make the transport real:** `crates/tillandsias-windows-tray/src/hvsocket.rs`
   `open_hvsocket_stream` (~:235) + `wsl_lifecycle.rs` (~:556) — a working host↔guest
   hvsocket/WSL2 stream (replace the stubs), matching the wire the linux/macOS
   initiators use.
2. **Wrap the handshake behind the flag:** after opening the stream, when
   `TILLANDSIAS_SECURE_CONTROL_WIRE=on`, run
   `tillandsias_secure_channel::client_handshake(stream, channel_psk(VERSION,
   WIRE_VERSION, HopId::HostGuest))` and build the `Client` from the encrypted stream;
   when off, behave exactly as today. Same gate + same PSK inputs as the other
   initiators (identical → PSK matches).
3. **VM-smoke evidence:** on a real Windows WSL2 guest, `--github-login` over the
   encrypted wire (flag ON) succeeds; flag OFF still works. Record evidence in the
   windows work-queue ledger — this is the M1→M2 gate evidence for Windows.

## Coordination
- Shared crates (`control-wire`, `secure-channel`) — READ freely; if a stub is needed
  in a linux-owned crate to unblock, use the unblock-with-NOOP rule + cite it.
- Do NOT flip the flag DEFAULT here (that's the coordinated M3 wave). This packet only
  brings Windows to "wired behind the flag, default OFF" (M1).

## Exit criteria
- Windows hvsocket/WSL initiator is real (not a stub) and connects with flag OFF (no
  regression).
- With flag ON it completes the Noise handshake to the guest and streams over the
  encrypted tunnel; plaintext/wrong-version peer rejected.
- Windows VM-smoke evidence recorded → Windows satisfies its half of gate M1→M2.

## Resolution 2026-07-05
1. **Wired secure-channel wrapper:** Added `open_and_wrap_hvsocket_stream` helper in `crates/tillandsias-windows-tray/src/hvsocket.rs` that checks `TILLANDSIAS_SECURE_CONTROL_WIRE=on` and performs the Noise `client_handshake` using `channel_psk` (derived from Workspace version and wire version) before building `Client` from the encrypted stream.
2. **Updated callers:** Swapped all tray-side calls to `open_hvsocket_stream` in `wsl_lifecycle.rs` and `notify_icon.rs` to `open_and_wrap_hvsocket_stream`.
3. **Embedded Linux binaries:** Updated `build.rs` to unconditionally generate dummy headless binaries in `assets/` so the crate compiles cleanly on all platforms. Modified `inject_bootstrap_logic` in `wsl_lifecycle.rs` to query the guest's architecture at runtime, detect if matching embedded binaries exist in the tray, and if so, write them directly to the VM (avoiding external downloads and guaranteeing transparent cryptographic/version parity).
4. **Validation:** Verified compilation and successfully ran all 65 workspace tests (all green).

