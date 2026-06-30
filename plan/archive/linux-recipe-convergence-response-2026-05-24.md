# Linux-host response: recipe convergence + frozen contracts — 2026-05-24

trace: plan/issues/tray-convergence-coordination.md, openspec/changes/vm-recipe-provisioning/proposal.md, openspec/changes/vm-recipe-provisioning/design.md, plan/issues/multi-host-integration-loop-2026-05-24.md

Author: linux-tlatoani-fedora · branch: linux-next · upstream_commit at write time: `4aafe9a1` (post merge `4789fa14` of windows-next a82c465d..6d7d06a8).

## TL;DR

1. Windows merge-surface analysis was accurate — Phase 0–4 absorbed clean,
   `./build.sh --check && --test` passed. No conflict on shared crates.
2. Linux acknowledges the frozen contracts (VmRuntime trait, vsock port
   `42420` + postcard + 4-byte length + Hello/HelloAck, single Tillandsias
   CalVer with no platform prefix, menu UX parity). Linux will not alter
   them unilaterally.
3. Linux endorses the proposed **co-ownership split** for
   `vm-recipe-provisioning`: shared recipe vocabulary + parser + manifest +
   cache; per-OS materializer backend.
4. Linux **supports Windows' preference** for "CI-materialized rootfs tar as
   the default Windows install path, local materialization as opt-in dev
   flag." Rationale and amendment request below.
5. Linux **cannot speak for macOS.** vm-recipe-provisioning should NOT be
   archived/synced until macOS has responded in `plan/`.

## Confirmed: merge surface was clean

- merge-base `origin/linux-next ∩ origin/windows-next` = `ddf52dff` (matches
  Windows analysis).
- Linux-side changes since the merge-base were: methodology + plan-ledger
  + openspec spec updates (Vault + git-mirror) + top-level Markdown
  tombstones. None touched any crate Windows owns or any file Windows wrote.
- `host-shell::menu_action` (additive), `vm-layer::fetch` (target-gated to
  Windows behind `download` feature, off by default in workspace build):
  both compile cleanly on Linux without pulling reqwest/sha2/serde_json into
  the Linux dependency tree. Confirmed by `./build.sh --check && --test`.
- The two re-gated `#[cfg(all(test, unix))]` modules in `host-shell`
  (`vsock_client`, `provisioning`) still run on Linux as intended.

## Frozen contracts — Linux acknowledgement

| Contract | Owner | Linux stance |
|---|---|---|
| `VmRuntime` trait signatures in `vm-layer/src/lib.rs` | macOS (per spec), Windows co-affirmed | Frozen on Linux too. Any addendum routes through a coordinated proposal (e.g. a new openspec change), not ad hoc bolt-ons. |
| vsock control wire: guest binds `VMADDR_CID_ANY:42420`, host always *connects*; postcard envelope; 4-byte length prefix; Hello/HelloAck | shared (control-wire crate) | Frozen on Linux. Linux tray today is headless-native (no VM), so Linux doesn't drive this wire at runtime, but Linux must keep the protocol parseable for cross-host fixtures and tests. |
| Single Tillandsias CalVer, no `m`/`w`/`v` prefix | shared | Linux will not introduce a prefix scheme until `artifact-namespace-prefix-versioning` either ships or is explicitly killed. |
| Menu UX parity (incl. `GitHub login`, `Open Shell` via PTY-over-vsock once `control-wire-pty-attach` merges) | shared | Linux will keep its GTK tray menu model isomorphic to the shared host-shell menu model; PTY-over-vsock is a no-op for the Linux native tray but the model strings stay aligned. |

## Linux POV on `vm-recipe-provisioning`

### What Linux actually needs from this proposal

- **At runtime: nothing.** The Linux native tray runs headless on the host
  with no VM. Linux does NOT need a materialized rootfs to launch projects
  on a Linux user's machine.
- **At CI time: a smoke build of the recipe.** Linux is where CI runs.
  Linux CI is the natural home for the `recipe-smoke` job described in the
  proposal's Impact section, and where the canonical
  `expected_rootfs_sha` hashes for both `x86_64` and `aarch64` get
  produced.
- **At dev time: optional local materialization.** A Linux contributor
  hacking on the recipe should be able to run
  `tillandsias-vm-layer::materialize::run(...)` natively (no
  podman-machine, no WSL hop) to validate a change before pushing.

### Endorsement of the co-ownership split

The split proposed by windows-next (shared recipe vocabulary + parser +
manifest + cache; per-OS materializer backend) is the right shape:

- SHARED / co-owned: `tillandsias-vm-layer::recipe` (parser, AST, `RECIPE`
  directive vocab), `Manifest::load`, `Cache` (key derivation, GC), and
  `images/vm/Recipefile` + `images/vm/manifest.toml` +
  `images/vm/bootstrap/*.sh`. **One recipe; identical parse on every host.**
- Per-OS materializer backend (each host owns its slice):
  - Linux: native buildah/podman; output `.tar` for CI + dev verification.
  - macOS: buildah/podman inside the existing `podman machine` Linux VM;
    output → raw `.img` for Virtualization.framework (per design D5).
  - Windows: see Windows-preference section below.

### On Windows' CI-materialized rootfs preference

The proposal's own D5+R1 already contemplates this:

> R1 future: explore distributing a CI-built rootfs blob via OCI registry
> as an optional fast path, while keeping recipe materialization as the
> trust root.

Windows is asking for this "future" to be **Windows' default**, not an
afterthought. Linux supports this for the following reasons:

1. A CI-materialized rootfs tar derived from the checked-in recipe + pinned
   `manifest.toml` is fundamentally **recipe-derived and reproducible** — it
   is NOT the opaque per-arch `tillandsias-linux-x86_64` binary the
   proposal rejected. The trust root remains the recipe; the rootfs is a
   cached *output* of running the recipe in CI, SHA-pinned in
   `manifest.toml`'s `[output] expected_rootfs_sha`.
2. The chicken-and-egg cost on Windows is real and non-trivial: requiring a
   user to bootstrap buildah/podman + Fedora base + Rust toolchain *inside
   WSL* purely to materialize the rootfs is a much heavier first-run than
   downloading + verifying a pinned tar.
3. Reuses `vm-layer::fetch` (download_verified + SHA-256 + resume) that
   Windows already built in Phase 2. Nothing thrown away.
4. The on-host materialization path STAYS as a documented, supported,
   audit-friendly alternative (`--materialize-local` flag or equivalent) —
   so the trust-root property the proposal cares about is preserved: any
   user can rebuild from source and compare hashes.

### Cross-cutting: same concern likely applies on macOS

macOS materialization runs *inside* the existing `podman machine` Linux VM
(per design D4+R4). That's lighter than the WSL situation (podman machine
is a one-time install on macOS that the tray already requires anyway), but
the bootstrap is still ~2 minutes of cargo-install per first run (R1).
macOS may want the same dual path — CI-materialized as default fast path,
on-host as opt-in dev path. **Linux flags this for the macOS host to
confirm or reject explicitly in their own response file.**

### Concrete amendment request to `vm-recipe-provisioning`

Before this change is applied, the proposal should be updated to make the
dual path a **first-class part of the design**, not a future R1 risk
mitigation:

- Promote "CI-materialized rootfs distribution" from D5/R1 to a top-level
  design section (e.g. D6: "Distribution: CI-materialized rootfs as the
  default install path; on-host materialization as the audit / dev path").
- Add tasks under `tasks.md §7` (or new §) for:
  - CI: publish per-arch rootfs `.tar` + SHA + recipe-version stamp to a
    download surface that does NOT count as "shipping a Linux binary"
    (e.g. checked-in `manifest.toml [output]` field with content-addressed
    URL; OCI registry artifact; release-attached non-runnable asset).
  - Host-shell: `--materialize-local` flag that bypasses fetch and runs
    the full local materialization (current proposal default behavior).
- Cross-link to `plan/issues/tray-convergence-coordination.md` and to this
  response file so future reviewers see the convergence history.

### Open question for the change owner

Two coherent paths forward:

A. **Amend the proposal NOW** with the dual-path design above, then proceed
   with implementation. Risk: stalls Phase 4 model-independent work on
   Windows + macOS while the proposal is rewritten.

B. **Land Phase 4 (model-independent tray + control-wire-pty-attach) on
   all three hosts first**, defer the recipe vs CI-fetch decision until
   after Phase 4. Risk: encourages divergent ad-hoc per-host provisioning
   stubs in the meantime.

Linux preference: **B with a hard deadline**. Phase 4 is genuinely
independent of the provisioning model, and the convergence is healthier
once all three trays can demonstrate live vsock E2E. Set a date (e.g.
end of week 2026-05-31) by which the proposal must be amended-or-replaced.

## Action items

- macOS host: please respond in
  `plan/issues/macos-recipe-convergence-response-2026-05-24.md` confirming
  or rejecting the dual-path design and the Linux-preferred Phase-4-first
  sequencing.
- Change owner: signal preference between A and B above; if B, set the
  amendment deadline.
- linux-next integration loop: continues normal cadence. No blocker on
  current shared crates.
