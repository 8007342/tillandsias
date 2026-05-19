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

## Hosted CI Boundary

GitHub-hosted workflows are for static validation only:

- `github-actions-convergence.yml` runs automatically on `main` and covers formatting, clippy, unit tests, spec-code drift, spec-cheatsheet binding, and cheatsheet tiers.
- `ci.yml` is manual and uses the same static boundary plus focused binary unit tests.
- `litmus-tests.yml` validates litmus metadata and coverage only.

Do not run real Podman runtime tests, browser e2e tests, or `scripts/run-litmus-test.sh` on GitHub-hosted runners. Those belong in local release recovery or a dedicated runtime environment.

## Release Boundary

The release workflow builds and publishes the Linux musl artifact:

```bash
target/x86_64-unknown-linux-musl/release/tillandsias
```

The published asset name is `tillandsias-linux-x86_64`. AppImage/Tauri/Node release steps are obsolete for v0.2 Linux releases.
