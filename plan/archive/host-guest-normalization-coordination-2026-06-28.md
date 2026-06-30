# Cross-Host Coordination: Host↔Guest Transport Normalization

**Status:** `active`
**Filed by:** linux (coordinator), 2026-06-28
**Kind:** coordination
**Release gate:** hold release until the **macOS host completes its current work**,
then ship linux+macos+windows together.

## Why

Operator directive: stop the per-platform drift on "connect host→guest". Normalize
vsock/host-guest comms to two primitives (InteractiveStream, ExecOneShot) behind
one facade, with one protocol, one nomenclature, and **1:1 tray feature/UX parity**
across linux/macos/windows. See
`host-guest-transport-normalization-research-2026-06-28.md` (order 123).

## Sequencing (dependency-ordered)

1. **order 123** research (linux) → target architecture verdict. *Ready now.*
2. **order 124** normalization spec + facade (linux) → the enforced canon. Blocks 125/126/127.
3. **order 125** Linux backend conforms (reference) + collapse 5 exec variants.
4. **order 126** macOS VZ virtio-vsock backend conforms — **owner: osx terminal.**
5. **order 127** Windows WSL/hvsock backend conforms — **owner: windows terminal.**
6. **order 128** tray parity matrix (linux authors; each host verifies its column). *Ready now.*

Linux lands 123→124→125 first so the facade exists; osx/windows rebase onto it
for 126/127.

## Per-Host Assignments & Blockers

### Linux
- Owns 123 (ready), 124, 125, 128 (ready). Also 122 (container-dependency-graph) in_progress.
- Action now: drain 123 (research verdict) and 128 (parity matrix authoring), which
  unblock the rest.

### macOS (osx terminal)
- Owns **order 126** (blocked on 124).
- **BLOCKER (active):** rustfmt drift in osx-owned `vm-layer/src/vz.rs` is blocking
  the coordinator merge of osx-next into linux-next (see
  `coord-osx-vz-fmt-drift-2026-06-28.md`). Run `cargo fmt` on osx-next and push.
- The current macOS work (VmPhase semantic health check, exec-guest sh -c wrapping,
  live exec-guest streaming) is the "current work" the release waits on. 126 will
  supersede the bespoke exec helpers with the shared ExecOneShot primitive.

### Windows (windows terminal)
- Owns **order 127** (blocked on 124).
- `origin/windows-next` (bb1d1f9c) is an ancestor of linux-next — **stale; pull
  linux-next forward** before starting 127 so it has the P0 credential fixes +
  the normalization facade.
- Resolve `windows-next-architecture-decision-2026-05-24.md` in favor of the
  normalized facade rather than a Windows-specific protocol.

## Parity Acceptance

`order 128` produces `openspec/tray-parity-matrix.yaml` + a litmus that fails when
any `parity: required` row is not `done` on all three platforms. That litmus going
green on the `required` rows is the gate that proves normalization delivered
identical UX — and the precondition for the post-macOS release.

## Related

- orders 123–128 in `plan/index.yaml`
- `coord-osx-vz-fmt-drift-2026-06-28.md` (active osx blocker)
- supersedes/coordinates: control-socket-protocol-convergence, tray-convergence-coordination,
  optimization-macos-vz-idiomatic-exec-layer, windows-next-architecture-decision
