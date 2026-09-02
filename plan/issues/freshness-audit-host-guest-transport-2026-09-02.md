# freshness audit: openspec/specs/host-guest-transport/spec.md (2026-09-02)

Class: `exploration/` (standing freshness audit, order 372, methodology
`component_freshness`). Selected by `scripts/freshness-inventory.sh`
(`freshness-next: openspec/specs/host-guest-transport/spec.md source=unstamped
seed=20260902`) during the macuahuitl meta-orchestration cycle of
2026-09-02T07:08Z. Auditor `linux-macuahuitl-fable51-20260902`.

## Question

Last properly looked at and confirmed still meaningful, useful, efficient,
sound, and complete?

## What was checked against the tree

| claim in the spec | tree | verdict |
| --- | --- | --- |
| facade contract `GuestTransport`, `GuestEndpoint`, `ExecRequest`, `ExecOutput`, `ExecChunk` in `tillandsias-control-wire::guest_transport` | all five present in `guest_transport.rs` (`pub struct ExecRequest`, `pub struct ExecOutput`, `pub enum ExecChunk`, `pub trait GuestTransport`) | holds |
| two primitives, `open_stream` + `exec`/`exec_streaming` | the `guest_transport` module docs name exactly those two (`GuestTransport::open_stream`, ExecOneShot) | holds |
| macOS VZ backend in `vm-layer` | `vz.rs`: `impl GuestTransport for VzRuntime` | holds |
| Windows WSL/hvsock backend in `vm-layer` | `transport_windows.rs`: `impl GuestTransport for WslGuestTransport` | holds |
| Linux AF_VSOCK + Unix backend "in control-wire (feature vsock)" | no `impl GuestTransport` anywhere in control-wire; only the wire | **untrue as written** — phase-1 status says "backends in progress", the sentence read as landed |
| conformance "pinned by `litmus:host-guest-transport-conformance` (per-host)" | zero litmus files by that name; the fixtures exist as Rust (`transport_conformance.rs`: `exec_echo_roundtrip`, `exec_exit_code_propagation`, …, `all_passed`, `render_report`) and a `MockTransport` | **untrue** — a spec citing a litmus that does not exist is the 709-in2f shape |
| `litmus:host-guest-no-cfg-transport-selection` enforces backend-agnostic callers | file present, bound | holds |
| four litmus files trace the spec | secure-control-wire-guest-responder-shape, vsock-unauthenticated-peer-rejected, psk-input-parity-shape, host-guest-no-cfg-transport-selection | holds |

## Disposition: **updated**

Still meaningful and sound as a contract (the facade is the thing every tray
should route through; the no-cfg litmus is real). Two sentences were corrected
in the same commit: the backend inventory now says which impls exist and that
the Linux facade impl does not, and the conformance requirement now names the
Rust fixtures that exercise it and states that no litmus binds them. Nothing
was discarded — the discard-over-repair bias does not apply to a spec whose
requirements are live and partially enforced; what was stale was the
*inventory* it asserted about the tree.

## Left open (not this audit's to fix)

- A litmus binding for the conformance fixtures (`transport_conformance.rs`)
  so the "identical across platforms" claim is gated per host, not only run
  when a developer runs the crate's tests. Candidate owner: the packet that
  lands the Linux `GuestTransport` impl (795-jeym / 798-vxj5 lineage, blocked).
- The Linux backend impl itself — tracked by the blocked vsock pair above.
