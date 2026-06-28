# Per-Platform Conformance: Host↔Guest Transport

**Status:** `pending` (blocked on normalization spec)
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
