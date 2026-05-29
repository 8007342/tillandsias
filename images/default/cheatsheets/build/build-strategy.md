---
tags: [build, ci, reproducible-builds, local-development, release]
languages: [bash]
since: 2026-05-06
last_verified: 2026-05-20
sources:
  - https://github.com/8007342/tillandsias/blob/main/README.md
  - https://github.com/8007342/tillandsias/blob/main/openspec/specs/ci-release/spec.md
  - file://cheatsheets/runtime/user-runtime-install.md
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
committed_for_project: false
---
# Build Strategy: Local Validation and Release

@trace spec:ci-release, spec:linux-native-portable-executable, spec:user-runtime-lifecycle
@cheatsheet runtime/user-runtime-install.md, runtime/image-lifecycle.md

**Use when**: Deciding how to validate Tillandsias locally, what may run in
GitHub Actions, and which artifact the release workflow publishes.

## Current Contract

Tillandsias v0.2 is released as a Linux musl-static binary named
`tillandsias-linux-x86_64`. Tauri, AppImage, Node, WebKit packaging, and
cross-platform release jobs are retired for this release lane. The binary
embeds the runtime image contexts and materializes them on first use, so the
installed user runtime does not need a Tillandsias checkout.

## Local Release Recovery

Use the full local chain before pushing a release candidate:

```bash
./build.sh --ci-full --install
tillandsias --init --debug
tillandsias --debug --tray
```

`./build.sh --ci-full --install` builds the router sidecar, bumps the local
build version, generates traces, compiles
`target/x86_64-unknown-linux-musl/release/tillandsias` with the tray feature,
validates the binary is statically linked, installs it to `~/.local/bin`, and
runs local static plus runtime checks.

## Hosted CI Boundary

GitHub-hosted workflows are intentionally small:

| Workflow | Trigger | Purpose |
|---|---|---|
| `github-actions-convergence.yml` | push to `main`, manual | static convergence metrics |
| `ci.yml` | manual | static Rust/spec/cheatsheet validation |
| `litmus-tests.yml` | manual | litmus metadata and coverage only |
| `release.yml` | manual | build, sign, and publish the musl binary |

Do not run real Podman runtime tests, browser e2e tests, or container-backed
litmus execution on GitHub-hosted runners. Those consume cloud minutes and need
a real local runtime boundary.

## Release Artifact

The release workflow:

1. Checks out the selected ref with tags.
2. Installs Rust stable, `x86_64-unknown-linux-musl`, and `musl-tools`.
3. Runs `scripts/build-sidecar.sh`.
4. Builds the workspace with `--features tray`.
5. Validates the binary with `file`, `--version`, and a headless start/stop smoke.
6. Publishes `tillandsias-linux-x86_64`, installer scripts, `SHA256SUMS`, and Cosign bundles.

The curl installer downloads that exact asset and installs it as
`tillandsias` in a safe user-owned bin directory, usually
`~/.local/bin/tillandsias`. If that directory is not on `PATH`, the installer
writes idempotent shell startup snippets and prints the absolute command path
for immediate use.
