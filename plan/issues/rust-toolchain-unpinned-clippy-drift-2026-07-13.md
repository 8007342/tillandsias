# Unpinned Rust toolchain: new stable clippy breaks fresh hosts while established hosts stay green

- filed_by: linux-yolanda-fable5-20260713T1058Z (meta-orchestration drain, fresh Silverblue host)
- date: 2026-07-13
- status: ready
- kind: enhancement
- classification: optimization/
- capability_tags: [build, toolchain, ci, portability]
- owner_host: any

## Problem

The repo has no `rust-toolchain.toml`, so every host builds with whatever
`rustup` stable it happens to have. A freshly provisioned host installs the
latest stable — today Rust 1.97.0 — and `./build.sh --check` runs clippy with
`-D warnings`, so every NEW clippy lint instantly breaks fresh hosts on code
that established hosts (older toolchains) still pass green.

## Evidence (2026-07-13, host yolanda, first-ever build)

The first `./build.sh --check` on this pristine Silverblue host failed twice
on lints that do not fire on the sibling hosts' toolchains:

1. `clippy::manual_filter` (new in recent clippy) —
   `crates/tillandsias-headless/src/main.rs` (`run_evidence_bundle_retention`,
   repo_root chain). Fixed on linux-next 2026-07-13.
2. `clippy::useless_borrows_in_formatting` (new in 1.97) — 9 sites in
   `crates/tillandsias-router-sidecar/tests/caddy_reload_integration.rs`.
   Fixed on linux-next 2026-07-13.

Both fixes are semantics-preserving, but the class recurs on every clippy
release: the trunk is only "green" relative to the oldest toolchain still in
the fleet, and a brand-new host cannot get a green gate on an untouched
checkout — which also poisons first-cycle e2e/litmus evidence.

## Verifiable constraint (exit criteria)

- A committed `rust-toolchain.toml` pins the workspace toolchain (channel +
  components clippy/rustfmt), OR methodology explicitly records the decision
  to track latest-stable with a scheduled lint-debt drain.
- `scripts/with-tillandsias-builder.sh` provisioning honors the pin (rustup
  respects rust-toolchain.toml automatically once present).
- A fresh-host `./build.sh --check` on an untouched checkout passes without
  code edits (the exact scenario that failed 2026-07-13).

## Smallest next action

Decide pin-vs-track (coordinator/operator call, affects all hosts + CI), then
add `rust-toolchain.toml` and roll it to sibling branches via the normal
integration merges.
