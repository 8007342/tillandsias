# No Python Runtime Policy - 2026-06-16

Status: in_progress
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

### Slice 2 — 2026-06-18

- **Rewrote** `scripts/check-cheatsheet-tiers.sh` — the shell wrapper now
  builds and dispatches the existing Rust `tillandsias-policy` binary, and the
  former embedded Python validator lives in
  `crates/tillandsias-policy/src/main.rs` as `check-cheatsheet-tiers`.
- **Refreshed trace indexes** with the Rust policy trace annotations so
  `cheatsheets-license-tiered` points at the load-bearing implementation.

## Remaining Work

Rewrite or retire the existing Python-backed maintenance scripts:

- ~~`scripts/check-cheatsheet-tiers.sh`~~ **rewritten in Rust dispatcher**
  (slice 2, 2026-06-18)
- `scripts/check-cheatsheet-sources.sh`
- `scripts/bind-provenance-local-paths.sh`
- `scripts/audit-cheatsheet-sources.sh`
- `scripts/fetch-cheatsheet-source.sh`
- `scripts/regenerate-source-index.sh`
- `scripts/regenerate-cheatsheet-index.sh`
- `scripts/distill-forge-diagnostics.sh`
- `scripts/refresh-cheatsheet-sources.sh`
- ~~`scripts/check-convergence-velocity.sh`~~ **retired to explicit no-op
  wrapper** (2026-06-18; Rust replacement still desired for real enforcement)
- ~~`scripts/check-convergence-velocity.py`~~ **retired** (slice 1 follow-up,
  2026-06-17)
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

- type: progress
  ts: "2026-06-18T05:38:00Z"
  agent_id: "linux-macuahuitl-codex-20260618T0509Z"
  host: "linux"
  note: >
    Reconciled the observability-convergence script-shape litmus with the
    retired Python checker. The litmus now pins the 5 active shell surfaces and
    requires the `check-convergence-velocity.sh` Python-retired/no-op warning.
    Targeted observability litmus passed (2/2), and the subsequent
    `./build.sh --ci-full --install` gate passed. Remaining checker output is
    now the cheatsheet/provenance/diagnostics shell scripts that still embed
    python/python3 snippets.

- type: claim
  ts: "2026-06-18T10:01:31Z"
  agent_id: "linux-macuahuitl-codex-20260618T095856Z"
  host: linux
  lease_id: "no-python-slice-2-202606181001"
  expires_at: "2026-06-18T14:01:31Z"
  note: >
    Reclaiming the expired no-Python policy packet for a narrow slice: port
    `scripts/check-cheatsheet-tiers.sh` from embedded Python to the existing
    Rust `tillandsias-policy` checker while preserving its strict/quiet
    behavior and tier-validation output.

- type: progress
  ts: "2026-06-18T10:09:38Z"
  agent_id: "linux-macuahuitl-codex-20260618T095856Z"
  host: linux
  lease_id: "no-python-slice-2-202606181001"
  note: >
    Slice 2 checkpoint: ported `scripts/check-cheatsheet-tiers.sh` to the Rust
    `tillandsias-policy check-cheatsheet-tiers` subcommand. The wrapper no
    longer embeds Python and strict tier validation still reports 210
    cheatsheets validated. Trace indexes were regenerated so the
    `cheatsheets-license-tiered` spec points at the new Rust implementation.
  files_touched:
    - crates/tillandsias-policy/src/main.rs
    - scripts/check-cheatsheet-tiers.sh
    - TRACES.md
    - openspec/specs/*/TRACES.md
  evidence:
    - cargo test -p tillandsias-policy
    - cargo clippy -p tillandsias-policy -- -D warnings
    - ./scripts/check-cheatsheet-tiers.sh --strict
    - ./scripts/check-no-python-scripts.sh still fails on the remaining
      cheatsheet/provenance/diagnostics/source-index scripts, with
      `check-cheatsheet-tiers.sh` removed from the violation list.
  next_checkpoint: >
    Continue with one of the remaining Python-backed cheatsheet/source scripts,
    preferably `scripts/check-cheatsheet-sources.sh` or
    `scripts/bind-provenance-local-paths.sh`.
