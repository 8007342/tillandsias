<!-- @trace spec:host-guest-transport -->
# host-guest-transport Specification

## Status

active
phase: 1 (facade contract landed; per-platform backends in progress)

## Purpose

Normalize every host→guest interaction onto a single platform-agnostic facade so
the Linux, macOS, and Windows trays stop drifting into separate "connect from host
to guest" implementations. Two primitives cover every need the operator named:

- **InteractiveStream** — a long-lived bidirectional byte stream for PTY/attach.
- **ExecOneShot** — a run-to-completion command for quick interactions and
  one-off reads (status probes, single secret reads, `gh api`-style calls).

The facade contract (`GuestTransport` trait, `GuestEndpoint`, `ExecRequest`,
`ExecOutput`, `ExecChunk`) lives in `tillandsias-control-wire::guest_transport`.
Per-platform backends implement it: Linux AF_VSOCK + Unix in `control-wire`
(feature `vsock`); macOS VZ virtio-vsock and Windows WSL/hvsock in
`tillandsias-vm-layer`. Both primitives ride the unchanged wire protocol
(`encode`/`decode`, 4-byte BE length prefix, `WIRE_VERSION`, `MAX_MESSAGE_BYTES`,
`Hello`/`HelloAck`).

Cross-references:
- `vsock-transport` — the Linux AF_VSOCK backend's protocol/CID contract.
- `vm-idiomatic-layer` — sets up each platform's guest socket device.
- `tray-host-control-socket` — same-host Unix backend.
- `simplified-tray-ux` / `tray-app` — the parity consumers (see tray-parity-matrix).

## Requirements

### Requirement: Two canonical primitives
- **ID**: host-guest-transport.primitives.stream-and-exec@v1
- **Modality**: MUST
- **Measurable**: true

The facade SHALL expose exactly two host→guest interaction primitives:
`open_stream` (InteractiveStream) and `exec` / `exec_streaming` (ExecOneShot).
New host→guest interactions MUST be expressed as one of these; no third bespoke
connect/exec path may be added in tray or headless code.

### Requirement: Callers are backend-agnostic
- **ID**: host-guest-transport.facade.no-cfg-selection@v1
- **Modality**: MUST
- **Measurable**: true

Tray and headless callers SHALL obtain a `Box<dyn GuestTransport>` resolved once
at the platform boundary and MUST NOT select a transport by `cfg!(target_os)` or
by matching `GuestEndpoint` variants. Backend implementation names (`virtio-vsock`,
`hvsock`, `VZVirtioSocketDevice`) MUST NOT appear in the facade's public API,
logs, or caller code. Enforced by `litmus:host-guest-no-cfg-transport-selection`.

### Requirement: One wire protocol for both primitives on every backend
- **ID**: host-guest-transport.protocol.single-framing@v1
- **Modality**: MUST
- **Measurable**: true

Both primitives, on every backend, SHALL use the `control-wire` framing and the
`Hello`/`HelloAck` handshake with `WIRE_VERSION`. A version-skew handshake MUST be
rejected with a typed error; `WIRE_VERSION` changes MUST remain additive.

### Requirement: Cross-platform conformance
- **ID**: host-guest-transport.conformance.shared-fixtures@v1
- **Modality**: MUST
- **Measurable**: true

Each backend SHALL pass the shared conformance fixtures (InteractiveStream echo +
half-close; ExecOneShot stdout/stderr/exit + stdin + streaming + version-skew
rejection). The fixtures are identical across platforms so behavior is provably
1:1. Pinned by `litmus:host-guest-transport-conformance` (per-host).

## Nomenclature (canonical)

- **host / guest** — the two endpoints.
- **GuestEndpoint** — addressing value (how to reach the guest).
- **GuestTransport** — the backend that opens streams / runs exec.
- **InteractiveStream / ExecOneShot** — the two primitives.
- **CID / port** — vsock addressing fields.
- `vsock` is the protocol family; `virtio-vsock`, `hvsock`, `VZVirtioSocketDevice`
  are backend implementation names only.
