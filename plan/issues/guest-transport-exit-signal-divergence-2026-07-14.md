# GuestTransport backends diverge on signal-exit mapping: macOS 128+n, Windows raw protocol code

- Date: 2026-07-14
- Class: enhancement (facade contract gap; cross-backend divergence)
- Filed by: macos-osx-next meta-orchestration cycle 2026-07-14T19:04Z (order 126/128 conformance work)
- Related: openspec/specs/host-guest-transport, crates/tillandsias-vm-layer/src/vz.rs `guest_transport_exit_code` (128+signal), crates/tillandsias-vm-layer/src/transport_windows.rs (`out.exit.code` raw), transport_conformance.rs module doc
- Pickup: linux (spec decision), then one-line backend fixes

## Observed

When a guest process dies by signal, `PtyExit { code, signal }` reaches the
backends, and they map it differently into `ExecOutput::exit_code`:

- macOS `VzRuntime` (vz.rs `guest_transport_exit_code`): `128 + signal`
  (shell convention, e.g. SIGTERM → 143).
- Windows `WslGuestTransport` (transport_windows.rs:292/319): returns
  `out.exit.code` verbatim and drops the signal.

The facade spec does not pin a mapping, so both are "correct" today and
callers cannot rely on either. The shared conformance harness (order 128,
`transport_conformance.rs`) deliberately EXCLUDES a signal fixture until
this is decided — the module doc points here.

## Ask

1. Pin one mapping in openspec/specs/host-guest-transport (recommend the
   POSIX-shell 128+n convention the macOS backend already implements — it
   is what every caller inspecting exit codes expects from `$?`).
2. Apply the one-line fix to the divergent backend(s).
3. Add the signal fixture to `transport_conformance::run_all`
   (`/bin/bash -lc 'kill -TERM $$'` → expect 143) so the contract is pinned
   live on every platform runner.
