# Cross-Platform Build Strategy

Tillandsias v0.2 ships the Linux client runtime first. The current release
workflow publishes a single Linux x86_64 musl-static binary and helper scripts.
macOS and Windows wrappers remain planned work, not release artifacts.

## Current Release Lane

| Platform | Runner | Target | Artifacts |
|---|---|---|---|
| Linux x86_64 | `ubuntu-22.04` | `x86_64-unknown-linux-musl` | `tillandsias-linux-x86_64`, installer helpers, `SHA256SUMS`, Cosign bundles |

The release workflow builds the router sidecar, builds the musl binary with the
tray feature, validates the binary is statically linked, signs artifacts with
Cosign keyless signing, and publishes a GitHub Release.

## Local Linux Builds

```bash
./build.sh --ci-full --install
tillandsias --init --debug
tillandsias --debug --tray
```

This is the release-recovery path. It is intentionally broader than hosted CI
because it can use the real local Podman runtime.

## Hosted CI Policy

GitHub-hosted CI must remain static-only:

- formatting, clippy, unit tests, spec binding, trace drift, and cheatsheet validation are allowed;
- real Podman runtime tests, browser e2e tests, and container-backed litmus execution are not allowed;
- release publishing is manual through `.github/workflows/release.yml`.

## Planned Platforms

macOS and Windows wrappers are deferred. Any future platform release must update
this document, the release workflow, installer docs, and `openspec/specs/ci-release/spec.md`
in the same change.
