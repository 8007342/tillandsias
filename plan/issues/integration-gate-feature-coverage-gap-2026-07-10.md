# Integration gate has zero coverage of non-default-feature units

- **Filed**: 2026-07-10T00:25Z
- **Agent**: linux-macuahuitl-fable5-20260710T0009Z (meta-orchestration cycle)
- **Classification**: enhancement
- **Status**: open — vm-layer instance fixed; generalization is a bar-raise candidate
- **Related**: order 254 (listen-vsock CI lane — one instance of this class),
  plan/issues/windows-workspace-cargo-check-gap-2026-07-09.md (per-host variant),
  plan/issues/linux-audit-recent-work-2026-07-09.md F9 (verdict discipline)

## What

`./build.sh --check` runs `cargo check --workspace` and
`cargo clippy --all-targets -- -D warnings` with **default features only**.
Every unit behind a non-default feature is never type-checked, linted, or
(via `--test`, same default-features shape) tested by the Integration
Verification Gate. Known instances of the class:

| Crate | Uncovered features | Consequence observed |
|---|---|---|
| tillandsias-headless | `listen-vsock` (+ `tray` on non-tray lanes) | order 254: 13 warnings + 2 drifted tests; as of 2026-07-10 the sweep shows 9 `-D warnings` errors (main.rs 8093-8101, pty_handler.rs 34/120/220/222, cloud_projects.rs 142, remote_projects.rs 197) |
| tillandsias-vm-layer | `fake`, `download`, `recipe`, `materialize` | 3 `clippy::ptr_arg` in fake.rs test helper accumulated unseen; fixed f39f79e4. materialize-cli bin (`required-features`) never compiled by the gate |
| tillandsias-windows-tray / macos-tray | n/a (cfg-target) | windows keeps fixing "clippy warnings invisible to Linux CI" ad hoc (2abcb30) — same class, cfg-target variant tracked in windows-workspace-cargo-check-gap-2026-07-09.md |

## Why this makes us slower

1. Sibling hosts inherit lint debt invisibly and burn cycles fixing it ad hoc
   at merge time (2abcb30, f39f79e4, order 254's 13-warning burn-down).
2. A green `--check` on the coordinator does NOT mean the merged tree is
   green for the host that will actually build the feature (in-VM guest
   builds use `listen-vsock`; tray builds use `tray`) — trunk-red risk
   surfaces only at build/install e2e time, the most expensive detection
   point.
3. Verification session 2026-07-10T00:12Z spent ~15 min disproving a
   suspected cargo-freshness false-green before identifying feature gating
   as the cause; the same confusion will recur for any agent who assumes
   `--workspace` means "all code".

## Evidence

- Injection test: appending garbage to
  `crates/tillandsias-vm-layer/src/materialize/oci.rs` and running
  `cargo check --workspace` → exit 0, zero recompiles (the file is not in
  any default unit graph).
- `cargo clippy --workspace --all-targets --all-features -- -D warnings`
  on f39f79e4: exit 101, all remaining errors in tillandsias-headless
  (order 254 scope). `cargo test --workspace` (default): exit 0, 66 suites
  green.

## Proposed reduction (bar-raise candidate — requires The Tlatoāni's approval)

Extend the Integration Verification Gate with a feature-matrix lane, staged
per migration discipline (flag → soak → default):

1. Slice 1 (already a ready packet): order 254 adds `--features listen-vsock`
   clippy+test for headless.
2. Slice 2 (this proposal): add
   `cargo clippy --workspace --all-targets --all-features -- -D warnings`
   to `--ci-full` (NOT `--check`) once 254 lands and the sweep is green,
   so the deep lane runs where litmus/cheatsheet gates already live.
3. Slice 3 (optional): promote to `--check` after a soak period with zero
   red cycles, if wall-time cost is acceptable (~1 cold workspace pass).

Do NOT enable slice 2/3 without recorded approval — the scan bar is
Tlatoāni-gated (methodology/convergence.yaml bar_raise_governance). Until
then, agents verifying cross-host merges should run the vm-layer/headless
feature lanes manually when merged files live under feature gates.

## Verifiable closure

`./build.sh --ci-full` (or `--check` if slice 3 approved) fails on a
deliberately introduced warning inside a non-default-feature unit
(negative control), and passes on the clean tree (positive control).

## APPROVED (slice 2) — 2026-07-10

The Tlatoāni approved slice 2 on 2026-07-10 ("I approve — record it").
Recorded in `methodology/convergence.yaml` `approved_bar_raises`
(id `ci-full-all-features-clippy`) and implemented as plan order 266:
`rust-clippy-all-features` in `scripts/local-ci.sh`, non-fast pre-build
phase only (`--ci-full`; skipped under `--ci`/`--fast`). Baseline sweep was
green at enablement (exit 0 — order 254's in-forge fix cleared the last
failures). Slice 1 had already landed via order 254. **Slice 3 (promotion
into `--check`) remains unapproved** and needs its own recorded decision.
