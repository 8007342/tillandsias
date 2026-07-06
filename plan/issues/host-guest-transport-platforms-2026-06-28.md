# Per-Platform Conformance: Host↔Guest Transport

**Status:** `blocked` (macOS slices checkpointed; blocked on shared conformance/facade contract and live VM substrate)
**Depends on:** `host-guest-transport-normalization-spec-2026-06-28`
**Date:** 2026-06-28
**Kind:** enhancement
**Trace:** `spec:vsock-transport`, `spec:vm-idiomatic-layer`

Each platform implements the normalized `GuestTransport` facade so that
InteractiveStream + ExecOneShot behave identically, addressed by `GuestEndpoint`,
over the single wire protocol. One sub-packet per host (owned by that host).

---

## host-guest-transport-linux (owner: linux)

Linux is the reference backend (AF_VSOCK via tokio-vsock + Unix same-host).

- Collapse the **5** `exec_over_stream*` variants in `vm-layer/vsock_exec.rs` into
  the single `ExecOneShot` (`exec` + `exec_streaming`) facade method; migrate all
  call sites.
- Route `vsock_server.rs` and the tray's control-socket path through the facade.
- Keep `WIRE_VERSION` stable; add fixture tests for both primitives.
- Verifiable closure: `exec_over_stream`-family symbol count drops to the facade
  methods only (grep litmus); both-primitive round-trip unit tests green.

## host-guest-transport-macos (owner: osx)

macOS VZ virtio-vsock backend (`transport_macos.rs`, `vz.rs`).

Status 2026-07-06T18:17Z: claimed by
`macos-Tlatoanis-MacBook-Air-codex-20260706T1817Z`
(`host-guest-transport-macos-20260706T1817Z`) for the first coherent slice:
add the macOS `GuestTransport` backend over the existing VZ `VsockStream` and
pin compile-time conformance tests. Broader call-site migration can continue in
subsequent slices if needed.

Checkpoint 2026-07-06T18:20Z: first slice landed on `osx-next@0e49d480`.
`VzRuntime` implements `GuestTransport` for `GuestEndpoint::MacVz`; `open_stream`
uses the existing VZ `VsockStream`, and `exec` / `exec_streaming` route through
the existing `vsock_exec` helpers. Added macOS-only compile-time conformance and
endpoint validation tests. Evidence: `cargo test -p tillandsias-vm-layer` 26/26
and `./build.sh --check` pass on macOS. Remaining: migrate tray call sites to
the facade and run/live-prove the shared conformance fixture when the VM
substrate is available.

Checkpoint 2026-07-06T18:29Z: second slice landed on `osx-next@381dbdfc` and
`osx-next@e9d55c97`. The AppKit action-host control-wire opener now constructs
`GuestEndpoint::MacVz` and opens it through `GuestTransport::open_stream`, and
`VzRuntime::exec` now routes through `GuestTransport::exec` while explicitly
normalizing Unix signal exits at the facade boundary. Evidence:
`cargo test -p tillandsias-vm-layer` 28/28,
`cargo test -p tillandsias-macos-tray` 55 passed / 1 ignored, and
`./build.sh --check` pass on macOS. Remaining: migrate `diagnose.rs`'
current-thread VZ opener and direct live exec helper paths, then run/live-prove
the shared conformance fixture when VM substrate is available.

Checkpoint 2026-07-06T18:36Z: third slice landed on `osx-next@8e9f586d`.
`diagnose.rs` no longer names the raw macOS `VsockStream` type or calls
`open_vsock_stream_current_thread` directly. It constructs `GuestEndpoint::MacVz`
and delegates current-thread connection details to a vm-layer endpoint-shaped
helper that preserves the per-attempt timeout needed by headless CLI readiness
probes. Evidence: `cargo test -p tillandsias-vm-layer` 29/29,
`cargo test -p tillandsias-macos-tray` 56 passed / 1 ignored, and
`./build.sh --check` pass on macOS. Remaining: secure/expect-style live exec
helper calls still use `vsock_exec` over the secured boxed stream, and shared
conformance still needs a live VM run.

Blocked 2026-07-06T18:40Z: released the macOS lease after three coherent slices.
Completion now depends on work outside this macOS code slice: order 124 still
needs the shared conformance harness/litmus and a facade-contract decision for
secure/expect/signal ExecOneShot semantics, and this host path cannot run the
live Darwin fixture (`scripts/e2e-preflight.sh eligibility` returns
`skip:no-podman-user-session`; packaged/entitled VM substrate is still tracked by
the macOS runtime-smoke/entitlement blockers). Next: Linux/order124 lands the
harness/contract decision, then a macOS host with the packaged VM substrate runs
the shared fixture against `osx-next@8e9f586d` or newer.

- Implement the facade backend over `VZVirtioSocketDevice`; remove bespoke
  per-call connect logic in favor of `open_stream` / `exec`.
- Replace the macOS exec-guest helpers with the `ExecOneShot` facade (supersedes
  much of `optimization-macos-vz-idiomatic-exec-layer-2026-06-21.md`).
- Fixes the class behind `macos-tray-github-login-blank-terminal` (interactive
  stream lifecycle) via the shared InteractiveStream primitive.
- Verifiable closure: macОС tray uses no `cfg`-selected transport; both primitives
  pass the shared conformance fixtures on Darwin.

## host-guest-transport-windows (owner: windows)

Windows WSL/hvsock backend (`wsl.rs`).

- Implement the facade backend over the WSL pipe/hvsock path; unify connect/exec.
- Resolve `windows-next-architecture-decision-2026-05-24.md` in favor of the
  normalized facade.
- Verifiable closure: Windows tray uses no `cfg`-selected transport; both
  primitives pass the shared conformance fixtures on Windows.

---

## Shared conformance harness

A cross-platform fixture suite (same test names per platform) exercises:
InteractiveStream echo + resize + half-close; ExecOneShot stdout/stderr/exit +
stdin + streaming + version-skew rejection. Each host runs it locally as the
verifiable closure for its sub-packet. Pinned by
`litmus:host-guest-transport-conformance` (per-host size:quick).

## Coordination

- Release is held until the **macOS host completes its current work**; these
  conformance packets land per branch, then ship together.
- linux lands the facade + Linux backend first (reference); osx/windows rebase
  onto it and implement their backends.
