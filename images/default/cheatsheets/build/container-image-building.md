---
tags: [images, building, containerfile, nix, musl, deployment]
languages: [dockerfile, bash, nix, rust]
since: 260505
last_verified: 2026-05-19
sources: []
authority: internal
status: current
tier: bundled
pull_recipe: null
summary_generated_by: hand-curated
bundled_into_image: false
committed_for_project: false
---

# Container Image Building and Release Assets

@trace spec:user-runtime-lifecycle

**Use when**: Understanding how Tillandsias builds local service images, router
sidecar artifacts, and the published Linux musl release binary.

## Current Boundary

The release artifact is the Linux musl binary
`tillandsias-linux-x86_64`. AppImage/Tauri image embedding is retired for v0.2.
Container images are not published as release assets; they are built locally by
the installed binary from the repository's embedded image recipes.

## Developer Local Build

```bash
./build.sh --ci-full --install
```

The local release-recovery build:

1. Runs static validation.
2. Builds `images/router/tillandsias-router-sidecar` as a musl sidecar.
3. Builds `target/x86_64-unknown-linux-musl/release/tillandsias`.
4. Installs the binary to `~/.local/bin/tillandsias`.
5. Runs local post-build and runtime checks, including Podman-backed checks when the host runtime is healthy.

## User First Launch

After install, the user initializes local images:

```bash
tillandsias --init --debug
```

The binary builds the needed local images with Podman using the checked-in image
recipes under `images/`. Image tags are versioned with the Tillandsias version
so stale images can be detected and rebuilt.

## OpenCode Web Runtime

`tillandsias --opencode-web <project> --debug --tray` uses the local image set
and the router sidecar to launch the forge, proxy, git, inference, and browser
framework containers. This is a runtime path and is intentionally not exercised
on GitHub-hosted CI runners.

## GitHub Release Build

`.github/workflows/release.yml` performs only the release build:

```bash
scripts/build-sidecar.sh
cargo build --workspace --release --target x86_64-unknown-linux-musl --features tray
```

It validates the resulting binary is statically linked, signs the binary and
installer helpers with Cosign bundles, writes `SHA256SUMS`, and publishes the
GitHub Release. It does not build or publish container images and does not run
real Podman runtime tests.

## Related Specs

- `openspec/specs/ci-release/spec.md`
- `openspec/specs/linux-native-portable-executable/spec.md`
- `openspec/specs/podman-orchestration/spec.md`
