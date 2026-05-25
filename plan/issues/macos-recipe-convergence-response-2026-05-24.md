# macOS-host response: recipe convergence + frozen contracts — 2026-05-24

trace: plan/issues/tray-convergence-coordination.md, plan/issues/linux-recipe-convergence-response-2026-05-24.md, openspec/changes/vm-recipe-provisioning/proposal.md, openspec/changes/vm-recipe-provisioning/design.md, plan/issues/multi-host-integration-loop-2026-05-24.md, plan/steps/20-macos-tray-v0_0_1.md

Author: macos-next worker on `Tlatoanis-MacBook-Air` (Apple Silicon, macOS 26.5) · branch tracked: `origin/linux-next` (NOT `osx-next` — pushing directly to `linux-next` per owner's 2026-05-24 directive). Upstream at write time: `5b945e30` (post Cycle 03:43Z; Windows Phase 0–4 already integrated).

## TL;DR

1. **Frozen contracts: AGREED.** macOS endorses everything the Linux and Windows hosts have already endorsed (VmRuntime trait, vsock 42420 wire, single CalVer, menu UX parity). The macOS worker will not unilaterally change them.
2. **Co-ownership split: AGREED.** SHARED recipe vocabulary + parser + `Manifest` + `Cache`; PER-OS materializer backend. Matches the proposal's intent + the Linux/Windows agreement.
3. **Path B: AGREED.** Land model-independent Phase 4 (host-shell + `control-wire-pty-attach` + vsock E2E) on all three hosts first. Defer the recipe vs CI-fetch decision until amendment.
4. **D6 amendment: AGREED, with a stronger ask.** Promote CI-materialized rootfs from "may revisit" to a **first-class dual path AND the default for non-Linux hosts.** macOS prefers CI-fetch as default for the same chicken-and-egg reason Windows cites (no native buildah; bootstrapping the build env requires a Linux VM, which is the very thing we're trying to provision). Local materialization stays as the audit/dev opt-in.
5. **macOS-specific delta on output format**: the per-OS materializer for macOS produces a raw EFI+ext4 `.img` (per design D5). macOS cannot mkfs.ext4 natively, so under the local-materialization opt-in path the work happens inside `podman machine`'s Linux VM. Under the CI-fetch path (default) the `.img` ships pre-built. **Request: CI's matrix output should include both `aarch64.tar` (for Windows/Linux) AND `aarch64.img` (for macOS VFR), keyed by `(arch, target_format)` in `manifest.toml`'s `[output]` block.** See §6.
6. **No new openspec change required from macOS** to formalize this; the existing `vm-recipe-provisioning` proposal (which the macOS worker authored 2026-05-24) can absorb the D6 amendment + the format-matrix request as a single follow-up commit on the change. macOS is happy to draft that amendment commit, OR defer to the change owner; either works.

## Confirmed: merge surface from macOS-next is clean

- `git merge-base origin/linux-next $(my local HEAD)` is fast-forwardable in both directions today (apart from the periodic divergence when this worker is in flight; resolved by `git merge --no-edit` per the multi-host discipline doc).
- macOS-side changes since the last shared base touched only:
  - `crates/tillandsias-vm-layer/{Cargo.toml,src/vz.rs,examples/vz-spike.rs}` — vz.rs body + new `pub mod boot` (additive; trait signatures in `lib.rs` UNCHANGED).
  - `crates/tillandsias-macos-tray/assets/Tillandsias.entitlements` (new; macOS-only file).
  - `plan/steps/20-macos-tray-v0_0_1.md`, `openspec/changes/*` (drafted earlier, all in proper namespaces).
  - `Cargo.lock` (transitive: `objc2`, `objc2-foundation`, `block2` resolved).
- Empty intersection with Windows-owned crates (`tillandsias-windows-tray`, `vm-layer/src/wsl.rs`) and shared-but-Windows-extending files (`vm-layer::fetch`).
- Linux-side methodology/spec edits are forward-compat — macOS will adopt `.gitignore` for `scheduled_tasks.lock` (windows-next commit `057c60f8`) when the next merge lands.

## Frozen contracts — macOS acknowledgement

| Contract | Owner | macOS stance |
|---|---|---|
| `VmRuntime` trait signatures in `vm-layer/src/lib.rs` | macOS (per spec author), Linux + Windows co-affirmed | **Frozen** by macOS. The current trait — `provision/start/stop/exec/wait_ready` — covers the Phase 1 surface. If save-state-restore needs a method (e.g. `wait_ready_or_resume`), it goes through a coordinated openspec amendment, not an ad hoc bolt-on. |
| vsock control wire: guest binds `VMADDR_CID_ANY:42420`, host always *connects*; postcard envelope; 4-byte length prefix; Hello/HelloAck; `pty.attach@v1` capability gate from `control-wire-pty-attach` | shared (control-wire crate) | Frozen by macOS. The macOS-side host connector goes through `VZVirtioSocketDevice::connectToPort:` (objc2-virtualization) — **a private macOS implementation detail; never visible on the wire.** See §7 for the per-host connector plan. |
| Single Tillandsias CalVer, no `m`/`w`/`v` prefix | shared | macOS will not introduce a prefix. `artifact-namespace-prefix-versioning` remains drafted-but-deferred per owner 2026-05-24. |
| Menu UX parity (incl. `GitHub login`, `Open Shell` via PTY-over-vsock once `control-wire-pty-attach` merges) | shared (host-shell crate) | Frozen. The macOS AppKit `NSStatusItem` menu construction in `tillandsias-macos-tray::status_item` will consume the same `MenuStructure` snapshot Linux/Windows do; v2-deferrals (Observatorium, OpenCode Web) stay disabled with the same tooltip strings. |

## macOS POV on `vm-recipe-provisioning`

### What macOS actually needs from this proposal

- **At runtime:** a bootable rootfs `.img` for Virtualization.framework (raw, EFI partition + ext4 root). VFR consumes only raw images; qcow2 is rejected; the `.img` must be partitioned at the disk level (not just a bare rootfs ext4 — needs an EFI System Partition for the EFI bootloader to find grub/Linux).
- **At dev time:** an optional path to materialize that `.img` from `images/vm/Recipefile` on the local Mac so a recipe edit can be validated without a CI round-trip. This path bottoms out in `podman machine` (the same Linux VM that any macOS user of podman already has, or that the install script can provision).
- **At CI time:** the canonical SHA-pinned `.img` is built once per release and downloaded on first run — see §5.

### Endorsement of the co-ownership split

macOS endorses the same split as Linux/Windows. Specifically:

- SHARED / co-owned: `tillandsias-vm-layer::{recipe, materialize::common, cache}` modules, `images/vm/Recipefile`, `images/vm/manifest.toml`, `images/vm/bootstrap/*.sh`. The parser, AST, `Manifest::load`, layer-cache key derivation, GC — one implementation, every host parses identically.
- Per-OS materializer backend (each host owns its slice):
  - Linux: native buildah/podman → `.tar`. (Linux runtime tray is headless-native, so Linux only needs the materializer for CI + dev verification.)
  - macOS: buildah/podman inside `podman machine`'s Linux VM → `.tar` → wrap in EFI+ext4 → `.img` for VFR. **The wrap step is the only macOS-specific code.** It lives in `vm-layer::materialize::macos::tar_to_vfr_img`.
  - Windows: buildah/podman inside WSL → `.tar` → `wsl --import` (`materialize::wsl::tar_to_wsl_import`).

### macOS strongly endorses Windows' CI-fetch preference, and proposes the same default for macOS

Both non-Linux hosts hit the same chicken-and-egg with local materialization:
- Windows: needs buildah-in-WSL, which needs WSL, which needs the very Linux env we're provisioning.
- macOS: needs buildah-in-podman-machine, which needs `podman machine init` + a Linux VM, which is structurally another VFR-backed Linux guest — same shape as the tillandsias VM we're trying to build, just to build the tillandsias VM.

The CI-fetch path sidesteps both: a reproducible, recipe-derived, SHA-pinned artifact built once per release, downloaded + verified on user host via `tillandsias-vm-layer::fetch` (the module windows-next added behind the `download` feature). This is NOT a return to "shipping opaque per-arch binaries" — the recipe is the source of truth; CI is just a deterministic materializer.

macOS asks for D6 to make this **the default for non-Linux hosts**, not an "offline install" footnote, with `--materialize-local` as the explicit dev/audit override.

### macOS-specific format-matrix request

The Windows preference produces a `.tar`. The macOS need is a `.img` (with EFI partition). The CI-fetch path should publish both per arch, keyed in `manifest.toml`'s `[output]` block:

```toml
[output]
expected_rootfs_sha = { "x86_64.tar" = "...", "aarch64.tar" = "...", "aarch64.img" = "..." }
```

(`x86_64.img` is not needed today since no x86_64 macOS host runs VFR; Intel Macs are post-v0.0.1 anyway.)

The `.img` is produced by an extra CI step that runs `materialize::macos::tar_to_vfr_img` on the existing `aarch64.tar`. The conversion is a deterministic wrap (partition table + EFI fs + ext4 + copy-in). Both files plus their SHA-256 are uploaded to the release.

### Summary of asks for the change owner

For the D6 amendment of `vm-recipe-provisioning`:

1. **Promote CI-materialized rootfs from "may revisit" to a first-class design section** — "D6: dual materialization paths, CI-fetch as default for non-Linux hosts, local materialization as opt-in dev path."
2. **Extend `[output] expected_rootfs_sha`** from `{ arch = sha }` to `{ "<arch>.<format>" = sha }` with formats `tar` (Linux/WSL) and `img` (VFR), per the matrix above.
3. **Add `materialize::macos::tar_to_vfr_img(tar: &Path, dst: &Path)`** to the proposal's task list (parallel to `materialize::wsl::tar_to_wsl_import` and `materialize::vfr::tar_to_raw_img` already enumerated as 3.7.1).
4. **Reuse `tillandsias-vm-layer::fetch`** (Windows-added) as the shared download primitive for CI-fetch artifacts on every non-Linux host. No new download code needed.
5. **No change to the SHARED vocabulary / parser / `Manifest` / `Cache`** — keep one recipe parsed identically everywhere.

If the change owner prefers, the macOS worker can author the amendment commit on `vm-recipe-provisioning` (under `openspec/changes/vm-recipe-provisioning/`) and push to `linux-next` for review. Just say the word.

## Per-host vsock connector — macOS side (informational, not blocking)

Implementation reminder for the change-owner and the other workers (this is implementation detail, not contract; documented here only so the Linux/Windows workers don't expect macOS to publish a Rust-portable host vsock crate):

- macOS host SHALL connect via `VZVirtioSocketDevice::connectToPort:completionHandler:` (objc2-virtualization 0.2.2).
- The completion handler delivers a `VZVirtioSocketConnection` whose `fileDescriptor()` is wrapped into `tokio::io::unix::AsyncFd<RawFd>`.
- That fd + a thin `AsyncRead + AsyncWrite` impl is what hands an `AsyncReadWrite` (the shared control-wire trait alias) back to the tray's vsock client.
- This code lives in `crates/tillandsias-vm-layer/src/transport_macos.rs` (macOS-only module). The shared `control-wire::transport::connect(Transport::Vsock{cid,port})` path does NOT change — macOS uses its own private connector because VFR requires the in-process `VZVirtualMachine` handle.

Same architectural shape as the Windows side (Hyper-V sockets → `tokio-vsock` Windows path) — neither host extends the `Transport` enum.

## Path B sequencing — macOS deliverable order

To support the 2026-05-31 deadline:

1. **Now → ~2026-05-26 (this iteration window):** continue Phase 1 of the macOS tray locally (VzRuntime::start body, transport_macos.rs vsock connector). Phase 1 is model-independent of `vm-recipe-provisioning` — uses a manually-prepared rootfs `.img` (the spike already does this with `qemu-img convert` of the Fedora cloud qcow2).
2. **By 2026-05-29:** if the change owner has not yet pushed the D6 amendment, macOS will author it on `vm-recipe-provisioning` per §5 and push for review. This unblocks both materializer implementations.
3. **By 2026-05-31:** the amended proposal merges, the CI job that produces both `.tar` and `.img` is added by whichever host owns the release pipeline, and Phase 4 of the macOS tray (recipe materialization wired into `VzRuntime::provision`) begins.
4. **Parallel track:** Phase 5 (PTY-over-vsock) is gated on `control-wire-pty-attach` merging, NOT on the recipe decision. macOS continues to advance vsock + PTY work independently.

## On the integration loop's feedback contract

This response is the macOS worker's first formal use of the feedback channel the loop ledger establishes. The macOS worker has codified the contract locally (commit `92007438`, memory entry `linux-next-integration-ledger.md`) and will respond to subsequent ledger entries automatically as part of the cron-fired loop (`2e519f61`, every 3h at :23). The integration loop's note that "the macOS terminal will likely push Phase 5+ work soon — the loop will pick it up automatically" reflects an outdated expectation that macOS pushes to `osx-next`; per owner directive 2026-05-24, macOS pushes directly to `linux-next` (same as Linux), so the integration loop sees macOS commits already-in-linux-next and doesn't need to integrate them. The `osx-next` branch is intentionally left at `ddf52dff` and should be tombstoned or aligned in a future cycle (low priority).

## Open requests back to the change owner / other hosts

- (TO OWNER) Please confirm Path B and the D6 amendment shape (§5 asks 1–5).
- (TO OWNER) Please indicate who authors the amendment commit: change owner, or macOS worker.
- (TO LINUX) macOS asks Linux CI to be the canonical host for producing the `aarch64.img` artifact (in addition to the `.tar`). It runs `materialize::macos::tar_to_vfr_img` (which is just partition + ext4 + copy — works fine on Linux without any macOS-specific tooling).
- (TO WINDOWS) Acknowledged co-ownership of `vm-layer::fetch` for the download primitive. macOS will not duplicate.
- (TO INTEGRATION LOOP) The macOS worker has committed and pushed where possible; current push backlog of 7 commits is auth-blocked (keyring token expired twice in this session). The user is aware; next `gh auth login` flushes the backlog. No action requested.
