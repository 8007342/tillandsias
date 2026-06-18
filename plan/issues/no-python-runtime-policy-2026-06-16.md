# No Python Runtime Policy - 2026-06-16

Status: active
Owner: linux-next

## Policy

The Tlatoani has a hard-no policy on Python for Tillandsias runtime and
repository scripts. One-off Python use must not be copied into committed
harnesses, skills, litmus tests, or recurring automation. Use Rust for real
programs.

## Completed This Pass

- Removed Python from the `codex` launcher.
- Replaced `observatorium.sh`'s `python3 -m http.server` dependency with the
  Rust `tillandsias-static-server` binary.
- Added the Rust `tillandsias-policy` checker and
  `scripts/check-no-python-scripts.sh`.
- Added the policy to `methodology.yaml`.

## Slices Completed

### Slice 1 — 2026-06-17

- **Retired** `scripts/migrate-cheatsheets-to-v2.py` — one-shot migration,
  already executed for the full cheatsheet tree. File removed.
- **Retired** `scripts/generate-icons.py` — icon generation was a Tauri-era
  artifact; icons are now OS-native tray assets, not generated PNG blobs.
  File removed.

## Remaining Work

Rewrite or retire the existing Python-backed maintenance scripts:

- ~~`scripts/check-cheatsheet-tiers.sh`~~ **rewritten** (slice 2, 2026-06-18) →
  thin wrapper over Rust `tillandsias-cheatsheet-tools tiers`
- `scripts/check-cheatsheet-sources.sh`
- `scripts/bind-provenance-local-paths.sh`
- `scripts/audit-cheatsheet-sources.sh`
- `scripts/fetch-cheatsheet-source.sh`
- `scripts/regenerate-source-index.sh`
- `scripts/regenerate-cheatsheet-index.sh`
- `scripts/distill-forge-diagnostics.sh`
- `scripts/refresh-cheatsheet-sources.sh`
- `scripts/check-convergence-velocity.sh`
- `scripts/check-convergence-velocity.py`
- ~~`scripts/generate-icons.py`~~ **retired** (slice 1, 2026-06-17)
- ~~`scripts/migrate-cheatsheets-to-v2.py`~~ **retired** (slice 1, 2026-06-17)

## Events

- type: claim
  ts: "2026-06-17T22:15:00Z"
  agent_id: "linux-tlatoani-big-pickle-202606172215"
  host: linux
  lease_id: "no-python-slice-1-202606172215"
  expires_at: "2026-06-18T02:15:00Z"

- type: progress
  ts: "2026-06-17T22:16:00Z"
  agent_id: "linux-tlatoani-big-pickle-202606172215"
  host: linux
  note: >
    Slice 1: Retired scripts/migrate-cheatsheets-to-v2.py (one-shot migration,
    already executed) and scripts/generate-icons.py (Tauri-era icon generator;
    tray now uses pre-committed assets). 2 less scripts to handle. Validated
    with ./build.sh --check.

## Blocker

The checker intentionally fails until these scripts are rewritten in Rust or
explicitly approved by The Tlatoani.

- type: progress
  ts: "2026-06-17T23:57:00Z"
  agent_id: "linux-tillandsias-gemini-cli-2026-06-17T2220Z"
  host: "linux"
  note: >
    Retired check-convergence-velocity.py. The shell wrapper is now a
    no-op stub. 3 down, 10 to go. Commit cae63645.

- type: claim
  ts: "2026-06-18T04:21:00Z"
  agent_id: "linux-tlatoani-opus-202606180421"
  host: linux
  lease_id: "no-python-slice-2-202606180421"
  expires_at: "2026-06-18T08:21:00Z"

- type: progress
  ts: "2026-06-18T04:22:00Z"
  agent_id: "linux-tlatoani-opus-202606180421"
  host: linux
  note: >
    Slice 2: Rewrote scripts/check-cheatsheet-tiers.sh as a thin wrapper over a
    new Rust crate `tillandsias-cheatsheet-tools` (subcommand `tiers`). Faithful
    port of the former Python frontmatter parser, tier validation, pull-on-demand
    section checks, CRDT override discipline, and flake.nix/Containerfile package
    discovery. Wrapper locates target/{release,debug} binary or falls back to
    `cargo run`. Validated: `cargo build -p tillandsias-cheatsheet-tools` clean;
    `scripts/check-cheatsheet-tiers.sh` reports 210 cheatsheets validated, exit 0.
    4 down, 9 to go.
