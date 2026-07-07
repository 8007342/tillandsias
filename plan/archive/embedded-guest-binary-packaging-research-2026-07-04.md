# Research: embed matching guest binaries inside macOS and Windows trays — 2026-07-04

- class: research
- filed: 2026-07-04
- owner: any
- pickup_role: any
- status: obsoleted
- superseded_by: plan/issues/embedded-guest-binary-linux-build-2026-07-05.md

> TOMBSTONE 2026-07-05: research intake is preserved here, but the active
> implementation packet is order 190. New agents should not treat this file as a
> claimable ready item.

## Question

Can the macOS and Windows tray bundles ship the matching Linux guest binaries
directly, the same way the Linux build already vendors its containerfile
artifacts, so each host wrapper always talks to a guest binary built from the
same source revision?

The intended overhead is acceptable: each wrapper can include both Linux
`x86_64` and `aarch64` guest binaries if that is the simplest reliable shape.

## Why this matters

- Removes the release-latest network dependency for the guest binary.
- Prevents host/guest version skew after a release.
- Makes the macOS and Windows local smoke paths deterministic even when Wi-Fi
  is unavailable.

## Research checklist

1. Determine the smallest reliable bundle format for host-app packaging.
2. Confirm how the host launcher can select the embedded guest binary by
   `uname -m` / platform arch.
3. Identify where the current release/install flow resolves the guest binary,
   and whether that lookup can be replaced by bundle-local assets without
   breaking existing release behavior.
4. Verify the code-signing and installer implications for macOS app bundles
   and Windows installers.
5. Confirm whether the secure-control-wire handshake can then assume a matching
   guest responder version with no remote fetch.

## Exit criteria

- The packaging shape is documented with concrete paths and asset names.
- The source of truth for guest-binary selection is identified.
- The implementation packet has a clear, minimal first slice.

## Findings so far

- `ProvisionManifest` already carries `tillandsias_binary`, so the tray
  provisioning path does not need a new API to point at an embedded guest
  binary.
- The macOS guest already exposes the shared host tree at `/home/forge/src`,
  and the Windows guest already mounts the host source tree under the same
  project-root convention. That makes a host-staged guest payload feasible.
- `tillandsias-headless` already embeds its runtime containerfiles and related
  assets via `runtime_assets.rs`, so the release packaging goal is aligned with
  an existing pattern.
- This host does not currently have `rustup`/cross targets available on PATH,
  so cross-compiling Linux guest binaries from the macOS checkout is blocked
  until the Rust toolchain is installed or provided another way.
