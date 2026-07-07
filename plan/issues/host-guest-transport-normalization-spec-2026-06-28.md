# Normalization Spec: Host↔Guest Transport Canon

**Status:** `pending` (blocked on research verdict)
**Owner:** linux
**Depends on:** `host-guest-transport-normalization-research-2026-06-28`
**Date:** 2026-06-28
**Kind:** enhancement (spec + facade)
**Trace:** `spec:vsock-transport`, `spec:vm-idiomatic-layer`

## Intent

Turn the research verdict into the canonical, enforced standard every platform
conforms to. One protocol, one facade, two primitives, one glossary.

## Deliverables

1. **openspec spec** `openspec/specs/host-guest-transport/spec.md` — the
   authoritative requirements: the two primitives (InteractiveStream,
   ExecOneShot), the single wire protocol (length-prefixed encode/decode,
   `WIRE_VERSION`, `MAX_MESSAGE_BYTES`, Hello/HelloAck handshake, version-skew
   behavior), and the backend-matrix contract (callers never branch on
   `cfg!(target_os)`; they request a primitive and the facade resolves the
   backend).

2. **Facade API** (location decided by research — `control-wire` or a new
   `vm-layer` module):
   ```rust
   pub struct GuestEndpoint { /* unified addressing: Linux CID/port, macOS VZ
                                 socket device, Windows WSL pipe */ }
   pub trait GuestTransport {
       async fn open_stream(&self, ep: &GuestEndpoint) -> io::Result<Stream>; // InteractiveStream
       async fn exec(&self, ep: &GuestEndpoint, req: ExecRequest) -> io::Result<ExecOutput>; // ExecOneShot
       async fn exec_streaming(&self, ep: &GuestEndpoint, req: ExecRequest, on: impl FnMut(Chunk)) -> io::Result<ExecOutput>;
   }
   ```

3. **Nomenclature glossary** — `methodology/host-guest-transport-glossary.yaml`
   (or a cheatsheet) fixing one term per concept; `hvsock` / `virtio-vsock` /
   `VZVirtioSocketDevice` are demoted to backend-impl names, not protocol names.

4. **Drift litmus** `litmus:host-guest-no-cfg-transport-selection` — fails if a
   tray/headless caller selects a transport by `cfg!(target_os)` instead of going
   through the facade (the mechanism that let the three implementations drift).

## Exit Criteria

- `openspec/specs/host-guest-transport/spec.md` authored + bound in litmus-bindings.
- Facade trait + `GuestEndpoint` + `ExecRequest`/`ExecOutput` compile on all targets.
- Glossary committed; one canonical term per concept.
- `litmus:host-guest-no-cfg-transport-selection` pinned and green.
- `./build.sh --check` passes.

## Update 2026-07-06T19:35Z — closed

All exit criteria for this spec-authoring packet are met:

- `openspec/specs/host-guest-transport/spec.md` authored (4 MUST
  requirements) and bound in `openspec/litmus-bindings.yaml`
  (`host-guest-transport` spec_id, coverage_ratio 55 -> 67).
- The `GuestTransport` facade + `GuestEndpoint` + `ExecRequest`/`ExecOutput`
  live in `tillandsias-control-wire::guest_transport`, compile on all
  targets, and are exercised by object-safety/unit tests.
- Nomenclature glossary is committed as the spec's own Nomenclature section
  (one canonical term per concept: `vsock` protocol family vs.
  `virtio-vsock`/`hvsock`/`VZVirtioSocketDevice` backend-impl names).
- `litmus:host-guest-no-cfg-transport-selection` is pinned and green (3
  grep-based steps: no backend-impl name leaks into the facade's non-comment
  lines; the trait stays `Send + Sync`/object-safe; no shared
  `tillandsias-host-shell` file branches on `cfg(target_os)`/`cfg!(target_os)`
  near `GuestTransport`/`GuestEndpoint`). Verified it actually falsifies by
  temporarily injecting a `cfg(target_os)`-gated fake transport picker into
  `host-shell/lib.rs`, confirming the litmus caught it, then reverting.
- `./build.sh --check` passes.

**Not done here, split out instead**: the "conformance fixture harness"
deliverable (`host-guest-transport.conformance.shared-fixtures@v1`) needs a
real `GuestTransport` backend to validate against. Order 125 (the Linux
AF_VSOCK backend) hasn't landed on `linux-next` yet, so writing the fixtures
now would mean inventing the `ExecOneShot` wire-mapping myself — that
decision belongs to 125, not this packet. Filed as its own pending packet,
`host-guest-transport-conformance-harness` (order 128, depends on 125), in
`plan/index.yaml` rather than stretching this packet to cover unresolved
dependencies.

## Related

- `host-guest-transport-normalization-research-2026-06-28.md` (blocker)
