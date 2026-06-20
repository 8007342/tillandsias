---
title: Install Dart SDK for Flutter development and pub cache utilization
gap: PUB_CACHE is exported in lib-common.sh but no Dart SDK is installed to use it
category: sdk
status: proposed
proposed_at: 2026-05-29T18:00:00Z
changes:
  - file: images/default/Containerfile
    description: Add Dart SDK installation (via dartsig-linux-x64 tarball from the official stable channel, installed to /usr/lib/dart). PUB_CACHE is already exported by lib-common.sh routing pub downloads to the per-project cache.
approved_by: null
---

## Gap

The forge image exports `PUB_CACHE` (lib-common.sh:541) routing Dart/Flutter pub package downloads to the per-project cache. The `$PUB_CACHE/bin` directory should be on `$PATH` for dart pub global binaries. However, no Dart SDK is installed in the image.

Flutter SDK depends on the Dart SDK as a peer dependency. Without the Dart SDK, agents cannot:
1. Build or analyze Flutter projects (flutter analyze, flutter build)
2. Run dart pub commands for package management
3. Execute Dart scripts for build tooling or code generation

The forge-completeness-baseline audit (`plan/diagnostics/forge-completeness-baseline-2026-05-27.md`) shows the `forge-cache-dual` spec requires per-language env vars at PROMPT coverage — for Dart, the env var exists but the runtime is absent.

## Evidence

- `images/default/lib-common.sh` line 541: `export PUB_CACHE="$PROJECT_CACHE/pub"`
- `images/default/Containerfile` lines 17-24: no dart or flutter packages
- Dart SDK is available as a tarball from https://dart.dev/get-dart/archive (stable channel)

## Safety

- Dart SDK installation uses the official Google-hosted tarball (stable channel) — verified GPG-free download via HTTPS.
- PUB_CACHE already points to per-project cache; pub downloads will use the designated cache mount.
- Standard Dart SDK install to /usr/lib/dart with a symlink in /usr/local/bin.
- No credentials or secrets are involved.
