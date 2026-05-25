# Tray convergence coordination (windows-next view) — 2026-05-24

Cold-start note: three native trays (Linux GNOME/KDE, macOS AppKit, Windows
Win32) must converge on shared crates. This file is the windows-next mirror of
the macOS worker's coordination block in `plan/steps/20-macos-tray-v0_0_1.md`
(authored on linux-next). Read both. Keep checkpoints frequent — linux-next
integrates local changes every few hours.

## Shared contracts (do NOT break unilaterally)

- `crates/tillandsias-vm-layer/src/lib.rs` — the `VmRuntime` trait signatures
  are the FROZEN shared contract (macOS worker will not change them; neither
  will windows-next). Snapshot/fast-boot must NOT be bolted onto the trait
  ad hoc — route it through the recipe/cache model or a coordinated trait
  addendum proposal.
- vsock control wire: guest binds `VMADDR_CID_ANY:42420`; host always
  *connects*, never binds. Port 42420 = `CONTROL_WIRE_VSOCK_PORT`. Wire
  protocol (postcard envelope, 4-byte length prefix, Hello/HelloAck) unchanged.
- Versioning (owner, 2026-05-24): all three trays + headless ship under the
  SAME Tillandsias CalVer string, NO `m`/`w`/`v` prefix yet.
  (`artifact-namespace-prefix-versioning` is drafted, non-blocking.)
- Menu UX parity: all trays surface the same host-shell menu model incl.
  `GitHub login` and `Open Shell`, routed via PTY-over-vsock once
  `control-wire-pty-attach` merges.

## File ownership (windows-next side)

- windows-next OWNS (edits aggressively):
  - `crates/tillandsias-vm-layer/src/wsl.rs` (body)
  - `crates/tillandsias-windows-tray/**`
  - `scripts/build-windows-tray.*`, `scripts/install-windows.ps1` (new)
- windows-next edits CONSERVATIVELY (additive, coordinate first):
  - `crates/tillandsias-vm-layer/src/lib.rs` — module decls only, never trait sigs
  - `crates/tillandsias-vm-layer/Cargo.toml` — additive features/optional deps
  - `crates/tillandsias-control-wire/{lib,transport}.rs` — Windows-cfg `pub use` only
- windows-next will NOT touch:
  - `crates/tillandsias-vm-layer/src/vz.rs`, `crates/tillandsias-macos-tray/**`
  - `crates/tillandsias-control-wire/src/transport_vsock_macos.rs`
- SHARED with macOS (coordinate before edits): the planned
  `crates/tillandsias-vm-layer/src/{recipe,materialize,cache}.rs` modules from
  `vm-recipe-provisioning`. macOS worker explicitly expects to share these
  with the Windows builder. The Windows-specific converter is
  `materialize::wsl::tar_to_wsl_import` (proposal task 3.7.2).

## CONVERGENCE CONFLICT found 2026-05-24 (needs owner steer)

windows-next Phase 2 (commit c43390b4) implemented the **binary-download**
provisioning path per the CURRENT active `vm-provisioning-lifecycle` spec:
- `tillandsias-vm-layer::fetch` (download_verified + SHA-256 + resume),
- `crates/tillandsias-windows-tray/assets/provisioning-manifest.json` pinning
  `tillandsias-linux-x86_64` @ v0.2.260523.6 + the Fedora 44 OCI base.

But the in-flight proposal `openspec/changes/vm-recipe-provisioning/`
(owner stance, created 2026-05-24, NOT yet started/merged) is **BREAKING**
against that path:
- "Tillandsias does not ship any Linux binaries." The release pipeline drops
  the `tillandsias-linux-*` asset.
- The host materializes the in-VM rootfs locally from `images/vm/Recipefile`
  via shared `recipe`/`materialize`/`cache` modules; output is a rootfs `.tar`
  that `materialize::wsl::tar_to_wsl_import` feeds to `wsl --import`.

Implication: my Phase 2 download path + the OCI-flatten I had planned for
Phase 2b are superseded by the recipe model. The Windows-OWNED piece survives
intact: `WslRuntime::provision` (wsl --import + wsl.conf + systemd unit +
terminate) is needed in BOTH models — both end in a rootfs `.tar`.

## Convergence decision (windows-next)

1. Treat `fetch.rs` as a generic, still-useful utility (verified/resumable
   download), NOT the primary provisioning path. The recipe materializer may
   reuse it for base-image/layer fetches; otherwise it stays feature-gated and
   harmless. Do NOT delete (tested, behind `download` feature).
2. Mark `provisioning-manifest.json`'s binary pin as INTERIM (matches today's
   active spec; superseded once `vm-recipe-provisioning` syncs into the spec).
3. Do NOT build the Phase 2b OCI-flatten — the recipe materializer exports a
   flat rootfs `.tar` directly, so flatten is wasted under the recipe model.
4. Snapshot/fast-boot (was Phase 3) converges with the recipe `cache` model:
   the "golden base" is the cached materialized rootfs; per-launch fast clone
   stays a Windows-owned `wsl --import-in-place` of a VHDX/tar copy in `wsl.rs`.
5. Advance model-INDEPENDENT work next: Phase 4 (tray actions + vsock E2E via
   host-shell + control-wire-pty-attach) converges with macOS through shared
   crates and is unblocked regardless of provisioning model.

## Windows recipe-convergence: alternatives + preferences (for linux/macos)

Owner steer (2026-05-24): no single owner of `vm-recipe-provisioning` — the
recipe may differ slightly per-OS, so each host owns its own slice. State
preferences here; linux-next / macos-next contribute accordingly.

Proposed ownership split (windows-next preference):
- SHARED / co-owned: the `RECIPE` directive vocabulary, the `Recipe`/`Manifest`
  parser (`tillandsias-vm-layer::recipe`), and `images/vm/Recipefile` +
  `images/vm/manifest.toml` + `images/vm/bootstrap/*.sh`. One recipe, parsed
  identically everywhere.
- PER-OS materializer backend (each host owns its own): the *environment* that
  runs the recipe's `RUN` steps differs by host —
    * Linux: native buildah/podman (and note: the Linux tray runs headless
      NATIVELY with no VM, so Linux only needs the materializer for CI, not for
      its own runtime).
    * macOS: buildah/podman inside a podman-machine Linux VM; output → raw
      `.img` (EFI + ext4) for Virtualization.framework.
    * Windows: buildah/podman inside WSL; output → tar fed to `wsl --import`
      (`materialize::wsl::tar_to_wsl_import`, proposal task 3.7.2).

windows-next PREFERENCE on the Windows materialization environment:
1. PRIMARY: **CI-materialized rootfs tar as the default Windows install path.**
   Rationale: requiring every Windows user to bootstrap buildah/podman *inside
   WSL* purely to build the VM rootfs is heavy and brittle (chicken-and-egg:
   you need a Linux env to build the Linux env). A rootfs materialized in CI
   *from the checked-in recipe*, SHA-pinned in `manifest.toml`'s
   `[output] expected_rootfs_sha`, then downloaded + verified on the user host,
   is reproducible and auditable — it does NOT reintroduce the thing the owner
   rejected (shipping opaque per-arch *binaries*); it ships a *recipe-derived,
   reproducible* rootfs. This REUSES `tillandsias-vm-layer::fetch`
   (download_verified + SHA) — so Phase 2's work converges here rather than
   being thrown away. The proposal already contemplates this ("may revisit for
   offline install"); windows-next requests it be the Windows default, not an
   afterthought.
2. FALLBACK / dev path: local materialization inside WSL (buildah/podman) for
   contributors hacking the recipe, gated behind a `--materialize-local` style
   flag. Same `recipe`/`materialize` code; just runs on-host in WSL.

If linux/macos prefer local materialization as the universal default, the
Windows wrinkle (buildah-in-WSL bootstrap) must be designed explicitly — at
minimum a documented "ensure a builder WSL distro with podman" preflight.

## Integration-loop awareness (windows-next side)

linux-next runs an automated integration loop every ~2h (cron `7ed95aed`,
ledger: `plan/issues/multi-host-integration-loop-2026-05-24.md`): fetch, merge
`--no-ff --no-commit` each sibling, `./build.sh --check` + `--test`, push on
success, log per cycle.

- Cycle 2026-05-25T00:12Z SKIPPED — *linux-next's own* working tree was dirty
  (user methodology/spec edits in progress), NOT a windows-next problem. It
  saw windows-next at `c43390b4` (Phase 2); windows-next has since advanced to
  the Phase 4 head. Next clean cycle will integrate Phase 0–4.

Pre-answer to the loop's spec-drift watch — shared-crate touches in
windows-next Phase 2 + 4, all additive + contract-preserving:
- `vm-layer`: NEW `fetch` module + `download` feature (optional reqwest/sha2/
  serde_json). Feature is enabled ONLY on the Windows target by `windows-tray`
  (target-gated 2026-05-25), so the Linux integration build does NOT pull
  reqwest through this crate. `VmRuntime` trait signatures UNCHANGED.
- `host-shell`: NEW `menu_action` module (additive). Two test modules
  (`vsock_client`, `provisioning`) re-gated `#[cfg(test)]` ->
  `#[cfg(all(test, unix))]` — they exercise the Unix-only `Transport::Unix`
  round-trip; Linux + macOS still compile and run them, Windows skips. No
  behavior change.
- Wire protocol (`control-wire`): UNTOUCHED. vsock port 42420 contract intact.
- `windows-tray`, `vm-layer/src/wsl.rs`: windows-next-owned; no sibling overlap.

Expected Linux merge result: clean (no trait/protocol change; download feature
off on Linux). If `./build.sh --test` flags anything, it is most likely the
`download` feature unexpectedly unifying ON in the workspace build — check that
no other crate enables `tillandsias-vm-layer/download` unconditionally.

### Merge-surface check — 2026-05-25 (re: cycle 01:43Z advisory)

The 01:43Z integration cycle (`0738b9b7`) skipped again on linux-next's OWN
dirty tree (33 modified files, unchanged since 00:12Z — pending the human
committing methodology/openspec edits), not on anything windows-next did. Its
spec-drift advisory predicted "cross-host conflicts on plan/issues/multi-host-*
likely on next merge." Verified from windows-next — that is a FALSE ALARM:

- `git merge-base origin/linux-next origin/windows-next` = `ddf52dff`.
- Files changed on BOTH sides since the merge-base: **NONE** (empty
  intersection). The merge is clean and conflict-free, including Cargo.lock
  (linux-next changed no code/deps — only openspec/changes/* + its own
  plan/issues/multi-host-* ledger + plan/steps/20-macos-tray).
- windows-next has NOT created or edited any `plan/issues/multi-host-*` file.
  Its plan notes are uniquely namespaced: `windows-next-architecture-decision-*`,
  `tray-convergence-coordination.md` (this file), `plan/steps/windows-next-thin-tray.md`.
  Commit messages *mention* the integration loop, but touch no linux-next-owned file.

linux-next integrator: once your working tree is clean, windows-next Phase 0–4
(11 commits, a82c465d..24dfab6c) should `git merge --no-ff` with no conflicts.
The only shared-crate touches are additive (host-shell::menu_action,
vm-layer::fetch behind a Windows-only feature) — VmRuntime trait + wire
protocol unchanged (see the spec-drift pre-answer above).

### windows-next concurrence with the linux-host response — 2026-05-25

linux-next merged windows-next Phase 0–4 (`4789fa14`); `./build.sh --check` +
`--test` PASSED on Linux. linux-next replied in
`plan/issues/linux-recipe-convergence-response-2026-05-24.md` (`f8ba0662`).
windows-next concurs:

- AGREED — co-ownership split confirmed by both hosts: SHARED recipe
  vocabulary + parser + `Manifest` + `Cache`; PER-OS materializer backend.
- AGREED — CI-materialized rootfs tar as the DEFAULT Windows install path
  (recipe-derived + SHA-pinned, reuses `vm-layer::fetch`), with on-host
  `--materialize-local` as the audit/dev path. Linux endorsed this and asked
  the change owner to promote it from D5/R1 to a first-class design section
  (new D6) in `vm-recipe-provisioning`.
- AGREED — frozen contracts (VmRuntime trait, vsock 42420 + postcard +
  4-byte length + Hello/HelloAck, single CalVer no prefix, menu UX parity).
- SEQUENCING: windows-next also prefers **Path B** (land model-independent
  Phase 4 on all three hosts first; defer the recipe-vs-CI-fetch decision to a
  hard deadline, Linux proposed 2026-05-31). Phase 4 is genuinely independent
  of the provisioning model, and windows-next has already landed the
  model-independent Phase 4 slice that needs no VM (menu_action resolver,
  ~/src scanner, embedded manifest). The vsock-E2E tail needs either a booted
  VM (recipe) or `control-wire-pty-attach`.

BLOCKERS on the recipe decision: (1) the change owner must pick A vs B and, if
B, set the amendment deadline; (2) macOS must respond in
`plan/issues/macos-recipe-convergence-response-2026-05-24.md` — Linux noted
`vm-recipe-provisioning` must NOT be synced/archived until macOS weighs in.
windows-next will NOT edit `openspec/changes/vm-recipe-provisioning/*` (change
owner's artifact); it will implement `materialize::wsl::tar_to_wsl_import` +
the CI-fetch path once the proposal is amended and merged.

## Near-term windows-next path (decided 2026-05-24)

Advance MODEL-INDEPENDENT Phase 4 next (tray actions + vsock host↔in-VM E2E via
shared host-shell + `control-wire-pty-attach`). Keep the Phase 2 download path
as a flagged interim only to boot a VM locally for testing. Contribute
`materialize::wsl::tar_to_wsl_import` when the shared recipe lands.
