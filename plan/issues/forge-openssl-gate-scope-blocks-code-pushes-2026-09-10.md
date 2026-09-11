# Forge: openssl gate-scope blocks all forge code pushes (local gate cannot run green)

**Filed**: 2026-09-10T07:26Z
**Origin**: Big Pickle `/meta-orchestration` full-mode cycle on `forge-tillandsias`, branch `linux-next`
**Host**: `TILLANDSIAS_HOST_KIND=forge`, uid 1000 `forge`, no root/sudo, no podman, no `/nix`
**Classification**: blocker/process

## Summary

Since 2026-09-04/05 the Linux local gate (`./build.sh --check`) requires the
`openssl` binary at gate-scope (`missing:host-tools:linux:gate:openssl`, build.sh
step 989-ykks). A forge that (a) lacks a `/nix/store` RO mount, (b) has no root
(so `dnf`/build tooling cannot install it), and (c) has no openssl entry on the
brew shim allowlist **structurally cannot produce a green gate** — therefore
cannot push any code at all, because forges now carry the composed pre-push hook
(`pre_push=present`) that refuses any push that is not stamped by a green local
gate. Plan-only lanes (668-2xeh) still work because they accept new `plan/`
paths without a stamp, but `scripts/` and `gate-steps.d/` changes cannot ride
the lane.

The 2026-09-06 forge code push (`77ee26bdb`, fix(1022-73pk)) predates this
combination: it landed while forges still ran without composed pre-push hooks
(`plan/issues/forge-installs-no-pre-push-or-pre-commit-hooks-2026-09-02.md`),
so nothing enforced the gate on that launch. Current launch has the hook.

## Evidence

- Gate verdict: `missing:host-tools:linux:gate:openssl` at step 989-ykks
  (`scripts/test-host-tools.sh` → `scripts/check-host-tools.sh`; the `_step
  "Checking this host has the tools the gate needs (989-ykks)"` block in
  `build.sh` <!-- cite-ok: build.sh:3268-3271 is the exact step the cycle
  tripped and the location is the evidence -->), jumped straight to
  VERDICT-gate failure.
- `./build.sh --check` output captured 2026-09-10T07:19:38Z; gate stamp
  `stale:never-run`.
- openssl became linux gate-scope in `2b6302209` (fix(1042-svey),
  2026-09-04); SPEC row also touched by `255eea6b5` (2026-09-05). Packet
  `plan/index.d/20260905t003615z-build-distro-lacks-openssl-macuahuitl.yaml`
  (1042-svey) sits `ready` — it closed the WSL2 builder half
  (`scripts/with-wsl2-builder.sh` installs openssl in `provision_wsl2_distro`)
  but not the forge.
- Forge is CA-exempt **by design**: `ensure_ca_bundle` in `src/main.rs`
  early-returns when `TILLANDSIAS_HOST_KIND == "forge"` — the forge gets its CA
  injected, it does not need an openssl CLI. Requiring openssl on a forge is
  therefore an over-strict gate.
- `scripts/check-host-tools.sh` has **no forge carve-out**: its SPEC table row
  `openssl|binary|gate|linux` is unconditional. <!-- cite-ok: the line number
  of the SPEC row is the mnemonic for this exact row's location in the file -->
  build.sh forge exemptions (`_forge_check_only_without_host_podman_setup`,
  steps 600/739/753) cover only podman registry presence and dev-cache setup;
  host-tools is unconditional.
- No install path in this launch: `ls /nix` -> No such file or directory
  (`TILLANDSIAS_SHARED_CACHE=/nix/store` unset/absent mount); `dnf` requires
  root; openssl is NOT on `images/default/brew-tools-allowlist.txt` so the brew
  shim (`otool`-style wrapper) refuses to fake it; `id -u` = 1000 (forge).
- Forge image `images/default/Containerfile.base` never installs openssl. The
  image already flags the missing openssl CLI in item 2 of
  `plan/issues/forge-validation-findings-2026-07-04.md`.
- Consequence confirmed by history: every forge attestation
  2026-09-02..2026-09-06 pushed only `plan/` fragments; the single forge code
  push in that window rode an unguarded hook gap.

## Impact

Any forge launch without the `/nix` RO mount cannot land `scripts/`,
`gate-steps.d/`, or any other code path. Full-mode forge cycles on such a
launch must end `BLOCKED`, with the implemented code preserved via
`scripts/salvage-dirty-worktree.sh` and the packet left `blocked` naming the
salvage ref for a host that can gate. Implied: 1042-svey is not fully closed
for the forge host kind.

## Smallest next action

Make `check-host-tools.sh` forge-aware (skip the openssl row when
`TILLANDSIAS_HOST_KIND == forge`, mirroring the `ensure_ca_bundle` exemption), or
provision openssl in the forge image / restore the `/nix` RO mount for forge
launches. Land it from a host that can pass its own gate (macuahuitl /
lenovinha / WSL2 builder), because a code change to the gate itself is
unpushable from this forge by construction.

## Handoff affected packet

1080-4deb (ledger slug starts with `the-ledger-has-more-than-one-place…`,
`plan/index.d/20260905t200611z-1080-4deb-writes-that-reach-no-reader-macuahuitl.yaml`):
ARM 1 is implemented and verified locally (9 assertions green, gate step
`110-1080-4deb` written) but stranded at
`refs/heads/salvage/unknown/20260910-1080-4deb-arm1:94f12eeb7b2bacdc8b86e81fa43cccbb1810beda`.
It reads `blocked`; next claimer should fetch that ref and land the change.

## Resolution (2026-09-10)

Resolved on `macuahuitl`:
1. `scripts/check-host-tools.sh` is now forge-aware and skips the `openssl` gate-scope requirement when `TILLANDSIAS_HOST_KIND == "forge"`, mirroring the CA-exempt behavior in `ensure_ca_bundle`.
2. `scripts/test-host-tools.sh` added an arm verifying the forge openssl exemption.
3. The stranded ARM 1 implementation for 1080-4deb was fetched from `refs/heads/salvage/unknown/20260910-1080-4deb-arm1:94f12eeb` (`scripts/gate-steps.d/110-1080-4deb.step` and `scripts/test-ledger-write-reaches-its-reader.sh`) and passed all 9 assertions and the full local gate. Status moved back to `ready`.