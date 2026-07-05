# Research: embed matching guest binaries inside macOS and Windows trays — 2026-07-04

- class: research
- filed: 2026-07-04
- owner: any
- pickup_role: any
- status: ready

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

