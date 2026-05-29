---
tags: [podman, containers, runtime, control-plane]
languages: [bash, rust]
since: 2026-05-18
last_verified: 2026-05-18
sources:
  - https://docs.podman.io/en/stable/
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: false
---

# Podman Control Plane

Tillandsias treats Podman as one system with one throat to choke:

```text
specs + cheatsheets
        ↓
tillandsias-podman
        ↓
tillandsias-podman-cli
        ↓
runtime / build / tests
```

- `tillandsias-podman::PodmanBackend` is the transport seam. Production uses
  `RealBackend`; fast tests use `FakeBackend`; transcript tests use
  `ReplayBackend`.
- Every invocation records operation kind, redacted argv, exit status,
  stdout/stderr, duration, and retry posture before presentation.
- Health gates use `podman wait --condition=healthy`; failed launches attach a
  diagnostics snapshot with command facts, inspect facts, and recent logs.
- Shell is allowed to bootstrap the OS and delegate to
  `scripts/tillandsias-podman`; it is not the orchestration layer.
- Launch-path shell that still creates certs or containers must either call
  `scripts/tillandsias-podman` or be recorded as an explicit bootstrap
  grandfather. Do not add fresh raw `podman` orchestration in `build.sh` or
  `scripts/run-forge-project.sh`.
- CA/cert creation that feeds Podman mounts must be serialized and published
  atomically. A container should only ever see complete cert/key files.

Verification ladder:

```text
scripts/local_test.sh  -> pure Rust model/policy
scripts/small_test.sh  -> Rust entrypoints via fake/replay backends
scripts/large_test.sh  -> real rootless Podman
scripts/full_test.sh   -> installed binary + composed user flow
```
