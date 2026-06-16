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

## Remaining Work

Rewrite or retire the existing Python-backed maintenance scripts:

- `scripts/check-cheatsheet-tiers.sh`
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
- `scripts/generate-icons.py`
- `scripts/migrate-cheatsheets-to-v2.py`

## Blocker

The checker intentionally fails until these scripts are rewritten in Rust or
explicitly approved by The Tlatoani.
