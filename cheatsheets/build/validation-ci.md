---
tags: [build, ci, validation]
languages: []
since: 2026-05-03
last_verified: 2026-05-19
sources: [internal]
authority: internal
status: draft
tier: bundled
---
# Validation CI
@trace spec:enforce-trace-presence
**Use when**: Understanding CI validation and annotation enforcement.
## Provenance
- Internal documentation
- **Last updated:** 2026-05-19

## Local Validation Boundary

Verification runs locally before a release dispatch:

- `scripts/release-preflight-local.sh` fetches tags, checks version monotonicity, runs `scripts/local-ci.sh`, and optionally probes the Nix release targets.
- `scripts/local-ci.sh` owns formatting, clippy, unit tests, spec-code drift, spec-cheatsheet binding, cheatsheet tiers, litmus, and dashboard generation.

Do not run Podman runtime tests, browser e2e tests, dashboard refreshes, branch
merges, or cache warm jobs on GitHub-hosted runners. Those consume cloud minutes
and belong in the local release gate.

## Release Boundary

The hosted release workflow builds, signs, and publishes platform artifacts:

```bash
target/x86_64-unknown-linux-musl/release/tillandsias
```

The published Linux asset name is `tillandsias-linux-x86_64`. AppImage/Tauri/Node release steps are obsolete for v0.2 Linux releases.
