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

## Related

- `host-guest-transport-normalization-research-2026-06-28.md` (blocker)
